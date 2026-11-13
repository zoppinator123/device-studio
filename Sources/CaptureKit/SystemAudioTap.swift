import AVFoundation
import CoreAudio

public enum CaptureError: Error, Equatable {
    case tapUnavailable(OSStatus)
    case aggregateDeviceFailed(OSStatus)
    case ioFailed(OSStatus)
    case microphoneDenied
    case microphoneUnavailable
    case alreadyRunning
    case notEnoughDiskSpace
}

/// System audio through a Core Audio process tap. Audio only: no screen capture,
/// no video, no screen-recording permission. The tap is global, private, unmuted, and excludes this process.
/// macOS shows its "System Audio Recording" prompt the first time IO starts, not when the tap is created.
final class SystemAudioTap {
    typealias Handler = (_ buffer: AVAudioPCMBuffer, _ hostTime: UInt64) -> Void

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private(set) var format: AVAudioFormat?

    private static func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> OSStatus {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
    }

    static func defaultOutputDevice() -> AudioObjectID {
        var device = AudioObjectID(kAudioObjectUnknown)
        _ = property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, &device)
        return device
    }

    /// True while some process is playing through the default output. Used to tell "nothing is playing"
    /// from "the tap is being fed zeros because permission was denied".
    static func outputDeviceIsRunning() -> Bool {
        var running: UInt32 = 0
        let status = property(defaultOutputDevice(), kAudioDevicePropertyDeviceIsRunningSomewhere, &running)
        return status == noErr && running != 0
    }

    func start(handler: @escaping Handler) throws {
        guard tapID == kAudioObjectUnknown else { throw CaptureError.alreadyRunning }
        // Our own process object, so the tap leaves this app's audio out.
        var pid = getpid()
        var selfObject = AudioObjectID(kAudioObjectUnknown)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<pid_t>.size), &pid, &size, &selfObject)

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: selfObject != kAudioObjectUnknown ? [selfObject] : [])
        description.name = "Device Studio system audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { tapID = AudioObjectID(kAudioObjectUnknown); throw CaptureError.tapUnavailable(status) }

        var asbd = AudioStreamBasicDescription()
        status = Self.property(tapID, kAudioTapPropertyFormat, &asbd)
        guard status == noErr, let tapFormat = AVAudioFormat(streamDescription: &asbd) else {
            stop(); throw CaptureError.tapUnavailable(status)
        }
        format = tapFormat

        var outputUID: CFString = "" as CFString
        _ = Self.property(Self.defaultOutputDevice(), kAudioDevicePropertyDeviceUID, &outputUID)
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Device Studio capture",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID as String,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID as String]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else { aggregateID = AudioObjectID(kAudioObjectUnknown); stop(); throw CaptureError.aggregateDeviceFailed(status) }

        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, inputData, inputTime, _, _ in
            // The buffer list is only valid inside this callback: wrap it without copying and hand it on
            // synchronously. The receiver must finish with it before returning.
            guard let buffer = AVAudioPCMBuffer(pcmFormat: tapFormat, bufferListNoCopy: inputData, deallocator: nil),
                  buffer.frameLength > 0 else { return }
            handler(buffer, inputTime.pointee.mHostTime)
        }
        guard status == noErr else { stop(); throw CaptureError.ioFailed(status) }
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else { stop(); throw CaptureError.ioFailed(status) }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        format = nil
    }

    deinit { stop() }
}

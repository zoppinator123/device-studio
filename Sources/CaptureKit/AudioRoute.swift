import CoreAudio

/// What the default output is, for echo handling: with headphones the microphone cannot hear
/// the call, so nothing needs cancelling.
public enum OutputRoute: Equatable, Sendable {
    case headphones, speakers, unknown

    public static func current() -> OutputRoute {
        let device = SystemAudioTap.defaultOutputDevice()
        guard device != kAudioObjectUnknown else { return .unknown }
        var transport: UInt32 = 0
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else { return .unknown }
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            // The built-in output reports which jack is in use: 'hdpn' for headphones.
            var source: UInt32 = 0
            var sourceAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDataSource,
                                                           mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            size = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(device, &sourceAddress, 0, nil, &size, &source) == noErr else { return .speakers }
            return source == 0x6864_706E ? .headphones : .speakers      // 'hdpn'
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return .headphones          // AirPods and most Bluetooth outputs are worn; a Bluetooth speaker is the exception
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeAirPlay:
            return .speakers
        default:
            return .unknown             // USB and others: could be a headset or a desk speaker
        }
    }
}

/// Echo handling for the microphone channel. Off by default until its effect on call
/// audio has been checked on a real call; layer 3 (dropping mic text that duplicates system-audio text)
/// belongs to transcription.
public enum EchoCancellation: String, Codable, CaseIterable, Sendable {
    case off
    /// Apple's voice processing on the microphone, only when the output is not headphones.
    case whenOnSpeakers
    case always

    func enabled(for route: OutputRoute) -> Bool {
        switch self {
        case .off: return false
        case .always: return true
        case .whenOnSpeakers: return route != .headphones
        }
    }
}

/// Calls back when the default input or output device changes, so a source can be reopened mid-meeting.
final class DefaultDeviceMonitor {
    private var blocks: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private let queue: DispatchQueue

    init(queue: DispatchQueue, onInputChange: @escaping () -> Void, onOutputChange: @escaping () -> Void) {
        self.queue = queue
        for (selector, handler) in [(kAudioHardwarePropertyDefaultInputDevice, onInputChange),
                                    (kAudioHardwarePropertyDefaultOutputDevice, onOutputChange)] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block) == noErr {
                blocks.append((address, block))
            }
        }
    }

    func cancel() {
        for (address, block) in blocks {
            var a = address
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, queue, block)
        }
        blocks = []
    }

    deinit { cancel() }
}

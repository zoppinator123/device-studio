import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// System audio through ScreenCaptureKit, used only when a Core Audio tap cannot be created.
/// The API insists on a video configuration, so the smallest frame size and lowest frame rate are requested
/// and every frame is dropped unread. No pixel data is stored or processed. This path needs the
/// "Screen & System Audio Recording" permission rather than "System Audio Recording Only".
final class SystemAudioFallback: NSObject, SCStreamOutput, SCStreamDelegate {
    typealias Handler = (_ buffer: AVAudioPCMBuffer, _ hostTime: UInt64) -> Void
    private var stream: SCStream?
    private var handler: Handler?
    private let queue = DispatchQueue(label: "com.jackzoppa.devicestudio.capture.sck")
    var onStop: ((Error?) -> Void)?

    func start(handler: @escaping Handler) throws {
        self.handler = handler
        let done = DispatchSemaphore(value: 0)
        var content: SCShareableContent?
        var failure: Error?
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { c, e in
            content = c; failure = e; done.signal()
        }
        guard done.wait(timeout: .now() + 5) == .success, failure == nil, let display = content?.displays.first else {
            throw CaptureError.tapUnavailable(-1)
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 3
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)   // frames are dropped
        var startError: Error?
        let started = DispatchSemaphore(value: 0)
        stream.startCapture { e in startError = e; started.signal() }
        guard started.wait(timeout: .now() + 5) == .success, startError == nil else {
            throw CaptureError.tapUnavailable(-2)
        }
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        let done = DispatchSemaphore(value: 0)
        stream.stopCapture { _ in done.signal() }
        _ = done.wait(timeout: .now() + 3)
        self.stream = nil
        handler = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let handler, sampleBuffer.isValid,
              let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { return }
        var asbd = asbdPointer.pointee
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let format = AVAudioFormat(streamDescription: &asbd),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames),
                                                           into: buffer.mutableAudioBufferList) == noErr else { return }
        // ScreenCaptureKit stamps samples on the host clock, the same clock the tap and microphone use.
        let hostTime = CMClockConvertHostTimeToSystemUnits(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        handler(buffer, hostTime)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop?(error)
    }
}

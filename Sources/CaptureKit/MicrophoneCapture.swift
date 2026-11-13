import AVFoundation

/// The microphone through AVAudioEngine's input node. Every buffer carries its host time.
final class MicrophoneCapture {
    typealias Handler = (_ buffer: AVAudioPCMBuffer, _ hostTime: UInt64) -> Void
    private var engine = AVAudioEngine()
    private var running = false
    private var configurationObserver: NSObjectProtocol?
    /// Called when the engine stops itself because the input device or its format changed.
    var onConfigurationChange: (() -> Void)?
    private(set) var voiceProcessing = false

    static var authorization: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    func start(voiceProcessing wantVoiceProcessing: Bool, handler: @escaping Handler) throws {
        guard !running else { throw CaptureError.alreadyRunning }
        guard Self.authorization == .authorized else { throw CaptureError.microphoneDenied }
        engine = AVAudioEngine()          // a fresh engine picks up the current default input device
        let input = engine.inputNode
        voiceProcessing = false
        if wantVoiceProcessing {
            do {
                try input.setVoiceProcessingEnabled(true)
                // Keep other apps' audio (the call itself) at full volume.
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
                voiceProcessing = true
            } catch {
                voiceProcessing = false   // record without it rather than not at all
            }
        }
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw CaptureError.microphoneUnavailable }
        input.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { buffer, when in
            guard when.isHostTimeValid else { return }
            handler(buffer, when.hostTime)
        }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.onConfigurationChange?()
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            removeObserver()
            throw CaptureError.microphoneUnavailable
        }
        running = true
    }

    func stop() {
        removeObserver()
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
    }

    private func removeObserver() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
    }
}

import Foundation
import Speech
import AVFAudio

/// Push-to-talk voice input via Speech framework (native, on-device capable).
final class SpeechInput {
    enum State { case idle, starting, recording, denied, unavailable }
    var onPartial: (String) -> Void = { _ in }
    var onState: (State) -> Void = { _ in }

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let engine = AVAudioEngine()
    private(set) var state: State = .idle

    var available: Bool {
        SFSpeechRecognizer(locale: Locale(identifier: "en-US"))?.isAvailable ?? false
    }

    private var tapInstalled = false
    /// Bumped on every start/stop so a permission callback that resolves
    /// after cancel cannot resurrect a recording the user already stopped.
    private var generation = 0
    func start() {
        guard state == .idle || state == .denied || state == .unavailable else { return }
        generation += 1
        let gen = generation
        setState(.starting)
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard recognizer?.isAvailable == true else { setState(.unavailable); return }
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self, self.generation == gen, self.state == .starting else { return }
                guard status == .authorized else { self.setState(.denied); return }
                self.beginCapture(gen: gen)
            }
        }
    }

    private func setState(_ s: State) { state = s; onState(s) }

    private func beginCapture(gen: Int) {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self, self.generation == gen, self.state == .starting else { return }
                guard granted else { self.setState(.denied); return }
                self.capture(gen: gen)
            }
        }
    }

    private func capture(gen: Int) {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate.isFinite, format.sampleRate > 0, format.channelCount > 0 else {
            self.request = nil
            setState(.unavailable)
            return
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
            guard self != nil else { return }
            request.append(buf)
        }
        task = recognizer?.recognitionTask(with: request) { [weak self] result, err in
            let text = result?.bestTranscription.formattedString
            let finished = err != nil || (result?.isFinal ?? false)
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                if let text { self.onPartial(text) }
                if finished { self.stop() }
            }
        }
        tapInstalled = true
        do {
            engine.prepare(); try engine.start()
            setState(.recording)
        } catch {
            cleanupCapture()
            setState(.unavailable)
        }
    }

    private func cleanupCapture() {
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        request?.endAudio(); request = nil
        task?.cancel(); task = nil
    }

    func stop() {
        generation += 1 // invalidate any in-flight permission callbacks
        cleanupCapture()
        if state != .idle { setState(.idle) }
    }

    deinit {
        // AVAudioEngine must not deallocate with a running tap; UI normally
        // calls stop(), this covers deallocation while still recording.
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
        request?.endAudio()
        task?.cancel()
    }
}

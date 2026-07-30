#if !os(visionOS)
import AVFoundation
import Foundation
import Speech
import os

/// One live dictation: microphone → Speech framework → a finished string the
/// pane types into its session.
///
/// iOS exposes no way to *trigger* the system keyboard's dictation, and that
/// keyboard (and its mic key) is absent with a hardware keyboard attached or
/// while the user locks it closed — so Multiplex's dictation controls run
/// recognition themselves. On-device
/// recognition is requested whenever the locale supports it: a terminal's
/// input is the most sensitive text in the app, and the recognizer is the one
/// place it would otherwise leave the device outside the user's own SSH
/// connection.
///
/// Only one session may hold the microphone at a time, so starting a new one
/// cancels whatever was listening — a second terminal tab takes the mic, it
/// does not fail.
///
/// Nothing is typed until the dictation finishes. Partial results are shown
/// in the pane's dictation bar only: the recognizer rewrites earlier words as
/// it refines its hypothesis, and a terminal has no way to take a byte back.
@MainActor
final class DictationSession {
    enum Outcome {
        /// Everything the recognizer heard, unsanitized.
        case text(String)
        case cancelled
        case failure(String)
    }

    /// The session currently holding the microphone, if any.
    private static weak var active: DictationSession?

    private static let logger = Logger(
        subsystem: "app.multiplexterm.multiplex",
        category: "dictation"
    )

    /// Recognition stops itself after this much quiet. Deliberately far
    /// longer than system dictation's pause: what gets dictated here is a
    /// prompt for a CLI agent, and thinking mid-sentence must not end the
    /// take and type half a thought into the pane. STOP is the normal way
    /// to finish; this is the backstop for walking away.
    private static let silenceTimeout: Duration = .seconds(30)
    /// Runaway stop: a forgotten open mic is a battery and privacy problem.
    private static let maximumDuration: Duration = .seconds(5 * 60)
    /// How long to wait for the recognizer's final result after the audio
    /// ends. The tail of a sentence usually lands within a few hundred ms.
    private static let finalResultTimeout: Duration = .seconds(2)

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var onStart: (() -> Void)?
    private var onPartial: ((String) -> Void)?
    private var onFinish: ((Outcome) -> Void)?
    private var transcript = ""
    private var silenceTask: Task<Void, Never>?
    private var capTask: Task<Void, Never>?
    private var finalResultTask: Task<Void, Never>?
    private var finishing = false

    private(set) var isListening = false

    /// Ask for microphone + speech access, open the mic, and start
    /// recognizing.
    ///
    /// `onStart` fires only once the microphone is genuinely open — the first
    /// press can sit behind two system permission alerts, and a pane that
    /// claims to be LISTENING while one is on screen is lying about a live
    /// microphone. `onFinish` is called exactly once per start, including
    /// when authorization is refused or another session takes the mic away.
    func start(
        onStart: @escaping () -> Void,
        onPartial: @escaping (String) -> Void,
        onFinish: @escaping (Outcome) -> Void
    ) {
        guard !isListening else { return }
        Self.active?.cancel()
        self.onStart = onStart
        self.onPartial = onPartial
        self.onFinish = onFinish
        Task { await authorizeAndBegin() }
    }

    /// Finish normally: stop the audio, wait briefly for the recognizer's
    /// final pass, then deliver everything it heard.
    func stop() {
        guard isListening, !finishing else { return }
        finishing = true
        silenceTask?.cancel()
        capTask?.cancel()
        stopAudio()
        request?.endAudio()
        finalResultTask = Task { [weak self] in
            try? await Task.sleep(for: Self.finalResultTimeout)
            guard !Task.isCancelled, let self else { return }
            deliver(.text(transcript))
        }
    }

    /// Abandon the dictation without typing anything. Deliberately not gated
    /// on `isListening`: a cancel can land while authorization is still
    /// outstanding, and that must stop the microphone from ever opening.
    func cancel() {
        guard onFinish != nil else { return }
        deliver(.cancelled)
    }

    // MARK: Authorization

    private func authorizeAndBegin() async {
        guard await Self.requestSpeechAuthorization() else {
            deliver(.failure("Speech recognition access is off in Settings"))
            return
        }
        guard await Self.requestMicrophoneAccess() else {
            deliver(.failure("Microphone access is off in Settings"))
            return
        }
        begin()
    }

    private static func requestSpeechAuthorization() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .denied, .restricted: return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        @unknown default: return false
        }
    }

    private static func requestMicrophoneAccess() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default: return false
        }
    }

    // MARK: Recognition

    private func begin() {
        // A cancel that landed while authorization was outstanding already
        // delivered its outcome; do not open the microphone behind it.
        guard onFinish != nil, !isListening else { return }

        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            deliver(.failure("Dictation isn't available for this language"))
            return
        }
        self.recognizer = recognizer

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Keep the words on the device wherever the locale allows it. Where
        // it does not, Apple's service does the transcription — the same
        // boundary the system keyboard's own dictation key has.
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        self.request = request

        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audio.setActive(true, options: .notifyOthersOnDeactivation)
            let input = engine.inputNode
            input.removeTap(onBus: 0)
            input.installTap(
                onBus: 0,
                bufferSize: 1024,
                format: input.outputFormat(forBus: 0)
            ) { buffer, _ in
                request.append(buffer)
            }
            engine.prepare()
            try engine.start()
        } catch {
            Self.logger.error("dictation-audio-failed \(error.localizedDescription, privacy: .public)")
            stopAudio()
            self.request = nil
            deliver(.failure("The microphone couldn't be opened"))
            return
        }

        isListening = true
        Self.active = self
        transcript = ""
        Self.logger.debug(
            "dictation-start onDevice=\(request.requiresOnDeviceRecognition, privacy: .public)"
        )
        onStart?()
        onStart = nil

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                self?.handle(result: result, error: error)
            }
        }
        armSilenceTimer()
        capTask = Task { [weak self] in
            try? await Task.sleep(for: Self.maximumDuration)
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?) {
        guard isListening else { return }
        if let result {
            transcript = result.bestTranscription.formattedString
            onPartial?(transcript)
            if result.isFinal {
                deliver(.text(transcript))
                return
            }
            armSilenceTimer()
        }
        guard let error else { return }
        // After `endAudio()` the recognizer reports the shutdown as an error
        // even though the transcript is good — this is the normal finish.
        if finishing {
            deliver(.text(transcript))
            return
        }
        Self.logger.error("dictation-failed \(error.localizedDescription, privacy: .public)")
        deliver(transcript.isEmpty
            ? .failure("Dictation stopped unexpectedly")
            : .text(transcript))
    }

    private func armSilenceTimer() {
        guard !finishing else { return }
        silenceTask?.cancel()
        silenceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.silenceTimeout)
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    // MARK: Teardown

    private func deliver(_ outcome: Outcome) {
        let finish = onFinish
        onStart = nil
        onPartial = nil
        onFinish = nil
        silenceTask?.cancel()
        capTask?.cancel()
        finalResultTask?.cancel()
        silenceTask = nil
        capTask = nil
        finalResultTask = nil
        stopAudio()
        task?.cancel()
        task = nil
        request = nil
        recognizer = nil
        isListening = false
        finishing = false
        if Self.active === self { Self.active = nil }
        finish?(outcome)
    }

    private func stopAudio() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        // Handing the session back can block briefly; the pane has already
        // moved on by the time it completes.
        Task.detached {
            try? AVAudioSession.sharedInstance().setActive(
                false, options: .notifyOthersOnDeactivation
            )
        }
    }
}
#endif

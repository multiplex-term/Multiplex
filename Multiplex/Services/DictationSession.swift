#if !os(visionOS)
import AVFoundation
import Foundation
import Speech
import os

/// One live dictation: microphone → Speech framework → words the pane types
/// into its session *as they settle*, the way the system keyboard's dictation
/// fills a text field while you are still talking.
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
/// Two things make the input continuous rather than one lump at the end:
///
/// - `DictationStream` decides which words the recognizer has stopped
///   reconsidering; only those are handed over, because a terminal cannot
///   take a byte back. A pause flushes the rest (`quietFlush`), so a spoken
///   phrase lands as soon as the speaker draws breath.
/// - Recognition **rolls**. One `SFSpeechRecognitionTask` does not last: it
///   finalizes at an endpoint, and the server-backed path gives up after
///   about a minute. The audio engine keeps running across that, and each
///   finished task is replaced by a fresh one whose words append to the same
///   dictation — otherwise "continuous" would mean "until the first pause".
@MainActor
final class DictationSession {
    enum Outcome {
        /// The microphone closed normally. Everything heard was already
        /// typed as it settled — there is no trailing text to deliver.
        case ended
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
    /// take. STOP is the normal way to finish; this is the backstop for
    /// walking away.
    private static let silenceTimeout: Duration = .seconds(30)
    /// Runaway stop: a forgotten open mic is a battery and privacy problem.
    private static let maximumDuration: Duration = .seconds(5 * 60)
    /// How long to wait for the recognizer's final result after the audio
    /// ends. The tail of a sentence usually lands within a few hundred ms.
    private static let finalResultTimeout: Duration = .seconds(2)
    /// Hypotheses arrive only while there is speech, so this much quiet
    /// means the recognizer has settled: the held-back tail is typed instead
    /// of waiting for the next sentence to push it out.
    private static let quietFlush: Duration = .milliseconds(1000)
    /// **The next task must not start in the same breath as the last one
    /// ended.** The speech daemon is still tearing the finished task down,
    /// and a task created into that window comes back dead immediately — so
    /// an endpoint at the speaker's first pause produced a burst of dead
    /// restarts and the take died with it, about a second after the pause.
    /// A breath here costs nothing (the endpoint fired *because* nobody is
    /// speaking) and the wait grows while restarts keep coming back empty.
    private static let restartDelays: [Duration] = [
        .milliseconds(200), .milliseconds(500), .seconds(1), .seconds(2),
    ]
    /// A task that dies this fast without hearing anything did not endpoint
    /// — it failed to start. Only those count toward the cap; a task that
    /// simply waited through a silence and ended is the recognizer working,
    /// and ending the take on those is what the 30 s timeout is for.
    private static let bornDeadWithin: Duration = .seconds(2)
    /// How many born-dead restarts to absorb before admitting the recognizer
    /// is broken. With the backoff above this is ~7 s of trying.
    private static let maximumEmptySegments = 6
    /// A task that has produced nothing at all for this long is replaced —
    /// silence looks the same from here, but so does a recognizer that
    /// stopped listening, and only one of them is fixed by a fresh task.
    /// Rolling is cheap; a deaf task is the whole complaint.
    private static let deafSegmentTimeout: Duration = .seconds(12)
    /// The analyzer's probation. If it has not produced a single result by
    /// now the take falls back to `SFSpeechRecognizer` — nothing has been
    /// typed yet, so the switch costs nothing, and a wrong audio conversion
    /// would otherwise mean a take that can never hear anything. Someone who
    /// pressed the key and thought for this long lands on the older engine,
    /// which is the shipping one and works.
    private static let analyzerProbation: Duration = .seconds(10)

    private let engine = AVAudioEngine()
    /// The audio tap runs on a realtime thread while the request it feeds is
    /// swapped on the main actor between segments. This box is the only
    /// thing both touch.
    private let audioSink = AudioSink()
    /// The iOS 26+ path, when this device can run it. While it is set, the
    /// `SFSpeechRecognizer` machinery below (segments, rolls, backoff) is
    /// unused — one analyzer runs for the whole take.
    private var analyzerBox: AnyObject?
    @available(iOS 26, *)
    private var analyzer: DictationAnalyzer? {
        get { analyzerBox as? DictationAnalyzer }
        set { analyzerBox = newValue }
    }
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var onStart: (() -> Void)?
    private var onText: ((String) -> Void)?
    private var onPending: ((String) -> Void)?
    private var onFinish: ((Outcome) -> Void)?
    private var stream = DictationStream()
    private var publishedPending = ""
    /// Results carry the generation of the task that produced them; a
    /// superseded task can still deliver one after its replacement started.
    private var generation = 0
    private var segmentHeardSpeech = false
    private var emptySegments = 0
    private var segmentStart: ContinuousClock.Instant?
    /// Decided once per take and logged, so the field answer to "did this
    /// leave the device" is in the same line as the start.
    private var onDeviceRecognition = true
    private var silenceTask: Task<Void, Never>?
    private var capTask: Task<Void, Never>?
    private var quietTask: Task<Void, Never>?
    private var finalResultTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var deafTask: Task<Void, Never>?
    private var probationTask: Task<Void, Never>?
    private var analyzerHeardAnything = false
    private var audioObservers: [NSObjectProtocol] = []
    private var finishing = false

    private(set) var isListening = false

    /// Ask for microphone + speech access, open the mic, and start
    /// recognizing.
    ///
    /// `onStart` fires only once the microphone is genuinely open — the first
    /// press can sit behind two system permission alerts, and a pane that
    /// claims to be LISTENING while one is on screen is lying about a live
    /// microphone. `onText` delivers each settled chunk, separator included,
    /// ready to send verbatim. `onPending` tracks what has been heard but not
    /// yet typed. `onFinish` is called exactly once per start, including when
    /// authorization is refused or another session takes the mic away.
    func start(
        onStart: @escaping () -> Void,
        onText: @escaping (String) -> Void,
        onPending: @escaping (String) -> Void,
        onFinish: @escaping (Outcome) -> Void
    ) {
        guard !isListening else { return }
        Self.active?.cancel()
        self.onStart = onStart
        self.onText = onText
        self.onPending = onPending
        self.onFinish = onFinish
        Task { await authorizeAndBegin() }
    }

    /// Finish normally: stop the audio, wait briefly for the recognizer's
    /// final pass, then type whatever the hold rules were still sitting on.
    func stop() {
        guard isListening, !finishing else { return }
        finishing = true
        silenceTask?.cancel()
        capTask?.cancel()
        quietTask?.cancel()
        restartTask?.cancel()
        deafTask?.cancel()
        probationTask?.cancel()
        stopAudio()
        if #available(iOS 26, *), let analyzer {
            // Ends the input and finalizes everything heard; the last words
            // arrive as final results and are typed on the way out.
            analyzer.finish()
            finalResultTask = Task { [weak self] in
                try? await Task.sleep(for: Self.finalResultTimeout)
                guard !Task.isCancelled, let self else { return }
                deliver(.ended)
            }
            return
        }
        guard let request else {
            // Stopped between segments (a restart was waiting its turn): no
            // task is left to deliver a final result, so nothing to wait for.
            publish(stream.endSegment())
            deliver(.ended)
            return
        }
        request.endAudio()
        finalResultTask = Task { [weak self] in
            try? await Task.sleep(for: Self.finalResultTimeout)
            guard !Task.isCancelled, let self else { return }
            publish(stream.endSegment())
            deliver(.ended)
        }
    }

    /// Stop without typing the tail. What already settled is in the session
    /// and stays there — this abandons the queue, not the dictation's past.
    /// Deliberately not gated on `isListening`: a cancel can land while
    /// authorization is still outstanding, and that must stop the microphone
    /// from ever opening.
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
        await begin()
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

    private func begin() async {
        // A cancel that landed while authorization was outstanding already
        // delivered its outcome; do not open the microphone behind it.
        guard onFinish != nil, !isListening else { return }

        do {
            try activateAudioSession()
        } catch {
            Self.logger.error("dictation-audio-failed \(error.localizedDescription, privacy: .public)")
            stopAudio()
            deliver(.failure("The microphone couldn't be opened"))
            return
        }

        // Pick the engine before the microphone opens: choosing costs a
        // couple of XPC round trips, and audio captured across them would
        // have nowhere to go. iOS 26's analyzer is the one built for this;
        // `SFSpeechRecognizer` is the fallback for everything older and for
        // languages whose dictation model is not installed.
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        if #available(iOS 26, *) {
            analyzer = await DictationAnalyzer.make(inputFormat: inputFormat)
        }
        guard onFinish != nil, !isListening else { return }
        if analyzerBox == nil {
            guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
                deliver(.failure("Dictation isn't available for this language"))
                return
            }
            self.recognizer = recognizer
            onDeviceRecognition = recognizer.supportsOnDeviceRecognition
        }

        do {
            try installTap()
        } catch {
            Self.logger.error("dictation-audio-failed \(error.localizedDescription, privacy: .public)")
            stopAudio()
            deliver(.failure("The microphone couldn't be opened"))
            return
        }

        isListening = true
        Self.active = self
        stream = DictationStream()
        publishedPending = ""
        emptySegments = 0
        segmentStart = nil
        observeAudioDisruption()
        Self.logger.debug(
            "dictation-start engine=\(self.analyzerBox == nil ? "sfspeech" : "analyzer", privacy: .public) onDevice=\(self.onDeviceRecognition, privacy: .public)"
        )
        onStart?()
        onStart = nil

        if #available(iOS 26, *), let analyzer {
            await startAnalyzer(analyzer)
        } else {
            beginSegment()
        }
        armSilenceTimer()
        capTask = Task { [weak self] in
            try? await Task.sleep(for: Self.maximumDuration)
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    /// Start one recognition task. Its words continue the same dictation —
    /// the stream keeps the typed-so-far state across segments.
    private func beginSegment() {
        guard let recognizer, isListening, !finishing else { return }
        // Tear the capture graph down and build it again for every task, the
        // way Apple's own recognition sample does: a task fed by the tap that
        // served the task before it came back deaf on device — the microphone
        // stayed open and nothing was ever heard again.
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Keep the words on the device wherever the locale allows it. Where
        // it does not, Apple's service does the transcription — the same
        // boundary the system keyboard's own dictation key has.
        request.requiresOnDeviceRecognition = onDeviceRecognition
        request.taskHint = .dictation
        // The system keyboard punctuates what it hears; a dictated agent
        // prompt reads the same way, and commas are otherwise unsayable.
        request.addsPunctuation = true
        self.request = request
        audioSink.use(request)
        generation &+= 1
        segmentHeardSpeech = false
        segmentStart = ContinuousClock.now
        let generation = generation
        Self.logger.debug("dictation-segment-begin n=\(generation, privacy: .public)")
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                self?.handle(result: result, error: error, generation: generation)
            }
        }
        // Audio starts flowing only once the request and its task are both
        // live, so nothing is spoken into a graph that has nowhere to put it.
        do {
            try installTap()
        } catch {
            Self.logger.error(
                "dictation-audio-restart-failed \(error.localizedDescription, privacy: .public)"
            )
            rollSegment("audio-restart-failed")
            return
        }
        armDeafTimer()
    }

    private func handle(
        result: SFSpeechRecognitionResult?,
        error: Error?,
        generation: Int
    ) {
        guard isListening, generation == self.generation else { return }
        if let result {
            let heard = result.bestTranscription.formattedString
            // Any result at all means this task is alive — restart the
            // watchdog rather than retiring it, so a task that goes deaf
            // *after* saying something is replaced too.
            armDeafTimer()
            if !heard.isEmpty { segmentHeardSpeech = true }
            if result.isFinal {
                stream.absorb(heard)
                rollSegment("final")
                return
            }
            publish(stream.heard(heard))
            armSilenceTimer()
            armQuietTimer()
        }
        // After `endAudio()` the recognizer reports the shutdown as an error
        // even though the transcript is good — that is the normal finish, and
        // mid-take it is just this task's end, not the dictation's. It is
        // also the only place a recognizer that cannot start says so, so the
        // reason is logged rather than swallowed into a restart.
        guard let error else { return }
        Self.logger.debug(
            "dictation-segment-error \(error.localizedDescription, privacy: .public)"
        )
        rollSegment("error")
    }

    /// This recognition task is done. Type what it settled on, then either
    /// roll into the next one or end the dictation.
    private func rollSegment(_ reason: String) {
        // Tell the daemon this request is finished before dropping it, so
        // the next one is not competing with a session still winding down.
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        audioSink.use(nil)
        deafTask?.cancel()
        quietTask?.cancel()
        publish(stream.endSegment())

        if finishing || !isListening {
            deliver(.ended)
            return
        }
        // Distinguish a task that failed to start from one that lived, heard
        // nothing, and ended: only the first is evidence of breakage.
        let lifetime = segmentStart.map { ContinuousClock.now - $0 } ?? .zero
        let bornDead = !segmentHeardSpeech && lifetime < Self.bornDeadWithin
        emptySegments = bornDead ? emptySegments + 1 : 0
        Self.logger.debug(
            "dictation-segment-ended reason=\(reason, privacy: .public) heard=\(self.segmentHeardSpeech, privacy: .public) dead=\(bornDead, privacy: .public) n=\(self.emptySegments, privacy: .public)"
        )
        guard emptySegments < Self.maximumEmptySegments else {
            // Always a visible ending, even when words already landed: the
            // microphone is closing for a reason the user did not choose,
            // and a bar that simply vanishes mid-dictation reads as the
            // feature quietly breaking.
            Self.logger.error("dictation-restart-exhausted")
            deliver(.failure("Dictation stopped unexpectedly"))
            return
        }
        scheduleSegment()
    }

    /// Give the finished task room to tear down before opening the next one,
    /// and back further off while restarts keep coming back dead.
    private func scheduleSegment() {
        let step = min(emptySegments, Self.restartDelays.count - 1)
        let delay = Self.restartDelays[step]
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, isListening, !finishing else { return }
            beginSegment()
        }
    }

    private func publish(_ emission: DictationStream.Emission) {
        if let text = emission.typed { onText?(text) }
        publishPending(emission.pending)
    }

    private func publishPending(_ pending: String) {
        guard pending != publishedPending else { return }
        publishedPending = pending
        onPending?(pending)
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

    /// A task that has said nothing at all since it started gets replaced.
    /// From here a silent room and a recognizer that quietly stopped
    /// listening look identical, and only one of them is worth waiting on —
    /// so the cheap thing (a fresh task) is done on the chance it is the
    /// second. Rolls during a real silence cost nothing and the 30 s
    /// timeout still owns when the take ends.
    private func armDeafTimer() {
        deafTask?.cancel()
        deafTask = Task { [weak self] in
            try? await Task.sleep(for: Self.deafSegmentTimeout)
            guard !Task.isCancelled, let self, isListening, !finishing else { return }
            Self.logger.debug("dictation-segment-deaf")
            rollSegment("no-results")
        }
    }

    /// The speaker stopped mid-take: hand over the words the hold rules were
    /// protecting, since nothing is arriving to revise them.
    private func armQuietTimer() {
        guard !finishing else { return }
        quietTask?.cancel()
        quietTask = Task { [weak self] in
            try? await Task.sleep(for: Self.quietFlush)
            guard !Task.isCancelled, let self, isListening, !finishing else { return }
            if #available(iOS 26, *), let analyzer {
                // The analyzer decides what is final, so ask it to finalize
                // rather than typing its volatile tail behind its back.
                analyzer.finalizePending()
            } else {
                publish(stream.flush())
            }
        }
    }

    // MARK: The analyzer path (iOS 26+)

    /// Hand the microphone to the analyzer and let it decide what is final.
    /// There is no rolling here: one analyzer runs for the whole take, which
    /// is the entire reason this path exists.
    @available(iOS 26, *)
    private func startAnalyzer(_ analyzer: DictationAnalyzer) async {
        audioSink.useAnalyzer { [weak analyzer] buffer in analyzer?.append(buffer) }
        do {
            try await analyzer.start(
                onSettled: { [weak self] text in self?.analyzerSettled(text) },
                onVolatile: { [weak self] text in self?.analyzerVolatile(text) },
                onEnded: { [weak self] error in self?.analyzerEnded(error) }
            )
            analyzerHeardAnything = false
            probationTask = Task { [weak self] in
                try? await Task.sleep(for: Self.analyzerProbation)
                guard !Task.isCancelled, let self else { return }
                fallBackToSFSpeech(reason: "analyzer-silent")
            }
        } catch {
            Self.logger.error(
                "dictation-analyzer-failed \(error.localizedDescription, privacy: .public)"
            )
            fallBackToSFSpeech(reason: "analyzer-start-failed")
        }
    }

    /// Hand the rest of this take to `SFSpeechRecognizer`. Only ever called
    /// before the analyzer has produced anything, so nothing typed is lost
    /// and the stream's state carries over untouched.
    private func fallBackToSFSpeech(reason: String) {
        guard isListening, !finishing, analyzerBox != nil, !analyzerHeardAnything else { return }
        Self.logger.error("dictation-analyzer-abandoned \(reason, privacy: .public)")
        probationTask?.cancel()
        probationTask = nil
        if #available(iOS 26, *) {
            analyzer?.cancel()
            analyzer = nil
        }
        analyzerBox = nil
        audioSink.useAnalyzer(nil)
        if recognizer == nil {
            recognizer = SFSpeechRecognizer()
            onDeviceRecognition = recognizer?.supportsOnDeviceRecognition ?? false
        }
        guard recognizer?.isAvailable == true else {
            deliver(.failure("Dictation isn't available for this language"))
            return
        }
        beginSegment()
    }

    /// The recognizer has finalized these words: it will not revise them, so
    /// they can go to the terminal, which cannot take a byte back.
    private func analyzerSettled(_ text: String) {
        guard isListening else { return }
        analyzerHeard()
        stream.absorb(text)
        publish(stream.endSegment())
        armSilenceTimer()
    }

    /// The tail still being reconsidered — the bar's queue, never typed.
    private func analyzerVolatile(_ text: String) {
        guard isListening else { return }
        analyzerHeard()
        stream.absorb(text)
        publishPending(stream.pending)
        armSilenceTimer()
        armQuietTimer()
    }

    /// The analyzer is alive; it has said something. Probation is over.
    private func analyzerHeard() {
        guard !analyzerHeardAnything else { return }
        analyzerHeardAnything = true
        probationTask?.cancel()
        probationTask = nil
    }

    private func analyzerEnded(_ error: (any Error)?) {
        guard isListening else { return }
        if let error {
            Self.logger.error(
                "dictation-analyzer-ended \(error.localizedDescription, privacy: .public)"
            )
        } else {
            Self.logger.debug("dictation-analyzer-ended")
        }
        // On STOP this is the expected ending, and everything heard was
        // finalized on the way out. Otherwise the analyzer gave up on its
        // own, which the pane says rather than leaving a dead LISTENING bar.
        deliver(finishing || error == nil ? .ended : .failure("Dictation stopped unexpectedly"))
    }

    // MARK: Audio

    private func activateAudioSession() throws {
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audio.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func installTap() throws {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let sink = audioSink
        input.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: input.outputFormat(forBus: 0)
        ) { buffer, _ in
            sink.append(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    /// A dictation here can run for minutes, so the two things that end an
    /// audio graph out from under it are worth handling: an interruption
    /// (a call, another app taking the mic) ends the take with everything
    /// heard typed, and a route change (AirPods arriving) re-taps the input
    /// at its new format and continues in a fresh segment.
    private func observeAudioDisruption() {
        let center = NotificationCenter.default
        audioObservers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor in
                // The system took the microphone (a call, another app). End
                // the take with everything heard already typed, the way the
                // system keyboard's dictation ends on an interruption. This
                // is the one disruption that is not recoverable in place —
                // and the log names it, because from the pane it looks the
                // same as any other ending.
                Self.logger.debug("dictation-interrupted")
                self?.stop()
            }
        })
        audioObservers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.audioConfigurationChanged() }
        })
    }

    private func audioConfigurationChanged() {
        guard isListening, !finishing else { return }
        Self.logger.debug("dictation-audio-reconfigured")
        // The new input format cannot be fed to a request that started on the
        // old one, so the current segment ends here — the words it settled on
        // are already in the stream's hypothesis and get typed by the roll,
        // and the next segment re-taps the input at its new format. A route
        // change must never end a take: this is AirPods arriving, not the
        // user finishing.
        engine.inputNode.removeTap(onBus: 0)
        guard analyzerBox == nil else {
            // The analyzer keeps running — its feed re-derives the converter
            // from the next buffer's format, so only the tap comes back.
            do {
                try installTap()
            } catch {
                Self.logger.error(
                    "dictation-retap-failed \(error.localizedDescription, privacy: .public)"
                )
                stop()
            }
            return
        }
        rollSegment("audio-reconfigured")
    }

    // MARK: Teardown

    private func deliver(_ outcome: Outcome) {
        // Exactly once per start, and re-entrancy-safe: a commit handed to a
        // pane whose session just died cancels this dictation from inside
        // its own callback, and the roll it interrupted still runs to its
        // own ending afterwards.
        guard let finish = onFinish else { return }
        onStart = nil
        onText = nil
        onPending = nil
        onFinish = nil
        silenceTask?.cancel()
        capTask?.cancel()
        quietTask?.cancel()
        finalResultTask?.cancel()
        restartTask?.cancel()
        deafTask?.cancel()
        probationTask?.cancel()
        silenceTask = nil
        capTask = nil
        quietTask = nil
        finalResultTask = nil
        restartTask = nil
        deafTask = nil
        probationTask = nil
        stopAudio()
        if #available(iOS 26, *) {
            analyzer?.cancel()
            analyzer = nil
        }
        analyzerBox = nil
        task?.cancel()
        task = nil
        request = nil
        recognizer = nil
        isListening = false
        finishing = false
        if Self.active === self { Self.active = nil }
        finish(outcome)
    }

    private func stopAudio() {
        audioSink.use(nil)
        for observer in audioObservers { NotificationCenter.default.removeObserver(observer) }
        audioObservers = []
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        // Handing the session back can block briefly, so it happens off the
        // main actor — but by the time it runs another tab may have taken
        // the microphone, and deactivating the session under that take would
        // leave it with a running engine that never hears anything again.
        Task { [weak self] in
            guard Self.active == nil || Self.active === self else { return }
            await Task.detached {
                try? AVAudioSession.sharedInstance().setActive(
                    false, options: .notifyOthersOnDeactivation
                )
            }.value
        }
    }
}

/// The seam between the realtime audio tap and the rolling recognition
/// requests it feeds. The tap outlives every individual request, so it holds
/// this instead of a request, and swapping one costs the audio thread a
/// pointer read behind an uncontended lock.
private final class AudioSink: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var analyzer: (@Sendable (AVAudioPCMBuffer) -> Void)?

    func use(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        self.request = request
        lock.unlock()
    }

    func useAnalyzer(_ analyzer: (@Sendable (AVAudioPCMBuffer) -> Void)?) {
        lock.lock()
        self.analyzer = analyzer
        lock.unlock()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        // The request is held across its append on purpose: releasing first
        // would let a segment swap slip in and hand the buffer to a request
        // that has already ended its audio. The analyzer's own feed does its
        // own locking, so it is called outside this one.
        lock.lock()
        request?.append(buffer)
        let analyzer = self.analyzer
        lock.unlock()
        analyzer?(buffer)
    }
}
#endif

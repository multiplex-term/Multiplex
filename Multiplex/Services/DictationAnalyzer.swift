#if !os(visionOS)
import AVFoundation
import Foundation
import Speech
import os

/// The recognition path this feature wants: one `SpeechAnalyzer` running the
/// whole take, driving `DictationTranscriber` — the same on-device dictation
/// model the system keyboard uses.
///
/// It exists because `SFSpeechRecognizer` is built around **one utterance per
/// task**. Its task ends at the speaker's first pause, and the replacement,
/// however carefully spaced, came back deaf on device: the microphone stayed
/// open, the pane still said LISTENING, and nothing was ever heard again
/// (user-reported, twice). Rolling tasks is working against that API rather
/// than with it.
///
/// This one is built for long-form dictation, and it answers the question a
/// terminal actually has to ask. Results arrive marked **volatile** (the tail
/// still being reconsidered) or **final** (the recognizer will not revise
/// these words) — which is exactly the line `DictationStream` has to guess at
/// on the older path, decided here by the recognizer itself. Final text is
/// typed; volatile text is the bar's queue and nothing more.
@available(iOS 26, *)
@MainActor
final class DictationAnalyzer {
    private static let logger = Logger(
        subsystem: "app.multiplexterm.multiplex",
        category: "dictation"
    )

    private let transcriber: DictationTranscriber
    private let analyzer: SpeechAnalyzer
    private let feed: AnalyzerFeed
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?

    private init(
        transcriber: DictationTranscriber,
        analyzer: SpeechAnalyzer,
        feed: AnalyzerFeed
    ) {
        self.transcriber = transcriber
        self.analyzer = analyzer
        self.feed = feed
    }

    /// Build one for the take's language, or nil when it cannot run here —
    /// an unsupported locale, or a model that is not installed. The caller
    /// falls back to `SFSpeechRecognizer` rather than failing the dictation.
    static func make(
        inputFormat: AVAudioFormat,
        locale: Locale
    ) async -> DictationAnalyzer? {
        guard let locale = await DictationTranscriber.supportedLocale(
            equivalentTo: locale
        ) else {
            logger.debug("dictation-analyzer-unsupported-locale")
            return nil
        }
        let transcriber = DictationTranscriber(
            locale: locale,
            contentHints: [],
            // The system keyboard punctuates what it hears; a dictated agent
            // prompt reads the same way.
            transcriptionOptions: [.punctuation],
            // Volatile results are the bar's queue; frequent finalization is
            // what gets words into the session while the speaker is still
            // talking, rather than at the end of a thought.
            reportingOptions: [.volatileResults, .frequentFinalization],
            attributeOptions: []
        )
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            // Ask for the model so the next take can use it, and let this one
            // run on the older recognizer rather than making the user wait on
            // a download they did not ask for.
            logger.debug("dictation-analyzer-model-missing")
            Task.detached {
                try? await AssetInventory
                    .assetInstallationRequest(supporting: [transcriber])?
                    .downloadAndInstall()
            }
            return nil
        }
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber]
        ) else {
            logger.debug("dictation-analyzer-no-format")
            return nil
        }
        guard let feed = AnalyzerFeed(from: inputFormat, to: analyzerFormat) else {
            logger.debug("dictation-analyzer-no-converter")
            return nil
        }
        return DictationAnalyzer(
            transcriber: transcriber,
            analyzer: SpeechAnalyzer(modules: [transcriber]),
            feed: feed
        )
    }

    /// Begin analysing. `onSettled` carries text the recognizer has finalized
    /// — safe to hand to a terminal, which cannot take a byte back.
    /// `onVolatile` is the live tail, for the bar only. `onEnded` fires once,
    /// when the results sequence ends or fails.
    func start(
        onSettled: @escaping (String) -> Void,
        onVolatile: @escaping (String) -> Void,
        onEnded: @escaping ((any Error)?) -> Void
    ) async throws {
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        input = continuation
        feed.attach(continuation)
        try await analyzer.start(inputSequence: stream)
        Self.logger.debug("dictation-analyzer-started")
        resultsTask = Task { [transcriber] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        onSettled(text)
                    } else {
                        onVolatile(text)
                    }
                }
                onEnded(nil)
            } catch {
                onEnded(error)
            }
        }
    }

    /// One buffer of microphone audio, straight off the tap's realtime
    /// thread — converted to the analyzer's format and handed over.
    nonisolated func append(_ buffer: AVAudioPCMBuffer) {
        feed.append(buffer)
    }

    /// The speaker paused: ask for what has been heard so far to be
    /// finalized, so the tail is typed instead of sitting in the bar waiting
    /// for the next sentence to push it out.
    func finalizePending() {
        Task { [analyzer] in try? await analyzer.finalize(through: nil) }
    }

    /// STOP: end the input, finalize everything heard, and let the results
    /// sequence finish — the last words are typed on the way out.
    func finish() {
        input?.finish()
        Task { [analyzer] in try? await analyzer.finalizeAndFinishThroughEndOfInput() }
    }

    /// CANCEL: drop what has not been typed and stop now.
    func cancel() {
        resultsTask?.cancel()
        resultsTask = nil
        input?.finish()
        input = nil
        Task { [analyzer] in await analyzer.cancelAndFinishNow() }
    }
}

/// The seam between the realtime audio tap and the analyzer's input sequence:
/// the microphone runs at the hardware's format and the analyzer wants its
/// own, so each buffer is converted where it arrives and yielded straight
/// through. The continuation is the only thing the two threads share.
@available(iOS 26, *)
private final class AnalyzerFeed: @unchecked Sendable {
    private let lock = NSLock()
    private let outputFormat: AVAudioFormat
    /// Rebuilt whenever the microphone's format changes under us — a route
    /// change (AirPods arriving) hands the tap a different format, and a
    /// converter built for the old one would turn speech into noise.
    private var inputFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var ratio: Double
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?

    init?(from input: AVAudioFormat, to output: AVAudioFormat) {
        outputFormat = output
        inputFormat = input
        ratio = output.sampleRate / max(input.sampleRate, 1)
        if input != output {
            guard let converter = AVAudioConverter(from: input, to: output) else {
                return nil
            }
            self.converter = converter
        }
    }

    /// The tap is the only caller, so this is serial with itself.
    private func adopt(_ format: AVAudioFormat) {
        guard format != inputFormat else { return }
        inputFormat = format
        ratio = outputFormat.sampleRate / max(format.sampleRate, 1)
        converter = format == outputFormat
            ? nil
            : AVAudioConverter(from: format, to: outputFormat)
    }

    func attach(_ continuation: AsyncStream<AnalyzerInput>.Continuation) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        adopt(buffer.format)
        guard let converted = convert(buffer) else { return }
        lock.lock()
        let continuation = self.continuation
        lock.unlock()
        continuation?.yield(AnalyzerInput(buffer: converted))
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter else { return buffer }
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: capacity
        ) else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            // The block is asked for input until it says there is none; this
            // buffer is all there is for this call.
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }
}
#endif

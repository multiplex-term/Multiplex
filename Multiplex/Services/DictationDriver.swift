import Foundation

/// One mic control's take: a `DictationSession` driven from a button, and the
/// state its chrome renders. The pane (rail key / lock tip, typing into the
/// session) and the Talkback composer (writing into the draft) each own one;
/// they differ only in where `onText` delivers. Starting either cancels the
/// other — `DictationSession`'s one-mic-app-wide rule.
@MainActor
final class DictationDriver {
    enum State: Equatable {
        case idle
        /// Pressed, and waiting on the permission alerts or the engine — the
        /// control latches, but nothing claims to be listening yet (the first
        /// press can sit behind two system alerts).
        case starting
        /// The microphone is open; `pending` is heard, not yet delivered.
        case listening(pending: String)
        /// A short, actionable reason the take could not run or ended.
        case failed(String)

        /// The mic is engaged: pressed, or open.
        var isActive: Bool {
            switch self {
            case .starting, .listening: true
            case .idle, .failed: false
            }
        }
    }

    /// How long a failure stays on screen.
    static let failureDisplay: Duration = .seconds(4)

    private(set) var state: State = .idle {
        didSet {
            guard state != oldValue else { return }
            onStateChange?()
        }
    }

    var onStateChange: (() -> Void)?
    /// One settled chunk, exactly as `DictationStream` emits it.
    var onText: ((String) -> Void)?

    private var session: DictationSession?
    private var clearTask: Task<Void, Never>?

    var isActive: Bool { state.isActive }

    func start() {
        guard !isActive else { return }
        clearTask?.cancel()
        state = .starting
        let session = session ?? DictationSession()
        self.session = session
        session.start(
            locale: DictationLanguageSetting.chosenLocale(),
            onStart: { [weak self] in
                guard let self, state == .starting else { return }
                state = .listening(pending: "")
            },
            onText: { [weak self] settled in
                self?.onText?(settled)
            },
            onPending: { [weak self] pending in
                guard let self, isActive else { return }
                state = .listening(pending: DictationText.preview(pending))
            },
            onFinish: { [weak self] outcome in
                self?.finish(outcome)
            }
        )
    }

    /// Finish normally: the tail the hold rules were keeping is delivered on
    /// the way out. A press that has not reached the microphone yet has
    /// nothing to deliver, so it simply abandons the attempt.
    func stop() {
        guard let session else { return }
        if session.isListening {
            session.stop()
        } else {
            session.cancel()
        }
    }

    /// Leave without the unsettled tail — what was delivered stays — and
    /// clear any failure still on screen.
    func cancel() {
        clearTask?.cancel()
        if case .failed = state { state = .idle }
        session?.cancel()
    }

    /// The language chip: persist the pick and, mid-take, restart in the new
    /// language — the recognizer heard the old one, and "applies next time"
    /// from a control pressed mid-take would read as the pick not working.
    /// A full restart, not an in-place engine swap: a recognition task created
    /// while the daemon tears its predecessor down comes back dead.
    func selectLanguage(_ choice: DictationLanguageChoice) {
        DictationLanguageSetting.setChosen(choice.id)
        guard isActive else { return }
        session?.cancel()
        start()
    }

    private func finish(_ outcome: DictationSession.Outcome) {
        guard case .failure(let message) = outcome else {
            state = .idle
            return
        }
        state = .failed(message)
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: Self.failureDisplay)
            guard !Task.isCancelled, let self, case .failed = state else { return }
            state = .idle
        }
    }
}

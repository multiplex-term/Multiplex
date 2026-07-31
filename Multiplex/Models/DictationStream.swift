import Foundation

/// Turns the recognizer's stream of hypotheses into text the pane can type
/// *while the person is still speaking* — the continuous feel of the system
/// keyboard's dictation, on a surface that works nothing like a text field.
///
/// The keyboard dictates into a document it owns, so when the recognizer
/// changes its mind about a word three words back it simply rewrites it.
/// A terminal is the opposite: a byte handed to `TerminalView.send` has left
/// the app, and there is no honest way to take it back. Backspaces would be
/// aimed at a remote composer whose contents this app cannot see — one Enter,
/// one keystroke of the user's own, or one line of agent output in between
/// and they would delete somebody else's text. So nothing is ever retracted;
/// instead a word is held back until the recognizer has stopped reconsidering
/// it, and only then does it become bytes.
///
/// Two ordinal rules decide that, and neither needs a clock (which is what
/// keeps this model pure and its tests exact):
///
/// - **Tail hold** — the newest `tailHold` words are the ones being revised,
///   so they are never committed. A word becomes eligible once the recognizer
///   has moved that far past it.
/// - **Hold updates** — the word must also have survived `holdUpdates`
///   consecutive hypotheses unchanged at its own index. A revision resets its
///   count, so a word the recognizer is still trading in and out waits.
///
/// The third rule lives with the caller, because it is about silence rather
/// than about words: hypotheses only arrive while there is speech, so a
/// pause means the recognizer has settled and `flush()` commits everything
/// heard. That is what makes a spoken phrase land promptly instead of hanging
/// two words short until the next sentence starts.
///
/// The baseline for "already typed" is the typed **text**, never a position
/// in the hypothesis (see `rebase`). A recognizer endpoints inside a single
/// task and starts its next hypothesis over, so it comes back shorter than
/// what has gone out; a positional baseline could then never be passed again
/// and every later word was swallowed in silence while the microphone stayed
/// open. That was the "types the first sentence, then LISTENING forever"
/// bug, and `testANewUtteranceInTheSameSegmentKeepsTyping` is its shape.
struct DictationStream {
    /// Text to hand the session, and what is still only heard.
    struct Emission: Equatable {
        /// Terminal-safe bytes to type now, word separator included, or nil
        /// when nothing settled. Already sanitized by construction — it is
        /// built from `DictationText.words`, so it can carry no control byte
        /// and no line break, and it must NOT be re-run through
        /// `DictationText.typed`, which would eat the leading separator.
        var typed: String?
        /// Heard but not typed: the dictation bar's queue. Everything before
        /// it is already in the session.
        var pending: String
    }

    /// How many words at the leading edge are assumed to still be in play.
    /// A tuning knob: larger buys accuracy and costs lag.
    var tailHold = 2
    /// How many consecutive hypotheses a word must hold its index unchanged
    /// before it counts as settled.
    var holdUpdates = 2

    /// The current segment's hypothesis, and how long each of its words has
    /// held its place.
    private var words: [String] = []
    private var runs: [Int] = []
    /// The words this segment has actually typed — kept as *text*, never as a
    /// position. A recognizer that endpoints inside one task starts its next
    /// hypothesis over, so it comes back shorter than what went out; a
    /// positional baseline could then never be passed again and every later
    /// word was swallowed in silence, with the microphone still open. That
    /// was the "types once, then LISTENING forever" bug.
    private var typedWords: [String] = []
    /// Whether this dictation has typed anything at all — decides whether the
    /// next chunk needs a separating space in front of it. Unlike
    /// `typedWords`, this survives a rebase: it is about the whole take.
    private(set) var hasTyped = false

    init() {}

    private var typedCount: Int { typedWords.count }

    /// Everything heard in this segment that has not been typed.
    var pending: String {
        guard words.count > typedCount else { return "" }
        return words[typedCount...].joined(separator: " ")
    }

    /// Take a partial hypothesis and commit whatever it settles.
    mutating func heard(_ raw: String) -> Emission {
        absorb(raw)
        return emit(upTo: settledCount)
    }

    /// Take a hypothesis without committing anything — for a final result,
    /// which the caller follows with `endSegment()`.
    mutating func absorb(_ raw: String) {
        let next = DictationText.words(raw)
        var nextRuns = [Int](repeating: 1, count: next.count)
        for index in 0..<commonPrefix(words, next) {
            nextRuns[index] = runs[index] + 1
        }
        words = next
        runs = nextRuns
        rebase()
    }

    /// Line the typed text up against the hypothesis in front of it.
    ///
    /// Everything the recognizer can do to a hypothesis has to land
    /// somewhere honest here:
    ///
    /// - It extends it — the common case. The shared prefix covers all of
    ///   the typed words and the baseline stands.
    /// - It re-punctuates or re-capitalizes words already typed, which
    ///   auto-punctuation does at every endpoint. Comparison ignores case and
    ///   punctuation, so this still counts as covered and nothing is typed
    ///   twice.
    /// - It changes its mind about a word, or starts a whole new sentence.
    ///   Then the typed text stops matching, and the baseline drops back to
    ///   where the two agree — so the words after that point go out rather
    ///   than being counted as already sent. **Nothing typed is retracted**;
    ///   the worst case is a revised word arriving twice, which is visible,
    ///   while the alternative was a stream that went silent forever.
    private mutating func rebase() {
        let shared = commonPrefix(typedWords, words, normalized: true)
        guard shared < typedWords.count else { return }
        typedWords = Array(typedWords.prefix(shared))
    }

    /// The speaker paused, so the hold rules have nothing left to protect:
    /// commit everything heard. The segment continues — a hypothesis that
    /// grows afterwards resumes from here.
    mutating func flush() -> Emission {
        emit(upTo: words.count)
    }

    /// This recognition task is done (a final result, or one that died and is
    /// being replaced). Commit its last words and start the next segment's
    /// hypothesis from scratch, keeping the typed-anything state so the join
    /// between segments still gets its space.
    mutating func endSegment() -> Emission {
        let emission = flush()
        words = []
        runs = []
        typedWords = []
        return emission
    }

    // MARK: Internals

    /// How far into the hypothesis the two rules allow committing.
    private var settledCount: Int {
        let edge = words.count - tailHold
        guard edge > typedCount else { return typedCount }
        var count = typedCount
        while count < edge, runs[count] >= holdUpdates { count += 1 }
        return count
    }

    private mutating func emit(upTo count: Int) -> Emission {
        guard count > typedCount, count <= words.count else {
            return Emission(typed: nil, pending: pending)
        }
        let going = Array(words[typedCount..<count])
        typedWords.append(contentsOf: going)
        let chunk = going.joined(separator: " ")
        let text = hasTyped ? " " + chunk : chunk
        hasTyped = true
        return Emission(typed: text, pending: pending)
    }

    private func commonPrefix(
        _ lhs: [String],
        _ rhs: [String],
        normalized: Bool = false
    ) -> Int {
        var count = 0
        while count < lhs.count, count < rhs.count {
            let same = normalized
                ? Self.compared(lhs[count]) == Self.compared(rhs[count])
                : lhs[count] == rhs[count]
            guard same else { break }
            count += 1
        }
        return count
    }

    /// What two words are compared by when deciding whether a hypothesis
    /// still covers what was typed: the recognizer adds commas and capitals
    /// to words it has already said, and that is a revision of the same word,
    /// not a different one.
    private static func compared(_ word: String) -> String {
        let stripped = word.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }
        let text = String(String.UnicodeScalarView(stripped)).lowercased()
        return text.isEmpty ? word.lowercased() : text
    }
}

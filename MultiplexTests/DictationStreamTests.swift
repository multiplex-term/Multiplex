import XCTest
@testable import Multiplex

final class DictationStreamTests: XCTestCase {
    /// The defaults: a word is typed once two newer words sit behind it and
    /// it has held its index for two hypotheses.
    private func makeStream() -> DictationStream { DictationStream() }

    /// Everything typed across a whole run, exactly as the pane would
    /// receive it — so the assertions read like the composer's contents.
    private func typed(_ emissions: [DictationStream.Emission]) -> String {
        emissions.compactMap(\.typed).joined()
    }

    // MARK: Streaming as you speak

    func testWordsAreTypedWhileTheHypothesisIsStillGrowing() {
        var stream = makeStream()
        var out: [DictationStream.Emission] = []
        // The recognizer keeps repeating the whole hypothesis; each new word
        // pushes an older one past both hold rules.
        for hypothesis in [
            "run",
            "run the",
            "run the tests",
            "run the tests again",
            "run the tests again now",
        ] {
            out.append(stream.heard(hypothesis))
        }
        XCTAssertEqual(typed(out), "run the tests")
        XCTAssertEqual(out.last?.pending, "again now")
    }

    /// The newest two words are always in play, so they stay in the queue no
    /// matter how settled everything in front of them is.
    func testTheLeadingEdgeIsAlwaysHeldBack() {
        var stream = makeStream()
        XCTAssertNil(stream.heard("one two three").typed)
        XCTAssertEqual(stream.heard("one two three").typed, "one")
        XCTAssertEqual(stream.pending, "two three")
    }

    /// A word that appears for the first time is never typed in the same
    /// breath, even with plenty of words behind it: the recognizer trades the
    /// leading edge in and out, and the second sighting is the confirmation.
    func testAWordMustSurviveASecondHypothesis() {
        var stream = makeStream()
        XCTAssertNil(stream.heard("one two three four five").typed)
        XCTAssertEqual(stream.heard("one two three four five").typed, "one two three")
    }

    // MARK: Revisions

    func testARevisedTailIsNeverTypedTwice() {
        var stream = makeStream()
        var out: [DictationStream.Emission] = []
        out.append(stream.heard("recognise beach"))
        out.append(stream.heard("recognise beach please"))
        // The recognizer reconsiders everything it has heard so far.
        out.append(stream.heard("recognise speech please now"))
        out.append(stream.heard("recognise speech please now thanks"))
        // "recognise" settled before the revision landed, so it stands; the
        // word it changed its mind about was still in the queue and goes out
        // corrected, and nothing is ever said twice.
        XCTAssertEqual(typed(out), "recognise speech please")
        XCTAssertFalse(typed(out).contains("beach"))
    }

    /// A word the recognizer swaps restarts its own hold while its settled
    /// neighbour goes out — that is the rule doing its job, one index at a
    /// time.
    func testARevisedWordWaitsWhileItsNeighbourGoesOut() {
        var stream = makeStream()
        XCTAssertNil(stream.heard("alpha bravo charlie delta").typed)
        XCTAssertEqual(stream.heard("alpha brave charlie delta").typed, "alpha")
        XCTAssertEqual(stream.heard("alpha brave charlie delta").typed, " brave")
    }

    /// A hypothesis that collapses to fewer words than were typed cannot
    /// un-type them, and must not replay the words that come back.
    func testAShrunkHypothesisTypesNothingAgain() {
        var stream = makeStream()
        _ = stream.heard("one two three four")
        XCTAssertEqual(stream.heard("one two three four").typed, "one two")
        XCTAssertNil(stream.heard("one").typed)
        XCTAssertEqual(stream.pending, "")
        XCTAssertNil(stream.heard("one two").typed)
    }

    // MARK: Pauses and segment ends

    func testAPauseTypesEverythingHeard() {
        var stream = makeStream()
        _ = stream.heard("commit the fix")
        XCTAssertEqual(stream.flush().typed, "commit the fix")
        XCTAssertEqual(stream.pending, "")
        // A flush is not an ending: the same hypothesis may keep growing.
        XCTAssertNil(stream.heard("commit the fix now").typed)
        XCTAssertEqual(stream.flush().typed, " now")
    }

    func testFlushingTwiceTypesNothingTwice() {
        var stream = makeStream()
        _ = stream.heard("hello there")
        XCTAssertEqual(stream.flush().typed, "hello there")
        XCTAssertNil(stream.flush().typed)
    }

    /// The recognition task rolls (endpoint, or a recognizer that gives up
    /// after a minute) and the next one starts from an empty hypothesis. The
    /// dictation is still one dictation, so the join gets its space.
    func testRolledSegmentsJoinWithASpace() {
        var stream = makeStream()
        _ = stream.heard("first sentence")
        XCTAssertEqual(stream.endSegment().typed, "first sentence")
        _ = stream.heard("second sentence")
        XCTAssertEqual(stream.endSegment().typed, " second sentence")
    }

    func testAnEmptySegmentTypesNothing() {
        var stream = makeStream()
        XCTAssertNil(stream.endSegment().typed)
        XCTAssertFalse(stream.hasTyped)
    }

    func testAbsorbUpdatesTheHypothesisWithoutTyping() {
        var stream = makeStream()
        _ = stream.heard("one two three four")
        stream.absorb("one two three four five")
        XCTAssertEqual(stream.endSegment().typed, "one two three four five")
    }

    // MARK: Restarted hypotheses

    /// **The "it types once and then never again" failure.** A recognizer
    /// that endpoints inside one task starts its next hypothesis over, so it
    /// comes back SHORTER than what was already typed. A baseline kept as a
    /// position can never be passed again — every later word is swallowed in
    /// silence while the microphone stays open, which is exactly what a
    /// terminal user sees as "still LISTENING, but dead".
    func testANewUtteranceInTheSameSegmentKeepsTyping() {
        var stream = makeStream()
        var out: [DictationStream.Emission] = []
        out.append(stream.heard("please run the tests again now"))
        out.append(stream.heard("please run the tests again now"))
        out.append(stream.flush())
        XCTAssertEqual(typed(out), "please run the tests again now")
        // The speaker pauses, then starts a new sentence; the recognizer
        // hands back a hypothesis for that sentence alone.
        out.append(stream.heard("and commit"))
        out.append(stream.heard("and commit the fix"))
        out.append(stream.flush())
        XCTAssertEqual(typed(out), "please run the tests again now and commit the fix")
    }

    /// Re-punctuating and capitalizing what was already typed is a revision,
    /// not a new sentence: the recognizer does it at every endpoint with
    /// auto-punctuation on, and re-typing it would double the phrase.
    func testAPunctuationRevisionOfTypedTextIsNotRetyped() {
        var stream = makeStream()
        _ = stream.heard("commit the fix")
        XCTAssertEqual(stream.flush().typed, "commit the fix")
        XCTAssertNil(stream.heard("Commit the fix.").typed)
        XCTAssertNil(stream.heard("Commit the fix.").typed)
        XCTAssertEqual(stream.flush().typed, nil)
    }

    /// A hypothesis that keeps growing after a pause-flush must keep going
    /// too — the flush is not the end of the segment.
    func testGrowthAfterAFlushStillTypes() {
        var stream = makeStream()
        _ = stream.heard("run the tests")
        XCTAssertEqual(stream.flush().typed, "run the tests")
        _ = stream.heard("run the tests again")
        XCTAssertEqual(stream.flush().typed, " again")
    }

    // MARK: Safety

    /// Chunks are handed to `TerminalView.send` verbatim, so the sanitizing
    /// `DictationText` does for a one-shot dictation has to hold for every
    /// streamed piece: no control bytes, and above all no CR — a submit would
    /// run whatever is in the composer mid-sentence.
    func testStreamedChunksCanCarryNoControlBytes() {
        var stream = makeStream()
        var out: [DictationStream.Emission] = []
        out.append(stream.heard("line one\nline\u{1B}two"))
        out.append(stream.heard("line one\nline\u{1B}two three\r\nfour"))
        out.append(stream.flush())
        let text = typed(out)
        XCTAssertEqual(text, "line one line two three four")
        for scalar in text.unicodeScalars {
            XCTAssertNotEqual(scalar.properties.generalCategory, .control)
        }
    }

    func testSpeechIsTypedVerbatimAndUnquoted() {
        var stream = makeStream()
        _ = stream.heard("git commit -m \"fix: retry\"")
        XCTAssertEqual(stream.flush().typed, "git commit -m \"fix: retry\"")
    }

    func testNonASCIISpeechSurvives() {
        var stream = makeStream()
        _ = stream.heard("重新執行測試")
        XCTAssertEqual(stream.flush().typed, "重新執行測試")
    }

    /// The whole run, end to end: the composer's contents must read exactly
    /// like what was said, with no duplicated or dropped word at any seam.
    func testAWholeDictationReadsAsOneSentence() {
        var stream = makeStream()
        var out: [DictationStream.Emission] = []
        for hypothesis in [
            "add", "add a", "add a retry", "add a retry to",
            "add a retry to the", "add a retry to the probe",
        ] {
            out.append(stream.heard(hypothesis))
        }
        out.append(stream.flush())          // the speaker pauses
        out.append(stream.endSegment())     // the recognizer endpoints there
        for hypothesis in ["then", "then run", "then run the tests"] {
            out.append(stream.heard(hypothesis))
        }
        out.append(stream.endSegment())     // STOP
        XCTAssertEqual(typed(out), "add a retry to the probe then run the tests")
    }
}

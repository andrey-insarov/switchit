import XCTest
@testable import SwitchitCore

/// The typing state machine against the behaviour spec (docs/PLAN.md, "Behaviour while typing")
/// and the stage-2 rules: report once per word mid-word, nothing while paused or in a password
/// field, shortcuts end a word silently, arrows and Backspace-past-start veto it.
final class TypingObserverTests: XCTestCase {
    private func observer(active: String? = "en") -> TypingObserver {
        TypingObserver(detector: TestDetector.shared, active: active)
    }

    private func type(_ s: String, _ o: inout TypingObserver, shift: Bool = false) -> [TypingObserver.Decision] {
        Keys.codes(s).map { o.handle(.key($0, shift ? [.shift] : [])) }
    }

    // MARK: Spec 1 — mid-word, once, from the 3rd letter

    func testPriverTypedInEnglishIsReportedAtTheThirdLetterOnce() {
        var o = observer()
        let d = type("ghbdtn", &o)
        XCTAssertEqual(d[0], .none)
        XCTAssertEqual(d[1], .none)
        XCTAssertEqual(d[2], .midWord(keys: Keys.codes("ghb"), letters: 3, from: "en", to: "ru"))
        XCTAssertEqual(Array(d[3...]), [.none, .none, .none], "reported once per word")
        // The boundary still reports the whole word (stage 3 will already have switched).
        XCTAssertEqual(o.handle(.key(.space, [])), .boundary(keys: Keys.codes("ghbdtn"), terminator: .space, from: "en", to: "ru"))
        XCTAssertFalse(o.midWordReported, "cleared at the boundary")
    }

    func testFirstCapitalDoesNotStopTheMidWordDecision() {
        // `Ghb` as in the spec: Shift on the first letter only.
        var o = observer()
        XCTAssertEqual(o.handle(.key(.g, [.shift])), .none)
        XCTAssertEqual(o.handle(.key(.h, [])), .none)
        XCTAssertEqual(o.handle(.key(.b, [])), .midWord(keys: Keys.codes("ghb"), letters: 3, from: "en", to: "ru"))
    }

    func testTwoCapitalsAreLeftAlone() {
        var o = observer()
        XCTAssertEqual(type("ghb", &o, shift: true).last, TypingObserver.Decision.none)
        XCTAssertEqual(type("dtn", &o, shift: true).last, TypingObserver.Decision.none)
        XCTAssertEqual(o.handle(.key(.space, [])), .leftAlone(keys: Keys.codes("ghbdtn"), terminator: .space, from: "en", verdict: nil))
    }

    func testCorrectEnglishIsLeftAlone() {
        var o = observer()
        XCTAssertTrue(type("hello", &o).allSatisfy { $0 == .none })
        XCTAssertEqual(o.handle(.key(.space, [])), .leftAlone(keys: Keys.codes("hello"), terminator: .space, from: "en", verdict: "en"))
    }

    func testEnglishTypedInRussianLayout() {
        var o = observer(active: "ru")
        let d = type("hello", &o)
        XCTAssertEqual(d[2], .none, "руд is a Russian word start; the 3rd letter is not enough")
        XCTAssertEqual(d[3], .midWord(keys: Keys.codes("hell"), letters: 4, from: "ru", to: "en"))
        XCTAssertEqual(o.handle(.key(.return, [])), .boundary(keys: Keys.codes("hello"), terminator: .return, from: "ru", to: "en"))
    }

    func testLaterLettersAreTriedWhenTheThirdIsNotEnough() {
        // удачи = elfxb: the reference catches it at the 4th letter.
        var o = observer()
        let d = type("elfxb", &o)
        XCTAssertEqual(d[2], .none)
        XCTAssertEqual(d[3], .midWord(keys: Keys.codes("elfx"), letters: 4, from: "en", to: "ru"))
    }

    // MARK: Spec 3 — veto

    func testArrowVetoesTheWord() {
        var o = observer()
        _ = type("gh", &o)
        XCTAssertEqual(o.handle(.key(.leftArrow, [])), .none)
        XCTAssertTrue(type("bdtn", &o).allSatisfy { $0 == .none }, "no mid-word decision after the veto")
        XCTAssertEqual(o.handle(.key(.space, [])), .none, "nothing reported at the boundary either")
    }

    func testArrowWithFnFlagStillVetoes() {
        // Apple keyboards report fn on the arrow keys themselves.
        var o = observer()
        _ = type("gh", &o)
        XCTAssertEqual(o.handle(.key(.rightArrow, [.function])), .none)
        XCTAssertTrue(type("bdtn", &o).allSatisfy { $0 == .none })
        XCTAssertEqual(o.handle(.key(.space, [])), .none)
    }

    func testBackspacePastTheStartVetoes() {
        var o = observer()
        XCTAssertEqual(o.handle(.key(.delete, [])), .none)
        XCTAssertTrue(type("ghbdtn", &o).allSatisfy { $0 == .none })
        XCTAssertEqual(o.handle(.key(.space, [])), .none)
        // The next word is observed again.
        XCTAssertEqual(type("ghb", &o).last, .midWord(keys: Keys.codes("ghb"), letters: 3, from: "en", to: "ru"))
    }

    // MARK: Shortcuts and Option

    func testCommandShortcutEndsTheWordSilently() {
        var o = observer()
        _ = type("ghb", &o)                                   // mid-word already reported
        XCTAssertEqual(o.handle(.key(.s, [.command])), .none)  // ⌘S
        XCTAssertFalse(o.midWordReported)
        XCTAssertEqual(o.handle(.key(.space, [])), .none, "the word is gone, not reported")
    }

    func testOptionCharacterIsABoundary() {
        var o = observer()
        _ = type("ghbdtn", &o)
        // ⌥8 (•) ends the word like punctuation would, and the word is decided.
        XCTAssertEqual(o.handle(.key(.eight, [.option])), .boundary(keys: Keys.codes("ghbdtn"), terminator: .eight, from: "en", to: "ru"))
    }

    // MARK: Pause, secure input, layouts, flushes

    func testNothingWhilePaused() {
        var o = observer()
        XCTAssertEqual(o.handle(.paused(true)), .none)
        XCTAssertFalse(o.isObserving)
        XCTAssertTrue(type("ghbdtn", &o).allSatisfy { $0 == .none })
        XCTAssertEqual(o.handle(.key(.space, [])), .none)
        XCTAssertEqual(o.handle(.paused(false)), .none)
        XCTAssertEqual(type("ghb", &o).last, .midWord(keys: Keys.codes("ghb"), letters: 3, from: "en", to: "ru"))
    }

    func testSecureInputDropsTheWordAndObservesNothing() {
        var o = observer()
        _ = type("gh", &o)
        XCTAssertEqual(o.handle(.secureInput(true)), .none)
        XCTAssertTrue(o.buffer.isEmpty)
        XCTAssertTrue(type("bdtn", &o).allSatisfy { $0 == .none })
        XCTAssertEqual(o.handle(.secureInput(false)), .none)
        XCTAssertTrue(o.buffer.isEmpty, "what was typed in the password field is not kept")
    }

    func testUnknownLayoutObservesNothing() {
        var o = observer(active: nil)
        XCTAssertFalse(o.isObserving)
        XCTAssertTrue(type("ghbdtn", &o).allSatisfy { $0 == .none })
        XCTAssertEqual(o.handle(.layoutChanged(language: "en")), .none)
        XCTAssertEqual(type("ghb", &o).last, .midWord(keys: Keys.codes("ghb"), letters: 3, from: "en", to: "ru"))
    }

    func testLayoutChangeDropsTheWord() {
        var o = observer()
        _ = type("ghb", &o)
        XCTAssertEqual(o.handle(.layoutChanged(language: "ru")), .none)
        XCTAssertTrue(o.buffer.isEmpty)
        XCTAssertEqual(o.active, "ru")
    }

    func testClickAndAppChangeFlushTheWord() {
        var o = observer()
        _ = type("ghbdtn", &o)
        XCTAssertEqual(o.handle(.flush(.click)), .boundary(keys: Keys.codes("ghbdtn"), terminator: nil, from: "en", to: "ru"))
        _ = type("hello", &o)
        XCTAssertEqual(o.handle(.flush(.appChanged)), .leftAlone(keys: Keys.codes("hello"), terminator: nil, from: "en", verdict: "en"))
        XCTAssertEqual(o.handle(.flush(.click)), .none, "nothing buffered")
    }

    func testWordKeysAreTheUnionOfTheLayouts() {
        let o = observer()
        XCTAssertTrue(o.buffer.wordKeys.contains(.semicolon), "ж in Russian")
        XCTAssertTrue(o.buffer.wordKeys.contains(.grave), "ё in Russian – PC")
        XCTAssertFalse(o.buffer.wordKeys.contains(.one))
    }
}

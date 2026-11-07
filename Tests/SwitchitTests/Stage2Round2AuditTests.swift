import XCTest
@testable import SwitchitCore

/// The auditor's stage-2 round-2 reproducers (7 Nov 2026, PR #2 at 0af6cfa), inverted after the
/// fixes. His cases and names; a failure here is a regression of a closed finding.
final class Stage2Round2AuditTests: XCTestCase {
    private var models: [String: LanguageModel] {
        Dictionary(uniqueKeysWithValues: TestDetector.shared.languages.map { ($0.code, $0.model) })
    }

    private func type(_ text: String, into observer: inout TypingObserver) -> [TypingObserver.Decision] {
        Keys.codes(text).map { observer.handle(.key($0, [])) }
    }

    // MARK: P1 — an empty layout enumeration observes nothing; no default table stands in

    func testP1EmptyLayoutEnumerationObservesNothing() {
        var observer = TypingObserver(models: models, layouts: [:], active: nil)
        let selected = Layout.forInputSource(id: "com.apple.keylayout.Russian")!
        _ = observer.handle(.layoutChanged(active: selected.code, layouts: [:]))
        XCTAssertFalse(observer.isObserving)
        XCTAssertTrue(observer.detector.languages.isEmpty, "no Russian – PC standing in for Russian")
        XCTAssertNil(observer.activeLayout)
        _ = observer.handle(.key(.t, []))
        _ = observer.handle(.key(.o, []))
        XCTAssertEqual(observer.handle(.key(.backslash, [])), .none)
        XCTAssertEqual(observer.handle(.key(.space, [])), .none)
        XCTAssertEqual(observer.handle(.flush(.click)), .none)
        // The enumeration comes back: observing resumes with the *selected* table.
        _ = observer.handle(.layoutChanged(active: "ru", layouts: ["en": .usEnglish, "ru": selected.layout]))
        XCTAssertTrue(observer.isObserving)
        XCTAssertEqual(observer.activeLayout?.id, Layout.russian.id)
        XCTAssertTrue(observer.buffer.wordKeys.contains(.backslash))
    }

    func testP1EmptyDetectorDecidesNothing() {
        let empty = LayoutDetector(languages: [])
        XCTAssertNil(empty.decideWord(Keys.codes("ghbdtn"), active: "en"))
        XCTAssertNil(empty.decidePrefix(Keys.codes("ghb"), active: "en"))
    }

    // MARK: P2 — a plain shortcut keeps the caret veto; Forward Delete is an edit, not a boundary

    func testP2PlainShortcutKeepsTheCaretVetoUntilTheBoundary() {
        var observer = TypingObserver(detector: TestDetector.shared, active: "en")
        _ = observer.handle(.key(.leftArrow, [.command]))
        XCTAssertTrue(observer.buffer.suppressed)
        _ = observer.handle(.key(.b, [.command]))                  // ⌘B: bold, the caret stays
        XCTAssertTrue(observer.buffer.suppressed)
        XCTAssertTrue(type("ghb", into: &observer).allSatisfy { $0 == .none })
        XCTAssertEqual(observer.handle(.key(.space, [])), .none)
        XCTAssertFalse(observer.buffer.suppressed)
        XCTAssertEqual(type("ghb", into: &observer).last, .midWord(keys: [.g, .h, .b], letters: 3, from: "en", to: "ru"))
    }

    func testP2PlainShortcutMidWordVetoesTheRestOfTheWord() {
        // ⌘S in the middle of `ghbdtn`: the letters typed afterwards join `ghb` on screen, so
        // nothing is said about `dtn` on its own.
        var observer = TypingObserver(detector: TestDetector.shared, active: "en")
        _ = type("ghb", into: &observer)
        XCTAssertEqual(observer.handle(.key(.s, [.command])), .none)
        XCTAssertFalse(observer.midWordReported)
        XCTAssertTrue(type("dtn", into: &observer).allSatisfy { $0 == .none })
        XCTAssertEqual(observer.handle(.key(.space, [])), .none)
    }

    func testP2ForwardDeleteVetoesTheWord() {
        var observer = TypingObserver(detector: TestDetector.shared, active: "en")
        _ = type("ghbdtn", into: &observer)
        XCTAssertEqual(observer.handle(.key(.forwardDelete, [.function])), .none)
        XCTAssertTrue(observer.buffer.suppressed)
        XCTAssertEqual(observer.handle(.key(.space, [])), .none)
        var plain = TypingObserver(detector: TestDetector.shared, active: "en")
        _ = type("ghbdtn", into: &plain)
        XCTAssertEqual(plain.handle(.key(.forwardDelete, [])), .none)
        XCTAssertTrue(plain.buffer.suppressed)
    }

    func testP2HomeEndAndPageKeysVetoLikeArrows() {
        for key in [KeyCode.home, .end, .pageUp, .pageDown] {
            var observer = TypingObserver(detector: TestDetector.shared, active: "en")
            _ = type("ghbdtn", into: &observer)
            XCTAssertEqual(observer.handle(.key(key, [.function])), .none, "\(key)")
            XCTAssertTrue(observer.buffer.suppressed, "\(key)")
            XCTAssertEqual(observer.handle(.key(.space, [])), .none, "\(key)")
        }
    }

    // MARK: P2 — a dead key of the selected layout vetoes without Option

    func testP2UnmodifiedInternationalDeadKeyVetoes() {
        let selected = Layout.forInputSource(id: "com.apple.keylayout.USInternational-PC")!
        XCTAssertEqual(selected.layout.id, Layout.usInternationalPC.id)
        var observer = TypingObserver(models: models, layouts: ["en": selected.layout, "ru": .russianPC], active: "en")
        // U.S. International – PC translates quote + e to a single é: `caf'e` is café on screen.
        for key in Keys.codes("caf'e") { _ = observer.handle(.key(key, [])) }
        XCTAssertTrue(observer.buffer.suppressed)
        XCTAssertTrue(observer.buffer.isEmpty)
        XCTAssertEqual(observer.handle(.key(.space, [])), .none)
        // `"` (Shift-quote), `` ` ``, `~` and `^` (Shift-6) are dead keys too; plain 6 is a digit.
        for stroke in [KeyStroke(.quote, shift: true), KeyStroke(.grave), KeyStroke(.grave, shift: true), KeyStroke(.six, shift: true)] {
            var o = TypingObserver(models: models, layouts: ["en": selected.layout, "ru": .russianPC], active: "en")
            _ = type("ghbdtn", into: &o)
            XCTAssertEqual(o.handle(.key(stroke.code, stroke.shift ? [.shift] : [])), .none, "\(stroke)")
            XCTAssertTrue(o.buffer.suppressed, "\(stroke)")
        }
        var digit = TypingObserver(models: models, layouts: ["en": selected.layout, "ru": .russianPC], active: "en")
        _ = type("ghbdtn", into: &digit)
        XCTAssertEqual(digit.handle(.key(.six, [])), .boundary(keys: Keys.codes("ghbdtn"), terminator: .six, from: "en", to: "ru"))
        // On plain U.S. the quote is ordinary punctuation and ends the word.
        var us = TypingObserver(detector: TestDetector.shared, active: "en")
        _ = type("ghbdtn", into: &us)
        XCTAssertEqual(us.handle(.key(.quote, [])), .boundary(keys: Keys.codes("ghbdtn"), terminator: .quote, from: "en", to: "ru"))
        XCTAssertTrue(Layout.usEnglish.deadKeys.isEmpty)
        XCTAssertTrue(Layout.russian.deadKeys.isEmpty)
        XCTAssertTrue(Layout.russianPC.deadKeys.isEmpty)
    }
}

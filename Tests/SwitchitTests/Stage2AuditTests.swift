import XCTest
@testable import SwitchitCore

/// The auditor's stage-2 reproducers (7 Nov 2026, PR #2 at b09cd3d), inverted after the fixes.
/// The cases and the structure are his; a failure here is a regression of a closed finding.
final class Stage2AuditTests: XCTestCase {
    private func type(_ text: String, into observer: inout TypingObserver,
                      modifiers: TypingObserver.Modifiers = []) -> [TypingObserver.Decision] {
        Keys.codes(text).map { observer.handle(.key($0, modifiers)) }
    }

    /// The word reached the boundary intact and was not switched (the verdict itself — the
    /// language or `nil` for a protected word — is the detector's business, tested elsewhere).
    private func assertLeftAlone(_ d: TypingObserver.Decision, keys: [KeyCode], file: StaticString = #filePath, line: UInt = #line) {
        guard case .leftAlone(let k, _, _, _) = d else { return XCTFail("expected leftAlone, got \(d)", file: file, line: line) }
        XCTAssertEqual(k, keys, file: file, line: line)
    }

    private var models: [String: LanguageModel] {
        Dictionary(uniqueKeysWithValues: TestDetector.shared.languages.map { ($0.code, $0.model) })
    }

    // MARK: P1 — the Russian table must follow the selected layout (ё on \ or on `)

    func testP1SelectedRussianLayoutDecidesWhereYoIs() {
        // Russian (Apple): ё on the backslash key. ещё = t o \ — one word, left alone.
        var apple = TypingObserver(models: models, layouts: ["en": .usEnglish, "ru": .russian], active: "ru")
        let keys = Keys.codes("to") + [.backslash]
        XCTAssertEqual(Layout.russian.text(for: keys.map { KeyStroke($0) }), "ещё")
        XCTAssertTrue(keys.map { apple.handle(.key($0, [])) }.allSatisfy { $0 == .none })
        assertLeftAlone(apple.handle(.key(.space, [])), keys: keys)
        // Russian – PC: ё on the grave key, and the same word is still one word.
        var pc = TypingObserver(models: models, layouts: ["en": .usEnglish, "ru": .russianPC], active: "ru")
        let pcKeys = Keys.codes("to") + [.grave]
        XCTAssertEqual(Layout.russianPC.text(for: pcKeys.map { KeyStroke($0) }), "ещё")
        XCTAssertTrue(pcKeys.map { pc.handle(.key($0, [])) }.allSatisfy { $0 == .none })
        assertLeftAlone(pc.handle(.key(.space, [])), keys: pcKeys)
        // The layout change rebuilds the detector and the word keys.
        _ = pc.handle(.layoutChanged(active: "ru", layouts: ["en": .usEnglish, "ru": .russian]))
        XCTAssertTrue(pc.buffer.wordKeys.contains(.backslash))
        XCTAssertFalse(pc.buffer.wordKeys.contains(.grave))
        XCTAssertEqual(pc.detector.languages.first { $0.code == "ru" }?.layout.id, Layout.russian.id)
        // мёрфи on the Apple layout: v \ h a b — one word, no mid-word suffix decision.
        var murphy = TypingObserver(models: models, layouts: ["en": .usEnglish, "ru": .russian], active: "ru")
        let m = [KeyCode.v, .backslash, .h, .a, .b]
        XCTAssertTrue(m.map { murphy.handle(.key($0, [])) }.allSatisfy { $0 == .none })
    }

    // MARK: P1 — Caps Lock is a capital

    func testP1CapsLockCountsAsCapitals() {
        var caps = TypingObserver(detector: TestDetector.shared, active: "en")
        XCTAssertTrue(type("kfc", into: &caps, modifiers: .capsLock).allSatisfy { $0 == .none }, "KFC with Caps Lock: two+ capitals, left alone")
        assertLeftAlone(caps.handle(.key(.space, [])), keys: Keys.codes("kfc"))
        var shifted = TypingObserver(detector: TestDetector.shared, active: "en")
        XCTAssertTrue(type("kfc", into: &shifted, modifiers: .shift).allSatisfy { $0 == .none })
        // Caps Lock + Shift is lower case again.
        var both = TypingObserver(detector: TestDetector.shared, active: "en")
        XCTAssertEqual(type("ghb", into: &both, modifiers: [.capsLock, .shift]).last,
                       .midWord(keys: Keys.codes("ghb"), letters: 3, from: "en", to: "ru"))
        XCTAssertTrue(TypingObserver.Modifiers(eventFlags: 0x10000).contains(.capsLock))
        XCTAssertTrue(TypingObserver.Modifiers(eventFlags: 0x10000).uppercase)
        XCTAssertFalse(TypingObserver.Modifiers(eventFlags: 0x10000 | 0x20000).uppercase)
    }

    // MARK: P1 — an input method under a known base layout is not observed

    func testP1InputMethodIsNotAKnownLayout() {
        // The core map knows keyboard layouts only; the app gates by the *selected* source's
        // type before consulting it (InputSources.language(for:)).
        XCTAssertNotNil(Layout.forInputSource(id: "com.apple.keylayout.US"))
        XCTAssertNotNil(Layout.forInputSource(id: "com.apple.keylayout.USInternational-PC"))
        XCTAssertEqual(Layout.forInputSource(id: "com.apple.keylayout.Russian")?.layout.id, Layout.russian.id)
        XCTAssertEqual(Layout.forInputSource(id: "com.apple.keylayout.RussianWin")?.layout.id, Layout.russianPC.id)
        for id in ["com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese", "com.apple.inputmethod.SCIM.ITABC",
                   "com.apple.keylayout.Dvorak", "com.apple.keylayout.Colemak", "com.apple.keylayout.German",
                   "com.apple.keylayout.Russian-Phonetic", ""] {
            XCTAssertNil(Layout.forInputSource(id: id), id)
        }
        // With `active` nil (unknown source) nothing is decided, whatever the base layout.
        var o = TypingObserver(models: models, layouts: ["en": .usEnglish, "ru": .russianPC], active: nil)
        XCTAssertFalse(o.isObserving)
        XCTAssertTrue(type("ghbdtn", into: &o).allSatisfy { $0 == .none })
        XCTAssertEqual(o.handle(.key(.space, [])), .none)
    }

    // MARK: P1 — no decision on stale text at the secure-input transition

    func testP1SecureInputIsAppliedBeforeAnyFlush() {
        // The coordinator now reads the secure-input state before handling a key, a click or an
        // app change (Observation.syncState). In the core the order is what matters: secure
        // first → the stale buffer is dropped without a decision.
        var o = TypingObserver(detector: TestDetector.shared, active: "en")
        _ = type("hello", into: &o)
        XCTAssertEqual(o.handle(.secureInput(true)), .none)
        XCTAssertEqual(o.handle(.flush(.appChanged)), .none)
        XCTAssertEqual(o.handle(.flush(.click)), .none)
        XCTAssertEqual(o.handle(.secureInput(false)), .none)
        XCTAssertEqual(o.handle(.flush(.appChanged)), .none, "nothing survives the transition")
    }

    // MARK: P2 — the mid-word latch is cleared whenever the run ends

    func testP2EscapeClearsTheMidWordLatch() {
        var o = TypingObserver(detector: TestDetector.shared, active: "en")
        _ = type("ghb", into: &o)
        XCTAssertTrue(o.midWordReported)
        XCTAssertEqual(o.handle(.key(.escape, [])), .none)
        XCTAssertFalse(o.midWordReported)
        XCTAssertEqual(type("ghb", into: &o).last, .midWord(keys: Keys.codes("ghb"), letters: 3, from: "en", to: "ru"))
    }

    func testP2ArrowVetoThenSpaceClearsTheMidWordLatch() {
        var o = TypingObserver(detector: TestDetector.shared, active: "en")
        _ = type("ghb", into: &o)
        XCTAssertEqual(o.handle(.key(.leftArrow, .function)), .none)
        XCTAssertFalse(o.midWordReported)
        XCTAssertEqual(o.handle(.key(.space, [])), .none)
        XCTAssertFalse(o.buffer.suppressed)
        XCTAssertEqual(type("ghb", into: &o).last, .midWord(keys: Keys.codes("ghb"), letters: 3, from: "en", to: "ru"))
    }

    func testP2BackspacingTheWordAwayClearsTheMidWordLatch() {
        var o = TypingObserver(detector: TestDetector.shared, active: "en")
        _ = type("ghb", into: &o)
        for _ in 0..<3 { _ = o.handle(.key(.delete, [])) }
        XCTAssertTrue(o.buffer.isEmpty)
        XCTAssertFalse(o.midWordReported)
        XCTAssertEqual(type("ghb", into: &o).last, .midWord(keys: Keys.codes("ghb"), letters: 3, from: "en", to: "ru"))
    }

    // MARK: P2 — caret movement, deletion and composition are not shortcuts or boundaries

    func testP2CommandArrowVetoes() {
        var o = TypingObserver(detector: TestDetector.shared, active: "en")
        _ = type("he", into: &o)
        XCTAssertEqual(o.handle(.key(.leftArrow, [.command, .function])), .none)
        XCTAssertTrue(o.buffer.suppressed)
        XCTAssertTrue(type("ghb", into: &o).allSatisfy { $0 == .none }, "the caret moved: nothing until the boundary")
        XCTAssertEqual(o.handle(.key(.space, [])), .none)
        for mods in [TypingObserver.Modifiers.option, [.option, .function], .shift, []] {
            var p = TypingObserver(detector: TestDetector.shared, active: "en")
            _ = type("he", into: &p)
            XCTAssertEqual(p.handle(.key(.rightArrow, mods)), .none)
            XCTAssertTrue(p.buffer.suppressed, "\(mods)")
        }
    }

    func testP2OptionDeleteSaysNothingAboutTheDeletedWord() {
        var o = TypingObserver(detector: TestDetector.shared, active: "en")
        _ = type("ghbdtn", into: &o)
        XCTAssertEqual(o.handle(.key(.delete, .option)), .none)
        XCTAssertTrue(o.buffer.suppressed)
        XCTAssertEqual(o.handle(.key(.space, [])), .none)
        var c = TypingObserver(detector: TestDetector.shared, active: "en")
        _ = type("ghbdtn", into: &c)
        XCTAssertEqual(c.handle(.key(.delete, .command)), .none)
        XCTAssertTrue(c.buffer.suppressed)
    }

    func testP2DeadKeyVetoesTheWord() {
        // caf ⌥e e Space → café on screen. The observer cannot read the composition: nothing is
        // said about `caf`, nor about a lone `e`.
        var o = TypingObserver(detector: TestDetector.shared, active: "en")
        _ = type("caf", into: &o)
        XCTAssertEqual(o.handle(.key(.e, .option)), .none)
        XCTAssertTrue(o.buffer.suppressed)
        XCTAssertEqual(o.handle(.key(.e, [])), .none)
        XCTAssertEqual(o.handle(.key(.space, [])), .none)
        // After the boundary the next word is observed again.
        XCTAssertEqual(type("ghb", into: &o).last, .midWord(keys: Keys.codes("ghb"), letters: 3, from: "en", to: "ru"))
        // ⌥8 (•) right after a word: the word is dropped rather than decided — safe, not missed-free.
        var p = TypingObserver(detector: TestDetector.shared, active: "en")
        _ = type("ghbdtn", into: &p)
        XCTAssertEqual(p.handle(.key(.eight, .option)), .none)
    }

    // MARK: P2 — a broken event stream drops the buffer

    func testP2InterruptionDropsTheBuffer() {
        var o = TypingObserver(detector: TestDetector.shared, active: "en")
        _ = type("gh", into: &o)
        XCTAssertEqual(o.handle(.interrupted), .none)
        XCTAssertTrue(o.buffer.isEmpty)
        XCTAssertFalse(o.midWordReported)
        // `b` after the gap is the start of something unknown, not the third letter of `ghb`.
        XCTAssertEqual(o.handle(.key(.b, [])), .none)
        assertLeftAlone(o.handle(.key(.space, [])), keys: [.b])
    }

    // MARK: Controls the auditor checked that held

    func testControlKeyRepeatOverflowsAndNextWordResumes() {
        var o = TypingObserver(detector: TestDetector.shared, active: "en")
        for _ in 0...32 { _ = o.handle(.key(.g, [])) }
        XCTAssertTrue(o.buffer.suppressed)
        XCTAssertEqual(o.handle(.key(.space, [])), .none)
        XCTAssertFalse(o.buffer.suppressed)
        XCTAssertNotEqual(type("ghb", into: &o).last, TypingObserver.Decision.none)
    }

    func testPausedShortcutIsNotObserving() {
        var o = TypingObserver(detector: TestDetector.shared, active: "en")
        _ = o.handle(.paused(true))
        XCTAssertFalse(o.isObserving)
        XCTAssertEqual(o.handle(.flush(.click)), .none)
    }
}

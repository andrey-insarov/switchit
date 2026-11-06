import XCTest
@testable import SwitchitCore

/// Readable cases on top of the golden table: the behaviour the plan promises, by example.
final class DetectorTests: XCTestCase {
    let det = TestDetector.shared

    // MARK: Whole word at the boundary

    func testRussianWordTypedInEnglishLayout() {
        XCTAssertEqual(det.decideWord(Keys.codes("ghbdtn"), active: "en"), "ru")      // привет
        XCTAssertEqual(det.decideWord(Keys.codes("cgfcb,j"), active: "en"), "ru")     // спасибо
        XCTAssertEqual(det.decideWord(Keys.codes("vtytl;th"), active: "en"), "ru")    // менеджер
        XCTAssertEqual(det.decideWord(Keys.codes("rjvgm.nth"), active: "en"), "ru")   // компьютер
    }

    func testEnglishWordTypedInRussianLayout() {
        XCTAssertEqual(det.decideWord(Keys.codes("hello"), active: "ru"), "en")       // руддщ
        XCTAssertEqual(det.decideWord(Keys.codes("macos"), active: "ru"), "en")       // ьфсщы
    }

    func testCorrectTypingIsLeftAlone() {
        for w in ["hello", "sudo", "privet", "spasibo", "insarov", "xcode", "swift"] {
            let got = det.decideWord(Keys.codes(w), active: "en")
            XCTAssertTrue(got == "en" || got == nil, "\(w): \(got ?? "nil")")
        }
    }

    func testTechWordsAreNotSwitched() {
        for w in ["grep", "kubectl", "json", "mkdir", "chmod"] {
            XCTAssertNotEqual(det.decideWord(Keys.codes(w), active: "en"), "ru", w)
        }
    }

    func testShortWordsComeFromTheCuratedListsOnly() {
        XCTAssertEqual(det.decideWord(Keys.codes("ds"), active: "en"), "ru")    // вы
        XCTAssertEqual(det.decideWord(Keys.codes("ytn"), active: "en"), "ru")   // нет
        XCTAssertEqual(det.decideWord(Keys.codes("lf"), active: "en"), "ru")    // да
        XCTAssertEqual(det.decideWord(Keys.codes("ok"), active: "en"), "en")
        XCTAssertEqual(det.decideWord(Keys.codes("he"), active: "en"), "en")    // not ру
        XCTAssertNil(det.decideWord(Keys.codes("xq"), active: "en"))            // in neither list
    }

    func testWordKnownInBothLanguagesIsLeftAlone() {
        // keys / луны: both are dictionary words. Whichever layout is active, the typed word is a
        // real word there and is protected.
        XCTAssertEqual(det.decideWord(Keys.codes("keys"), active: "en"), "en")
        XCTAssertEqual(det.decideWord(Keys.codes("keys"), active: "ru"), "ru")
    }

    func testProtectedWordsAreNeverSwitchedAway() {
        for w in ["cctv", "http", "pdf", "vs", "tot", "ltd"] {
            XCTAssertEqual(det.decideWord(Keys.codes(w), active: "en"), "en", w)
        }
        for (keys, w) in [("her", "рук"), ("key", "лун")] {
            XCTAssertEqual(det.decideWord(Keys.codes(keys), active: "ru"), "ru", w)
        }
        // Protection is for the active language only: typed in the other layout, they are
        // still candidates for a fix.
        XCTAssertEqual(det.decideWord(Keys.codes("hello"), active: "ru"), "en")
    }

    func testPunctuationInActiveLayoutSwitchesOnlyToAKnownWord() {
        XCTAssertNil(det.decideWord(Keys.codes("hello,"), active: "en"))
        XCTAssertNil(det.decideWord(Keys.codes("can't"), active: "en"))
        XCTAssertNil(det.decideWord(Keys.codes("end."), active: "en"))
        // `;` is ж in Russian: a real Russian word spelled with it does switch.
        XCTAssertEqual(det.decideWord(Keys.codes("vtytl;th"), active: "en"), "ru")
    }

    func testTwoCapitalsAreLeftAlone() {
        XCTAssertNil(det.decideWord(Keys.codes("ghbdtn"), active: "en", capitals: 2))
        XCTAssertNil(det.decidePrefix(Keys.codes("ghb"), active: "en", capitals: 2))
        XCTAssertEqual(det.decideWord(Keys.codes("ghbdtn"), active: "en", capitals: 1), "ru")
    }

    func testSingleKeyIsNeverAWord() {
        XCTAssertNil(det.decideWord(Keys.codes("z"), active: "en"))
    }

    // MARK: Mid-word

    func testSwitchesAtTheThirdLetter() {
        // Ghb → При: the plan's reference example.
        XCTAssertEqual(det.decidePrefix(Keys.codes("ghb"), active: "en"), "ru")
        let first = det.firstPrefixSwitch(Keys.codes("ghbdtn"), active: "en")
        XCTAssertEqual(first?.letters, 3)
        XCTAssertEqual(first?.language, "ru")
    }

    func testRetriesAtLaterLetters() {
        // Every mid-word decision for a full word must agree with checking each prefix in turn.
        for (w, lang) in [("ghbdtn", "en"), ("hello", "ru"), ("cgfcb,j", "en")] {
            let keys = Keys.codes(w)
            let first = det.firstPrefixSwitch(keys, active: lang)
            var expected: (Int, String)?
            for k in 3...min(6, keys.count) {
                if let l = det.decidePrefix(Array(keys[..<k]), active: lang) { expected = (k, l); break }
            }
            XCTAssertEqual(first?.letters, expected?.0, w)
            XCTAssertEqual(first?.language, expected?.1, w)
        }
    }

    func testNoMidWordSwitchForCorrectTyping() {
        for w in ["hello", "privet", "insarov", "swift", "the", "and", "because"] {
            XCTAssertNil(det.firstPrefixSwitch(Keys.codes(w), active: "en"), w)
        }
    }

    func testMidWordIgnoresTooShortAndTooLong() {
        XCTAssertNil(det.decidePrefix(Keys.codes("gh"), active: "en"))
        XCTAssertNil(det.decidePrefix(Keys.codes("ghbdtnghb"), active: "en"))
    }

    // MARK: Performance — a decision per keystroke must stay far under a millisecond

    func testDecisionSpeed() {
        let words = ["ghbdtn", "hello", "cgfcb,j", "kubectl", "insarov", "rjvgm.nth"].map(Keys.codes)
        let n = 2000
        let start = DispatchTime.now().uptimeNanoseconds
        var sink = 0
        for i in 0..<n {
            let keys = words[i % words.count]
            if det.decideWord(keys, active: "en") != nil { sink += 1 }
            if det.firstPrefixSwitch(keys, active: "en") != nil { sink += 1 }
        }
        let perWord = Double(DispatchTime.now().uptimeNanoseconds - start) / Double(n) / 1e6
        XCTAssertLessThan(perWord, 1.0, "ms per word (whole word + every prefix), sink \(sink)")
    }
}

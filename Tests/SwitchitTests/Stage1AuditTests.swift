import Foundation
import XCTest
@testable import SwitchitCore

/// The auditor's stage-1 reproducers (6 Nov 2026, PR #1 at b23fd7a), inverted: each one asserted
/// the defect as it behaved; after the fixes each asserts the safe behaviour. The structure and the
/// cases are his; a test here that fails is a regression of a closed finding.
final class Stage1AuditTests: XCTestCase {
    /// A tiny model in the file format. `records` is filled in from the body.
    private func model(_ body: String, alphabet: String = "abc", total: String? = nil, language: String = "en") throws -> LanguageModel {
        try LanguageModel(language: language, modelText: Self.text(body, alphabet: alphabet, total: total, lang: language))
    }

    static func text(_ body: String, alphabet: String = "abc", total: String? = nil, lang: String = "en") -> String {
        let records = body.split(separator: "\n").map(String.init)
        // Unigrams for every letter and $ unless the body supplies them — the loader requires coverage.
        var lines = records
        var uni: [String: Double] = [:]
        var present: Set<String> = []
        for r in records {
            let f = r.split(separator: "\t").map(String.init)
            if f[0] == "u", f.count == 3 {
                present.insert(f[1])
                // A non-finite weight is left out of the sum so that the loader reaches the record
                // and refuses it there, not at the header.
                if let v = Double(f[2]), v.isFinite, uni[f[1]] == nil { uni[f[1]] = v }
            }
        }
        for c in alphabet.map(String.init) + ["$"] where !present.contains(c) {
            lines.append("u\t\(c)\t1.0"); uni[c] = 1.0
        }
        let sum = total ?? "\(uni.values.reduce(0, +))"
        return "switchit-model\t1\nlang\t\(lang)\nalphabet\t\(alphabet)\ntotal\t\(sum)\nrecords\t\(lines.count)\n" + lines.joined(separator: "\n") + "\n"
    }

    /// The bundled model with one record removed, to show that the record is what protects.
    private func bundled(_ lang: String, without word: String, kind: String) throws -> LanguageModel {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "model-\(lang)", withExtension: "txt"))
        var lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        let before = lines.count
        lines.removeAll { $0 == "\(kind)\t\(word)" }
        XCTAssertEqual(lines.count, before - 1, "\(kind)\t\(word) is in the shipped model exactly once")
        lines[4] = "records\t\(lines.count - 5)"
        return try LanguageModel(language: lang, modelText: lines.joined(separator: "\n") + "\n")
    }

    // MARK: P1 — cleaning removed the protection of vowelless abbreviations

    func testP1VowellessAbbreviationsAreProtectedByTheCuratedList() throws {
        let d = TestDetector.shared
        for w in ["cctv", "http", "pdf"] {
            XCTAssertFalse(d.languages[0].model.words.contains(w), "\(w): not in the cleaned dictionary")
            XCTAssertTrue(d.languages[0].model.protectedWords.contains(w), "\(w): protected by Data/protect-en.txt")
            let k = Keys.codes(w)
            XCTAssertNotEqual(d.decideWord(k, active: "en"), "ru", w)
            XCTAssertNil(d.firstPrefixSwitch(k, active: "en"), w)
            // Remove the protection record: the defect is back — the record is what protects.
            let unprotected = LayoutDetector(languages: [
                .init(code: "en", layout: .usEnglish, model: try bundled("en", without: w, kind: "p")), d.languages[1]])
            if w == "pdf" {
                XCTAssertEqual(unprotected.decidePrefix(k, active: "en"), "ru")
            } else {
                XCTAssertEqual(unprotected.decideWord(k, active: "en"), "ru")
            }
        }
    }

    // MARK: P1 — short real words of the active language were switched away

    func testP1ShortRealWordsOfTheActiveLanguageAreProtected() throws {
        let d = TestDetector.shared
        for (keys, active, other, word) in [("her", "ru", "en", "рук"), ("key", "ru", "en", "лун"),
                                            ("vs", "en", "ru", "vs"), ("tot", "en", "ru", "tot")] {
            let a = try XCTUnwrap(d.languages.first { $0.code == active })
            XCTAssertTrue(a.model.protectedWords.contains(word), word)
            XCTAssertNotEqual(d.decideWord(Keys.codes(keys), active: active), other, "\(word) must stay")
            XCTAssertEqual(d.decideWord(Keys.codes(keys), active: active), active, word)
        }
        // The raw frequency list is not the protection: its 2-letter entries are junk, and the
        // most common Russian words must still be reachable from the English layout.
        for (keys, meant) in [("lf", "да"), ("ds", "вы"), ("ns", "ты"), ("bp", "из"), ("dj", "во")] {
            let got = d.decideWord(Keys.codes(keys), active: "en")
            if keys == "dj" {
                XCTAssertEqual(got, "en", "dj is a real abbreviation and protected: \(meant) needs the shortcut")
            } else {
                XCTAssertEqual(got, "ru", "\(keys) → \(meant)")
            }
        }
    }

    // MARK: P2 — weights finite one by one, arithmetic not

    func testP2TotalMustEqualTheSumOfUnigrams() throws {
        XCTAssertNoThrow(try model("u\ta\t4\nu\tb\t3\nu\tc\t3\nu\t$\t1\n", total: "11"))
        for bad in ["0.001", "11.1", "10", "1e308"] {
            XCTAssertThrowsError(try model("u\ta\t4\nu\tb\t3\nu\tc\t3\nu\t$\t1\n", total: bad), bad) { e in
                XCTAssertEqual(e as? LanguageModel.Failure, .totalMismatch, bad)
            }
        }
        // Float ordering is tolerated; a real disagreement is not.
        XCTAssertNoThrow(try model("u\ta\t0.1\nu\tb\t0.2\nu\tc\t0.3\nu\t$\t0.4\n", total: "1.0"))
    }

    func testP2RowSumsMustBeFinite() throws {
        for records in ["b\t^a\t1e308\nb\t^b\t1e308\n", "t\t^^a\t1e308\nt\t^^b\t1e308\n"] {
            XCTAssertThrowsError(try model(records)) { e in
                XCTAssertEqual(e as? LanguageModel.Failure, .overflow)
            }
        }
        XCTAssertThrowsError(try model("u\ta\t1e308\nu\tb\t1e308\nu\tc\t1\nu\t$\t1\n", total: "inf"))
    }

    func testP2NonFiniteMarginNeverSwitches() throws {
        // A model cannot be built with an infinite score any more; the detector guards anyway.
        // Two valid models whose prefix scores are equal give margin 0 → no switch.
        let a = try model("w\taaab\nw\taaac\nw\taaad\nw\taaae\nw\taaaf\n", alphabet: "abcdef")
        let b = try model("w\taaab\nw\taaac\nw\taaad\nw\taaae\nw\taaaf\n", alphabet: "abcdef", language: "ru")
        let d = LayoutDetector(languages: [.init(code: "en", layout: .usEnglish, model: a),
                                           .init(code: "ru", layout: .usEnglish, model: b)])
        XCTAssertNil(d.decidePrefix(Keys.codes("aaa"), active: "en"))
        XCTAssertNotEqual(d.decideWord(Keys.codes("aaab"), active: "en"), "ru", "a real word in the active language stays")
    }

    // MARK: P2 — a truncated resource must not load

    func testP2HeaderOnlyOrTruncatedResourceIsRefused() throws {
        let full = Self.text("u\ta\t4\nu\tb\t3\nu\tc\t3\nu\t$\t1\nw\tabc\n")
        XCTAssertNoThrow(try LanguageModel(language: "en", modelText: full))
        // Header only (records says 0, but no unigrams): incomplete.
        XCTAssertThrowsError(try LanguageModel(language: "en", modelText: "switchit-model\t1\nlang\ten\nalphabet\tabc\ntotal\t10\nrecords\t0\n")) { e in
            XCTAssertEqual(e as? LanguageModel.Failure, .incompleteUnigrams)
        }
        // Cut anywhere after the header: the record count disagrees.
        let lines = full.split(separator: "\n").map(String.init)
        for cut in 5..<lines.count {
            let text = lines[..<cut].joined(separator: "\n") + "\n"
            XCTAssertThrowsError(try LanguageModel(language: "en", modelText: text), "cut at \(cut)") { e in
                guard case .recordCountMismatch = e as? LanguageModel.Failure else { return XCTFail("cut at \(cut): \(e)") }
            }
        }
        // One record too many is the same error.
        XCTAssertThrowsError(try LanguageModel(language: "en", modelText: full + "w\tcab\n")) { e in
            guard case .recordCountMismatch = e as? LanguageModel.Failure else { return XCTFail("\(e)") }
        }
        // A missing unigram with a correct count is caught too.
        XCTAssertThrowsError(try LanguageModel(language: "en", modelText: "switchit-model\t1\nlang\ten\nalphabet\tabc\ntotal\t7\nrecords\t2\nu\ta\t4\nu\tb\t3\n")) { e in
            XCTAssertEqual(e as? LanguageModel.Failure, .incompleteUnigrams)
        }
    }

    // MARK: P2 — alphabet with reserved or control characters

    func testP2AlphabetMustBeLowercaseLetters() throws {
        for alphabet in ["abc^", "abc$", "abc\u{0000}", "abc1", "abC", "ab c", "aa", "abcé\u{0301}"] {
            XCTAssertThrowsError(try model("", alphabet: alphabet), alphabet.debugDescription) { e in
                XCTAssertEqual(e as? LanguageModel.Failure, .badHeader, alphabet.debugDescription)
            }
        }
        XCTAssertNoThrow(try model("", alphabet: "абвгдеёжз"))
        XCTAssertEqual(try model("", alphabet: "abc").vocabulary, 4)
    }

    // MARK: P2 — Backspace past the start of the buffer

    func testP2BackspacePastStartSuppressesTheRun() {
        var b = WordBuffer(wordKeys: Layout.usEnglish.letterKeys.union(Layout.russianPC.letterKeys))
        // Screen holds "foo ". Backspace deletes the space the buffer never saw; what follows
        // joins "foo" on screen, so it is not a word the buffer can vouch for.
        _ = b.append(KeyStroke(.delete))
        XCTAssertTrue(b.suppressed)
        for s in Keys.strokes("ghbdtn") { _ = b.append(s) }
        XCTAssertEqual(b.append(KeyStroke(.space)), .none)
        XCTAssertFalse(b.suppressed, "the boundary ends the suppression")
        // Backspace inside a run is still an edit, not a veto.
        for s in Keys.strokes("ab") { _ = b.append(s) }
        _ = b.append(KeyStroke(.delete))
        XCTAssertFalse(b.suppressed)
        XCTAssertEqual(b.append(KeyStroke(.space)), .word(strokes: Keys.strokes("a"), terminator: .space))
        // Backspace that empties the run exactly is fine; one more is past the start.
        _ = b.append(KeyStroke(.a)); _ = b.append(KeyStroke(.delete))
        XCTAssertFalse(b.suppressed)
        _ = b.append(KeyStroke(.delete))
        XCTAssertTrue(b.suppressed)
    }

    // MARK: Controls the auditor checked that already held

    func testControlsAndBounds() throws {
        for value in ["nan", "inf", "-inf", "1e999"] {
            XCTAssertThrowsError(try model("u\ta\t\(value)\n"), value)
        }
        XCTAssertThrowsError(try model("w\t" + String(repeating: "a", count: 33)))
        XCTAssertNoThrow(try model("w\t" + String(repeating: "a", count: 32)))
        XCTAssertThrowsError(try model("u\ta\t1\nu\ta\t2\n"))
        XCTAssertThrowsError(try model("w\tz\n"))
        XCTAssertThrowsError(try model("", alphabet: "aabc"))
        XCTAssertThrowsError(try LanguageModel(language: "en", modelText: "switchit-model\t1\nlang\ten\nw\tabc\nalphabet\tabc\ntotal\t1\nrecords\t0\n"))
        XCTAssertNoThrow(try model("u\ta\t-0\n"))   // -0 is numerically zero; no finding.
        XCTAssertThrowsError(try model("s\tabcd\n"))  // a short record must be short
        for action in [KeyCode.leftArrow, .rightArrow, .upArrow, .downArrow] {
            var b = WordBuffer(wordKeys: Layout.usEnglish.letterKeys, maxLength: 3)
            _ = b.append(KeyStroke(.g)); _ = b.append(KeyStroke(action))
            for k in [.h, .b] as [KeyCode] { _ = b.append(KeyStroke(k)) }
            XCTAssertEqual(b.append(KeyStroke(.space)), .none)
            XCTAssertFalse(b.suppressed)
        }
    }

    func testInvalidUTF8BundleIsRejected() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("switchit-audit-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data([0xff, 0xfe]).write(to: dir.appendingPathComponent("model-en.txt"))
        XCTAssertThrowsError(try LanguageModel.load(language: "en", bundle: try XCTUnwrap(Bundle(url: dir))))
    }

    // MARK: P3 — empty prefix

    func testP3EmptyPrefixScoresZero() throws {
        let m = try LanguageModel.load(language: "en")
        XCTAssertEqual(m.logP(prefix: ""), 0)
        XCTAssertTrue(m.logP(prefix: "a").isFinite)
    }

    // MARK: Expanded parity (auditor's table, when present) and latency

    func testExpandedPythonParity() throws {
        guard let path = ProcessInfo.processInfo.environment["SWITCHIT_AUDIT_PARITY"] else {
            throw XCTSkip("Generate the expanded table with the auditor's switchit-expanded-parity.py and set SWITCHIT_AUDIT_PARITY")
        }
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let d = TestDetector.shared
        var worst = 0.0
        for line in text.split(separator: "\n") {
            let f = line.split(separator: "\t").map(String.init), k = Keys.codes(f[0])
            XCTAssertEqual(d.decideWord(k, active: f[1]) ?? "-", f[2], f[0])
            let p = d.firstPrefixSwitch(k, active: f[1])
            XCTAssertEqual(p.map { "\($0.letters):\($0.language)" } ?? "-", f[3], f[0])
            if f[4] != "-" {
                for pair in f[4].split(separator: ";") {
                    let a = pair.split(separator: "="), scores = a[1].split(separator: ",").map { Double($0)! }
                    let c = try XCTUnwrap(d.candidates(k).first { $0.language.code == a[0] })
                    for (got, expected) in zip([c.language.model.logP(word: c.text), c.language.model.logP(prefix: c.text)], scores) {
                        XCTAssertTrue(got.isFinite)
                        worst = max(worst, abs(got - expected))
                    }
                }
            }
        }
        XCTAssertLessThan(worst, 1e-9)
    }

    func testLatencyPercentilesIncluding32Keys() {
        let d = TestDetector.shared
        let corpus = ["ghbdtn", "hello", "cgfcb,j", "kubectl", "insarov", "rjvgm.nth", String(repeating: "a", count: 32)].map(Keys.codes)
        var samples = [Double](), sink = 0
        for keys in corpus {                                   // warm-up: first touch of the model is not typing
            if d.decideWord(keys, active: "en") != nil { sink += 1 }
        }
        for i in 0..<7000 {
            let keys = corpus[i % corpus.count], start = DispatchTime.now().uptimeNanoseconds
            if d.decideWord(keys, active: "en") != nil { sink += 1 }
            if d.firstPrefixSwitch(keys, active: "en") != nil { sink += 1 }
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        samples.sort()
        // p99 is the bound; max on a shared CI runner is noise (5 ms seen once on a debug build)
        // and is reported, not asserted. The auditor measured p50 0.020 ms, p99 0.057 ms, max 0.066 ms.
        XCTAssertLessThan(samples[6930], 1.0, "p99 ms per word including every prefix attempt; p50 \(samples[3500]) max \(samples.last!) sink \(sink)")
    }
}

import XCTest
@testable import SwitchitCore

/// The model loader is a validation boundary: a resource that is not exactly what
/// `Scripts/export_model.py` writes is refused, never half-loaded. Same discipline as Keepit's
/// `Backup.validate` — every malformed input here is a counterexample the loader must reject.
/// The auditor's own counterexamples are in `Stage1AuditTests`.
final class LanguageModelTests: XCTestCase {
    /// A well-formed tiny model: three letters, unigrams for all of them and $, a few n-grams,
    /// three words, one short word. `records` and `total` are computed by the helper.
    private let good = """
    u\t$\t3.0
    u\ta\t4.0
    u\tb\t2.0
    u\tc\t1.0
    b\t^a\t2.0
    b\tab\t1.5
    t\t^^a\t2.0
    t\t^ab\t1.5
    w\tab
    w\tabc
    w\tcab
    s\tab
    """

    private func load(_ body: String, language: String = "en") throws -> LanguageModel {
        try LanguageModel(language: language, modelText: Stage1AuditTests.text(body, lang: language))
    }

    private func raw(_ text: String) throws -> LanguageModel {
        try LanguageModel(language: "en", modelText: text)
    }

    func testWellFormedModelLoads() throws {
        let m = try load(good)
        XCTAssertEqual(m.language, "en")
        XCTAssertEqual(m.vocabulary, 4)                     // a b c + end of word
        XCTAssertEqual(m.words, ["ab", "abc", "cab"])
        XCTAssertEqual(m.shortWords, ["ab"])
        XCTAssertEqual(m.protectedWords, ["ab"], "short words and 4+ letter words only; abc and cab are 3 letters and not curated")
        XCTAssertEqual(m.wordsStarting(with: "ab"), 2, "ab and abc; the short ab is the same word")
        XCTAssertEqual(m.wordsStarting(with: "c"), 1)
        XCTAssertEqual(m.wordsStarting(with: "zz"), 0)
        XCTAssertLessThan(m.logP(word: "ab"), 0)
        XCTAssertGreaterThan(m.logP(word: "ab"), m.logP(word: "cc"), "a trained word scores above an unseen one")
    }

    func testRefusesWrongHeaderAndMissingFields() {
        XCTAssertThrowsError(try raw("switchit-model\t2\nlang\ten\nalphabet\tabc\ntotal\t1.0\nrecords\t0\n"))
        XCTAssertThrowsError(try raw("lang\ten\nalphabet\tabc\ntotal\t1.0\nrecords\t0\n"))
        XCTAssertThrowsError(try raw("switchit-model\t1\nalphabet\tabc\ntotal\t1.0\nrecords\t0\n"))        // no lang
        XCTAssertThrowsError(try raw("switchit-model\t1\nlang\ten\ntotal\t1.0\nrecords\t0\n"))             // no alphabet
        XCTAssertThrowsError(try raw("switchit-model\t1\nlang\ten\nalphabet\tabc\nrecords\t0\n"))          // no total
        XCTAssertThrowsError(try raw("switchit-model\t1\nlang\ten\nalphabet\tabc\ntotal\t1.0\n"))          // no records
        XCTAssertThrowsError(try raw("switchit-model\t1\nalphabet\tabc\nlang\ten\ntotal\t1.0\nrecords\t0\n"))  // wrong order
        XCTAssertThrowsError(try raw(""))
    }

    func testRefusesNonFiniteTotal() {
        for t in ["inf", "nan", "0", "-1", "1e999", "x"] {
            XCTAssertThrowsError(try raw("switchit-model\t1\nlang\ten\nalphabet\tabc\ntotal\t" + t + "\nrecords\t1\nu\ta\t1.0\n"), t)
        }
    }

    func testRefusesLanguageMismatch() {
        XCTAssertThrowsError(try load(good, language: "ru")) { e in
            XCTAssertEqual(e as? LanguageModel.Failure, .languageMismatch(expected: "ru", found: "en"))
        }
    }

    func testRefusesMalformedRecords() {
        let cases: [(String, String)] = [
            ("unknown record", "x\tfoo"),
            ("unigram outside alphabet", "u\tz\t1.0"),
            ("duplicate unigram", "u\ta\t1.0"),
            ("negative weight", "u\tb\t-1"),
            ("non-numeric weight", "u\tb\tnan?"),
            ("infinite weight", "u\tb\tinf"),              // Double("inf") parses; must still be refused
            ("negative infinite weight", "b\tab\t-inf"),
            ("nan weight", "t\t^^b\tnan"),
            ("bigram with wrong length", "b\tabc\t1.0"),
            ("bigram context outside alphabet", "b\tza\t1.0"),
            ("trigram with wrong length", "t\tab\t1.0"),
            ("duplicate trigram", "t\t^^a\t1.0"),
            ("word outside alphabet", "w\tabz"),
            ("empty word", "w\t"),
            ("duplicate word", "w\tab"),
            ("word too long", "w\t" + String(repeating: "a", count: LanguageModel.maxWordLength + 1)),
            ("extra field", "u\ta\t1.0\tmore"),
            ("record that looks like a header", "total\t1"),
            ("short record too long", "s\tabcd"),
            ("protected record outside alphabet", "p\tzz"),
            ("one field only", "w"),
        ]
        for (name, record) in cases {
            XCTAssertThrowsError(try load(good + "\n" + record), name) { e in
                guard case .badRecord = e as? LanguageModel.Failure else {
                    return XCTFail("\(name): \(e)")
                }
            }
        }
    }

    func testRefusesTooManyRecords() {
        // Declared count over the limit is refused at the header, before anything is read.
        XCTAssertThrowsError(try raw("switchit-model\t1\nlang\ten\nalphabet\tabc\ntotal\t1.0\nrecords\t\(LanguageModel.maxRecords + 1)\n")) { e in
            XCTAssertEqual(e as? LanguageModel.Failure, .badHeader)
        }
    }

    func testShortAndProtectedRecords() throws {
        XCTAssertThrowsError(try load(good + "\ns\tab"), "duplicate short word")
        let m = try load(good + "\np\tabc")
        XCTAssertTrue(m.protectedWords.contains("abc"))
        XCTAssertEqual(m.wordsStarting(with: "abc"), 1, "the w and the p record are one word")
    }

    func testResourceFileOverTheSizeLimitIsRefused() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("switchit-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var big = Data(Stage1AuditTests.text(good).utf8)
        big.append(Data(repeating: 0x0A, count: LanguageModel.maxFileBytes + 1 - big.count))
        try big.write(to: dir.appendingPathComponent("model-en.txt"))
        XCTAssertThrowsError(try LanguageModel.load(language: "en", bundle: Bundle(url: dir)!)) { e in
            XCTAssertEqual(e as? BoundedFileReader.Failure, .tooLarge(limit: LanguageModel.maxFileBytes))
        }
    }

    func testMissingResourceIsAnError() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("switchit-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertThrowsError(try LanguageModel.load(language: "en", bundle: Bundle(url: dir)!)) { e in
            XCTAssertEqual(e as? LanguageModel.Failure, .resourceMissing("model-en.txt"))
        }
    }
}

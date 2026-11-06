import XCTest
@testable import SwitchitCore

/// The model loader is a validation boundary: a resource that is not exactly what
/// `Scripts/export_model.py` writes is refused, never half-loaded. Same discipline as Keepit's
/// `Backup.validate` — every malformed input here is a counterexample the loader must reject.
final class LanguageModelTests: XCTestCase {
    private let good = """
    switchit-model\t1
    lang\ten
    alphabet\tabc
    total\t10.0
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
    """
    private let short = "# comment\nab\n\n"

    private func load(_ model: String, short: String? = nil, language: String = "en") throws -> LanguageModel {
        try LanguageModel(language: language, modelText: model + "\n", shortText: short ?? self.short)
    }

    func testWellFormedModelLoads() throws {
        let m = try load(good)
        XCTAssertEqual(m.language, "en")
        XCTAssertEqual(m.vocabulary, 4)                     // a b c + end of word
        XCTAssertEqual(m.words, ["ab", "abc", "cab"])
        XCTAssertEqual(m.shortWords, ["ab"])
        XCTAssertEqual(m.wordsStarting(with: "ab"), 2)
        XCTAssertEqual(m.wordsStarting(with: "c"), 1)
        XCTAssertEqual(m.wordsStarting(with: "zz"), 0)
        XCTAssertLessThan(m.logP(word: "ab"), 0)
        XCTAssertGreaterThan(m.logP(word: "ab"), m.logP(word: "cc"), "a trained word scores above an unseen one")
    }

    func testRefusesWrongHeaderAndMissingFields() {
        XCTAssertThrowsError(try load("switchit-model\t2\nlang\ten\nalphabet\tabc\ntotal\t1.0"))
        XCTAssertThrowsError(try load("lang\ten\nalphabet\tabc\ntotal\t1.0"))
        XCTAssertThrowsError(try load("switchit-model\t1\nalphabet\tabc\ntotal\t1.0"))        // no lang
        XCTAssertThrowsError(try load("switchit-model\t1\nlang\ten\ntotal\t1.0"))             // no alphabet
        XCTAssertThrowsError(try load("switchit-model\t1\nlang\ten\nalphabet\tabc"))          // no total
    }

    func testRefusesNonFiniteTotal() {
        for t in ["inf", "nan", "0", "-1", "1e999"] {
            XCTAssertThrowsError(try load("switchit-model\t1\nlang\ten\nalphabet\tabc\ntotal\t" + t + "\nu\ta\t1.0"), t)
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
            ("infinite total", "total\tinf"),
            ("bigram with wrong length", "b\tabc\t1.0"),
            ("bigram context outside alphabet", "b\tza\t1.0"),
            ("trigram with wrong length", "t\tab\t1.0"),
            ("duplicate trigram", "t\t^^a\t1.0"),
            ("word outside alphabet", "w\tabz"),
            ("empty word", "w\t"),
            ("duplicate word", "w\tab"),
            ("word too long", "w\t" + String(repeating: "a", count: LanguageModel.maxWordLength + 1)),
            ("extra field", "u\ta\t1.0\tmore"),
            ("second lang", "lang\ten"),
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
        // Unique words, so nothing but the count can fail.
        var flood = ""
        flood.reserveCapacity(LanguageModel.maxRecords * 12)
        for i in 0...LanguageModel.maxRecords {
            var n = i, w = "c"
            repeat { w.append(["a", "b", "c"][n % 3]); n /= 3 } while n > 0
            flood += "w\t" + w + "\n"
        }
        XCTAssertThrowsError(try load("switchit-model\t1\nlang\ten\nalphabet\tabc\ntotal\t1.0\n" + flood)) { e in
            XCTAssertEqual(e as? LanguageModel.Failure, .tooManyRecords)
        }
    }

    func testShortListMustUseTheAlphabet() {
        XCTAssertThrowsError(try load(good, short: "ab\nzz\n"))
        XCTAssertEqual(try load(good, short: "  ab  \n#ab\n").shortWords, ["ab"])
    }

    func testResourceFileOverTheSizeLimitIsRefused() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("switchit-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var big = Data((good + "\n").utf8)
        big.append(Data(repeating: 0x0A, count: LanguageModel.maxFileBytes + 1 - big.count))
        try big.write(to: dir.appendingPathComponent("model-en.txt"))
        try Data(short.utf8).write(to: dir.appendingPathComponent("short-en.txt"))
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

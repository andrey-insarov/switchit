import XCTest
@testable import SwitchitCore

/// The shipped resources: written by the Python scripts, inside the loader's limits, free of the
/// junk the cleaning rules remove, and in step with each other. Modelled on Keepit's FixtureTests
/// ("fixtures were not written by Swift").
final class ResourceTests: XCTestCase {
    private func resource(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "txt"), name)
    }

    func testShippedModelsLoadAndAreWithinLimits() throws {
        for lang in ["en", "ru"] {
            let url = try resource("model-\(lang)")
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int
            XCTAssertLessThan(size, LanguageModel.maxFileBytes / 2, "\(lang): headroom under the limit")
            let m = try LanguageModel.load(language: lang)
            XCTAssertGreaterThan(m.words.count, 30_000, lang)
            XCTAssertGreaterThan(m.shortWords.count, 80, lang)
            XCTAssertTrue(m.shortWords.allSatisfy { $0.count <= 3 }, "\(lang): short list holds 2–3 letter words only")
            XCTAssertGreaterThan(m.protectedWords.count, m.shortWords.count, "\(lang): protected = short ∪ curated ∪ long words")
        }
    }

    func testModelFilesCarryTheReferenceHeader() throws {
        for lang in ["en", "ru"] {
            let lines = try String(contentsOf: resource("model-\(lang)"), encoding: .utf8).split(separator: "\n")
            XCTAssertEqual(lines[0], "switchit-model\t1", "written by Scripts/export_model.py, not by hand")
            XCTAssertTrue(lines[4].hasPrefix("records\t"))
            XCTAssertTrue(lines[5].hasPrefix("sha256\t"))
            XCTAssertEqual(Int(lines[4].dropFirst(8)), lines.count - 6, "\(lang): record count matches the file")
        }
    }

    func testCuratedListsAreInTheModel() throws {
        // Data/short-*.txt and Data/protect-*.txt are the sources; export_model.py copies them in.
        let en = try LanguageModel.load(language: "en")
        XCTAssertTrue(en.shortWords.isSuperset(of: ["the", "and", "ok", "he"]))
        XCTAssertTrue(en.protectedWords.isSuperset(of: ["vs", "tot", "dj", "ye", "cctv", "http", "pdf", "ltd"]))
        let ru = try LanguageModel.load(language: "ru")
        XCTAssertTrue(ru.shortWords.isSuperset(of: ["да", "нет", "вы", "ты", "при"]))
        XCTAssertTrue(ru.protectedWords.isSuperset(of: ["рук", "лун", "ввс"]))
    }

    func testDictionaryHasNoJunk() throws {
        // The cleaning rules of detector_proto.load_list: no letter three times in a row, no
        // three-letter-or-longer word without a vowel. If either fails, export_model.py was run
        // from a reference without the rules.
        let vowels = ["en": Set("aeiouy"), "ru": Set("аеёиоуыэюя")]
        for lang in ["en", "ru"] {
            let m = try LanguageModel.load(language: lang)
            for w in m.words {
                let chars = Array(w)
                for i in 0..<max(0, chars.count - 2) {
                    XCTAssertFalse(chars[i] == chars[i + 1] && chars[i + 1] == chars[i + 2], "\(lang): \(w)")
                }
                if chars.count >= 3 {
                    XCTAssertTrue(chars.contains { vowels[lang]!.contains($0) }, "\(lang): \(w) has no vowel")
                }
            }
            for stopped in ["ifyou", "ljust", "ghb", "chffffff"] where lang == "en" {
                XCTAssertFalse(m.words.contains(stopped), stopped)
            }
        }
    }

    func testGoldenTableWasWrittenByTheReference() throws {
        let text = try String(contentsOf: TestDetector.fixtures.appendingPathComponent("golden.tsv"), encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("# keys\tactive\tcapitals\tword\tprefix\tword_scores\tprefix_scores\n"))
    }
}

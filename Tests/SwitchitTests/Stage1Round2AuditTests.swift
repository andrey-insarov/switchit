import Foundation
import XCTest
@testable import SwitchitCore

/// The auditor's stage-1 round-2 reproducers (6 Nov 2026, PR #1 at 140d237), inverted after the
/// fix: a `sha256` of the record lines in the header. The cases and structure are his.
final class Stage1Round2AuditTests: XCTestCase {
    private func text(_ lang: String) throws -> String {
        try String(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "model-\(lang)", withExtension: "txt")), encoding: .utf8)
    }

    // MARK: P2 — a cut inside the last record

    func testP2TruncationInsideLastRecordIsRefused() throws {
        for (lang, lastWord) in [("en", "yml"), ("ru", "фсб")] {
            let original = try text(lang)
            XCTAssertTrue(original.hasSuffix("p\t\(lastWord)\n"), "the shipped model still ends with p \(lastWord)")
            let intact = try LanguageModel(language: lang, modelText: original)
            XCTAssertTrue(intact.protectedWords.contains(lastWord))
            // Drop the final LF and one letter: valid UTF-8, a legal p record, same line count.
            let cut = String(original.dropLast(2))
            XCTAssertThrowsError(try LanguageModel(language: lang, modelText: cut), lang) { e in
                XCTAssertEqual(e as? LanguageModel.Failure, .badHeader, "\(lang): no trailing newline")
            }
            // With a LF put back the count matches and only the hash can tell.
            XCTAssertThrowsError(try LanguageModel(language: lang, modelText: cut + "\n"), lang) { e in
                XCTAssertEqual(e as? LanguageModel.Failure, .digestMismatch, lang)
            }
        }
    }

    /// Byte-level cuts of the shipped Russian model through `load`, across UTF-8 boundaries:
    /// a cut in the middle of a two-byte letter is not UTF-8 and fails before parsing; a cut on a
    /// boundary fails at the trailing-newline rule.
    func testP2ByteLevelTruncationOfTheShippedModelIsRefused() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "model-ru", withExtension: "txt"))
        let data = try Data(contentsOf: url)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("switchit-cut-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = try XCTUnwrap(Bundle(url: dir))
        for drop in 1...8 {
            try data.dropLast(drop).write(to: dir.appendingPathComponent("model-ru.txt"))
            XCTAssertThrowsError(try LanguageModel.load(language: "ru", bundle: bundle), "\(drop) bytes dropped")
        }
        try data.write(to: dir.appendingPathComponent("model-ru.txt"))
        XCTAssertNoThrow(try LanguageModel.load(language: "ru", bundle: bundle))
    }

    // MARK: Same-count edit — a limit of the count the hash removes

    func testP2SameCountMutationIsRefused() throws {
        let original = try text("en")
        let edited = original.replacingOccurrences(of: "p\tpdf\n", with: "p\tpdg\n")
        XCTAssertNotEqual(edited, original)
        XCTAssertEqual(edited.utf8.count, original.utf8.count)
        XCTAssertThrowsError(try LanguageModel(language: "en", modelText: edited)) { e in
            XCTAssertEqual(e as? LanguageModel.Failure, .digestMismatch)
        }
        // Reordering two records keeps count, bytes and even the multiset of lines; still refused.
        var lines = original.split(separator: "\n").map(String.init)
        let i = try XCTUnwrap(lines.firstIndex(of: "p\tpdf")), j = try XCTUnwrap(lines.firstIndex(of: "p\tpng"))
        lines.swapAt(i, j)
        XCTAssertThrowsError(try LanguageModel(language: "en", modelText: lines.map { $0 + "\n" }.joined())) { e in
            XCTAssertEqual(e as? LanguageModel.Failure, .digestMismatch)
        }
    }

    // MARK: P3 — the margin test reaches the margin (now Stage1AuditTests.testP2PrefixMarginGuardIsReached)

    func testValidModelsCanExercisePrefixMargin() throws {
        let a = try LanguageModel(language: "en", modelText: Stage1AuditTests.text("", alphabet: "abcdef", lang: "en"))
        let b = try LanguageModel(language: "ru", modelText: Stage1AuditTests.text("w\taaab\nw\taaac\nw\taaad\nw\taaae\nw\taaaf\n", alphabet: "abcdef", lang: "ru"))
        XCTAssertEqual(a.wordsStarting(with: "aaa"), 0)
        XCTAssertEqual(b.wordsStarting(with: "aaa"), 5)
        XCTAssertEqual(a.logP(prefix: "aaa"), b.logP(prefix: "aaa"))
        let d = LayoutDetector(languages: [.init(code: "en", layout: .usEnglish, model: a), .init(code: "ru", layout: .usEnglish, model: b)])
        XCTAssertNil(d.decidePrefix(Keys.codes("aaa"), active: "en"))
    }

    // MARK: Every protected word, every prefix (the auditor's sweep: 91 429 words)

    func testEveryCuratedProtectedWordSurvivesEveryTypingPrefix() throws {
        let d = TestDetector.shared
        var count = 0
        for language in d.languages {
            let other = language.code == "en" ? "ru" : "en"
            for word in language.model.protectedWords {
                let keys = try word.map { c in try XCTUnwrap(language.layout.letterKeys.first { language.layout.character(for: KeyStroke($0)) == c }) }
                if d.decideWord(keys, active: language.code) == other { XCTFail("\(word) switched at the boundary") }
                if d.firstPrefixSwitch(keys, active: language.code) != nil { XCTFail("\(word) switched mid-word") }
                count += 1
            }
        }
        XCTAssertGreaterThan(count, 90_000)
    }
}

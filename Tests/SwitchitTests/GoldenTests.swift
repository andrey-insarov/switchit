import XCTest
@testable import SwitchitCore

/// Parity with the Python reference: every decision and every score in `Fixtures/golden.tsv`
/// (written by `Scripts/export_model.py`) must be reproduced exactly.
final class GoldenTests: XCTestCase {
    struct Row {
        let keys: String
        let active: String
        let capitals: Int
        let word: String?
        let prefix: (letters: Int, language: String)?
        let wordScores: [String: Double]
        let prefixScores: [String: Double]
    }

    static func rows() throws -> [Row] {
        let url = TestDetector.fixtures.appendingPathComponent("golden.tsv")
        let text = try String(contentsOf: url, encoding: .utf8)
        var out: [Row] = []
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            XCTAssertEqual(f.count, 7, "bad golden row: \(line)")
            func scores(_ s: String) -> [String: Double] {
                if s == "-" { return [:] }
                var d: [String: Double] = [:]
                for part in s.split(separator: ";") {
                    let kv = part.split(separator: "=")
                    d[String(kv[0])] = Double(kv[1])!
                }
                return d
            }
            var prefix: (Int, String)?
            if f[4] != "-" {
                let kv = f[4].split(separator: ":")
                prefix = (Int(kv[0])!, String(kv[1]))
            }
            out.append(Row(keys: f[0], active: f[1], capitals: Int(f[2])!,
                           word: f[3] == "-" ? nil : f[3], prefix: prefix,
                           wordScores: scores(f[5]), prefixScores: scores(f[6])))
        }
        return out
    }

    func testGoldenTableIsLarge() throws {
        XCTAssertGreaterThan(try Self.rows().count, 1500)
    }

    func testWordDecisionsMatchReference() throws {
        let det = TestDetector.shared
        var mismatches: [String] = []
        for r in try Self.rows() {
            let got = det.decideWord(Keys.codes(r.keys), active: r.active, capitals: r.capitals)
            if got != r.word {
                mismatches.append("\(r.keys) active=\(r.active) caps=\(r.capitals): got \(got ?? "-"), reference \(r.word ?? "-")")
            }
        }
        XCTAssertTrue(mismatches.isEmpty, "\(mismatches.count) mismatches:\n" + mismatches.prefix(20).joined(separator: "\n"))
    }

    func testPrefixDecisionsMatchReference() throws {
        let det = TestDetector.shared
        var mismatches: [String] = []
        for r in try Self.rows() {
            let got = det.firstPrefixSwitch(Keys.codes(r.keys), active: r.active, capitals: r.capitals)
            let same = (got == nil && r.prefix == nil) || (got != nil && r.prefix != nil && got!.letters == r.prefix!.letters && got!.language == r.prefix!.language)
            if !same {
                mismatches.append("\(r.keys) active=\(r.active): got \(got.map { "\($0.letters):\($0.language)" } ?? "-"), reference \(r.prefix.map { "\($0.letters):\($0.language)" } ?? "-")")
            }
        }
        XCTAssertTrue(mismatches.isEmpty, "\(mismatches.count) mismatches:\n" + mismatches.prefix(20).joined(separator: "\n"))
    }

    func testScoresMatchReference() throws {
        let det = TestDetector.shared
        var worst = 0.0
        for r in try Self.rows() {
            for (lang, text) in det.candidates(Keys.codes(r.keys)) {
                if let ref = r.wordScores[lang.code] {
                    worst = max(worst, abs(lang.model.logP(word: text) - ref))
                }
                if let ref = r.prefixScores[lang.code] {
                    worst = max(worst, abs(lang.model.logP(prefix: text) - ref))
                }
            }
        }
        XCTAssertLessThan(worst, 1e-9, "largest score difference from the reference")
    }
}

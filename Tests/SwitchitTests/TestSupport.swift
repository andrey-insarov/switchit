import Foundation
import XCTest
@testable import SwitchitCore

/// Keys as the Python reference writes them: the US character on each key.
enum Keys {
    private static let punctuation: [Character: KeyCode] = [
        "[": .leftBracket, "]": .rightBracket, ";": .semicolon, "'": .quote,
        ",": .comma, ".": .period, "`": .grave, "\\": .backslash,
    ]
    private static let letters: [Character: KeyCode] = {
        var map: [Character: KeyCode] = [:]
        for code in Layout.usEnglish.letterKeys {
            map[Layout.usEnglish.character(for: KeyStroke(code))!] = code
        }
        return map
    }()

    static func codes(_ s: String) -> [KeyCode] {
        s.map { c in
            if let k = letters[c] { return k }
            if let k = punctuation[c] { return k }
            fatalError("no key for \(c)")
        }
    }

    static func strokes(_ s: String) -> [KeyStroke] { codes(s).map { KeyStroke($0) } }
}

/// The detector under test: US English and Russian – PC (ё on `, as in the reference), models
/// loaded once per process.
enum TestDetector {
    static let shared: LayoutDetector = {
        do {
            let en = try LanguageModel.load(language: "en")
            let ru = try LanguageModel.load(language: "ru")
            return LayoutDetector(languages: [
                .init(code: "en", layout: .usEnglish, model: en),
                .init(code: "ru", layout: .russianPC, model: ru),
            ])
        } catch {
            fatalError("cannot load models: \(error)")
        }
    }()

    static var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    }
}

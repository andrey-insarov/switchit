/// A keyboard layout as the detector sees it: which letter each key produces.
///
/// Only letters are mapped. That is enough for the detector — a word is a run of letter keys —
/// and it keeps the tables small and certain. Punctuation, digits and dead keys differ between
/// close variants of a layout (Apple's *Russian* vs *Russian – PC* disagree on `.`, `,` and `/`),
/// and at runtime the app does not need the table at all: it asks the system to translate key
/// codes under the real input source (`UCKeyTranslate`, stage 2). The built-in tables below are
/// for tests and for the detector's unit of work.
public struct Layout: Sendable, Identifiable, Equatable {
    /// The input source ID macOS uses for this layout, e.g. `com.apple.keylayout.US`.
    public let id: String
    /// ISO 639-1 code of the language the layout types, e.g. `en`, `ru`. Picks the language model.
    public let language: String
    /// Lower-case letter per key.
    private let letters: [KeyCode: Character]

    public init(id: String, language: String, letters: [KeyCode: Character]) {
        self.id = id
        self.language = language
        self.letters = letters
    }

    /// Keys that produce a letter in this layout. The word buffer treats these as word-forming.
    public var letterKeys: Set<KeyCode> { Set(letters.keys) }

    /// The character for one stroke, or nil when the key is not a letter in this layout.
    public func character(for stroke: KeyStroke) -> Character? {
        guard let c = letters[stroke.code] else { return nil }
        if stroke.shift, let upper = String(c).uppercased().first { return upper }
        return c
    }

    /// The word a stroke sequence spells in this layout, or nil if any key is not a letter here.
    public func text(for strokes: [KeyStroke]) -> String? {
        var out = ""
        out.reserveCapacity(strokes.count)
        for s in strokes {
            guard let c = character(for: s) else { return nil }
            out.append(c)
        }
        return out
    }
}

// MARK: - Built-in tables

extension Layout {
    /// Keys of the three letter rows in QWERTY order, including the four punctuation keys that
    /// carry letters in ЙЦУКЕН (`[` `]` `;` `'`) and the two that carry `б` `ю` (`,` `.`).
    private static let qwertyRows: [KeyCode] = [
        .q, .w, .e, .r, .t, .y, .u, .i, .o, .p, .leftBracket, .rightBracket,
        .a, .s, .d, .f, .g, .h, .j, .k, .l, .semicolon, .quote,
        .z, .x, .c, .v, .b, .n, .m, .comma, .period,
    ]

    /// Builds a letter table from a string with one character per key of `qwertyRows`;
    /// a `.` in the string means "not a letter on this key".
    private static func table(_ rows: String, extra: [KeyCode: Character] = [:]) -> [KeyCode: Character] {
        precondition(rows.count == qwertyRows.count, "layout string must have \(qwertyRows.count) characters")
        var map = extra
        for (key, ch) in zip(qwertyRows, rows) where ch != "." {
            map[key] = ch
        }
        return map
    }

    /// U.S. English (ANSI). Same letters as ABC, British and most other Latin layouts; those get
    /// their own entries only when their letter positions differ (AZERTY, QWERTZ — later).
    public static let usEnglish = Layout(
        id: "com.apple.keylayout.US",
        language: "en",
        letters: table("qwertyuiop..asdfghjkl..zxcvbnm..")
    )

    /// Russian, Apple's own arrangement: ЙЦУКЕН with `ё` on the key left of Return (`\` on ANSI).
    public static let russian = Layout(
        id: "com.apple.keylayout.Russian",
        language: "ru",
        letters: table("йцукенгшщзхъфывапролджэячсмитьбю", extra: [.backslash: "ё"])
    )

    /// Russian – PC: the same letters with `ё` on the key left of `1` (`` ` `` on ANSI), as on Windows.
    public static let russianPC = Layout(
        id: "com.apple.keylayout.RussianWin",
        language: "ru",
        letters: table("йцукенгшщзхъфывапролджэячсмитьбю", extra: [.grave: "ё"])
    )

    /// The layouts the tests and the first detector know about.
    public static let builtIn: [Layout] = [usEnglish, russian, russianPC]
}

// MARK: - Input sources

extension Layout {
    /// The detector language and letter table for a macOS keyboard-layout input source ID
    /// (`kTISPropertyInputSourceID`), or nil for a layout 1.0 does not handle (AZERTY, QWERTZ,
    /// Dvorak, Colemak, phonetic Russian …). Only *keyboard layouts* belong here: an input method
    /// (Pinyin, Romaji …) reports a base layout of US or ABC through
    /// `TISCopyCurrentKeyboardLayoutInputSource`, and must be gated by the selected source's own
    /// ID and type, never by its base layout (auditor's stage-2 P1).
    public static func forInputSource(id: String) -> (code: String, layout: Layout)? {
        switch id {
        case "com.apple.keylayout.US", "com.apple.keylayout.ABC", "com.apple.keylayout.British",
             "com.apple.keylayout.USExtended", "com.apple.keylayout.USInternational-PC",
             "com.apple.keylayout.British-PC", "com.apple.keylayout.Australian",
             "com.apple.keylayout.Canadian", "com.apple.keylayout.Irish":
            // Same letter positions as US; they differ in punctuation and dead keys only.
            return ("en", .usEnglish)
        case "com.apple.keylayout.Russian":
            return ("ru", .russian)
        case "com.apple.keylayout.RussianWin":
            return ("ru", .russianPC)
        default:
            return nil
        }
    }
}

import Foundation

/// Decides whether the keys of the current word were typed in the wrong layout.
///
/// Two questions, both answered with the language the user meant, or nil for "leave it alone":
///
/// - `decideWord` at a word boundary (Space, Return, …), for the whole word;
/// - `decidePrefix` after the 3rd … 6th letter, mid-word, so the layout can be switched while
///   the word is still being typed.
///
/// A result equal to the active language also means "leave it alone". The rules, constants and
/// arithmetic are those of `Scripts/detector_proto.py` — the Python reference whose decisions the
/// tests replay from `golden.tsv`.
public struct LayoutDetector: Sendable {
    /// One language the detector knows: its layout (for reading the keys) and its model.
    public struct Language: Sendable {
        public let code: String
        public let layout: Layout
        public let model: LanguageModel

        public init(code: String, layout: Layout, model: LanguageModel) {
            self.code = code
            self.layout = layout
            self.model = model
        }
    }

    public static let minModelLength = 4     // shorter words: short-word list only
    public static let wordMargin = 1.0
    public static let dictionaryBonus = 1.5
    public static let prefixMin = 3
    public static let prefixMax = 6
    public static let prefixSupport = 5
    public static let prefixMargin = 1.0
    /// Words with this many capitals or more (abbreviations, `iPhone`) are never touched.
    public static let capitalsLimit = 2

    public let languages: [Language]

    public init(languages: [Language]) {
        precondition(!languages.isEmpty)
        self.languages = languages
    }

    /// The word the keys spell in each language whose layout has a letter on every key.
    func candidates(_ keys: [KeyCode]) -> [(language: Language, text: String)] {
        var out: [(language: Language, text: String)] = []
        for lang in languages {
            var text = ""
            text.reserveCapacity(keys.count)
            var ok = true
            for k in keys {
                guard let c = lang.layout.character(for: KeyStroke(k)) else { ok = false; break }
                text.append(c)
            }
            if ok { out.append((language: lang, text: text)) }
        }
        return out
    }

    /// May the detector switch *to* this word of `lang`? Short words only from the curated list.
    private func isTarget(_ lang: Language, _ text: String) -> Bool {
        text.count < Self.minModelLength ? lang.model.shortWords.contains(text) : lang.model.words.contains(text)
    }

    /// Is this a real word of `lang` that must never be switched away from while `lang` is active?
    private func isProtected(_ lang: Language, _ text: String) -> Bool {
        lang.model.protectedWords.contains(text)
    }

    /// Language the whole word was meant in, or nil.
    /// - `active`: code of the language whose layout was active while typing.
    /// - `capitals`: number of upper-case letters typed (Shift held).
    public func decideWord(_ keys: [KeyCode], active: String, capitals: Int = 0) -> String? {
        if keys.count < 2 || capitals >= Self.capitalsLimit { return nil }
        let cands = candidates(keys)
        if cands.isEmpty { return nil }
        if let a = cands.first(where: { $0.language.code == active }), isProtected(a.language, a.text) {
            return active                                            // a real word in the active language
        }
        let targets = cands.filter { isTarget($0.language, $0.text) }.map { $0.language.code }
        if targets.count > 1 { return nil }                          // a real word in more than one language
        guard cands.contains(where: { $0.language.code == active }) else {
            // A key is punctuation in the active layout (`hello,` `can't`): switch only to a
            // known word of the other language, never on the model alone.
            return targets.count == 1 ? targets[0] : nil
        }
        if cands.count == 1 { return active }                        // the other layout cannot spell it
        if keys.count < Self.minModelLength { return targets.count == 1 ? targets[0] : nil }
        var scored: [(code: String, score: Double)] = []
        for c in cands {
            var s = c.language.model.logP(word: c.text)
            if targets.contains(c.language.code) { s += Self.dictionaryBonus }
            if !s.isFinite { return nil }                            // a broken model never decides
            scored.append((c.language.code, s))
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.code < $1.code }
        let margin = scored[0].score - scored[1].score
        return margin.isFinite && margin >= Self.wordMargin ? scored[0].code : nil
    }

    /// Language to switch to after the latest letter, or nil. Meaningful at 3–6 letters.
    public func decidePrefix(_ keys: [KeyCode], active: String, capitals: Int = 0) -> String? {
        let n = keys.count
        if n < Self.prefixMin || n > Self.prefixMax || capitals >= Self.capitalsLimit { return nil }
        let cands = candidates(keys)
        guard let a = cands.first(where: { $0.language.code == active }) else { return nil }
        if a.language.model.wordsStarting(with: a.text) > 0 { return nil }   // still a possible start here (a protected word's prefix included)
        for o in cands where o.language.code != active {
            if o.language.model.wordsStarting(with: o.text) < Self.prefixSupport { continue }
            let margin = o.language.model.logP(prefix: o.text) - a.language.model.logP(prefix: a.text)
            if !margin.isFinite || margin < Self.prefixMargin { continue }
            return o.language.code
        }
        return nil
    }

    /// The first mid-word switch while typing `keys` letter by letter: (letters typed, language).
    public func firstPrefixSwitch(_ keys: [KeyCode], active: String, capitals: Int = 0) -> (letters: Int, language: String)? {
        guard keys.count >= Self.prefixMin else { return nil }
        for k in Self.prefixMin...min(keys.count, Self.prefixMax) {
            if let lang = decidePrefix(Array(keys[..<k]), active: active, capitals: capitals) {
                return (k, lang)
            }
        }
        return nil
    }
}

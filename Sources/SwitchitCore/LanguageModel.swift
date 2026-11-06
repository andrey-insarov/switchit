import Foundation

/// Everything the detector knows about one language: the character n-gram model, the dictionary
/// (words and their prefixes), the hand-curated short-word list and the protected words.
///
/// Built from `model-<lang>.txt` in the module's resources — a file written by
/// `Scripts/export_model.py` from the Python reference, which is where the numbers come from.
/// The loader is a validation boundary like the ones in Keepit: the file is read through
/// `BoundedFileReader`, every record is checked, the record count and the unigram total are
/// verified, and anything unexpected is an error rather than a model that silently scores
/// differently. A model that loads is complete and arithmetically sound; a decision on it is
/// made of finite numbers (auditor's stage-1 findings P2, 6 Nov 2026).
public final class LanguageModel: Sendable {
    public enum Failure: Error, Equatable {
        case resourceMissing(String)
        case badHeader
        case badRecord(line: Int)
        case languageMismatch(expected: String, found: String)
        case tooManyRecords
        /// The `records` header says one number of records, the file holds another: truncated or edited.
        case recordCountMismatch(declared: Int, found: Int)
        /// `total` does not equal the sum of the unigram weights.
        case totalMismatch
        /// A letter of the alphabet (or the end-of-word symbol) has no unigram record.
        case incompleteUnigrams
        /// Weights are finite one by one but their sums are not.
        case overflow
    }

    /// Hard limits on what a model file may contain; the shipped files are well inside them.
    public static let maxFileBytes = 8 << 20
    public static let maxRecords = 400_000
    public static let maxWordLength = 32
    public static let maxAlphabet = 64
    /// Relative tolerance for `total` against the sum of the unigrams — float summation order.
    static let totalTolerance = 1e-9

    // Model constants — identical to detector_proto.py.
    static let smoothing = 0.01
    static let weightTri = 0.75
    static let weightBi = 0.2
    static let weightUni = 0.05
    static let bos: Character = "^"
    static let eos: Character = "$"

    public let language: String
    /// The letters the model knows.
    public let alphabet: Set<Character>
    /// Alphabet size including the end-of-word symbol: the `V` of add-k smoothing.
    let vocabulary: Int
    let total: Double
    let unigram: [Character: Double]
    /// Bigram and trigram rows keyed by context; each row holds its own sum.
    let bigram: [String: Row]
    let trigram: [String: Row]
    /// Cleaned frequency-list words: correction targets at 4+ letters.
    public let words: Set<String>
    /// Hand-curated 2–3 letter words: the only correction targets under 4 letters.
    public let shortWords: Set<String>
    /// Words never switched away from while this language is active: the short list, the curated
    /// protected list (real short words, vowelless abbreviations) and every dictionary word of
    /// 4+ letters.
    public let protectedWords: Set<String>
    /// Every prefix (up to `prefixMax` letters) of the words, short words and protected words,
    /// with the number of entries sharing it.
    let prefixes: [String: Int]

    struct Row {
        var counts: [Character: Double] = [:]
        var sum: Double = 0
    }

    static let prefixMax = 6
    static let shortMax = 3

    // MARK: Loading

    /// Loads the model for `language` from the module's resources.
    public static func load(language: String) throws -> LanguageModel {
        try load(language: language, bundle: .module)
    }

    /// Loads the model for `language` from any bundle (tests point this at a temporary folder).
    public static func load(language: String, bundle: Bundle) throws -> LanguageModel {
        guard let url = bundle.url(forResource: "model-\(language)", withExtension: "txt") else {
            throw Failure.resourceMissing("model-\(language).txt")
        }
        let data = try BoundedFileReader.read(url, max: maxFileBytes)
        guard let text = String(data: data, encoding: .utf8) else { throw Failure.badHeader }
        return try LanguageModel(language: language, modelText: text)
    }

    /// Parses the file. Internal so tests can feed malformed text.
    init(language: String, modelText: String) throws {
        var lines = modelText.split(separator: "\n", omittingEmptySubsequences: false)[...]
        // Only the trailing newline may leave an empty line, and only at the end.
        while lines.last == "" { lines = lines.dropLast() }
        guard lines.count >= 5 else { throw Failure.badHeader }

        // Header: five lines, fixed order.
        guard lines[lines.startIndex] == "switchit-model\t1" else { throw Failure.badHeader }
        func headerField(_ i: Int, _ key: String) throws -> Substring {
            let f = lines[lines.startIndex + i].split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count == 2, f[0] == key, !f[1].isEmpty else { throw Failure.badHeader }
            return f[1]
        }
        let lang = String(try headerField(1, "lang"))
        let alphabetText = try headerField(2, "alphabet")
        guard let total = Double(try headerField(3, "total")), total.isFinite, total > 0 else { throw Failure.badHeader }
        guard let declared = Int(try headerField(4, "records")), declared >= 0, declared <= Self.maxRecords else {
            throw Failure.badHeader
        }
        guard lang == language else { throw Failure.languageMismatch(expected: language, found: lang) }

        // Alphabet: lower-case letters, unique, no padding symbols, no controls.
        let alphabet = Set(alphabetText)
        guard alphabet.count == alphabetText.count, alphabet.count <= Self.maxAlphabet else { throw Failure.badHeader }
        for c in alphabet {
            guard c.isLetter, c.isLowercase, c != Self.bos, c != Self.eos, c.unicodeScalars.count == 1 else {
                throw Failure.badHeader
            }
        }

        let records = lines.dropFirst(5)
        guard records.count == declared else { throw Failure.recordCountMismatch(declared: declared, found: records.count) }

        var unigram: [Character: Double] = [:]
        var bigram: [String: Row] = [:]
        var trigram: [String: Row] = [:]
        var words: Set<String> = []
        var short: Set<String> = []
        var protect: Set<String> = []
        var lineNo = 5

        func checkWord(_ w: Substring, _ bad: () -> Failure) throws -> String {
            guard !w.isEmpty, w.count <= Self.maxWordLength else { throw bad() }
            for x in w where !alphabet.contains(x) { throw bad() }
            return String(w)
        }

        for line in records {
            lineNo += 1
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            func bad() -> Failure { .badRecord(line: lineNo) }
            guard f.count >= 2 else { throw bad() }
            switch f[0] {
            case "u":
                guard f.count == 3, f[1].count == 1, let v = Double(f[2]), v.isFinite, v >= 0 else { throw bad() }
                let c = f[1].first!
                guard c == Self.eos || alphabet.contains(c), unigram[c] == nil else { throw bad() }
                unigram[c] = v
            case "b", "t":
                let n = f[0] == "b" ? 2 : 3
                guard f.count == 3, f[1].count == n, let v = Double(f[2]), v.isFinite, v >= 0 else { throw bad() }
                let chars = Array(f[1])
                let context = String(chars.dropLast())
                let c = chars.last!
                guard c == Self.eos || alphabet.contains(c) else { throw bad() }
                for x in context where x != Self.bos && !alphabet.contains(x) { throw bad() }
                if n == 2 {
                    guard bigram[context]?.counts[c] == nil else { throw bad() }
                    bigram[context, default: Row()].counts[c] = v
                    bigram[context]!.sum += v
                } else {
                    guard trigram[context]?.counts[c] == nil else { throw bad() }
                    trigram[context, default: Row()].counts[c] = v
                    trigram[context]!.sum += v
                }
            case "w":
                guard f.count == 2 else { throw bad() }
                guard words.insert(try checkWord(f[1], bad)).inserted else { throw bad() }
            case "s":
                guard f.count == 2 else { throw bad() }
                let w = try checkWord(f[1], bad)
                guard w.count <= Self.shortMax, short.insert(w).inserted else { throw bad() }
            case "p":
                guard f.count == 2 else { throw bad() }
                guard protect.insert(try checkWord(f[1], bad)).inserted else { throw bad() }
            default:
                throw bad()
            }
        }

        // Completeness and arithmetic: every letter and the end symbol have a unigram; the total
        // is the sum of them; no row sum overflowed.
        for c in alphabet where unigram[c] == nil { throw Failure.incompleteUnigrams }
        guard unigram[Self.eos] != nil else { throw Failure.incompleteUnigrams }
        let sum = unigram.values.reduce(0, +)
        guard sum.isFinite, abs(sum - total) <= Self.totalTolerance * max(sum, total) else { throw Failure.totalMismatch }
        for row in bigram.values where !row.sum.isFinite { throw Failure.overflow }
        for row in trigram.values where !row.sum.isFinite { throw Failure.overflow }

        var prefixes: [String: Int] = [:]
        for w in words.union(short).union(protect) {
            let chars = Array(w)
            for k in 1...min(chars.count, Self.prefixMax) {
                prefixes[String(chars[..<k]), default: 0] += 1
            }
        }

        self.language = language
        self.alphabet = alphabet
        self.vocabulary = alphabet.count + 1
        self.total = total
        self.unigram = unigram
        self.bigram = bigram
        self.trigram = trigram
        self.words = words
        self.shortWords = short
        self.protectedWords = short.union(protect).union(words.filter { $0.count >= LayoutDetector.minModelLength })
        self.prefixes = prefixes
    }

    // MARK: Scoring — same arithmetic, in the same order, as NGramModel in detector_proto.py

    private func charLogP(_ s: [Character], _ i: Int) -> Double {
        let c = s[i]
        let v = Double(vocabulary)
        let p1 = ((unigram[c] ?? 0) + Self.smoothing) / (total + Self.smoothing * v)
        let p2 = rowP(bigram[String(s[i - 1])], c)
        let p3 = rowP(trigram[String(s[(i - 2)..<i])], c)
        let p2v = p2 ?? p1
        let p3v = p3 ?? p2v
        return log(Self.weightUni * p1 + Self.weightBi * p2v + Self.weightTri * p3v)
    }

    private func rowP(_ row: Row?, _ c: Character) -> Double? {
        guard let row else { return nil }
        return ((row.counts[c] ?? 0) + Self.smoothing) / (row.sum + Self.smoothing * Double(vocabulary))
    }

    /// Average log-probability per character of a whole word, end-of-word included.
    public func logP(word: String) -> Double {
        let s = [Self.bos, Self.bos] + Array(word) + [Self.eos]
        var sum = 0.0
        for i in 2..<s.count { sum += charLogP(s, i) }
        return sum / Double(word.count + 1)
    }

    /// Average log-probability per character of a word start, no end-of-word term.
    /// An empty start scores 0 (the average over nothing is defined as log 1).
    public func logP(prefix: String) -> Double {
        if prefix.isEmpty { return 0 }
        let s = [Self.bos, Self.bos] + Array(prefix)
        var sum = 0.0
        for i in 2..<s.count { sum += charLogP(s, i) }
        return sum / Double(prefix.count)
    }

    /// Number of dictionary, short or protected words starting with `prefix` (up to 6 letters).
    public func wordsStarting(with prefix: String) -> Int {
        prefixes[prefix] ?? 0
    }
}

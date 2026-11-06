import Foundation

/// Everything the detector knows about one language: the character n-gram model, the dictionary
/// (words and their prefixes) and the hand-curated short-word list.
///
/// Built from `model-<lang>.txt` and `short-<lang>.txt` in the module's resources — files written
/// by `Scripts/export_model.py` from the Python reference, which is where the numbers come from.
/// The loader is a validation boundary like the ones in Keepit: the files are read through
/// `BoundedFileReader`, every record is checked, and anything unexpected is an error rather than a
/// model that silently scores differently.
public final class LanguageModel: Sendable {
    public enum Failure: Error, Equatable {
        case resourceMissing(String)
        case badHeader
        case badRecord(line: Int)
        case languageMismatch(expected: String, found: String)
        case tooManyRecords
    }

    /// Hard limits on what a model file may contain; the shipped files are well inside them.
    public static let maxFileBytes = 8 << 20
    public static let maxRecords = 400_000
    public static let maxWordLength = 32

    // Model constants — identical to detector_proto.py.
    static let smoothing = 0.01
    static let weightTri = 0.75
    static let weightBi = 0.2
    static let weightUni = 0.05
    static let bos: Character = "^"
    static let eos: Character = "$"

    public let language: String
    /// Alphabet size including the end-of-word symbol: the `V` of add-k smoothing.
    let vocabulary: Int
    let total: Double
    let unigram: [Character: Double]
    /// Bigram and trigram rows keyed by context; each row holds its own sum.
    let bigram: [String: Row]
    let trigram: [String: Row]
    /// Dictionary words (frequency-list words) and every prefix of them up to `prefixMax` letters,
    /// with the number of words sharing the prefix.
    public let words: Set<String>
    let prefixes: [String: Int]
    /// Hand-curated short words: the only words under `LayoutDetector.minModelLength` the detector
    /// may act on.
    public let shortWords: Set<String>

    struct Row {
        var counts: [Character: Double] = [:]
        var sum: Double = 0
    }

    static let prefixMax = 6

    // MARK: Loading

    /// Loads the model for `language` from the module's resources.
    public static func load(language: String) throws -> LanguageModel {
        try load(language: language, bundle: .module)
    }

    /// Loads the model for `language` from any bundle (tests point this at a temporary folder).
    public static func load(language: String, bundle: Bundle) throws -> LanguageModel {
        guard let modelURL = bundle.url(forResource: "model-\(language)", withExtension: "txt") else {
            throw Failure.resourceMissing("model-\(language).txt")
        }
        guard let shortURL = bundle.url(forResource: "short-\(language)", withExtension: "txt") else {
            throw Failure.resourceMissing("short-\(language).txt")
        }
        let modelData = try BoundedFileReader.read(modelURL, max: maxFileBytes)
        let shortData = try BoundedFileReader.read(shortURL, max: 1 << 20)
        guard let modelText = String(data: modelData, encoding: .utf8),
              let shortText = String(data: shortData, encoding: .utf8) else {
            throw Failure.badHeader
        }
        return try LanguageModel(language: language, modelText: modelText, shortText: shortText)
    }

    /// Parses the two files. Internal so tests can feed malformed text.
    init(language: String, modelText: String, shortText: String) throws {
        var lines = modelText.split(separator: "\n", omittingEmptySubsequences: false)[...]
        guard lines.first == "switchit-model\t1" else { throw Failure.badHeader }
        lines = lines.dropFirst()

        var lang: String?
        var alphabet: Set<Character> = []
        var total: Double?
        var unigram: [Character: Double] = [:]
        var bigram: [String: Row] = [:]
        var trigram: [String: Row] = [:]
        var words: Set<String> = []
        var prefixes: [String: Int] = [:]
        var lineNo = 1
        var records = 0

        for line in lines {
            lineNo += 1
            if line.isEmpty { continue }        // only the trailing newline
            records += 1
            if records > Self.maxRecords { throw Failure.tooManyRecords }
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            func bad() -> Failure { .badRecord(line: lineNo) }
            switch f[0] {
            case "lang":
                guard f.count == 2, lang == nil else { throw bad() }
                lang = String(f[1])
            case "alphabet":
                guard f.count == 2, alphabet.isEmpty, !f[1].isEmpty else { throw bad() }
                alphabet = Set(f[1])
                guard alphabet.count == f[1].count else { throw bad() }
            case "total":
                guard f.count == 2, total == nil, let v = Double(f[1]), v.isFinite, v > 0 else { throw bad() }
                total = v
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
                guard f.count == 2, !f[1].isEmpty, f[1].count <= Self.maxWordLength else { throw bad() }
                let w = String(f[1])
                for x in w where !alphabet.contains(x) { throw bad() }
                guard words.insert(w).inserted else { throw bad() }
                let chars = Array(w)
                for k in 1...min(chars.count, Self.prefixMax) {
                    prefixes[String(chars[..<k]), default: 0] += 1
                }
            default:
                throw bad()
            }
        }
        guard let foundLang = lang, let foundTotal = total, !alphabet.isEmpty else { throw Failure.badHeader }
        guard foundLang == language else { throw Failure.languageMismatch(expected: language, found: foundLang) }

        var short: Set<String> = []
        for raw in shortText.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            for x in line where !alphabet.contains(x) { throw Failure.badRecord(line: 0) }
            short.insert(line)
        }

        self.language = language
        self.vocabulary = alphabet.count + 1
        self.total = foundTotal
        self.unigram = unigram
        self.bigram = bigram
        self.trigram = trigram
        self.words = words
        self.prefixes = prefixes
        self.shortWords = short
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
    public func logP(prefix: String) -> Double {
        let s = [Self.bos, Self.bos] + Array(prefix)
        var sum = 0.0
        for i in 2..<s.count { sum += charLogP(s, i) }
        return sum / Double(prefix.count)
    }

    /// Number of dictionary words starting with `prefix` (prefixes up to 6 letters are indexed).
    public func wordsStarting(with prefix: String) -> Int {
        prefixes[prefix] ?? 0
    }
}

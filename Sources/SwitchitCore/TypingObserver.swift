import Foundation

/// The typing state machine: key strokes in, decisions out. No AppKit, no event tap — the app
/// feeds it from `CGEvent`s, the tests feed it directly.
///
/// It owns the `WordBuffer` and the `LayoutDetector`, knows which layout is active, whether a
/// password field has the keyboard (secure input) and whether the user paused the app, and
/// applies the plan's rules: a mid-word decision at most once per word, nothing while paused or
/// in secure input, shortcuts (⌘ ⌃ fn) end a word silently, an Option-character is a boundary.
///
/// Stage 2 only *reports* decisions; stage 3 acts on them.
public struct TypingObserver {
    /// Modifier state of a key stroke, as the tap sees it.
    public struct Modifiers: OptionSet, Sendable, Equatable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let shift = Modifiers(rawValue: 1)
        public static let option = Modifiers(rawValue: 2)
        public static let command = Modifiers(rawValue: 4)
        public static let control = Modifiers(rawValue: 8)
        public static let function = Modifiers(rawValue: 16)
    }

    /// Why a word ended without a key.
    public enum FlushReason: Equatable, Sendable {
        case click, appChanged, layoutChanged, windowChanged
    }

    public enum Input: Equatable, Sendable {
        case key(KeyCode, Modifiers)
        case flush(FlushReason)
        /// The active layout changed; `language` is the detector code it maps to, nil if the new
        /// layout is one the detector does not know (then nothing is decided until it changes back).
        case layoutChanged(language: String?)
        case secureInput(Bool)
        case paused(Bool)
    }

    public enum Decision: Equatable, Sendable {
        case none
        /// Letters 3–6: the word so far reads as `to`, not as the active `from`.
        case midWord(keys: [KeyCode], letters: Int, from: String, to: String)
        /// At a boundary: the whole word was meant in `to`.
        case boundary(keys: [KeyCode], terminator: KeyCode?, from: String, to: String)
        /// A word ended and was left alone: `verdict` is the detector's answer (nil = unsure).
        case leftAlone(keys: [KeyCode], terminator: KeyCode?, from: String, verdict: String?)
    }

    public let detector: LayoutDetector
    private(set) public var buffer: WordBuffer
    private(set) public var active: String?
    private(set) public var secureInput = false
    private(set) public var paused = false
    /// Set once a mid-word decision was reported for the current word; cleared at the boundary.
    private(set) public var midWordReported = false
    /// Letters of the current word that were typed with Shift (for the two-capitals rule).
    private var capitals: Int { buffer.capitals }

    public init(detector: LayoutDetector, active: String?, maxWordLength: Int = 32) {
        self.detector = detector
        self.active = active
        var keys: Set<KeyCode> = []
        for lang in detector.languages { keys.formUnion(lang.layout.letterKeys) }
        self.buffer = WordBuffer(wordKeys: keys, maxLength: maxWordLength)
    }

    /// Whether anything is being observed right now; the menu shows why not.
    public var isObserving: Bool { active != nil && !secureInput && !paused }

    public mutating func handle(_ input: Input) -> Decision {
        switch input {
        case .paused(let on):
            paused = on
            buffer.reset()
            midWordReported = false
            return .none
        case .secureInput(let on):
            // The tap receives nothing while secure input is on; whatever was in the buffer is
            // stale when it comes back. Drop it either way.
            secureInput = on
            buffer.reset()
            midWordReported = false
            return .none
        case .layoutChanged(let language):
            active = language
            buffer.reset()
            midWordReported = false
            return .none
        case .flush:
            guard isObserving else { buffer.reset(); return .none }
            return finish(buffer.flush(), terminator: nil)
        case .key(let code, let mods):
            guard isObserving, let from = active else { buffer.reset(); return .none }
            if !mods.intersection([.command, .control]).isEmpty {
                // A shortcut, not typing. The word is over and nothing is said about it.
                // (fn is not in the set: Apple keyboards report it on the arrow keys themselves,
                // and an arrow must veto the word, not merely end it.)
                buffer.reset()
                midWordReported = false
                return .none
            }
            if mods.contains(.option) && !code.isArrow {
                // ⌥-characters (©, ™, dead keys) are not letters of any layout: a boundary.
                return finish(buffer.append(KeyStroke(.space)), terminator: code)
            }
            let event = buffer.append(KeyStroke(code, shift: mods.contains(.shift)))
            switch event {
            case .word:
                return finish(event, terminator: code)
            case .none:
                // Mid-word: once per word, letters 3–6, on a letter that was actually appended.
                let n = buffer.strokes.count
                guard !midWordReported, n >= LayoutDetector.prefixMin, n <= LayoutDetector.prefixMax,
                      buffer.wordKeys.contains(code), !buffer.suppressed else { return .none }
                let keys = buffer.strokes.map(\.code)
                if let to = detector.decidePrefix(keys, active: from, capitals: capitals) {
                    midWordReported = true
                    return .midWord(keys: keys, letters: n, from: from, to: to)
                }
                return .none
            }
        }
    }

    private mutating func finish(_ event: WordBuffer.Event, terminator: KeyCode?) -> Decision {
        defer { midWordReported = false }
        guard case .word(let strokes, let term) = event, let from = active else { return .none }
        let keys = strokes.map(\.code)
        let caps = strokes.lazy.filter(\.shift).count
        let verdict = detector.decideWord(keys, active: from, capitals: caps)
        let t = terminator ?? term
        if let to = verdict, to != from {
            return .boundary(keys: keys, terminator: t, from: from, to: to)
        }
        return .leftAlone(keys: keys, terminator: t, from: from, verdict: verdict)
    }
}

import CoreGraphics
import Foundation

/// The typing state machine: key strokes in, decisions out. No AppKit, no event tap — the app
/// feeds it from `CGEvent`s, the tests feed it directly.
///
/// It owns the `WordBuffer` and builds the `LayoutDetector` from the layouts the system has
/// enabled, knows which one is active, whether a password field has the keyboard (secure input)
/// and whether the user paused the app, and applies the plan's rules: a mid-word decision at most
/// once per word, nothing while paused or in secure input, shortcuts (⌘ ⌃) end a word silently,
/// arrows and deletions with modifiers veto the word, an Option key stroke (dead keys, ⌥⌫,
/// special characters) is an unknown edit and vetoes too.
///
/// Stage 2 only *reports* decisions; stage 3 acts on them.
public struct TypingObserver {
    /// Modifier state of a key stroke, as the tap sees it. `shift` and `capsLock` are reported
    /// separately; a letter is upper-case when exactly one of them is on.
    public struct Modifiers: OptionSet, Sendable, Equatable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let shift = Modifiers(rawValue: 1)
        public static let option = Modifiers(rawValue: 2)
        public static let command = Modifiers(rawValue: 4)
        public static let control = Modifiers(rawValue: 8)
        public static let function = Modifiers(rawValue: 16)
        public static let capsLock = Modifiers(rawValue: 32)

        /// From a `CGEventFlags` raw value (the tap's `event.flags.rawValue`).
        public init(eventFlags: UInt64) {
            var m: Modifiers = []
            if eventFlags & CGEventFlags.maskShift.rawValue != 0 { m.insert(.shift) }
            if eventFlags & CGEventFlags.maskAlternate.rawValue != 0 { m.insert(.option) }
            if eventFlags & CGEventFlags.maskCommand.rawValue != 0 { m.insert(.command) }
            if eventFlags & CGEventFlags.maskControl.rawValue != 0 { m.insert(.control) }
            if eventFlags & CGEventFlags.maskSecondaryFn.rawValue != 0 { m.insert(.function) }
            if eventFlags & CGEventFlags.maskAlphaShift.rawValue != 0 { m.insert(.capsLock) }
            self = m
        }

        /// Whether a letter typed with these modifiers is upper-case.
        public var uppercase: Bool { contains(.shift) != contains(.capsLock) }
    }

    /// Why a word ended without a key.
    public enum FlushReason: Equatable, Sendable {
        case click, appChanged, windowChanged
    }

    public enum Input: Equatable, Sendable {
        case key(KeyCode, Modifiers)
        case flush(FlushReason)
        /// The enabled or selected layouts changed. `active` is the detector code of the selected
        /// one (nil: a layout or input method the detector does not handle — nothing is decided
        /// until it changes back); `layouts` are the enabled layouts the detector may read keys
        /// with, by code. The detector and the buffer's word keys are rebuilt from them.
        case layoutChanged(active: String?, layouts: [String: Layout])
        case secureInput(Bool)
        case paused(Bool)
        /// The event stream broke (the tap was disabled and re-enabled): whatever was buffered
        /// may be stale. Dropped silently.
        case interrupted
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

    /// The models, by language code; layouts come and go, models stay.
    public let models: [String: LanguageModel]
    private(set) public var detector: LayoutDetector
    private(set) public var buffer: WordBuffer
    private(set) public var active: String?
    private(set) public var secureInput = false
    private(set) public var paused = false
    /// Set once a mid-word decision was reported for the current word; cleared whenever the
    /// run ends — boundary, Escape, veto, the buffer emptied by Backspace.
    private(set) public var midWordReported = false
    private let maxWordLength: Int

    /// Builds the observer with the given models and an initial set of layouts.
    public init(models: [String: LanguageModel], layouts: [String: Layout], active: String?, maxWordLength: Int = 32) {
        self.models = models
        self.maxWordLength = maxWordLength
        self.detector = Self.makeDetector(models: models, layouts: layouts)
        self.buffer = WordBuffer(wordKeys: Self.wordKeys(of: detector), maxLength: maxWordLength)
        self.active = active
    }

    /// Convenience for tests: the models and layouts of an existing detector.
    public init(detector: LayoutDetector, active: String?, maxWordLength: Int = 32) {
        var models: [String: LanguageModel] = [:]
        var layouts: [String: Layout] = [:]
        for lang in detector.languages {
            models[lang.code] = lang.model
            layouts[lang.code] = lang.layout
        }
        self.init(models: models, layouts: layouts, active: active, maxWordLength: maxWordLength)
    }

    private static func makeDetector(models: [String: LanguageModel], layouts: [String: Layout]) -> LayoutDetector {
        let languages = layouts.keys.sorted().compactMap { code -> LayoutDetector.Language? in
            guard let model = models[code], let layout = layouts[code] else { return nil }
            return .init(code: code, layout: layout, model: model)
        }
        // A detector needs at least one language; with none enabled, keep the models' own
        // default tables so the structure stays valid — `active` is nil then and nothing is decided.
        if languages.isEmpty {
            return LayoutDetector(languages: models.keys.sorted().map {
                .init(code: $0, layout: $0 == "ru" ? .russianPC : .usEnglish, model: models[$0]!)
            })
        }
        return LayoutDetector(languages: languages)
    }

    private static func wordKeys(of detector: LayoutDetector) -> Set<KeyCode> {
        var keys: Set<KeyCode> = []
        for lang in detector.languages { keys.formUnion(lang.layout.letterKeys) }
        return keys
    }

    /// Whether anything is being observed right now; the menu shows why not.
    public var isObserving: Bool {
        guard let active, !secureInput, !paused else { return false }
        return detector.languages.contains { $0.code == active }
    }

    public mutating func handle(_ input: Input) -> Decision {
        switch input {
        case .paused(let on):
            paused = on
            drop()
            return .none
        case .secureInput(let on):
            // The tap receives nothing while secure input is on; whatever was in the buffer is
            // stale when it comes back. Drop it either way, and never decide on it.
            secureInput = on
            drop()
            return .none
        case .layoutChanged(let newActive, let layouts):
            detector = Self.makeDetector(models: models, layouts: layouts)
            buffer = WordBuffer(wordKeys: Self.wordKeys(of: detector), maxLength: maxWordLength)
            active = newActive
            midWordReported = false
            return .none
        case .interrupted:
            drop()
            return .none
        case .flush:
            guard isObserving else { drop(); return .none }
            return finish(buffer.flush(), terminator: nil)
        case .key(let code, let mods):
            guard isObserving, let from = active else { drop(); return .none }
            // 1. Caret movement, with or without modifiers (⌘← ⌥→ fn-arrows): the buffer no
            //    longer matches the screen. Veto until the next boundary.
            if code.isArrow {
                _ = buffer.append(KeyStroke(code))
                midWordReported = false
                return .none
            }
            // 2. Deleting more than a character (⌥⌫ ⌘⌫): the text changed in a way the buffer
            //    cannot follow. Veto, and say nothing about the word being deleted.
            if code == .delete && !mods.intersection([.option, .command, .control]).isEmpty {
                buffer.suppressUntilBoundary()
                midWordReported = false
                return .none
            }
            // 3. A shortcut (⌘S, ⌃A …), not typing. The word is over and nothing is said about it.
            if !mods.intersection([.command, .control]).isEmpty {
                drop()
                return .none
            }
            // 4. Option with a key: a dead key (⌥e + e = é), a special character (⌥8 = •) or
            //    anything else the buffer cannot read. An unknown edit: veto until the boundary.
            if mods.contains(.option) {
                buffer.suppressUntilBoundary()
                midWordReported = false
                return .none
            }
            // 5. Typing.
            let event = buffer.append(KeyStroke(code, shift: mods.uppercase))
            switch event {
            case .word:
                return finish(event, terminator: code)
            case .none:
                if code == .delete {
                    if buffer.isEmpty { midWordReported = false }     // the word was erased
                    return .none
                }
                if !buffer.wordKeys.contains(code) {
                    // A boundary that ended nothing reportable (empty or vetoed run, Escape).
                    midWordReported = false
                    return .none
                }
                // Mid-word: once per word, letters 3–6, on a letter that was actually appended.
                let n = buffer.strokes.count
                guard !midWordReported, n >= LayoutDetector.prefixMin, n <= LayoutDetector.prefixMax,
                      !buffer.suppressed else { return .none }
                let keys = buffer.strokes.map(\.code)
                if let to = detector.decidePrefix(keys, active: from, capitals: buffer.capitals) {
                    midWordReported = true
                    return .midWord(keys: keys, letters: n, from: from, to: to)
                }
                return .none
            }
        }
    }

    private mutating func drop() {
        buffer.reset()
        midWordReported = false
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

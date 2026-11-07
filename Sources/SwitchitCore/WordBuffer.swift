/// Collects the key strokes of the word being typed and reports when a word is complete.
///
/// The buffer knows nothing about layouts or languages. It only decides what a word is:
/// a run of strokes on word-forming keys (the union of every enabled layout's letter keys),
/// ended by a boundary — Space, Return, Tab, a non-letter key, a mouse click, a change of
/// window or input source. The detector gets the finished run; everything else is dropped.
///
/// Pure value type: the app feeds it from the event tap, tests feed it directly.
public struct WordBuffer: Sendable {
    /// What the buffer reports after a stroke.
    public enum Event: Equatable, Sendable {
        /// Nothing to act on yet.
        case none
        /// A word ended. `strokes` is the complete run; `terminator` is the key that ended it
        /// (nil when the end came from `flush()` — a click, focus change, etc.).
        case word(strokes: [KeyStroke], terminator: KeyCode?)
    }

    /// Keys that continue a word. Build it from `Layout.letterKeys` of every enabled layout.
    public let wordKeys: Set<KeyCode>
    /// Longest run that is still treated as a word. Longer runs (pasted-looking input, key
    /// repeat held down, identifiers) are discarded rather than analysed.
    public let maxLength: Int

    private(set) public var strokes: [KeyStroke] = []
    /// Set when the run is no longer a word — it grew past `maxLength`, or the user moved the
    /// caret with an arrow key (the buffer no longer matches the screen). Letters are dropped
    /// until the next boundary; nothing is reported for the run.
    private(set) public var suppressed = false

    public init(wordKeys: Set<KeyCode>, maxLength: Int = 32) {
        precondition(maxLength > 0)
        self.wordKeys = wordKeys
        self.maxLength = maxLength
    }

    public var isEmpty: Bool { strokes.isEmpty }

    /// Feeds one key press.
    public mutating func append(_ stroke: KeyStroke) -> Event {
        if stroke.code == .delete {
            if !strokes.isEmpty {
                strokes.removeLast()
            } else if !suppressed {
                // Backspace past the start of the run: the caret has crossed a boundary into
                // text the buffer never saw, so whatever is typed next joins something unknown on
                // screen. Nothing in this run is a word any more (auditor's P2, 6 Nov).
                suppressed = true
            }
            return .none
        }
        if wordKeys.contains(stroke.code) {
            if suppressed { return .none }
            strokes.append(stroke)
            if strokes.count > maxLength {
                strokes.removeAll()
                suppressed = true
            }
            return .none
        }
        if stroke.code.movesCaret {
            // Veto: the user moved the caret inside or right after the word. Drop the run and
            // keep dropping until a boundary — this word is never corrected.
            strokes.removeAll()
            suppressed = true
            return .none
        }
        // Any other key ends the run. Escape is a boundary too, but the word it ends is not
        // reported: the user is backing out of something, not finishing a word.
        let finished = take()
        if stroke.code == .escape || finished.isEmpty { return .none }
        return .word(strokes: finished, terminator: stroke.code)
    }

    /// Ends the current run without a key — mouse click, window or input-source change.
    /// Reports the run as a word if there is one.
    public mutating func flush() -> Event {
        let finished = take()
        return finished.isEmpty ? .none : .word(strokes: finished, terminator: nil)
    }

    /// Drops the current run and ignores everything until the next boundary: the caret or the
    /// text changed in a way the buffer cannot follow (word deletion, a composed character …).
    public mutating func suppressUntilBoundary() {
        strokes.removeAll()
        suppressed = true
    }

    /// Drops the current run but keeps a veto that is already in force: for an event that ends
    /// the run without telling the buffer anything about the screen (a ⌘/⌃ shortcut).
    public mutating func dropRun() {
        strokes.removeAll()
    }

    /// Drops the current run silently.
    public mutating func reset() {
        strokes.removeAll()
        suppressed = false
    }

    /// Number of upper-case letters in the current run.
    public var capitals: Int { strokes.lazy.filter(\.shift).count }

    private mutating func take() -> [KeyStroke] {
        defer { reset() }
        return suppressed ? [] : strokes
    }
}

/// A macOS virtual key code: the physical key, independent of the active keyboard layout.
///
/// The values are Apple's ANSI key codes (`kVK_ANSI_*` in Carbon's `Events.h`); they are what a
/// `CGEvent` of type `keyDown` carries in `keyboardEventKeycode`. The detector works on these
/// rather than on characters, because the same key sequence can be read under any layout the
/// user has enabled — that is the whole trick of a layout switcher.
public struct KeyCode: Hashable, Sendable {
    public let raw: UInt16

    public init(_ raw: UInt16) { self.raw = raw }

    // Letter keys, ANSI layout.
    public static let a = KeyCode(0x00)
    public static let s = KeyCode(0x01)
    public static let d = KeyCode(0x02)
    public static let f = KeyCode(0x03)
    public static let h = KeyCode(0x04)
    public static let g = KeyCode(0x05)
    public static let z = KeyCode(0x06)
    public static let x = KeyCode(0x07)
    public static let c = KeyCode(0x08)
    public static let v = KeyCode(0x09)
    public static let b = KeyCode(0x0B)
    public static let q = KeyCode(0x0C)
    public static let w = KeyCode(0x0D)
    public static let e = KeyCode(0x0E)
    public static let r = KeyCode(0x0F)
    public static let y = KeyCode(0x10)
    public static let t = KeyCode(0x11)
    public static let o = KeyCode(0x1F)
    public static let u = KeyCode(0x20)
    public static let i = KeyCode(0x22)
    public static let p = KeyCode(0x23)
    public static let l = KeyCode(0x25)
    public static let j = KeyCode(0x26)
    public static let k = KeyCode(0x28)
    public static let n = KeyCode(0x2D)
    public static let m = KeyCode(0x2E)

    // Digit row.
    public static let one = KeyCode(0x12)
    public static let two = KeyCode(0x13)
    public static let three = KeyCode(0x14)
    public static let four = KeyCode(0x15)
    public static let six = KeyCode(0x16)
    public static let five = KeyCode(0x17)
    public static let equal = KeyCode(0x18)
    public static let nine = KeyCode(0x19)
    public static let seven = KeyCode(0x1A)
    public static let minus = KeyCode(0x1B)
    public static let eight = KeyCode(0x1C)
    public static let zero = KeyCode(0x1D)

    // Punctuation keys that carry letters in some layouts (ЙЦУКЕН puts х ъ ж э б ю ё on them).
    public static let rightBracket = KeyCode(0x1E)
    public static let leftBracket = KeyCode(0x21)
    public static let quote = KeyCode(0x27)
    public static let semicolon = KeyCode(0x29)
    public static let backslash = KeyCode(0x2A)
    public static let comma = KeyCode(0x2B)
    public static let slash = KeyCode(0x2C)
    public static let period = KeyCode(0x2F)
    public static let grave = KeyCode(0x32)

    // Control keys the word buffer cares about.
    public static let `return` = KeyCode(0x24)
    public static let tab = KeyCode(0x30)
    public static let space = KeyCode(0x31)
    public static let delete = KeyCode(0x33)   // Backspace
    public static let escape = KeyCode(0x35)
}

/// One key press as the detector sees it: which key, and whether Shift was held.
///
/// Other modifiers (⌘ ⌃ ⌥) never reach the buffer — a shortcut is not typing — so they are
/// filtered out before a stroke is made, by the event tap in the app.
public struct KeyStroke: Hashable, Sendable {
    public let code: KeyCode
    public let shift: Bool

    public init(_ code: KeyCode, shift: Bool = false) {
        self.code = code
        self.shift = shift
    }
}

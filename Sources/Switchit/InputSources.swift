import Carbon.HIToolbox
import Foundation
import SwitchitCore

/// The keyboard layouts macOS has enabled, and which of them the detector knows.
///
/// Stage 2 maps input-source IDs to the detector's built-in letter tables; `UCKeyTranslate`
/// against the real layout data comes with the correction mechanics in stage 3.
enum InputSources {
    struct Entry: Equatable {
        let id: String          // kTISPropertyInputSourceID, e.g. com.apple.keylayout.US
        let name: String        // localized name, for the status line
    }

    /// Detector language and letter table for a layout ID, or nil for one we do not handle.
    static func language(for id: String) -> (code: String, layout: Layout)? {
        switch id {
        case "com.apple.keylayout.US", "com.apple.keylayout.ABC", "com.apple.keylayout.British",
             "com.apple.keylayout.USExtended", "com.apple.keylayout.Australian",
             "com.apple.keylayout.Canadian", "com.apple.keylayout.Irish":
            return ("en", .usEnglish)
        case "com.apple.keylayout.Russian":
            return ("ru", .russian)
        case "com.apple.keylayout.RussianWin":
            return ("ru", .russianPC)
        default:
            return nil          // AZERTY, QWERTZ, phonetic Russian, Dvorak …: not in 1.0
        }
    }

    /// Enabled keyboard layouts, in the order System Settings shows them.
    static func enabled() -> [Entry] {
        let filter: [CFString: Any] = [
            kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource as Any,
            kTISPropertyInputSourceIsEnabled: true,
            kTISPropertyInputSourceIsSelectCapable: true,
        ]
        guard let list = TISCreateInputSourceList(filter as CFDictionary, false)?.takeRetainedValue() as? [TISInputSource] else {
            return []
        }
        return list.compactMap { entry(of: $0) }.filter { $0.id.hasPrefix("com.apple.keylayout.") }
    }

    static func current() -> Entry? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
        return entry(of: source)
    }

    private static func entry(of source: TISInputSource) -> Entry? {
        func string(_ key: CFString) -> String? {
            guard let ptr = TISGetInputSourceProperty(source, key) else { return nil }
            return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
        }
        guard let id = string(kTISPropertyInputSourceID) else { return nil }
        return Entry(id: id, name: string(kTISPropertyLocalizedName) ?? id)
    }

    /// Fires when the user (or we) switch the layout.
    static let changedNotification = Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)
}

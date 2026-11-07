import Carbon.HIToolbox
import Foundation
import SwitchitCore

/// The keyboard input sources macOS has selected and enabled, and which of them the detector knows.
///
/// Two TIS queries matter and they differ (auditor's stage-2 P1): the *selected* source
/// (`TISCopyCurrentKeyboardInputSource`) is what the user picked — a layout, or an input method
/// such as Pinyin or Romaji; the *layout* source (`TISCopyCurrentKeyboardLayoutInputSource`) is
/// the letter table in use, which for an input method is its base layout (US or ABC). Observing
/// must be gated by the selected source: an input method is never observed, whatever its base.
/// Stage 3 will use `UCKeyTranslate` against the layout's own data; stage 2 maps IDs to the
/// detector's built-in tables (`Layout.forInputSource`).
enum InputSources {
    struct Entry: Equatable {
        let id: String          // kTISPropertyInputSourceID, e.g. com.apple.keylayout.US
        let name: String        // localized name, for the status line
        let isKeyboardLayout: Bool   // kTISTypeKeyboardLayout, as opposed to an input method or mode
    }

    /// Detector language and letter table for a *selected* source, or nil when it is an input
    /// method, a mode, or a layout 1.0 does not handle.
    static func language(for entry: Entry) -> (code: String, layout: Layout)? {
        guard entry.isKeyboardLayout else { return nil }
        return Layout.forInputSource(id: entry.id)
    }

    /// The selected source, as the user picked it.
    static func selected() -> Entry? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return entry(of: source)
    }

    /// The ID of the selected source only — cheap enough to check on every key.
    static func selectedID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return string(kTISPropertyInputSourceID, of: source)
    }

    /// Enabled keyboard layouts the detector knows, by language code. When two layouts of one
    /// language are enabled (Russian and Russian – PC), the selected one wins, else the first.
    static func enabledLayouts(selected: Entry?) -> [String: Layout] {
        let filter: [CFString: Any] = [
            kTISPropertyInputSourceType: kTISTypeKeyboardLayout as Any,
            kTISPropertyInputSourceIsEnabled: true,
            kTISPropertyInputSourceIsSelectCapable: true,
        ]
        guard let list = TISCreateInputSourceList(filter as CFDictionary, false)?.takeRetainedValue() as? [TISInputSource] else {
            return [:]
        }
        var out: [String: Layout] = [:]
        for source in list {
            guard let e = entry(of: source), let (code, layout) = Layout.forInputSource(id: e.id) else { continue }
            if out[code] == nil || e.id == selected?.id { out[code] = layout }
        }
        return out
    }

    private static func entry(of source: TISInputSource) -> Entry? {
        guard let id = string(kTISPropertyInputSourceID, of: source) else { return nil }
        let type = string(kTISPropertyInputSourceType, of: source)
        return Entry(id: id, name: string(kTISPropertyLocalizedName, of: source) ?? id,
                     isKeyboardLayout: type == (kTISTypeKeyboardLayout as String))
    }

    private static func string(_ key: CFString, of source: TISInputSource) -> String? {
        guard let ptr = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }

    /// Fires when the user (or we) switch the source, and when the set of enabled sources changes.
    static let selectionChanged = Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)
    static let enabledChanged = Notification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String)
}

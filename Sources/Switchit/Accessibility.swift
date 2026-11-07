import AppKit
import ApplicationServices

/// The Accessibility permission (TCC): an active event tap needs it. Keepit's approach, copied:
/// no `kAXTrustedCheckOptionPrompt` (that sheet stays on screen after the user flips the switch
/// and has to be dismissed with "Deny"); a denied AX query is enough to make TCC list the app,
/// and the System Settings pane does the rest.
enum Accessibility {
    static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Open System Settings → Privacy & Security → Accessibility with Switchit already in the list.
    static func openSettings() {
        var focused: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &focused)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

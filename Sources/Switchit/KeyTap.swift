import AppKit
import Carbon.HIToolbox
import SwitchitCore

/// The event tap: every key press and mouse click in the session, before the frontmost app
/// sees it. Needs the Accessibility permission (`CGEvent.tapCreate` fails without it).
///
/// Stage 2 observes only — every event is passed through untouched. The tap is nevertheless
/// created as an *active* tap (`.defaultTap`), because stage 3 will hold a boundary key back
/// while it corrects the word, and because macOS asks for the same permission either way.
final class KeyTap {
    /// Right Option: the default correction shortcut (behaviour spec, item 2).
    static let rightOptionKeyCode: Int64 = Int64(kVK_RightOption)

    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    /// Whether right Option is down alone, for the press-and-release-with-nothing-between rule.
    private var rightOptionAlone = false

    /// Called for every key down (never with ⌘⌃fn-shortcuts filtered here: that is the observer's
    /// job, so the rule lives in one testable place).
    var onKey: ((KeyCode, TypingObserver.Modifiers) -> Void)?
    /// Called when a mouse button goes down anywhere.
    var onClick: (() -> Void)?
    /// Called when right Option was pressed and released with no key in between.
    var onShortcut: (() -> Void)?

    var isRunning: Bool { port != nil }

    /// Creates and starts the tap. Returns false when the permission is missing.
    func start() -> Bool {
        if port != nil { return true }
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue)
        let info = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: mask,
                                           callback: { proxy, type, event, info in
                                               let tap = Unmanaged<KeyTap>.fromOpaque(info!).takeUnretainedValue()
                                               return tap.handle(proxy: proxy, type: type, event: event)
                                           }, userInfo: info) else {
            Log.system.error("event tap could not be created (Accessibility not granted?)")
            return false
        }
        self.port = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        Log.system.info("event tap started")
        return true
    }

    func stop() {
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        self.source = nil
        self.port = nil
        Log.system.info("event tap stopped")
    }

    private func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS disables a tap whose callback was too slow; re-enable and carry on.
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            Log.system.notice("event tap re-enabled after \(type == .tapDisabledByTimeout ? "timeout" : "user input", privacy: .public)")
            return Unmanaged.passUnretained(event)
        case .keyDown:
            rightOptionAlone = false
            // Our own synthetic events (stage 3) will carry a marker; nothing to skip yet.
            let code = KeyCode(UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)))
            onKey?(code, Self.modifiers(of: event.flags))
        case .flagsChanged:
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            if keycode == Self.rightOptionKeyCode {
                if flags.contains(.maskAlternate) {
                    // Right Option went down. "Alone" means no other modifier is held.
                    rightOptionAlone = flags.intersection([.maskCommand, .maskControl, .maskShift, .maskSecondaryFn]).isEmpty
                } else if rightOptionAlone {
                    rightOptionAlone = false
                    onShortcut?()
                }
            } else {
                rightOptionAlone = false
            }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            rightOptionAlone = false
            onClick?()
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    static func modifiers(of flags: CGEventFlags) -> TypingObserver.Modifiers {
        var m: TypingObserver.Modifiers = []
        if flags.contains(.maskShift) { m.insert(.shift) }
        if flags.contains(.maskAlternate) { m.insert(.option) }
        if flags.contains(.maskCommand) { m.insert(.command) }
        if flags.contains(.maskControl) { m.insert(.control) }
        if flags.contains(.maskSecondaryFn) { m.insert(.function) }
        return m
    }
}

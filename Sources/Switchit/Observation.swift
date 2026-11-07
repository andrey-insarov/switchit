import AppKit
import SwitchitCore

/// Stage 2: watches typing and logs what the detector would do. Owns the tap, the secure-input
/// watch, the input-source observation and the `TypingObserver`; the menu reads `status`.
/// Main thread only: the tap's run-loop source is on the main loop, and so are the notifications.
final class Observation {
    enum Status: Equatable {
        case needsAccessibility
        case paused
        case secureInput
        case unknownLayout(String)      // a layout the detector does not know
        case observing(layout: String)
    }

    private let tap = KeyTap()
    private let secure = SecureInputWatch()
    private var observer: TypingObserver
    private var layoutName = ""
    private(set) var status: Status = .needsAccessibility { didSet { if status != oldValue { onStatusChange?(status) } } }
    var onStatusChange: ((Status) -> Void)?
    /// For the menu: how many decisions of each kind since launch.
    private(set) var counts = (midWord: 0, boundary: 0, leftAlone: 0)
    /// `--unmask-log`: write the keys of decided words as public log values, for the manual
    /// check of stage 2 on a Mac where `log config --mode private_data:on` is not available.
    /// Off by default; never on in a release build.
    private let unmask: Bool

    init(detector: LayoutDetector, unmaskLog: Bool = false) {
        observer = TypingObserver(detector: detector, active: nil)
        unmask = unmaskLog
        if unmaskLog { Log.system.notice("--unmask-log: typed keys of decided words are logged as public values") }
    }

    var isPaused: Bool { observer.paused }

    func start() {
        tap.onKey = { [weak self] code, mods in self?.report(self?.observer.handle(.key(code, mods))) }
        tap.onClick = { [weak self] in self?.report(self?.observer.handle(.flush(.click))) }
        tap.onShortcut = { [weak self] in
            // Stage 3 undoes or converts here. Stage 2 notes that the shortcut arrived and ends the word.
            Log.detector.info("shortcut: right Option")
            self?.report(self?.observer.handle(.flush(.click)))
        }
        secure.onChange = { [weak self] on in
            self?.report(self?.observer.handle(.secureInput(on)))
            self?.refreshStatus()
        }
        DistributedNotificationCenter.default().addObserver(forName: InputSources.changedNotification, object: nil, queue: .main) { [weak self] _ in
            self?.layoutChanged()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.report(self?.observer.handle(.flush(.appChanged)))
            self?.secure.check()
        }
        layoutChanged()
        secure.start()
        startTapIfTrusted()
    }

    /// Called at launch and whenever the user may have granted the permission.
    func startTapIfTrusted() {
        if !tap.isRunning, Accessibility.isTrusted() {
            _ = tap.start()
        }
        refreshStatus()
    }

    func setPaused(_ on: Bool) {
        report(observer.handle(.paused(on)))
        Log.system.info("paused \(on, privacy: .public)")
        refreshStatus()
    }

    private func layoutChanged() {
        let current = InputSources.current()
        layoutName = current?.name ?? "?"
        let language = current.flatMap { InputSources.language(for: $0.id)?.code }
        report(observer.handle(.layoutChanged(language: language)))
        Log.system.info("layout \(current?.id ?? "nil", privacy: .public) → \(language ?? "unknown", privacy: .public)")
        refreshStatus()
    }

    private func refreshStatus() {
        if !tap.isRunning { status = .needsAccessibility }
        else if observer.paused { status = .paused }
        else if observer.secureInput { status = .secureInput }
        else if observer.active == nil { status = .unknownLayout(layoutName) }
        else { status = .observing(layout: layoutName) }
    }

    /// Logs a decision. The key sequence is the typed word: `.private`, like everything typed.
    private func report(_ decision: TypingObserver.Decision?) {
        guard let decision else { return }
        switch decision {
        case .none:
            break
        case .midWord(let keys, let letters, let from, let to):
            counts.midWord += 1
            if unmask {
                Log.detector.info("mid-word at \(letters, privacy: .public): \(Self.describe(keys), privacy: .public) \(from, privacy: .public) → \(to, privacy: .public)")
            } else {
                Log.detector.info("mid-word at \(letters, privacy: .public): \(Self.describe(keys)) \(from, privacy: .public) → \(to, privacy: .public)")
            }
        case .boundary(let keys, let terminator, let from, let to):
            counts.boundary += 1
            if unmask {
                Log.detector.info("boundary (\(Self.name(terminator), privacy: .public)): \(Self.describe(keys), privacy: .public) \(from, privacy: .public) → \(to, privacy: .public)")
            } else {
                Log.detector.info("boundary (\(Self.name(terminator), privacy: .public)): \(Self.describe(keys)) \(from, privacy: .public) → \(to, privacy: .public)")
            }
        case .leftAlone(let keys, let terminator, let from, let verdict):
            counts.leftAlone += 1
            if unmask {
                Log.detector.debug("left alone (\(Self.name(terminator), privacy: .public)): \(Self.describe(keys), privacy: .public) \(from, privacy: .public), verdict \(verdict ?? "unsure", privacy: .public)")
            } else {
                Log.detector.debug("left alone (\(Self.name(terminator), privacy: .public)): \(Self.describe(keys)) \(from, privacy: .public), verdict \(verdict ?? "unsure", privacy: .public)")
            }
        }
    }

    /// The word as US-layout characters of its keys — what the Python bench calls `keys`.
    private static func describe(_ keys: [KeyCode]) -> String {
        String(keys.map { Layout.usEnglish.character(for: KeyStroke($0)) ?? "·" })
    }

    private static func name(_ code: KeyCode?) -> String {
        guard let code else { return "flush" }
        switch code {
        case .space: return "space"
        case .return: return "return"
        case .tab: return "tab"
        default: return "key \(code.raw)"
        }
    }
}

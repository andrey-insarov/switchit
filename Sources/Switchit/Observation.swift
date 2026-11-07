import AppKit
import SwitchitCore

/// Stage 2: watches typing and logs what the detector would do. Owns the tap, the secure-input
/// watch, the input-source observation and the `TypingObserver`; the menu reads `status`.
/// Main thread only: the tap's run-loop source is on the main loop, and so are the notifications.
///
/// Order of checks before any event that can produce a decision (auditor's stage-2 P1): the
/// secure-input state is read *now*, not from the last poll; the selected input source is
/// compared with the one the observer was built for, so a key typed before the change
/// notification arrives is handled under the new source, not the old one.
final class Observation {
    enum Status: Equatable {
        case needsAccessibility
        case paused
        case secureInput
        case unknownSource(String)      // an input method, or a layout the detector does not know
        case observing(source: String)
    }

    private let tap = KeyTap()
    private let secure = SecureInputWatch()
    private var observer: TypingObserver
    private var sourceName = ""
    private var sourceID: String?
    private var statusTimer: Timer?
    private(set) var status: Status = .needsAccessibility { didSet { if status != oldValue { onStatusChange?(status) } } }
    var onStatusChange: ((Status) -> Void)?
    /// For the menu: how many decisions of each kind since launch.
    private(set) var counts = (midWord: 0, boundary: 0, leftAlone: 0)

    #if DIAGNOSTICS
    /// `--unmask-log` (diagnostics build only): write the keys of decided words as public log
    /// values, for the manual check on a Mac where `log config --mode private_data:on` is not
    /// available. The release builds do not contain this code path.
    private let unmask: Bool
    #endif

    init(models: [String: LanguageModel], unmaskLog: Bool = false) {
        observer = TypingObserver(models: models, layouts: [:], active: nil)
        #if DIAGNOSTICS
        unmask = unmaskLog
        if unmaskLog { Log.system.notice("--unmask-log: typed keys of decided words are logged as public values (diagnostics build)") }
        #endif
    }

    var isPaused: Bool { observer.paused }

    func start() {
        tap.onKey = { [weak self] code, mods in
            guard let self else { return }
            self.syncState()
            self.report(self.observer.handle(.key(code, mods)))
        }
        tap.onClick = { [weak self] in
            guard let self else { return }
            self.syncState()
            self.report(self.observer.handle(.flush(.click)))
        }
        tap.onShortcut = { [weak self] in
            guard let self else { return }
            self.syncState()
            // Stage 3 undoes or converts here. Stage 2 notes that the shortcut arrived and ends the word.
            if self.observer.isObserving { Log.detector.info("shortcut: right Option") }
            self.report(self.observer.handle(.flush(.click)))
        }
        tap.onInterrupted = { [weak self] in
            self?.report(self?.observer.handle(.interrupted))
        }
        secure.onChange = { [weak self] on in
            self?.report(self?.observer.handle(.secureInput(on)))
            self?.refreshStatus()
        }
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: InputSources.selectionChanged, object: nil, queue: .main) { [weak self] _ in self?.sourcesChanged() }
        dnc.addObserver(forName: InputSources.enabledChanged, object: nil, queue: .main) { [weak self] _ in self?.sourcesChanged() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.syncState()
            self.report(self.observer.handle(.flush(.appChanged)))
        }
        sourcesChanged()
        secure.start()
        startTapIfTrusted()
        // Permission revoked, tap disabled by the system: the status line must not keep saying
        // "Observing" (auditor's stage-2 P2). Checked once a second, like secure input.
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.startTapIfTrusted() }
    }

    /// Reads the secure-input state and the selected source *now*, before an event is handled.
    private func syncState() {
        secure.check()
        if InputSources.selectedID() != sourceID { sourcesChanged() }
    }

    /// Called at launch, on every menu open and once a second: starts the tap when the
    /// permission is there, stops it when it went away, and keeps the status honest.
    func startTapIfTrusted() {
        let trusted = Accessibility.isTrusted()
        if trusted, !tap.isRunning {
            _ = tap.start()
        } else if !trusted, tap.isRunning {
            Log.system.notice("Accessibility permission gone; stopping the tap")
            tap.stop()
            report(observer.handle(.interrupted))
        }
        refreshStatus()
    }

    func setPaused(_ on: Bool) {
        report(observer.handle(.paused(on)))
        Log.system.info("paused \(on, privacy: .public)")
        refreshStatus()
    }

    private func sourcesChanged() {
        let selected = InputSources.selected()
        sourceID = selected?.id
        sourceName = selected?.name ?? "?"
        let language = selected.flatMap { InputSources.language(for: $0) }
        let layouts = InputSources.enabledLayouts(selected: selected)
        report(observer.handle(.layoutChanged(active: language?.code, layouts: layouts)))
        Log.system.info("source \(selected?.id ?? "nil", privacy: .public) → \(language?.code ?? "unknown", privacy: .public); layouts \(layouts.keys.sorted().joined(separator: ","), privacy: .public)")
        refreshStatus()
    }

    private func refreshStatus() {
        if !tap.isLive { status = .needsAccessibility }
        else if observer.paused { status = .paused }
        else if observer.secureInput { status = .secureInput }
        else if !observer.isObserving { status = .unknownSource(sourceName) }
        else { status = .observing(source: sourceName) }
    }

    /// Logs a decision. The key sequence is the typed word: `.private`, like everything typed.
    private func report(_ decision: TypingObserver.Decision?) {
        guard let decision else { return }
        switch decision {
        case .none:
            break
        case .midWord(let keys, let letters, let from, let to):
            counts.midWord += 1
            logKeys("mid-word at \(letters)", keys, "\(from) → \(to)")
        case .boundary(let keys, let terminator, let from, let to):
            counts.boundary += 1
            logKeys("boundary (\(Self.name(terminator)))", keys, "\(from) → \(to)")
        case .leftAlone(let keys, let terminator, let from, let verdict):
            counts.leftAlone += 1
            logKeys("left alone (\(Self.name(terminator)))", keys, "\(from), verdict \(verdict ?? "unsure")", debug: true)
        }
    }

    /// `what: <keys> outcome` — `what` and `outcome` carry no typed text and are public; the
    /// keys are private, always, except in a diagnostics build started with `--unmask-log`.
    private func logKeys(_ what: String, _ keys: [KeyCode], _ outcome: String, debug: Bool = false) {
        let text = Self.describe(keys)
        #if DIAGNOSTICS
        if unmask {
            if debug { Log.detector.debug("\(what, privacy: .public): \(text, privacy: .public) \(outcome, privacy: .public)") }
            else { Log.detector.info("\(what, privacy: .public): \(text, privacy: .public) \(outcome, privacy: .public)") }
            return
        }
        #endif
        if debug { Log.detector.debug("\(what, privacy: .public): \(text, privacy: .private) \(outcome, privacy: .public)") }
        else { Log.detector.info("\(what, privacy: .public): \(text, privacy: .private) \(outcome, privacy: .public)") }
    }

    /// The word as US-layout characters of its keys — what the Python bench calls `keys`; a key
    /// without a US letter is written as its code in brackets (`[41]` for `;`), so the line is
    /// unambiguous.
    private static func describe(_ keys: [KeyCode]) -> String {
        keys.map { Layout.usEnglish.character(for: KeyStroke($0)).map(String.init) ?? "[\($0.raw)]" }.joined()
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

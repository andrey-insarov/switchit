import AppKit
import SwitchitCore

/// Menu-bar shell. Stage 2: the status line, Pause / Resume, the Accessibility prompt and Quit;
/// the detector runs in observation mode and logs what it would do (docs/PLAN.md, stage 2).
/// Settings, Exceptions and the rest of the menu arrive in stage 4.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var observation: Observation?
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "Pause", action: #selector(togglePause), keyEquivalent: "")
    private let grantItem = NSMenuItem(title: "Grant Accessibility Permission…", action: #selector(grantAccessibility), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon("keyboard")
        statusItem.menu = buildMenu()

        let selftest = ProcessInfo.processInfo.arguments.contains("--selftest")
        do {
            let models = ["en": try LanguageModel.load(language: "en"), "ru": try LanguageModel.load(language: "ru")]
            let observation = Observation(models: models,
                                          unmaskLog: ProcessInfo.processInfo.arguments.contains("--unmask-log"))
            observation.onStatusChange = { [weak self] status in self?.show(status) }
            self.observation = observation
            observation.start()
            show(observation.status)
            if selftest {
                // CI: the models loaded, the app built its menu and tried the tap (which fails
                // without the permission, as expected). That is the smoke test: exit 0.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(0) }
            }
        } catch {
            // A model that does not load is a broken bundle: say so, do nothing else.
            Log.system.fault("language model failed to load: \(String(describing: error), privacy: .public)")
            statusLine.title = "Language model failed to load"
            setIcon("exclamationmark.triangle")
            if selftest { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(1) } }
        }
    }

    // MARK: Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        pauseItem.target = self
        menu.addItem(pauseItem)
        grantItem.target = self
        menu.addItem(grantItem)
        menu.addItem(.separator())
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let title = NSMenuItem(title: "Switchit \(version) — observing only", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Switchit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        return menu
    }

    private func show(_ status: Observation.Status) {
        switch status {
        case .needsAccessibility:
            statusLine.title = "Needs Accessibility permission"
            setIcon("keyboard.badge.ellipsis")
        case .paused:
            statusLine.title = "Paused"
            setIcon("pause.circle")
        case .secureInput:
            statusLine.title = "Password field — not watching"
            setIcon("lock")
        case .unknownSource(let name):
            statusLine.title = "\(name) — not supported"
            setIcon("keyboard")
        case .observing(let name):
            statusLine.title = "Observing: \(name)"
            setIcon("keyboard")
        }
        grantItem.isHidden = status != .needsAccessibility
        pauseItem.title = observation?.isPaused == true ? "Resume" : "Pause"
    }

    private func setIcon(_ symbol: String) {
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Switchit")
        statusItem.button?.image?.isTemplate = true
    }

    @objc private func togglePause() {
        guard let observation else { return }
        observation.setPaused(!observation.isPaused)
    }

    @objc private func grantAccessibility() {
        Accessibility.openSettings()
    }
}

extension AppDelegate: NSMenuDelegate {
    /// The user may have flipped the switch in System Settings since the last look.
    func menuWillOpen(_ menu: NSMenu) {
        observation?.startTapIfTrusted()
    }
}

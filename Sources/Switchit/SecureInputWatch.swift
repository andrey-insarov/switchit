import Carbon.HIToolbox
import Foundation

/// Tells whether a password field (or any app that asked for secure event input) has the
/// keyboard. There is no notification for it; the app polls once a second and on activation,
/// which is cheap and enough for a status line — the tap receives no key events either way.
final class SecureInputWatch {
    private var timer: Timer?
    private(set) var isOn = false
    var onChange: ((Bool) -> Void)?

    func start() {
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.check() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func check() {
        let now = IsSecureEventInputEnabled()
        if now != isOn {
            isOn = now
            Log.system.info("secure input \(now ? "on" : "off", privacy: .public)")
            onChange?(now)
        }
    }
}

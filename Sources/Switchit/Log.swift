import Foundation
import os

/// Switchit's diagnostics go to the unified system log (Console.app, `log show`) under subsystem
/// `com.it.switch`. Same rules as Keepit, so that the log can never become a side channel:
///
/// - Static text is public; every interpolated value is `.private` (Logger's default), so Console
///   shows `<private>` unless an administrator turns private data on for the subsystem:
///   `sudo log config --subsystem com.it.switch --mode private_data:on`
/// - Typed text appears only in the `detector` category, only as the key sequence of a word the
///   detector decided about, only while stage 2 observes — and never while secure input is on
///   (the tap receives nothing then). Stage 3 reduces this to decisions without the keys.
/// - `NSLog` is not used (it marks the whole message public).
///
/// Watching live: `log stream --predicate 'subsystem == "com.it.switch"' --level info`
enum Log {
    static let system   = Logger(subsystem: "com.it.switch", category: "system")    // tap, Accessibility, input sources
    static let detector = Logger(subsystem: "com.it.switch", category: "detector")  // decisions
}

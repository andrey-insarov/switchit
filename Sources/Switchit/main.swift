import AppKit

// Entry point. No storyboard/XIB: everything is built in code so the project
// compiles with plain `swift build` (no Xcode project required).
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

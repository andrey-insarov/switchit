# Switchit

Keyboard-layout switcher for macOS: notices when a word was typed in the wrong layout
(`ghbdtn` → `привет`), switches the layout and retypes the word. Menu-bar app, no account,
no cloud, no analytics in the app.

Written from scratch; see [docs/PLAN.md](docs/PLAN.md) for the stages and the macOS mechanisms
it builds on.

## Build

```
swift build
swift test
make app      # ad-hoc signed Switchit.app
make run
```

Requires macOS 13+ and a Swift 5.9 toolchain. CI (`.github/workflows/build.yml`) runs the same
steps on every push and pull request.

## Layout

- `Sources/SwitchitCore` — detector layer, no AppKit: key codes, layout tables, word buffer,
  language models (stage 1). Everything here has unit tests.
- `Sources/Switchit` — the app: event tap, input sources, menu bar, settings.
- `Tests/SwitchitTests` — tests for the core.
- `Resources/Info.plist` — bundle template (`make app` fills in version, build, SHA, date).

## Status

Stage 0 (skeleton). Nothing is intercepted yet.

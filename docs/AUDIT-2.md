# Switchit — audit brief, stage 2 (observation)

6 November 2026 · PR #2 `stage-2-observe` → `main` · same process as stage 1: findings become tests, the stage closes on "no further findings".

## What stage 2 contains — and what it does not

Stage 1 answered *which language was this key sequence meant in?* Stage 2 connects that answer to the keyboard: an event tap sees every key press, a state machine turns them into decisions, and the app **logs** the decisions. It corrects nothing: no key is swallowed, modified or synthesised, no layout is switched, nothing is typed into any application. Every event passes through the tap untouched. The trust boundary now has a second side: what the app may learn, and where it may write it.

In:
- `SwitchitCore.TypingObserver` — the typing state machine: keys and flushes in, decisions out. Owns the `WordBuffer` and the `LayoutDetector`; applies the plan's rules (one mid-word report per word at letters 3–6; nothing while paused, in a password field or on an unknown layout; ⌘/⌃ shortcuts end the word silently; an Option character is a boundary; arrows and Backspace past the start veto the word).
- `Switchit/KeyTap` — `CGEvent.tapCreate` (session tap, head insert, `.defaultTap`): key down, flags changed, mouse down. Right Option pressed and released with nothing in between is the shortcut. Re-enables itself after `tapDisabledByTimeout` / `ByUserInput`.
- `Switchit/InputSources` — TIS: enabled layouts, the current one, the change notification; a fixed map of input-source IDs to the detector's letter tables (US/ABC/British… → en, Russian → ru, Russian – PC → ru; everything else → unknown, nothing observed).
- `Switchit/SecureInputWatch` — `IsSecureEventInputEnabled()` polled once a second and on app activation.
- `Switchit/Accessibility` — Keepit's approach: no system prompt; a denied AX query puts the app in the TCC list, the pane does the rest.
- `Switchit/Observation` — the coordinator; logs to os.Logger subsystem `com.it.switch`.
- `Switchit/Log` — Keepit's rules: static text public, every interpolated value `.private`.
- Two editions: `SWITCHIT_APPSTORE` / `APPSTORE` flag, entitlements for both (the App Store one sandboxed). CI builds both and launches the app with `--selftest`.

Not in: the correction mechanics (stage 3), settings and exclusions (stage 4), any file the app writes. The app writes nothing to disk; the log is the system's.

## What to look at

1. **What reaches the log, and when.** The plan allows stage 2 to log the key sequence of a decided word as a `.private` value. Check: is anything logged while secure input is on (the tap should receive nothing, and `TypingObserver` drops the buffer on the transition both ways)? Is there a window between a password field taking focus and the one-second poll noticing, in which keys are buffered and later logged? What about the word in the buffer *before* the field took focus — it is dropped, but was any decision about it logged on the transition? Is a `.private` value ever interpolated with `privacy: .public` by mistake? Is the US-layout spelling of the keys (`describe`) a faithful `.private` value or is it leaking through a format string?
2. **The tap as an attack surface.** It is an active tap that modifies nothing. Can the callback be made slow or re-entered? What happens on `tapDisabledByTimeout` mid-word? If `CGEvent.tapCreate` fails after the permission is revoked at run time, does the app notice (the status line) or keep claiming to observe? Can another process's synthetic events (CGEventPost) drive the state machine into a decision — and does it matter while nothing is corrected? (It will matter in stage 3: note it.)
3. **`TypingObserver` against the behaviour spec** (`docs/PLAN.md`, "Behaviour while typing") and against the real event stream: dead keys (⌥e then e), key repeat (held key = one stroke per repeat — does the buffer grow to `maxLength` and suppress?), Caps Lock (no Shift flag, upper-case letters — the two-capitals rule sees `capitals = 0`), fn on arrows, the numeric keypad, Emoji picker, input methods that compose (not in 1.0 but the state must not misbehave), ⌘-shortcut *inside* a word (⌘B) — the word is dropped silently; is that right for the spec, or should the shortcut end the word and decide it?
4. **Input-source mapping.** The fixed table maps IDs to letter tables. A layout we think is `en` but whose letters differ (Dvorak is excluded; is Colemak? is `com.apple.keylayout.USInternational-PC`?) would make the detector read wrong candidates. What does the app do on a layout it does not know, and is "nothing" the right answer? `kTISNotifySelectedKeyboardInputSourceChanged` — delivered on the main queue after the keys already typed under the new layout? What is in the buffer then?
5. **Secure input detection.** Polling once a second is a window. Is there a faster signal we should use (the tap receiving no events is not one)? Is the `appChanged` check enough for Terminal `sudo`?
6. **Pause and the two editions.** Paused drops the buffer; does anything still reach the log? In the App Store edition, does the sandbox change anything stage 2 does (tap creation, TIS calls, `NSWorkspace` notifications, DistributedNotificationCenter)?
7. **Tests.** The observer has 18 tests; the AppKit glue has none and cannot run on CI without the permission. Which of the glue's rules could be lifted into the core and tested — the right-Option-alone rule, the modifier mapping, the input-source map?

Out of scope: everything stage 1 closed; the correction mechanics; settings persistence.

## Expected output

Findings as P1 / P2 / P3 with a reproducer each — as a test where the core is involved, as a step-by-step on a Mac where the tap is. P1 for this stage: typed text reaching the log in a case the plan says it must not (secure input, paused, unknown layout), or a decision reported for a correctly typed word that stage 1 did not already know about. "No further findings" closes stage 2.

## Where things are

- PR #2: https://github.com/andrey-insarov/switchit/pull/2 · plan: `docs/PLAN.md` · manual check: `docs/TESTING-2.md`
- Core: `Sources/SwitchitCore/TypingObserver.swift` · app: `Sources/Switchit/{KeyTap,Observation,InputSources,SecureInputWatch,Accessibility,Log}.swift`
- Tests: `Tests/SwitchitTests/TypingObserverTests.swift`
- Build: `swift build && swift test`; the app: `make app` (Full) / `make app APPSTORE=1`.

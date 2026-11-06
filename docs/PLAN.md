# Switchit — plan

Separate app, separate repo, written from scratch. Working name: Switchit (final name, domain
and bundle id are open decisions).

## What it does

Automatic layout switching when a word was typed in the wrong layout (ru/en first), correction of
the word already typed, manual correction by hot key, per-application exclusions, menu bar, login
item. No cloud, no account, no analytics in the app.

## macOS mechanisms it builds on

- **Key interception**: `CGEvent.tapCreate` (session tap, head insert) for `keyDown` /
  `flagsChanged`. An active tap (one that may swallow or modify events) needs the **Accessibility**
  permission; a listen-only tap needs Input Monitoring. We need the active one: a correction deletes
  the word and types it again. Consequence: the app cannot run in the sandbox → **Developer ID +
  notarization only**, no Mac App Store.
- **Secure input**: while a password field has focus the tap receives no key events;
  `IsSecureEventInputEnabled()` → pause, and say so in the menu.
- **Layouts**: `TISCreateInputSourceList` (keyboard input sources, enabled only),
  `TISCopyCurrentKeyboardInputSource`, `TISSelectInputSource`. Key code → character under a given
  layout: `UCKeyTranslate` with `kTISPropertyUnicodeKeyLayoutData`.
- **Correction**: N × Backspace via `CGEvent(keyboardEventSource:virtualKey:keyDown:)`, then input.
  Two ways to type the word back — decided in stage 3 by trying both in real applications:
  (a) switch the layout and replay the same key codes (the system translates them under the new
  layout); (b) `keyboardSetUnicodeString` (layout-independent, but terminals and some Electron apps
  treat it differently).
- **Login item**: `SMAppService.mainApp`. **Hot keys**: Carbon `RegisterEventHotKey` or the same tap.

## Core: the detector

Input: the virtual key codes of the current word (layout-independent). For each enabled layout the
candidate string comes from `UCKeyTranslate`; in tests from table maps (US, Russian, Russian – PC)
without Carbon.

Scoring: log-likelihood under character n-grams of the layout's language (bigrams + trigrams; models
trained by a script from a permissively licensed corpus; the model ships as a binary resource, the
script lives in the repo), a bonus for a dictionary word, a penalty for impossible sequences. The
decision fires only when the gap between candidates exceeds a threshold **and** the word is longer
than a minimum; a word ends at space / punctuation / Return. User exclusions (words, applications)
are checked before the model. A manual correction by the user is a training signal (the word goes
into a local list).

All of this is `SwitchitCore`: pure Swift, no AppKit, covered by a table of examples —
`ghbdtn` → `привет`, `руддщ` → `hello`, words that are valid in both layouts, abbreviations,
URLs / e-mail (leave alone), passwords (secure input), digits and punctuation inside a word.

## Stages — one stage = one branch / PR, tests, auditor

Same principle as Keepit: the next stage starts after "no further findings".

**Stage 0 — skeleton.** SPM: `SwitchitCore` (library, no AppKit) + `Switchit` (app) + tests. CI
from Keepit (build on push). `VERSION` / `CHANGELOG`. Decide the name and bundle id.

**Stage 1 — `SwitchitCore`: detector.** Key-code tables for tests; `WordBuffer` (accumulation,
boundaries, reset on window change / click); n-gram models + training script; `LayoutDetector` with
thresholds; the example table as tests; performance — a decision per word in < 1 ms. Acceptance: a
table of ≥ 200 words with the expected result, with false positives on English technical words and
Russian loanwords in a section of their own.

**Stage 2 — observing.** Event tap, Accessibility request with onboarding (explain before the
system dialog), secure input, frontmost-app filter (bundle id), buffer reset on mouseDown / window
change. Corrects nothing yet — only logs decisions to os.Logger (private values). Manual check in
Safari, Terminal, VS Code, Slack, Pages.

**Stage 3 — switching and correction.** `TIS*` wrapper; correction of the last word by hot key;
automatic mode after a word; choice of input method (a)/(b) from the results in the same
applications; loop protection (never correct a word that was just corrected; do not correct when
the user switched the layout themselves). Tests for the correction planner (pure logic: what to
delete, what to type).

**Stage 4 — the app.** Menu bar (status, pause, current layout, "fix last word"), Settings:
General / Shortcuts / Languages / Exclusions / Advanced — HIG, the Keepit rules (one control width
per pane, help behind (?), no truncation ellipses). Exclusions: words and applications. Login item.
First run. Localizations with Keepit's `add_strings.py`.

**Stage 5 — release 1.0.** Developer ID, notarization, DMG, Sparkle, one site page, privacy policy
(Keepit wording). Not in 1.0: other languages, pre-emptive layout switching, syncing exclusions.

## Open decisions

- Name, domain, bundle id (placeholder `com.it.switch`).
- Languages after ru/en (the detector is written for N layouts; models are added one at a time).
- Reuse of Keepit code (hot keys, Settings scaffolding, localization): copy modules into this repo,
  no shared dependency.
- Corpus for the n-grams: needs a permissive licence; candidates are checked in stage 1.

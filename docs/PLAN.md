# Switchit — plan

Separate app, separate repo, written from scratch. Working name: Switchit (final name, domain
and bundle id are open decisions).

## What it does

Automatic layout switching when a word was typed in the wrong layout (ru/en first), correction of
the word already typed, manual correction by hot key, per-application exclusions, menu bar, login
item. No cloud, no account, no analytics in the app.

## Features beyond layout switching (requested 6 Nov)

All word-level corrections run as **one pipeline of rules** at a word boundary — layout → typos → ё —
sharing the correction planner, the undo (Backspace / ⌘Z right after a correction), the exclusions
and the sounds. Each rule has its own switch; an undo puts the word on that rule's "leave alone"
list. Only one rewrite per word per pass; a rule never fires on a word another rule just produced.

- **Typos** (ru, en): a curated table of common misspellings, wrong → right, high confidence only —
  not a spell checker. Applied only when the typed word is not a dictionary word and the table entry
  is unambiguous. The table ships as a read-only resource; its data source needs a licence check
  (share-alike lists cannot go into the bundle as is). macOS's own autocorrect works only in Cocoa
  text views; ours works everywhere, so the two must not fight: skip when the system has just
  replaced the word.
- **ё** (ru): е → ё only for words where the replacement is unambiguous (ёлка, ещё); ambiguous pairs
  (все / всё, небо / нёбо) are left alone. Dictionary source needs a licence check. Off by default
  until the table is proven on the bench.
- **Program exclusions**: per application (bundle id) — nothing is corrected there; defaults include
  terminals and IDEs. Pick from running apps or from /Applications.
- **Word exclusions**: an editable, visible list (add, remove, search, which rule it applies to),
  the same lists the undo fills. Exported and imported with `.switchit`.
- **Sounds**: a sound on layout switch and on a typo fix, separately; system sounds or a file the
  user picks (a picked file is external input: bounded read, audio type checked; in the App Store
  edition a security-scoped bookmark). Off by default.

Settings panes: General / Shortcuts / Languages / Typos / ё / Exclusions (Programs, Words) / Sounds /
Advanced.

## Two editions (decided 6 Nov)

One code base, a build flag `SWITCHIT_APPSTORE`, the same way Keepit has `KEEPIT_APPSTORE`:

- **Full** — Developer ID, notarized DMG, Sparkle updates, every feature including the typing
  diary (1.x).
- **App Store edition** — sandboxed, no Sparkle, storage only inside the container / app group or
  in places the user picks, **no diary** (`#if !APPSTORE`).

## Typing diary (1.x, Full edition only)

Encrypted with Keepit's container (header as AAD, PBKDF2/HKDF, LZFSE, verify on read). Never records
while secure input is on; off by default; a menu-bar indicator while it records; per-application
exclusions with password managers, banks and messengers excluded by default; local only, no
automatic backup. Its own staged review by the auditor.

Storage (decided 6 Nov): a folder of sealed segments, one file per day (or hour), no database. The
current segment stays in memory and is sealed periodically and on quit; erasing a period deletes its
files, erasing everything deletes the folder; search decrypts the segments of the chosen period in
memory, no index. Not SQLite: the system SQLite has no encryption, row-level encryption leaves
metadata and fragments in the journal / WAL, and SQLCipher brings third-party C crypto into the build
and the export-compliance question. Revisit SQLCipher only if fast search across years is needed.

Export to HTML (decided 6 Nov, like Telegram's chat export) is the way to search seriously: ⌘F in a
browser, an editor, grep. Rules: only on an explicit action, never automatic or scheduled; the user
picks the location in a save panel, after one warning that the file is not encrypted; a period and
applications can be chosen; the warning says that in an ordinary folder Spotlight indexes the file,
Time Machine keeps a copy, and a synced folder (iCloud Drive, Dropbox) uploads it; one self-contained
HTML file with no external links or scripts, grouped by day and application with anchors.

## Moving to another Mac: encrypted archive and import

Not a password zip: `zip -e` uses ZipCrypto, which is broken, and AES zip needs a third-party library
(macOS Archive Utility neither creates nor opens it). Instead one `.switchit` file built on Keepit's
container (AES-GCM, PBKDF2, LZFSE, verify on read), sealed with an export password:

- Contents: settings, personal word lists, application exclusions, and — optionally, Full edition
  only — the diary. Diary segments are decrypted in memory and resealed under the export password;
  the diary key of the old Mac never leaves it.
- Import follows Keepit's Restore flow: open → password → preview (days of diary, words in the lists)
  → merge or replace → commit with a journal and rollback. Merging joins diary days.
- Import is external input: bounded read, one validation point, the auditor's A–J matrix as for
  `.keepit`.
- The App Store edition has export and import too, without the diary.

## macOS mechanisms it builds on

- **Key interception**: `CGEvent.tapCreate` (session tap, head insert) for `keyDown` /
  `flagsChanged`. An active tap (one that may swallow or modify events) needs the **Accessibility**
  permission; a listen-only tap needs Input Monitoring. We need the active one: a correction deletes
  the word and types it again. Accessibility is a TCC permission granted by the user at run time,
  not an entitlement, so it works in a sandboxed build too (checked 6 Nov on the App Store build of
  Caramba Switcher: sandboxed, and it links `CGEventTapCreate`, `CGEventPost`, `AXIsProcessTrusted`).
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

Scoring: interpolated character trigram / bigram / unigram models per language, average
log-probability per character, trained by `Scripts/detector_proto.py` from frequency lists (the
model ships as a binary resource; the script lives in the repo). Bench result (6 Nov, every 5th
word held out, 19 000 words): 4 letters 87–91 % recognised with 6 false switches in 1 443;
5 letters 93–95 %, none; 6+ letters 97–99 %, none.

Decision rules:
1. Words shorter than 4 letters are decided by a hand-curated dictionary of short words only;
   longer words by the models, with a margin of 1.0 (average log-prob per character).
2. A word that exists in more than one language (`keys` / `луны`) is left alone.
3. User exclusions (words, applications) are checked before the model.
4. Sentence context (`SentenceContext`): the language of the previous one or two words shifts the
   thresholds. Stores nothing.
5. Personal lists are the only learning: an automatic switch undone at once by the user
   (Backspace, ⌘Z, the undo hot key) puts the word on the "leave alone" list; a manual correction
   of a word we left alone puts it on the "always" list. Both lists are visible and editable in
   Settings → Exclusions.
6. **No adaptive model trained on what the user types** — decided 6 Nov. It would mean keeping
   statistics of everything typed, in a file on disk that changes the text the app itself types
   into other applications: an attack surface and an audit subject. No neural models either; the
   trigrams are enough.

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

**Stage 5 — release 1.0, both editions.** Full: Developer ID, notarization, DMG, Sparkle. App Store
edition: sandbox, no Sparkle, no diary. One site page, privacy policy (Keepit wording). Not in 1.0: other languages, pre-emptive layout switching, syncing exclusions.

## Open decisions

- Name, domain, bundle id (placeholder `com.it.switch`).
- Languages after ru/en (the detector is written for N layouts; models are added one at a time).
- Reuse of Keepit code (hot keys, Settings scaffolding, localization): copy modules into this repo,
  no shared dependency.
- Corpus for the n-grams: needs a permissive licence; candidates are checked in stage 1.

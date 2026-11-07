# Stage 2 — manual check on a Mac

Stage 2 watches typing and logs what the detector *would* do. It corrects nothing and types
nothing. The check is: does the log say the right thing in real applications, and does the menu
reflect the state?

## 1. Build and run

```
cd ~/Documents/switchit
git checkout stage-2-observe
git pull
make app DIAG=1 SIGN_ID="Developer ID Application: UK Intis Telecom LTD (WQ66955SW2)"
open Switchit.app --args --unmask-log
```

Signing with the Developer ID keeps the Accessibility grant across rebuilds (an ad-hoc signature
changes with every build, and macOS then treats the app as a new one). `DIAG=1` builds the
diagnostic edition: only there does `--unmask-log` exist, and it makes the app write the keys of
decided words as public log values. A release build (`make app` without `DIAG=1`) ignores the
flag and always logs them as `<private>` (auditor's stage-2 finding).

The keyboard icon appears in the menu bar. Its first line reads **Needs Accessibility permission**.

## 2. Grant Accessibility

Menu → **Grant Accessibility Permission…** → System Settings opens with Switchit in the list →
turn it on. Open the menu again: the first line becomes **Observing: U.S.** (or whichever layout
is active). Until then nothing is observed.

If Switchit is listed but the status does not change: turn it off and on again (macOS forgets the
grant when the app is rebuilt with a different signature — same as Keepit).

## 3. Watch the log

In a second Terminal window:

```
log stream --predicate 'subsystem == "com.it.switch"' --level debug
```

(`log config --mode private_data:on` is not accepted on current macOS; the `--unmask-log` launch
argument above does the same for this app only.)

Lines to expect:

- `layout com.apple.keylayout.US → en` — on launch and on every layout change;
- `mid-word at 3: ghb en → ru` — the detector would switch at the 3rd letter;
- `boundary (space): ghbdtn en → ru` — the detector would fix the whole word;
- `left alone (space): hello en, verdict en` — a correct word (debug level);
- `secure input on` / `off`, `paused true` / `false`, `shortcut: right Option`.

The keys are written as the US-layout characters of the keys pressed — what you typed, not what
appeared on screen — so `привет` typed with the Russian layout active shows as `ghbdtn ru`.

## 4. What to try

Type the following, with the English layout active, in each of: Safari (address bar and a text
field), Telegram, VS Code, Terminal, Pages, Notes. One word per line; press Space after each.

| Type                | Expect in the log                                   |
|---------------------|-----------------------------------------------------|
| `ghbdtn`            | `mid-word at 3: ghb en → ru`, then `boundary … → ru` |
| `hello`             | `left alone … verdict en`                           |
| `Ghb` (Shift on G)  | `mid-word at 3` — one capital is fine               |
| `GHBDTN` (Caps)     | `left alone … verdict unsure` — two capitals        |
| `cctv`, `http`, `pdf` | `left alone … verdict en` — protected             |
| `grep`              | `left alone … verdict unsure`                       |
| `gh` then ← then `bdtn` Space | nothing for this word (arrow veto)       |
| `foo` Space Backspace `ghbdtn` Space | nothing (Backspace past the start) |
| `ghb` then ⌘S       | nothing more for this word                          |
| right Option alone  | `shortcut: right Option`                            |
| `KFC` with Caps Lock on | `left alone … verdict unsure` — Caps Lock counts as capitals |
| `ghbdtn` then ⌥⌫    | nothing for this word (deleted, not decided)        |
| `he` then ⌘← then `ghb` Space | nothing (the caret moved: ⌘-arrows veto like plain arrows) |
| `caf` ⌥e `e` Space (café) | nothing for this word (dead key: an edit the app cannot read) |
| `ghb` Esc `ghb`     | `mid-word at 3` twice — Esc clears the once-per-word latch |

Then with the Russian layout active:

| Type (what appears) | Expect                                              |
|---------------------|-----------------------------------------------------|
| `руддщ` (keys hello) | `mid-word at 4: hell ru → en`, `boundary … → en`  |
| `привет`            | `left alone … verdict ru`                           |
| `рук`, `лун`        | `left alone … verdict ru` — protected               |
| `ещё`, `мёрфи`      | one word each, `left alone` — ё is read where the *selected* Russian layout has it (Russian: on `\`; Russian – PC: on `` ` ``). Check with both layouts enabled; the log line `source … layouts en,ru` shows the rebuild on switching |

And:

- click into another window mid-word → the word is decided at once (`boundary` / `left alone`
  with `flush`);
- switch layouts with the system shortcut mid-word → `layout … → …`, the word is dropped;
- open a password field (Safari login, `sudo` in Terminal) → status line **Password field — not
  watching**, `secure input on`; type a password; nothing about it in the log; leave the field →
  `secure input off`;
- menu → **Pause** → status **Paused**, typing logs nothing; **Resume**;
- a layout the detector does not know (add Dvorak or German temporarily) → status **… — layout
  not supported**, nothing logged while it is active;
- an input method (add Japanese – Romaji temporarily) → the same **not supported**, even though
  its base layout is US: the app looks at the selected source, not the layout under it;
- revoke the Accessibility permission while the app runs (System Settings → Privacy & Security →
  Accessibility, toggle off) → within a second the status reads **Needs Accessibility
  permission** and the log says `Accessibility permission gone`; toggle on → observing again.

## 5. What to report

- Any `mid-word` or `boundary` line for a word you typed correctly: the word, the application,
  the layout. That is the P1 of this stage.
- Any application where typing produces no lines at all while the status says Observing.
- Anything in the log that should not be there — in particular anything while **secure input on**.
- Whether the status line and the icon matched what was happening.
- Rough feel: did anything lag while typing? (It should not: the tap does ~0.02 ms of work per key.)

## 6. Quit

Menu → Quit. The event tap goes away with the process; nothing is left running.

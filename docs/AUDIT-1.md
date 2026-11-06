# Switchit — audit brief, stage 1 (layout detector)

6 November 2026 · PR #1 `stage-1-detector` → `main` · same process as Keepit: findings become tests, the stage closes on "no further findings".

## What Switchit is

A menu-bar keyboard-layout switcher for macOS (ru/en first): when a word is typed in the wrong layout (`ghbdtn` for `привет`), the app switches the layout and retypes the word — from the 3rd letter mid-word, or at the word boundary. Written from scratch; Keepit's process, reader and test style are reused. The full plan, the typing-behaviour specification and the two editions (Developer ID / App Store) are in `docs/PLAN.md`.

## What stage 1 contains — and what it does not

In: `SwitchitCore`, a library with no AppKit. It answers one question — *which language was this key sequence meant in?* — and nothing else.

- `KeyCode`, `KeyStroke`, `Layout` — key positions and letter tables (US, Russian, Russian – PC).
- `WordBuffer` — collects a word from key strokes: boundaries, Backspace, Escape, overflow, arrow-key veto.
- `LanguageModel` — loads `model-<lang>.txt` and `short-<lang>.txt` from the module's resources through `BoundedFileReader` (copied from Keepit) and a record-by-record validator. Character trigram / bigram / unigram model, dictionary words, prefix counts, hand-curated short-word list.
- `LayoutDetector` — `decideWord` (whole word at the boundary), `decidePrefix` / `firstPrefixSwitch` (after letters 3–6).

Not in: no event tap, no Accessibility, no input sources, no typing into other apps, no settings or files written by the app. The app target is a status item with Quit. Those come in stages 2–4; the trust boundary grows then.

## The reference and the contract

`Scripts/detector_proto.py` is the reference implementation (Python). `Scripts/export_model.py` writes the resources and `Tests/SwitchitTests/Fixtures/golden.tsv` — 2 001 cases with the reference's decisions and scores. `GoldenTests` replays them in Swift: every decision equal, every score within 1e-9. The Swift code is a port; if the port and the reference disagree, the test fails.

Data: `hermitdave/FrequencyWords` (MIT; derived from OpenSubtitles) — 50 000 most frequent words per language. Cleaning before training (`load_list`): words the layout cannot type, words with a letter three times in a row, words of 3+ letters without a vowel, and the stop lists `stop-{en,ru}.txt`. Bench numbers on 19 000 held-out words are in the PR description.

## Trust boundary today

The only input the library reads is its own bundled resources. They are treated as external anyway, because stage 4 reads user files (exclusion lists, `.switchit` archives) through the same discipline, and because a tampered bundle should fail loudly rather than score differently.

`LanguageModel.init(language:modelText:shortText:)`:
- file size ≤ 8 MiB (`BoundedFileReader`), UTF-8;
- first line `switchit-model<TAB>1`; `lang`, `alphabet`, `total` exactly once;
- records `u` / `b` / `t` / `w` with the field counts, lengths and alphabet membership checked; duplicates refused; weights finite and ≥ 0; `total` finite and > 0; ≤ 400 000 records; words ≤ 32 letters;
- the short list: letters of the alphabet only.

## What to look at

1. **The loader as a validation boundary.** Your A–J matrix, adapted: oversized / limit + 1 / truncated file, duplicate and contradictory records, NUL and invalid UTF-8, `inf` / `nan` / `-0` / `1e999` weights (one of these was found and fixed today — `Double("inf")` parses), a `total` that disagrees with the unigram sum, an alphabet with duplicates or with `^` / `$` in it, record floods, words of exactly 32 and 33 letters, a `w` record before `alphabet`. What slips through, and what does it do to a score?
2. **Does a malformed resource fail closed?** Any path where a partially parsed model is used, or where an error leaves the detector in a state that still answers.
3. **Arithmetic parity.** Is `golden.tsv` a sufficient contract? It samples every 97th word of each list typed in both layouts plus hand-picked cases. Would a different sample, or a float edge (log of a smoothed probability for a character outside the model's alphabet) expose a divergence?
4. **The decision rules against the specification** (`docs/PLAN.md`, "Behaviour while typing"). Specifically: the both-languages rule (`keys` / `луны`), the two-capitals rule, the punctuation rule (`hello,` must not switch, `vtytl;th` must), the prefix rule at letters 3–6 with the "no word in the active language starts like this" condition. Counterexamples where a real word in the active language gets switched are P1.
5. **Dictionary cleaning.** The rules remove real abbreviations too (`cctv`, `pfft`, `psst`). Does removing them create a false switch (typed lowercase, mid-word or at the boundary) that the shipped word would have prevented? The alternative — relaxing the prefix rule — was measured and rejected (false switches on `вуаль`, `штык`).
6. **`WordBuffer` semantics.** Veto by arrows, overflow at `maxLength`, Backspace past the start, Escape, `capitals` with mixed shift, interleaved boundaries. The buffer is what the event tap will feed in stage 2; a wrong word here becomes a wrong correction there.
7. **Cost per keystroke.** `decidePrefix` runs on every letter 3–6, `decideWord` on every boundary; both must stay far under a millisecond on the main thread with a 1.1 MB model. The test asserts < 1 ms per word including all prefix attempts; is the bound and the measurement sound?
8. **Tests themselves.** Anything the suite claims but does not check; a counterexample that is asserted the wrong way round.

Out of scope for this stage: the event tap, secure input, the correction mechanics, settings persistence, the diary, the `.switchit` archive — all later stages, each with its own brief.

## Expected output

Findings as P1 / P2 / P3 with a reproducer each, ideally as a test file in the Keepit style (`Switchit-Stage1AuditTests.swift`, counterexamples asserted as they currently behave; we invert them when fixing). "No further findings" closes stage 1 and PR #1 is merged.

## Where things are

- PR #1: https://github.com/andrey-insarov/switchit/pull/1
- Plan: `docs/PLAN.md` · reference: `Scripts/detector_proto.py` · export: `Scripts/export_model.py`
- Library: `Sources/SwitchitCore/` · resources: `Sources/SwitchitCore/Resources/`
- Tests: `Tests/SwitchitTests/` · contract: `Tests/SwitchitTests/Fixtures/golden.tsv`
- Build and test: `swift build && swift test` (macOS 13+, Swift 5.9); CI runs the same on the PR.

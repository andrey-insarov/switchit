#!/usr/bin/env python3
"""Write the detector's model resources and the golden decision table.

    python3 -I Scripts/export_model.py --data DIR

Writes, from the full frequency lists (nothing held out):

  Sources/SwitchitCore/Resources/model-en.txt, model-ru.txt
      Everything SwitchitCore loads for one language: n-gram counts, dictionary words, the
      curated short and protected lists (format below). The curated sources are Data/*.txt.
  Tests/SwitchitTests/Fixtures/golden.tsv
      Decisions and scores of the reference (detector_proto.py) on a fixed sample; the Swift tests
      must reproduce every decision and every score to 1e-9.

Model file format, UTF-8, one record per line, fields separated by a single tab:

  switchit-model<TAB>1                header, must be the first line
  lang<TAB>en                         language code
  alphabet<TAB>abc…                   the letters, no separators (lower-case letters only)
  total<TAB><float>                   sum of all unigram weights
  records<TAB><int>                   number of record lines that follow — exactly
  u<TAB><c><TAB><float>               unigram weight of character c (a letter or $)
  b<TAB><x><c><TAB><float>            weight of c after context x (x: a letter or ^)
  t<TAB><x><y><c><TAB><float>         weight of c after context xy
  w<TAB><word>                        a dictionary word (cleaned frequency list)
  s<TAB><word>                        a curated short word (2–3 letters): correction target
  p<TAB><word>                        a curated protected word: never switched away from

The five header lines come first, in this order; then exactly `records` record lines. `^` is the
start-of-word padding, `$` the end of word. Floats are Python repr (round-trip exact). The loader
(LanguageModel.swift) refuses anything else — a truncated or edited file must not load.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import detector_proto as dp  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
OUT_RES = os.path.join(ROOT, "Sources", "SwitchitCore", "Resources")
OUT_GOLDEN = os.path.join(ROOT, "Tests", "SwitchitTests", "Fixtures", "golden.tsv")


def write_model(d, path):
    m = d.model
    alphabet = "".join(sorted(set(dp.LAYOUTS[d.lang].values())))
    records = []
    for c in sorted(m.uni):
        records.append(f"u\t{c}\t{m.uni[c]!r}")
    for x in sorted(m.bi):
        for c in sorted(m.bi[x]):
            records.append(f"b\t{x}{c}\t{m.bi[x][c]!r}")
    for xy in sorted(m.tri):
        for c in sorted(m.tri[xy]):
            records.append(f"t\t{xy}{c}\t{m.tri[xy][c]!r}")
    for w in d.word_list:
        records.append(f"w\t{w}")
    for w in sorted(d.short):
        records.append(f"s\t{w}")
    for w in sorted(d.protect):
        records.append(f"p\t{w}")
    # The total is re-derived from the written unigrams so that the loader's sum check is exact
    # up to float ordering, whatever rounding happened in training.
    total = sum(m.uni.values())
    lines = ["switchit-model\t1", f"lang\t{d.lang}", f"alphabet\t{alphabet}", f"total\t{total!r}",
             f"records\t{len(records)}"] + records
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    return len(lines)


def sample(words, step):
    return [w for i, (w, _) in enumerate(words) if i % step == 0]


def golden_rows(det, lists):
    """(keys, active, capitals) cases: a fixed sample typed in both layouts, plus edge cases."""
    cases = []
    for lang in dp.LANGS:
        for w in sample(lists[lang], 97):
            keys = dp.encode(w, lang)
            for active in dp.LANGS:
                cases.append((keys, active, 0))
    for word, lang, active, _ in dp.HARD_CASES:
        cases.append((dp.encode(word, lang), active, 0))
    for keys in ("hello,", "can't", "end.", "ok;", "ghbdtn", "nasa", "rfr", "z", "ds", "cctv", "http", "pdf", "her", "key", "vs", "tot"):
        for active in dp.LANGS:
            cases.append((keys, active, 0))
            cases.append((keys, active, 2))
    seen, out = set(), []
    for c in cases:
        if c not in seen:
            seen.add(c)
            out.append(c)
    return out


def fmt_scores(det, keys, prefix):
    cands = dp.candidates(keys)
    parts = []
    for lang in dp.LANGS:
        if lang in cands:
            m = det.data[lang].model
            v = m.prefix_logp(cands[lang]) if prefix else m.logp(cands[lang])
            parts.append(f"{lang}={v!r}")
    return ";".join(parts) or "-"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", required=True)
    args = ap.parse_args()

    lists = {}
    data = {}
    for lang in dp.LANGS:
        words = dp.load_list(os.path.join(args.data, f"{lang}_50k.txt"), lang)
        lists[lang] = words
        d = dp.LanguageData(lang, words)
        d.word_list = [w for w, _ in words]
        data[lang] = d
    det = dp.Detector(data)

    for lang in dp.LANGS:
        path = os.path.join(OUT_RES, f"model-{lang}.txt")
        n = write_model(data[lang], path)
        print(f"{path}: {n} lines, {os.path.getsize(path)} bytes")

    rows = golden_rows(det, lists)
    os.makedirs(os.path.dirname(OUT_GOLDEN), exist_ok=True)
    with open(OUT_GOLDEN, "w", encoding="utf-8", newline="\n") as f:
        f.write("# keys\tactive\tcapitals\tword\tprefix\tword_scores\tprefix_scores\n")
        for keys, active, caps in rows:
            word = det.decide_word(keys, active, caps) or "-"
            p = det.first_prefix_switch(keys, active, caps)
            prefix = f"{p[0]}:{p[1]}" if p else "-"
            f.write("\t".join([keys, active, str(caps), word, prefix,
                               fmt_scores(det, keys, False), fmt_scores(det, keys, True)]) + "\n")
    print(f"{OUT_GOLDEN}: {len(rows)} rows")


if __name__ == "__main__":
    main()

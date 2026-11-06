#!/usr/bin/env python3
"""Wrong-layout detector — reference implementation and test bench.

This file is the reference for SwitchitCore's LayoutDetector: same model, same decision rules, same
numbers. `Scripts/export_model.py` writes the model resources and a golden decision table from it,
and the Swift tests check that SwitchitCore decides exactly as this file does.

A word is a sequence of key positions; each layout turns it into a candidate string; a character
n-gram model per language scores the candidates. Two decisions:

  decide_word(keys, active, capitals)   at a word boundary (Space, Return, ...)
  decide_prefix(keys, active, capitals) after the 3rd … 6th letter, mid-word

Both return the language the user meant, or None ("leave it alone"). A result equal to `active`
also means "leave it alone"; anything else means "switch to that language's layout".

Usage (bench):
    python3 -I Scripts/detector_proto.py --data DIR
DIR holds ru_50k.txt and en_50k.txt ("word count" per line, most frequent first).
"""
import argparse
import math
import os
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
RESOURCES = os.path.join(HERE, "..", "Sources", "SwitchitCore", "Resources")

# ---- layouts: key position -> letter --------------------------------------------------------
# Key positions are written as the US character on the key. Same QWERTY order as
# Layout.qwertyRows in Swift; the ЙЦУКЕН letters on [ ] ; ' , . and ё on ` (Russian – PC).
ROWS = "qwertyuiop[]asdfghjkl;'zxcvbnm,."
RU = "йцукенгшщзхъфывапролджэячсмитьбю"
EN = "qwertyuiop..asdfghjkl..zxcvbnm.."

LAYOUTS = {
    "en": {k: c for k, c in zip(ROWS, EN) if c != "."},
    "ru": {**{k: c for k, c in zip(ROWS, RU)}, "`": "ё"},
}
ENCODERS = {lang: {c: k for k, c in table.items()} for lang, table in LAYOUTS.items()}
LANGS = ("en", "ru")


def encode(word, lang):
    """Key positions that type `word` in `lang`'s layout, or None if a character has no key."""
    enc = ENCODERS[lang]
    out = []
    for c in word:
        k = enc.get(c)
        if k is None:
            return None
        out.append(k)
    return "".join(out)


def candidates(keys):
    """{lang: text} for every layout in which every key is a letter."""
    out = {}
    for lang, table in LAYOUTS.items():
        text = []
        for k in keys:
            c = table.get(k)
            if c is None:
                break
            text.append(c)
        else:
            out[lang] = "".join(text)
    return out


# ---- character n-gram model -----------------------------------------------------------------
BOS, EOS = "^", "$"
K_SMOOTH = 0.01
WEIGHTS = (0.75, 0.2, 0.05)   # trigram, bigram, unigram


class NGramModel:
    """Interpolated trigram / bigram / unigram character model with add-k smoothing.

    Scores are average log-probabilities per character, so candidates of the same length compare
    directly and the margin is in the same units for any length.
    """

    def __init__(self, alphabet):
        self.alphabet = set(alphabet) | {EOS}
        self.tri = defaultdict(lambda: defaultdict(float))
        self.bi = defaultdict(lambda: defaultdict(float))
        self.uni = defaultdict(float)
        self.total = 0.0

    def train(self, word, weight=1.0):
        s = BOS + BOS + word + EOS
        for i in range(2, len(s)):
            self.tri[s[i - 2:i]][s[i]] += weight
            self.bi[s[i - 1]][s[i]] += weight
            self.uni[s[i]] += weight
            self.total += weight

    def _row(self, table, ctx, c):
        row = table.get(ctx)
        if row is None:
            return None
        n = sum(row.values())
        return (row.get(c, 0.0) + K_SMOOTH) / (n + K_SMOOTH * len(self.alphabet))

    def _char_logp(self, s, i):
        w3, w2, w1 = WEIGHTS
        c = s[i]
        p1 = (self.uni.get(c, 0.0) + K_SMOOTH) / (self.total + K_SMOOTH * len(self.alphabet))
        p2 = self._row(self.bi, s[i - 1], c)
        p3 = self._row(self.tri, s[i - 2:i], c)
        p2v = p2 if p2 is not None else p1
        p3v = p3 if p3 is not None else p2v
        return math.log(w1 * p1 + w2 * p2v + w3 * p3v)

    def logp(self, word):
        """Average log-prob per character of a whole word (with the end-of-word term)."""
        s = BOS + BOS + word + EOS
        return sum(self._char_logp(s, i) for i in range(2, len(s))) / (len(word) + 1)

    def prefix_logp(self, text):
        """Average log-prob per character of a word start (no end-of-word term)."""
        s = BOS + BOS + text
        return sum(self._char_logp(s, i) for i in range(2, len(s))) / len(text)


# ---- data -----------------------------------------------------------------------------------
def load_list(path, lang):
    """[(word, count)] keeping only words that the layout can type."""
    words = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            parts = line.split()
            if len(parts) != 2:
                continue
            w, n = parts[0].lower(), int(parts[1])
            if encode(w, lang) is None:
                continue
            words.append((w, n))
    return words


def load_short(lang):
    path = os.path.join(RESOURCES, f"short-{lang}.txt")
    out = set()
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                out.add(line)
    return out


def split(words):
    """Every 5th word (by rank) is held out: the model never sees it."""
    train, test = [], []
    for i, wn in enumerate(words):
        (test if i % 5 == 0 else train).append(wn)
    return train, test


PREFIX_MAX = 6


class LanguageData:
    """Everything the detector knows about one language."""

    def __init__(self, lang, words):
        self.lang = lang
        self.model = NGramModel(set(LAYOUTS[lang].values()))
        self.words = set()
        self.prefixes = defaultdict(int)
        for w, n in words:
            self.model.train(w, weight=math.log1p(n))
            self.words.add(w)
            for k in range(1, min(len(w), PREFIX_MAX) + 1):
                self.prefixes[w[:k]] += 1
        self.short = load_short(lang)


# ---- detector -------------------------------------------------------------------------------
MIN_MODEL_LEN = 4      # shorter words: short-word list only
WORD_MARGIN = 1.0
DICT_BONUS = 1.5
PREFIX_MIN = 3
PREFIX_SUPPORT = 5
PREFIX_MARGIN = 1.0


class Detector:
    def __init__(self, data):
        self.data = data   # {lang: LanguageData}

    def known(self, lang, text):
        d = self.data[lang]
        return text in (d.short if len(text) < MIN_MODEL_LEN else d.words)

    def decide_word(self, keys, active, capitals=0):
        """Language the word was meant in, or None (leave it alone)."""
        if len(keys) < 2 or capitals >= 2:
            return None
        cands = candidates(keys)
        if not cands:
            return None
        known = {lang: self.known(lang, text) for lang, text in cands.items()}
        if sum(known.values()) > 1:
            return None                                   # a real word in both languages
        if active not in cands:
            # A key is punctuation in the active layout (`hello,` `can't`): switch only to a
            # known word of the other language, never on the model alone.
            hits = [lang for lang, k in known.items() if k]
            return hits[0] if len(hits) == 1 else None
        if len(cands) == 1:
            return active                                  # the other layout cannot spell it
        if len(keys) < MIN_MODEL_LEN:
            hits = [lang for lang, k in known.items() if k]
            return hits[0] if len(hits) == 1 else None
        scores = {}
        for lang, text in cands.items():
            s = self.data[lang].model.logp(text)
            if known[lang]:
                s += DICT_BONUS
            scores[lang] = s
        ranked = sorted(scores.items(), key=lambda kv: (-kv[1], kv[0]))
        best, second = ranked[0], ranked[1]
        if best[1] - second[1] >= WORD_MARGIN:
            return best[0]
        return None

    def decide_prefix(self, keys, active, capitals=0):
        """Language to switch to after the latest letter, or None. Checked at 3rd–6th letter."""
        n = len(keys)
        if n < PREFIX_MIN or n > PREFIX_MAX or capitals >= 2:
            return None
        cands = candidates(keys)
        if active not in cands:
            return None
        a = cands[active]
        if self.data[active].prefixes.get(a, 0) > 0:
            return None                                    # still a possible start here
        for other in LANGS:
            if other == active or other not in cands:
                continue
            o = cands[other]
            if self.data[other].prefixes.get(o, 0) < PREFIX_SUPPORT:
                continue
            margin = self.data[other].model.prefix_logp(o) - self.data[active].model.prefix_logp(a)
            if margin < PREFIX_MARGIN:
                continue
            return other
        return None

    def first_prefix_switch(self, keys, active, capitals=0):
        """(k, lang) of the first mid-word switch while typing `keys` letter by letter, or None."""
        for k in range(PREFIX_MIN, min(len(keys), PREFIX_MAX) + 1):
            lang = self.decide_prefix(keys[:k], active, capitals)
            if lang is not None:
                return k, lang
        return None


def build(data_dir, held_out):
    """Detector trained on the lists; with held_out, every 5th word is kept back for testing."""
    data, tests = {}, {}
    for lang in LANGS:
        words = load_list(os.path.join(data_dir, f"{lang}_50k.txt"), lang)
        if held_out:
            train, test = split(words)
        else:
            train, test = words, []
        data[lang] = LanguageData(lang, train)
        tests[lang] = test
    return Detector(data), tests


# ---- evaluation -----------------------------------------------------------------------------
def bucket(n):
    return str(n) if n <= 6 else "7+"


def evaluate(det, tests):
    print("\n== whole word at the boundary, typed in the right layout (any switch is false) ==")
    print("lang  len   words  kept  false-switch  unsure")
    for lang, words in tests.items():
        by = defaultdict(lambda: [0, 0, 0, 0])
        worst = []
        for w, n in words:
            keys = encode(w, lang)
            got = det.decide_word(keys, active=lang)
            b = by[bucket(len(w))]
            b[0] += 1
            if got == lang:
                b[1] += 1
            elif got is None:
                b[3] += 1
            else:
                b[2] += 1
                worst.append((n, w, got, candidates(keys).get(got)))
        tot = [sum(c[i] for c in by.values()) for i in range(4)]
        for k in sorted(by, key=lambda x: (len(x), x)):
            c = by[k]
            print(f"{lang:4}  {k:3}  {c[0]:6}  {c[1]:5}  {c[2]:12}  {c[3]:6}")
        print(f"{lang:4}  all  {tot[0]:6}  {tot[1]:5}  {tot[2]:12}  {tot[3]:6}   false {100.0 * tot[2] / max(tot[0], 1):.3f} %")
        worst.sort(key=lambda t: -t[0])
        if worst:
            print("  most frequent: " + ", ".join(f"{w}→{t}" for _, w, _, t in worst[:10]))

    print("\n== whole word at the boundary, typed in the WRONG layout ==")
    for lang, words in tests.items():
        other = next(l for l in LANGS if l != lang)
        fixed = unsure = wrong = 0
        for w, n in words:
            keys = encode(w, lang)
            got = det.decide_word(keys, active=other)
            if got == lang:
                fixed += 1
            elif got is None or got == other:
                unsure += 1
            else:
                wrong += 1
        t = len(words)
        print(f"  {lang} word in {other} layout: fixed {100.0 * fixed / t:.1f} %, left alone {100.0 * unsure / t:.1f} %")

    print("\n== mid-word, letters 3–6 ==")
    for active in LANGS:
        other = next(l for l in LANGS if l != active)
        false = sum(1 for w, _ in tests[active] if det.first_prefix_switch(encode(w, active), active))
        hits = defaultdict(int)
        total = 0
        for w, _ in tests[other]:
            keys = encode(w, other)
            if len(keys) < PREFIX_MIN:
                continue
            total += 1
            r = det.first_prefix_switch(keys, active)
            hits[r[0] if r else None] += 1
        caught = sum(v for k, v in hits.items() if k is not None)
        shown = " ".join(f"k{k}:{100.0 * hits[k] / total:.1f}%" for k in range(PREFIX_MIN, PREFIX_MAX + 1))
        print(f"  {active} layout: typing {active} → false {false}/{len(tests[active])} = {100.0 * false / len(tests[active]):.2f} %;"
              f" typing {other} by mistake → caught {100.0 * caught / total:.1f} % ({shown})")


HARD_CASES = [
    # (what the user meant, language, layout active while typing, note)
    ("привет", "ru", "en", "ghbdtn"),
    ("спасибо", "ru", "en", "cgfcb,j"),
    ("менеджер", "ru", "en", "loanword, ; key"),
    ("компьютер", "ru", "en", "loanword"),
    ("hello", "en", "ru", "руддщ"),
    ("macos", "en", "ru", "ьфсщы"),
    ("hello", "en", "en", "plain English"),
    ("grep", "en", "en", "tech word"),
    ("sudo", "en", "en", "tech word"),
    ("kubectl", "en", "en", "tech word"),
    ("privet", "en", "en", "transliteration — must not be touched"),
    ("insarov", "en", "en", "surname"),
    ("вы", "ru", "en", "ds"),
    ("нет", "ru", "en", "ytn"),
    ("да", "ru", "en", "lf"),
    ("ok", "en", "en", "short English"),
    ("he", "en", "en", "short English, ру"),
    ("keys", "en", "en", "луны — word in both"),
]


def hard_cases(det):
    print("\n== hard cases (decision at the boundary) ==")
    for word, lang, active, note in HARD_CASES:
        keys = encode(word, lang)
        got = det.decide_word(keys, active)
        ok = (got == lang) or (got is None and lang == active)
        print(f"  {'ok ' if ok else 'BAD'} {keys:11} active {active} → {str(got):4} meant {lang}  {note}")
    print("\n== punctuation in the active layout ==")
    for typed in ("hello,", "can't", "end.", "ok;"):
        print(f"  {typed:8} active en → {det.decide_word(typed, 'en')}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", required=True)
    args = ap.parse_args()
    det, tests = build(args.data, held_out=True)
    for lang in LANGS:
        print(f"{lang}: {len(det.data[lang].words)} training words, {len(tests[lang])} held out, "
              f"{len(det.data[lang].short)} short words")
    evaluate(det, tests)
    hard_cases(det)


if __name__ == "__main__":
    main()

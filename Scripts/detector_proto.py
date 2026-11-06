#!/usr/bin/env python3
"""Wrong-layout detector — prototype and test bench (stage 1).

Simulates what the app will do: a word is a sequence of key codes; each enabled layout turns the
sequence into a candidate string; a character n-gram model per language scores every candidate;
the detector names the language whose candidate is far more plausible than the rest, or stays
silent. This script trains the models from frequency lists, evaluates on held-out words and
prints the numbers that decide the thresholds. The Swift port in SwitchitCore uses the same
model format and the same decision rule.

Usage:
    python3 -I Scripts/detector_proto.py --data DIR [--margin N] [--min-len N]

DIR holds ru_50k.txt and en_50k.txt ("word count" per line, most frequent first).
"""
import argparse
import math
import sys
from collections import defaultdict

# ---- layouts: key position -> letter --------------------------------------------------------
# Same QWERTY key order as Layout.qwertyRows in Swift: three letter rows left to right, with the
# four punctuation keys that carry letters in ЙЦУКЕН ([ ] ; ') and the two that carry б ю (, .).
ROWS = "qwertyuiop[]asdfghjkl;'zxcvbnm,."
RU = "йцукенгшщзхъфывапролджэячсмитьбю"
EN = "qwertyuiop..asdfghjkl..zxcvbnm.."

LAYOUTS = {
    "en": {k: c for k, c in zip(ROWS, EN) if c != "."},
    "ru": {**{k: c for k, c in zip(ROWS, RU)}, "`": "ё"},   # ё: Russian – PC position
}
# letter -> key, for turning a word from a list into the key sequence that types it
ENCODERS = {lang: {c: k for k, c in table.items()} for lang, table in LAYOUTS.items()}


def encode(word, lang):
    """Key sequence that types `word` in `lang`'s layout, or None if a character has no key."""
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


class NGramModel:
    """Interpolated trigram / bigram / unigram character model with add-k smoothing.

    Scores are per-character average log-probabilities so that candidates of the same length
    compare directly and the margin is in the same units for any word length.
    """

    def __init__(self, alphabet, k=0.01, weights=(0.75, 0.2, 0.05)):
        self.alphabet = set(alphabet) | {EOS}
        self.k = k
        self.w3, self.w2, self.w1 = weights
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

    def _p(self, table, ctx, c):
        row = table.get(ctx)
        if row is None:
            return None
        n = sum(row.values())
        return (row.get(c, 0.0) + self.k) / (n + self.k * len(self.alphabet))

    def logp(self, word):
        s = BOS + BOS + word + EOS
        total = 0.0
        v = len(self.alphabet)
        for i in range(2, len(s)):
            c = s[i]
            p1 = (self.uni.get(c, 0.0) + self.k) / (self.total + self.k * v)
            p2 = self._p(self.bi, s[i - 1], c)
            p3 = self._p(self.tri, s[i - 2:i], c)
            p = self.w1 * p1 + self.w2 * (p2 if p2 is not None else p1) + self.w3 * (p3 if p3 is not None else (p2 if p2 is not None else p1))
            total += math.log(p)
        return total / (len(word) + 1)


# ---- data -----------------------------------------------------------------------------------
def load_list(path, lang):
    """[(word, count)] keeping only words that the layout can type (letters of that alphabet)."""
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


def split(words):
    """Every 5th word (by rank) is held out: the model never sees it, so the evaluation is honest."""
    train, test = [], []
    for i, wn in enumerate(words):
        (test if i % 5 == 0 else train).append(wn)
    return train, test


# ---- detector -------------------------------------------------------------------------------
class Detector:
    def __init__(self, models, dictionaries, margin, min_len, dict_bonus):
        self.models = models
        self.dicts = dictionaries
        self.margin = margin
        self.min_len = min_len
        self.dict_bonus = dict_bonus

    def score(self, lang, text, use_dict):
        s = self.models[lang].logp(text)
        if use_dict and text in self.dicts[lang]:
            s += self.dict_bonus
        return s

    def decide(self, keys, use_dict=True):
        """Language of the word the keys spell, or None when it is not clear enough to act.

        Rule: a word shorter than `min_len` is decided only by the dictionaries — it must be a
        known word in exactly one language. A longer word is decided by the models; a candidate
        that is a known word in its language and whose rival is not gets `dict_bonus` first.
        """
        cands = candidates(keys)
        if not cands or len(keys) < 2:
            return None, {}
        known = {lang: (use_dict and text in self.dicts[lang]) for lang, text in cands.items()}
        if sum(known.values()) > 1:
            return None, {}      # a real word in more than one language: keep the current layout
        if len(keys) < self.min_len:
            hits = [lang for lang, k in known.items() if k]
            return (hits[0] if len(hits) == 1 else None), {}
        scores = {}
        for lang, text in cands.items():
            s = self.models[lang].logp(text)
            if known[lang] and not any(k for l, k in known.items() if l != lang):
                s += self.dict_bonus
            scores[lang] = s
        if len(scores) == 1:
            return next(iter(scores)), scores
        ranked = sorted(scores.items(), key=lambda kv: -kv[1])
        best, second = ranked[0], ranked[1]
        if best[1] - second[1] >= self.margin:
            return best[0], scores
        return None, scores


# ---- evaluation -----------------------------------------------------------------------------
def bucket(n):
    return str(n) if n <= 6 else "7+"


def evaluate(det, test_sets, use_dict, label):
    print(f"\n== {label} ==")
    print("lang  len   words  correct  wrong(false switch)  unsure")
    worst = []
    for lang, words in test_sets.items():
        by = defaultdict(lambda: [0, 0, 0, 0])
        for w, n in words:
            keys = encode(w, lang)
            got, scores = det.decide(keys, use_dict)
            b = by[bucket(len(w))]
            b[0] += 1
            if got == lang:
                b[1] += 1
            elif got is None:
                b[3] += 1
            else:
                b[2] += 1
                worst.append((n, lang, w, got, candidates(keys).get(got), scores))
        tot = [0, 0, 0, 0]
        for k in sorted(by, key=lambda x: (len(x), x)):
            c = by[k]
            for i in range(4):
                tot[i] += c[i]
            print(f"{lang:4}  {k:3}  {c[0]:6}  {c[1]:7}  {c[2]:19}  {c[3]:6}")
        print(f"{lang:4}  all  {tot[0]:6}  {tot[1]:7}  {tot[2]:19}  {tot[3]:6}   "
              f"false-switch rate {100.0 * tot[2] / max(tot[0], 1):.3f} %")
    worst.sort(key=lambda t: -t[0])
    if worst:
        print("most frequent false switches (count, lang, word → read as):")
        for n, lang, w, got, as_text, scores in worst[:12]:
            print(f"  {n:9} {lang} {w!r} → {got} {as_text!r}  {{{', '.join(f'{k}:{v:.2f}' for k, v in scores.items())}}}")


HARD_CASES = [
    # (intended word, its language, note) — the keys are whatever types it; the detector never
    # sees which layout was active, only the keys.
    ("привет", "ru", "typed in US as ghbdtn"),
    ("спасибо", "ru", "cgfcb,j"),
    ("hello", "en", "plain English / руддщ"),
    ("macos", "en", "ьфсщы"),
    ("grep", "en", "tech word"),
    ("sudo", "en", "tech word"),
    ("kubectl", "en", "tech word"),
    ("json", "en", "tech word"),
    ("mkdir", "en", "tech word"),
    ("chmod", "en", "tech word"),
    ("xcode", "en", "product name"),
    ("swift", "en", "product name"),
    ("privet", "en", "transliteration — must not be touched"),
    ("spasibo", "en", "transliteration"),
    ("insarov", "en", "surname"),
    ("вы", "ru", "2 letters / ds"),
    ("он", "ru", "2 letters / jy"),
    ("нет", "ru", "3 letters / ytn"),
    ("да", "ru", "2 letters / lf"),
    ("ok", "en", "2 letters / щл"),
    ("he", "en", "2 letters / ру"),
    ("менеджер", "ru", "loanword"),
    ("компьютер", "ru", "loanword"),
    ("keys", "en", "луны — real word in both"),
    ("lshtm", "en", "gibberish in both"),
]


def hard_cases(det):
    print("\n== hard cases ==")
    for word, lang, note in HARD_CASES:
        keys = encode(word, lang)
        got, scores = det.decide(keys)
        cands = candidates(keys)
        mark = "ok " if got == lang else ("—  " if got is None else "BAD")
        shown = ", ".join(f"{k}:{cands[k]!r} {scores[k]:.2f}" if k in scores else f"{k}:{cands[k]!r}" for k in cands)
        print(f"  {mark} {keys:11} expect {lang:3} got {str(got):4}  [{shown}]  {note}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", required=True)
    ap.add_argument("--margin", type=float, default=1.0, help="required gap in avg log-prob per char")
    ap.add_argument("--min-len", type=int, default=4, help="shorter words are decided by dictionary only")
    ap.add_argument("--dict-bonus", type=float, default=1.5)
    ap.add_argument("--train-top", type=int, default=50000)
    args = ap.parse_args()

    models, dicts, tests = {}, {}, {}
    for lang in ("ru", "en"):
        words = load_list(f"{args.data}/{lang}_50k.txt", lang)[: args.train_top]
        train, test = split(words)
        m = NGramModel(alphabet=set(LAYOUTS[lang].values()))
        for w, n in train:
            m.train(w, weight=math.log1p(n))
        models[lang] = m
        dicts[lang] = {w for w, _ in train}
        tests[lang] = test
        print(f"{lang}: {len(words)} usable words, {len(train)} train, {len(test)} held out")

    det = Detector(models, dicts, args.margin, args.min_len, args.dict_bonus)
    evaluate(det, tests, use_dict=False, label=f"held-out words, model only (margin {args.margin}, min-len {args.min_len})")
    evaluate(det, tests, use_dict=True, label="held-out words, model + dictionary of training words")
    hard_cases(det)


if __name__ == "__main__":
    main()

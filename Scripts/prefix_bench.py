#!/usr/bin/env python3
"""Mid-word switching bench: can the detector decide after the first k letters?

The user types in the active layout. After each letter the detector looks at the prefix typed so far
and asks: is this prefix impossible as the start of a word in the active layout's language, and
plausible as the start of a word in the other language? If so it switches mid-word.

Measured on held-out words (never seen in training), separately for:
  - correct typing (word of language A typed in layout A): any switch is a FALSE switch;
  - wrong-layout typing (word of language B typed in layout A): a switch at k is a HIT at k.

Rule "prefix": switch at the first k >= min_k where the active-language text is not the start of
any training word of that language and the other-language text is the start of at least `support`
training words. A model margin on the prefix can be required as well.

Usage: python3 -I Scripts/prefix_bench.py --data DIR
"""
import argparse
import math
import os
import sys
from collections import defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import detector_proto as dp  # noqa: E402


def prefix_counts(words, max_k):
    counts = defaultdict(int)
    for w, _ in words:
        for k in range(1, min(len(w), max_k) + 1):
            counts[w[:k]] += 1
    return counts


def prefix_logp(model, text):
    """Average log-prob per character of a word start (no end-of-word term)."""
    s = dp.BOS + dp.BOS + text
    total = 0.0
    v = len(model.alphabet)
    for i in range(2, len(s)):
        c = s[i]
        p1 = (model.uni.get(c, 0.0) + model.k) / (model.total + model.k * v)
        p2 = model._p(model.bi, s[i - 1], c)
        p3 = model._p(model.tri, s[i - 2:i], c)
        p = model.w1 * p1 + model.w2 * (p2 if p2 is not None else p1) + model.w3 * (p3 if p3 is not None else (p2 if p2 is not None else p1))
        total += math.log(p)
    return total / len(text)


def first_switch(keys, active, other, prefixes, models, min_k, max_k, support, margin):
    """k at which the rule switches from `active` to `other`, or None."""
    for k in range(min_k, min(len(keys), max_k) + 1):
        c = dp.candidates(keys[:k])
        if active not in c or other not in c:
            return None
        a, o = c[active], c[other]
        if prefixes[active].get(a, 0) > 0:
            continue                      # still a possible start in the active language
        if prefixes[other].get(o, 0) < support:
            continue
        if margin is not None and prefix_logp(models[other], o) - prefix_logp(models[active], a) < margin:
            continue
        return k
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", required=True)
    ap.add_argument("--max-k", type=int, default=6)
    args = ap.parse_args()

    langs = ("ru", "en")
    models, prefixes, tests = {}, {}, {}
    for lang in langs:
        words = dp.load_list(f"{args.data}/{lang}_50k.txt", lang)
        train, test = dp.split(words)
        m = dp.NGramModel(alphabet=set(dp.LAYOUTS[lang].values()))
        for w, n in train:
            m.train(w, weight=math.log1p(n))
        models[lang] = m
        prefixes[lang] = prefix_counts(train, args.max_k)
        tests[lang] = test

    configs = [
        ("min_k=3 support=1", 3, 1, None),
        ("min_k=3 support=5", 3, 5, None),
        ("min_k=3 support=5 margin=1", 3, 5, 1.0),
        ("min_k=4 support=5", 4, 5, None),
    ]
    for label, min_k, support, margin in configs:
        print(f"\n== {label} ==")
        for active, other in (("en", "ru"), ("ru", "en")):
            false = 0
            false_examples = []
            for w, n in tests[active]:
                keys = dp.encode(w, active)
                k = first_switch(keys, active, other, prefixes, models, min_k, args.max_k, support, margin)
                if k is not None:
                    false += 1
                    false_examples.append((n, w, k, dp.candidates(keys[:k])[other]))
            hits = defaultdict(int)
            total = 0
            for w, n in tests[other]:
                keys = dp.encode(w, other)
                if len(keys) < min_k:
                    continue
                total += 1
                k = first_switch(keys, active, other, prefixes, models, min_k, args.max_k, support, margin)
                hits[k] += 1
            nf = len(tests[active])
            shown = " ".join(f"k{k}:{100.0 * hits[k] / total:.1f}%" for k in range(min_k, args.max_k + 1))
            never = 100.0 * hits[None] / total
            print(f"  layout {active}: typing {active} correctly → false mid-word switch {false}/{nf} = {100.0 * false / nf:.2f} %")
            print(f"  layout {active}: typing {other} by mistake → switched at {shown}, not mid-word {never:.1f}%")
            false_examples.sort(key=lambda t: -t[0])
            if false_examples:
                print("    most frequent false switches: " + ", ".join(f"{w}→{t}@{k}" for _, w, k, t in false_examples[:8]))


if __name__ == "__main__":
    main()

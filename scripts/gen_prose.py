#!/usr/bin/env python3
"""Deterministic pseudo-prose for the tests: scripts/gen_prose.py BYTES > out

Words drawn from a Zipf-like vocabulary, sentences capitalised, some words in
capitals, CRLF-free. Not repetitive, so the BWT cannot fold it away and the
text transform is chosen, which puts its decoder on the tested path in CI
(the CI machines have no real corpus).
"""
import random
import sys

SYLLABLES = ["al", "be", "con", "de", "en", "for", "ga", "hi", "in", "jo", "ka",
             "le", "man", "ne", "or", "pa", "qui", "ra", "sto", "the", "un",
             "ver", "wa", "xen", "yo", "zu", "ing", "tion", "ed", "er"]


def main():
    size = int(sys.argv[1])
    rng = random.Random(20261024)
    vocab = sorted({"".join(rng.choice(SYLLABLES) for _ in range(rng.randint(1, 4)))
                    for _ in range(6000)})
    rng.shuffle(vocab)
    weights = [1.0 / (i + 1) for i in range(len(vocab))]
    out, n, start = [], 0, True
    while n < size:
        w = rng.choices(vocab, weights)[0]
        if start:
            w = w.capitalize()
            start = False
        elif rng.random() < 0.01:
            w = w.upper()
        r = rng.random()
        sep = ". " if r < 0.07 else (", " if r < 0.12 else (".\n\n" if r < 0.075 else " "))
        if sep.startswith("."):
            start = True
        out.append(w + sep)
        n += len(w) + len(sep)
    sys.stdout.write("".join(out)[:size])


if __name__ == "__main__":
    main()

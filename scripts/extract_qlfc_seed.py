#!/usr/bin/env python3
"""Extract QLFC payloads from tovyCT streams as fuzzer seeds.

Usage: scripts/extract_qlfc_seed.py stream.tvct outdir/ [prefix]

One file per BWT block, named PREFIX-NN.bin (prefix defaults to "payload").
The QLFC decoder fuzzer takes these directly: they are real, well-formed
arithmetic streams, which random bytes almost never are.
"""
import os
import sys

SAMPLE_RATE = 4096


def varint(blob, off):
    value, shift = 0, 0
    while True:
        b = blob[off]
        off += 1
        value |= (b & 0x7F) << shift
        if not b & 0x80:
            return value, off
        shift += 7


def parse(blob):
    """Yields (method, payload) for every block of a v4 stream."""
    if blob[:4] != b"TVCT" or blob[4] != 4:
        raise SystemExit("not a tovyCT v4 stream")
    off = 7
    if blob[6] & 1:
        _, off = varint(blob, off)
    while off < len(blob):
        orig, off = varint(blob, off)
        method = blob[off]
        off += 1
        body, off = varint(blob, off)
        if method == 0:
            off += 4 + body
            continue
        off += 8
        end = off + body
        pos = off
        bwt = orig
        if method & 8:
            bwt, pos = varint(blob, pos)
        _, pos = varint(blob, pos)                      # primary
        if method & 4:
            pos += 4 * ((bwt + SAMPLE_RATE - 1) // SAMPLE_RATE)
        yield method, blob[pos:end]
        off = end


def main():
    if len(sys.argv) < 3 or len(sys.argv) > 4:
        sys.exit(__doc__)
    blob = open(sys.argv[1], "rb").read()
    outdir = sys.argv[2]
    prefix = sys.argv[3] if len(sys.argv) == 4 else "payload"
    os.makedirs(outdir, exist_ok=True)
    count = 0
    for _, payload in parse(blob):
        if not payload:
            continue
        path = os.path.join(outdir, "%s-%02d.bin" % (prefix, count))
        open(path, "wb").write(payload)
        count += 1
    print("%d payloads from %s" % (count, sys.argv[1]))


if __name__ == "__main__":
    main()

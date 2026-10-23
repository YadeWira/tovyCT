#!/usr/bin/env python3
"""Extract QLFC payloads from tovyCT streams as fuzzer seeds.

Usage: scripts/extract_qlfc_seed.py stream.tvct outdir/

One file per BWT block, named payload-NN.bin. The QLFC decoder fuzzer takes
these directly: they are real, well-formed arithmetic streams, which random
bytes almost never are.
"""
import os
import struct
import sys


def parse(blob):
    off = 16                                  # stream header (v3)
    while off + 20 <= len(blob):
        orig, payload, method = struct.unpack_from("<III", blob, off)
        if method == 0:
            body = off + 20
            yield None, blob[body:body + payload]
            off = body + payload
        elif method == 1:
            nsamples = struct.unpack_from("<I", blob, off + 32)[0]
            body = off + 20 + 16 + nsamples * 4
            yield orig, blob[body:body + payload]
            off = body + payload
        else:
            return


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    blob = open(sys.argv[1], "rb").read()
    outdir = sys.argv[2]
    os.makedirs(outdir, exist_ok=True)
    count = 0
    for orig, payload in parse(blob):
        if orig is None or not payload:
            continue
        path = os.path.join(outdir, "payload-%02d.bin" % count)
        open(path, "wb").write(payload)
        count += 1
    print("%d payloads from %s" % (count, sys.argv[1]))


if __name__ == "__main__":
    main()

# tovyCT

A fast text compressor with a good ratio, written in Free Pascal with hand-tuned
assembly kernels for the hot paths.

**Status: work in progress.** No codec code exists yet. The design was chosen by
measurement; see [`docs/DESIGN.md`](docs/DESIGN.md) for the numbers and for the
first design that was dropped.

## What it is meant to be

On text, block-sorting compressors are 20 to 30 % smaller than the best LZ ones at
comparable speed: on a public 85 MB text corpus, `bzip3` produces 16.9 % against
`xz -6`'s 20.2 % and `zstd -12`'s 22.8 %. What block sorting lacks is speed: on the
same machine `bzip3` compresses at 7 MB/s and decompresses at 9 MB/s.

tovyCT is that pipeline — LZP, BWT, MTF/RLE and rANS — rewritten to be fast, in
Pascal, with assembly for the decode side. The target is the ratio of `bzip3` at
several times its compression speed and an order of magnitude its decompression
speed.

Supported targets:

| OS | Architectures |
|---|---|
| Linux | x86, x86-64, ARMv7, AArch64 |
| Windows (7 and later) | x86, x86-64 |
| macOS | AArch64 |

## Planned interface

```
tvct c [file] [-o out] [-0..-9]    compress
tvct d [file] [-o out]             decompress
tvct t [file ...]                  verify
tvct i [file]                      show header, blocks and sizes
tvct b [file ...]                  benchmark
```

A C header (`include/tvct.h`) and a set of Pascal units will expose the same
codec to third-party programs.

## Building

Requirements: Free Pascal 3.2.2 (the current stable release) and, optionally, a C
compiler for the libsais accelerator.

```sh
scripts/build.sh              # pure Pascal suffix array
scripts/build.sh --libsais    # vendor libsais as an optional accelerator
./build/tests/test_sais
./build/tests/test_bwt corpora/text.bin
```

The archive format does not depend on which build is used: the BWT is computed
in Pascal from the suffix array, and both suffix array backends produce the same
array.

## Status

| piece | state |
|---|---|
| measurement model and design | done (`docs/DESIGN.md`) |
| suffix array, SA-IS in Pascal | done, tested |
| optional libsais accelerator | done, tested against the Pascal backend |
| BWT forward and inverse | done, round-trip tested |
| LZP, MTF/RLE, rANS, format, CLI | done, end to end |

First end-to-end numbers on the 85 MB text corpus, 16 MB blocks, one thread:

| | ratio | compress | decompress |
|---|---|---|---|
| **tovyCT** | **20.36 %** | **11.9 MB/s** | **9.9 MB/s** |
| bzip3 | 16.90 % | 7 MB/s | 9 MB/s |
| xz -6 | 20.19 % | 6 MB/s | ~80 MB/s |
| bzip2 -9 | 20.78 % | 11 MB/s | 35 MB/s |
| zstd -19 | 20.18 % | 4 MB/s | 1087 MB/s |

The ratio already beats xz, zstd -19, bzip2 and brotli -9 on this corpus;
bzip3 is 17 % smaller because it codes with a context-mixing arithmetic coder
instead of MTF + order-0/3-context rANS. Decompression is the open problem:
the inverse BWT is a serial chain of random reads, and the MTF/RLE decode is
scalar, so the next phase moves both to C and assembly.

## Licence

MIT. See [`LICENSE`](LICENSE).

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

## Licence

MIT. See [`LICENSE`](LICENSE).

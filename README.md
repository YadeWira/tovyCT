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

| OS | Architectures | State |
|---|---|---|
| Linux | x86-64 | built and tested on the host |
| Linux | AArch64 | built and tested natively in a Debian 13 VM; output is byte-identical to x86-64 |
| Windows (7 and later) | x86-64 | built, tested in a Windows 10 VM (compress, verify, decompress, byte comparison) |
| Windows (7 and later) | x86 | built, tested in a Windows 7 VM |
| macOS | AArch64 | built and tested in GitHub Actions |

Windows builds need the Free Pascal cross compiler and mingw-w64, which the
hosted runners do not carry; they are built here and validated in Windows 7 and
Windows 10 virtual machines instead.

## CI

`.github/workflows/ci.yml` builds and tests Linux x86-64, Linux AArch64 and
macOS AArch64, then compares the SHA-256 of a compressed sample across the
three jobs: the compressed output is byte-identical on every architecture. The
three unit-test programs, the C API test and a full stream round-trip run in
each job.

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

## C API

`scripts/build.sh` produces `build/libtvct.so` and `build/tvct.h`:

```c
size_t  tvct_compress_bound(size_t src_size);
int64_t tvct_get_size(const void *src, size_t src_size);
int64_t tvct_compress(const void *src, size_t src_size,
                      void *dst, size_t dst_cap, int threads, int block_log);
int64_t tvct_decompress(const void *src, size_t src_size,
                        void *dst, size_t dst_cap, int threads);
const char *tvct_version(void);
```

`threads <= 0` picks one worker per CPU up to 8, `block_log <= 0` uses 23
(8 MiB blocks). Buffers are used in place: no copy of the payload is made.
Every call returns -1 on a corrupt stream or a destination that is too small.

## Building

Requirements: Free Pascal 3.2.2 (the current stable release) and, optionally, a C
compiler for the libsais accelerator.

```sh
scripts/build.sh --libsais    # recommended: libsais for the suffix array
scripts/build.sh --portable   # generic code generation instead of -march=native
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

Single mode, on the 85 MB text corpus. Blocks are independent, so `-T` emits
byte-identical output with the blocks compressed in parallel:

| | ratio | compress | decompress |
|---|---|---|---|
| **tovyCT, default (8 threads)** | **17.46 %** | **62.0 MB/s** | **71.9 MB/s** |
| tovyCT, one thread (`-T 1`) | 17.46 % | 16.4 MB/s | 30.4 MB/s |
| **tovyCT, `-T 8`** | **17.46 %** | **62.0 MB/s** | **71.9 MB/s** |
| **tovyCT, `-T 16`** | **17.46 %** | **72.4 MB/s** | **97.3 MB/s** |
| bsc 3.3.12, one thread | 17.33 % | 17.5 MB/s | 29.5 MB/s |
| bzip3 | 16.90 % | 7 MB/s | 9 MB/s |
| xz -6 | 20.19 % | 6 MB/s | ~80 MB/s |
| bzip2 -9 | 20.78 % | 11 MB/s | 35 MB/s |
| zstd -19 | 20.18 % | 4 MB/s | 1087 MB/s |

The ratio already beats xz, zstd -19, bzip2 and brotli -9 on this corpus;
bzip3 is 17 % smaller because it codes with a context-mixing arithmetic coder
instead of MTF + order-0/3-context rANS. Decoding runs in C kernels: the encoder stores the LF-chain row of every
4096-byte output chunk (taken from the inverse suffix array, about 0.1 % of the
block), so the decoder walks eight independent chains instead of one serial one.
That took decompression from 9.5 to 42.4 MB/s on the same corpus. Smaller blocks
trade a little ratio for more speed: 4 MB blocks give 20.77 % at 50 MB/s, 2 MB
blocks 21.25 % at 52 MB/s.

## Decoder safety

Each block carries a CRC-32C of its compressed payload, checked before anything
is decoded, and the decoder validates the BWT primary index and every sample row
against the block size before touching a buffer.

The entropy coder itself (QLFC from libbsc) does not validate the size it decodes
against the caller's buffer: a *crafted* stream with a valid payload CRC can make
it read a wild pointer. The bundled fuzzer (`.github/fuzz.sh`) demonstrates it.
Corruption is caught (the CRC), fabrication is not; decoding archives from
untrusted sources is therefore not safe yet. The fix on the table is to run the
entropy step inside a guard-page sandbox and turn a fault into an error.

## Licence

MIT. See [`LICENSE`](LICENSE).

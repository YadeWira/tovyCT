# tovyCT

A fast text compressor with a good ratio, written in Free Pascal and C, with
vectorised C kernels for the hot paths.

| Component | Status |
|---|---|
| CI | [![CI][ciBadge]][ciLink] |
| Latest release | [![Release][relBadge]][relLink] |
| Format | v4, stable (frozen at 1.0) |
| CLI and C API | working |
| Text transform and BLAKE3 digest | working |
| Decoder | hardened and fuzzed |
| Documentation | [`FORMAT.md`](docs/FORMAT.md), [`DESIGN.md`](docs/DESIGN.md) |

**Status: 1.0, format frozen.** Format v4 no longer changes: streams written by
any 1.0 build decode with any other, and a future change that needs new syntax
becomes v5. A small CLI, a C API, round-trip and hardening tests, coverage
fuzzing, and CI on Linux x86-64, Linux AArch64, Linux x86 (32-bit), macOS
AArch64, Windows x86-64 and Windows x86. The format is specified in
[`docs/FORMAT.md`](docs/FORMAT.md); the measurements and the designs that were
dropped are in [`docs/DESIGN.md`](docs/DESIGN.md).

## What it is meant to be

On text, block-sorting compressors are 20 to 30 % smaller than the best LZ ones at
comparable speed: on a public 85 MB text corpus, `bzip3` produces 16.9 % against
`xz -6`'s 20.2 % and `zstd -12`'s 22.8 %. What block sorting lacks is speed: on the
same machine `bzip3` compresses at 7 MB/s and decompresses at 9 MB/s.

tovyCT is that pipeline — BWT followed by QLFC, libbsc's entropy coder —
rewritten to be fast, in Pascal and C, with C kernels for the decode side, and a
text transform in front of the BWT that folds capitals and replaces frequent
words by short codes. On the same corpus it reaches 17.35 % by default, at eight
times bzip3's compression speed and eight times its decompression speed, and
16.84 % in its ratio mode, smaller than bzip3's 16.90 %.

Supported targets:

| OS | Architectures | State |
|---|---|---|
| Linux | x86-64 | built and tested on the host |
| Linux | AArch64 | built and tested in CI; output is byte-identical to x86-64 |
| Linux | x86 (32-bit) | built and tested in CI; output is byte-identical to x86-64 |
| Windows (7 and later) | x86-64 | built and tested in CI on a Windows runner; also validated in a Windows 10 VM |
| Windows (7 and later) | x86 | built and tested in CI on a Windows runner; also validated in a Windows 7 VM |
| macOS | AArch64 | built and tested in GitHub Actions |

Both Windows targets are built natively in CI with the official Free Pascal
installer and MSYS2's mingw-w64 (mingw64 and mingw32). The 32-bit binary is
also validated in a Windows 7 virtual machine.

## CI

`.github/workflows/ci.yml` builds and tests Linux x86-64, Linux AArch64,
Linux x86, macOS AArch64, Windows x86-64 and Windows x86, then compares the
SHA-256 of a compressed sample across the six jobs: the compressed output is
byte-identical on every architecture. The unit tests, the C API tests, the text transform test, the
BLAKE3 known-answer test and full stream round-trips run in each job; a
generated prose sample makes sure the text transform is on the tested path.

## CLI

```
tvct c <input> [output] [-l fast|compact|max] [-b MB] [-T N] [-a] [-s]
                        [-x off|auto|best] [-H]
tvct d <input> [output] [-T N]           decompress
tvct t <input>                           verify the CRCs without writing output
tvct i <input>                           show the header and the original size
tvct --version                           print the version (also tvct_version())
```

Decoding runs under a guard-page sandbox by default (see
[Decoder safety](#decoder-safety)); `--no-guard` turns it off.

Output defaults to `<input>.tvct` when compressing and the name without that
suffix when decompressing. `-T 1` forces the sequential path; by default it uses
one worker per CPU, capped at 8. The compressed bytes do not depend on `-T`.

`scripts/build.sh --checked` compiles the Pascal side with range and overflow
checks (and `-O1`); the CI suite runs once with them.

`-l` picks a preset: `fast` (default; static, 8 MiB blocks, sample rows),
`compact` (static, 16 MiB) or `max` (adaptive, no sample rows, 16 MiB, or 32 MiB
when the input fits in one block). The individual flags below override it.

- `-a` selects the adaptive QLFC coder (about 1-2 % smaller, slower).
- `-s` omits the sample rows (another ~0.1 % smaller and faster to compress, but
  the inverse BWT is serial, so decoding is slower).
- `-x` controls the text transform. `auto`, the default, uses it on a block when
  it removes at least a tenth of the block, and below 1 MiB only when the
  compressed block also comes out smaller. `off` never uses it; `best`
  compresses every block both ways and keeps the smaller (twice the time, and
  on the corpora measured it found nothing `auto` missed).
- `-H` ends the stream with a BLAKE3-128 digest of the whole input, checked when
  decompressing. Without it each block is still covered by a CRC-32C seeded with
  its index, so a corrupt, reordered or missing block is caught either way; the
  digest adds cryptographic strength for archiving at about 350 MB/s.

Medians of three runs on the 85 MB corpus, with the host otherwise idle:

| preset | ratio | compress T1 / T8 | decompress T1 / T8 |
|---|---|---|---|
| `fast` (default) | 17.35 % | 16.9 / 57.2 MB/s | 31.5 / 74.1 MB/s |
| `compact` | 17.10 % | 14.0 / 50.5 MB/s | 26.0 / 68.8 MB/s |
| `max` | 16.84 % | 9.9 / 37.3 MB/s | 10.4 / 30.7 MB/s |

Against format v3, which had no text transform, every preset is 0.11 points
smaller at the same compression speed, and decoding is faster: the transformed
block is shorter, so the inverse BWT has less to walk. There is no free middle
between `compact` and `max`: `-a` with samples costs about a third of the speed
for 0.15-0.25 points. The default stays at 8 MiB: it is the fastest and scales
better on medium files, where 16 MiB leaves only two blocks.

## Text transform

Before the BWT, a block can be rewritten (`src/c/tvct_text.c`, layout in
[`docs/FORMAT.md`](docs/FORMAT.md)): `The` becomes a CAP flag and `the`, `THE`
an UPPER flag and `the`, and the words that pay for their entry are replaced by
one- or two-byte codes taken from bytes the block does not use (or, when too
few are free, from the rarest ones, escaped). The dictionary travels inside the
BWT input, so it is compressed with the rest.

The transform is ASCII-only: it folds `A-Z` and builds its dictionary from
ASCII words. Measured on Project Gutenberg UTF-8 texts with `-l fast`, `auto`
against `off`: Spanish −0.94 %, French −1.0 %, German −0.4 to −0.75 %, Italian
−0.08 %, Portuguese −1.0 %, Russian −1.3 to −1.4 %. Chinese and Japanese blocks
skip it (0 %); it never made a measured file larger. Extending the dictionary to
Unicode words is possible but the measured headroom is under a point on the
languages tested.

| input (`-l fast`) | without | with | |
|---|---|---|---|
| dickens (English prose, 10 MB) | 2,335,846 | 2,299,795 | -1.5 % |
| samba (source code tar, 22 MB) | 4,051,328 | 4,036,805 | -0.4 % |
| 85 MB text corpus | 14,879,126 | 14,784,252 | -0.6 % |
| 111 text and document files, 24 MB | 7,168,568 | 7,166,509 | -0.03 %, no file larger |

The rule that decides it was measured, not guessed: on 35 large files from a
format-samples corpus the transform lost up to 0.5 % on every block where it
removed less than 6 % of the bytes, and won on every block where it removed more
than 13 %; the threshold sits at 10 %. It
encodes at about 95 MB/s and decodes at about 390 MB/s; the encoder computes the
exact output size before writing it, so a block that will not qualify costs only
the counting pass.

## C API

`scripts/build.sh` produces `build/libtvct.so` and `build/tvct.h`:

```c
size_t  tvct_compress_bound(size_t src_size);
int64_t tvct_get_size(const void *src, size_t src_size);
int64_t tvct_compress(const void *src, size_t src_size,
                      void *dst, size_t dst_cap, int threads, int block_log);
int64_t tvct_compress_ex(const void *src, size_t src_size, void *dst,
                         size_t dst_cap, int threads, int block_log,
                         int coder, int no_samples);
int64_t tvct_compress2(const void *src, size_t src_size, void *dst,
                       size_t dst_cap, int threads, int block_log,
                       int coder, int no_samples, int text, int digest);
int64_t tvct_decompress(const void *src, size_t src_size,
                        void *dst, size_t dst_cap, int threads);
const char *tvct_version(void);
```

`threads <= 0` picks one worker per CPU up to 8, `block_log <= 0` uses 23
(8 MiB blocks). Buffers are used in place: no copy of the payload is made.
Every call returns -1 on a corrupt stream or a destination that is too small.

## Building

Requirements: Free Pascal 3.2.2 (the current stable release) and a C compiler
(the text transform, the decode kernels and the libbsc coder are C/C++).

```sh
scripts/build.sh --libsais    # recommended: libsais for the suffix array
scripts/build.sh --portable   # generic code generation instead of -march=native
scripts/fpc-i386.sh /tmp/fpc-i386
FPC_I386=/tmp/fpc-i386/fpc scripts/build.sh --libsais --target linux-x86
sh .github/test.sh            # the CI test suite
sh .github/fuzz.sh 120 8      # the fuzzers, 120 s each on 8 workers
```

The stream format does not depend on which build is used: both suffix array
backends produce the same array, and the format is specified in
[`docs/FORMAT.md`](docs/FORMAT.md).

## Comparison

On the 85 MB text corpus, one thread unless noted:

| | ratio | compress | decompress |
|---|---|---|---|
| **tovyCT `fast`, 8 threads** | **17.35 %** | **57.2 MB/s** | **74.1 MB/s** |
| tovyCT `fast` | 17.35 % | 16.9 MB/s | 31.5 MB/s |
| tovyCT `max`, 8 threads | 16.84 % | 37.3 MB/s | 30.7 MB/s |
| tovyCT `max` | 16.84 % | 9.9 MB/s | 10.4 MB/s |
| libbsc 3.4.0 (reference CLI, 8 MB blocks) | 17.33 % | 20 MB/s | 29.5 MB/s |
| bzip3 | 16.90 % | 7 MB/s | 9 MB/s |
| xz -6 | 20.19 % | 6 MB/s | ~80 MB/s |
| bzip2 -9 | 20.78 % | 11 MB/s | 35 MB/s |
| zstd -19 | 20.18 % | 4 MB/s | 1087 MB/s |

The libbsc row is the 3.4.0 CLI with its default LZP preprocessing, on the same
corpus and block size. At 16 MB blocks it produces 17.06 % (static coder) and
16.90 % (adaptive); tovyCT produces 17.10 % with `compact` — which also carries
the text transform and the container — and 16.84 % with `max`, 0.06 points
smaller than bsc's adaptive coder. With preprocessing disabled (`-p`) bsc is
17.36 % and 16.95 %, behind tovyCT at both sizes.

The remaining gap at 8 and 16 MB is bsc's LZP stage, measured at 0.03-0.05
points on this corpus. It is not wired in on purpose: a preprocessing stage
would add a second format layer and its own decoder to guard, for less than the
text transform already gives (0.11 points on English prose, up to 1.5 on
caps-heavy prose). Block size is the stronger knob: `max -b 64` reaches
16.67 % for about twice the time.

Decoding runs in C kernels: the encoder stores the LF-chain row of every
4096-byte output chunk (taken from the inverse suffix array, about 0.1 % of the
block), so the decoder walks eight independent chains instead of one serial one.
That took decompression from 9.5 to 42 MB/s when it was introduced.

Small files pay little for the container: the headers are varints, so a
100-byte file becomes 115 bytes and an empty one 8.

## Decoder safety

Each compressed block carries a CRC-32C of its whole body, checked before
anything is decoded, and a CRC-32C of its original bytes seeded with the block's
index, checked after: a corrupt, swapped or duplicated block fails. The decoder
validates the stream header, every varint, the method byte, the BWT size, the
primary index and every sample row against the sizes it was given. A declared
total size is also checked for plausibility before any buffer is allocated:
real data does not compress better than about 1000:1 (16 MiB of zeros is
997:1), so anything above 4096:1 plus 1 MiB is treated as corruption. A
fabricated header cannot ask for a gigabyte.

The text transform's decoder checks every count, code and word against the
dictionary it read and the exact output size it was given, and fails on
anything the format does not allow.

The entropy coder takes the same treatment. Fuzzing the QLFC decoder with
coverage found seven problems, all fixed in the vendored source and marked with
comments:

1. a run write past the output buffer;
2. an input read past the compressed block;
3. a decoded MTF rank of 691 indexing the 256-entry stack table;
4. a block table read past a 15-byte payload;
5. an unbounded run width indexing the 32-entry run model (it showed up as a
   use-after-free when the index landed in a freed chunk);
6. an `i + runSize` check that overflows for a hostile run length and lets a
   2 GB write pass;
7. a block table declaring zero output, which switched the coder's bound off
   because zero meant "no limit".

It also removes the undefined behaviours UBSan and Valgrind flagged:
`__builtin_clz(0)` when a one-character alphabet is ranked, 16-bit loads through
a misaligned `unsigned short *` (the input is now read as bytes with `memcpy`),
and uninitialised MTF-table entries that a hostile rank could pull into the
alphabet (the table is cleared before decoding, so even garbage output is
deterministic). The coder takes an explicit output limit and input end, checks
every run and every rank, and has a bounded entry point
(`bsc_coder_decompress_bounded`) that validates its own block table. The output
limit and the end of the input are parameters of the decode call, so parallel
blocks share no state; a thread-local copy was the first attempt, but it did not
survive the Windows static-library link and made two-block decodes fail there.

On top of the checks, the decode path runs in a sandbox. Every buffer it writes
to — the QLFC output, the transformed block, the final block — and the copy of
the compressed payload it reads from end exactly at a page mapped `PROT_NONE`,
so a read or write one byte past either buffer faults at that byte instead of
touching the next allocation. `tvct_guard_run()` catches the fault and returns a
decode error, so a hostile stream costs a failed block, not the process. It is
per thread (parallel blocks are sandboxed independently), it restores the
previous handler when a fault is not ours, and it costs 2-4 % of decode speed
(46-49 MB/s against 48-49 on the 85 MB corpus, within run-to-run noise). The
command line enables it because it owns the process; a library leaves the choice
to its host and `tvct_set_guard(1)` is the opt-in. Windows has no implementation
— the allocations stay plain there — and `tvct --guard-check` reports that.
`--guard-check` writes one byte past a guarded buffer and succeeds only when the
fault is caught, which is how CI tests the mechanism on every run.

The evidence is measurement, not proof:

- `tests/fuzz_qlfc.c` fuzzes the static and the adaptive coder, and
  `tests/fuzz_text.c` the text transform (hostile transformed blocks, and
  encode-decode round trips of arbitrary data), all with coverage,
  AddressSanitizer and UBSan. These are the targets where libFuzzer sees the
  code it mutates, because the Pascal side cannot be instrumented. The seeds
  are regenerated from real streams on every run, plus the inputs that found
  the bugs above.
- `tests/test_text.c` round-trips real files through the transform and mutates
  the transformed blocks; run under the sanitizers it found nothing.
- `tests/test_payload.c` keeps the container valid, flips bits in a real block
  body, recomputes its CRC and checks that the API returns an error or exactly
  the original file (1,500 mutations per run, in CI, on a source sample and on
  a prose sample that goes through the text transform).
- `tests/test_truncate.c` walks every prefix, appends bytes and flips bits.
- `tests/test_hostile.c` feeds fabricated streams: absurd totals, blocks larger
  than the stream, undefined method bytes, out-of-range BWT sizes and primary
  indexes, swapped blocks, and a tampered or truncated digest.

An earlier round of "80 million executions" turned out to be worthless: the seed
corpus was from an older format, which the decoder rejects at the version byte,
and the shared library was not instrumented, so the coverage counter only saw
the harness. Both are fixed; the corpus is regenerated on every run.

## Licence

MIT. See [`LICENSE`](LICENSE). Vendored: libsais and libbsc (Apache-2.0),
pjablake3 (MIT).

[ciBadge]: https://github.com/YadeWira/tovyCT/actions/workflows/ci.yml/badge.svg "Continuous Integration"
[ciLink]: https://github.com/YadeWira/tovyCT/actions/workflows/ci.yml
[relBadge]: https://img.shields.io/github/v/release/YadeWira/tovyCT "Latest release"
[relLink]: https://github.com/YadeWira/tovyCT/releases/latest

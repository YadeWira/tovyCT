# tovyCT

A fast text compressor with a good ratio, written in Free Pascal and C, with
vectorised C kernels for the hot paths.

**Status: working.** Format v3, a small CLI, a C API, round-trip and hardening
tests, and CI on Linux x86-64, Linux AArch64 and macOS AArch64 (plus Windows
x86/x64 builds validated in virtual machines). The format is specified in
[`docs/FORMAT.md`](docs/FORMAT.md); the measurements and the design that was
dropped are in [`docs/DESIGN.md`](docs/DESIGN.md).

## What it is meant to be

On text, block-sorting compressors are 20 to 30 % smaller than the best LZ ones at
comparable speed: on a public 85 MB text corpus, `bzip3` produces 16.9 % against
`xz -6`'s 20.2 % and `zstd -12`'s 22.8 %. What block sorting lacks is speed: on the
same machine `bzip3` compresses at 7 MB/s and decompresses at 9 MB/s.

tovyCT is that pipeline — BWT followed by QLFC, libbsc's entropy coder —
rewritten to be fast, in Pascal and C, with C kernels for the decode side. On the
same corpus it reaches 17.46 % against bzip3's 16.90 %, at eight times bzip3's
compression speed and eight times its decompression speed.

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

## CLI

```
tvct c <input> [output] [-b MB] [-T N] [-a] [-s]   compress (default 8 MiB blocks)
tvct d <input> [output] [-T N]           decompress
tvct t <input>                           verify the CRCs without writing output
tvct i <input>                           show the header and the original size
```

Output defaults to `<input>.tvct` when compressing and the name without that
suffix when decompressing. `-T 1` forces the sequential path; by default it uses
one worker per CPU, capped at 8. The compressed bytes do not depend on `-T`.

`-a` selects the adaptive QLFC coder (about 1-2 % smaller, slower) and `-s`
omits the sample rows (another ~0.1 % smaller and faster to compress, but the
inverse BWT is serial, so decoding is slower). Both are off by default.

Medians of three runs on the 85 MB corpus, with the host otherwise idle:

| mode | ratio | compress T1 / T8 | decompress T1 / T8 |
|---|---|---|---|
| static, 8 MiB (default) | 17.46 % | 17.0 / 58.2 MB/s | 29.0 / 69.3 MB/s |
| static, 16 MiB | 17.21 % | 15.6 / 48.6 MB/s | 26.6 / 66.8 MB/s |
| adaptive, no samples, 16 MiB | 16.95 % | 11.4 / 37.8 MB/s | 10.9 / 29.0 MB/s |
| adaptive, no samples, 32 MiB | 16.93 % | 10.7 / 21.0 MB/s | 9.4 / 17.3 MB/s |

There is no free middle: `-a` with samples costs about a third of the speed for
0.15-0.25 points, so it is dominated. The last 0.02 points of 32 MiB blocks over
16 MiB cost more than half the threaded speed (three blocks instead of six), so
16 MiB is the sane ratio mode unless the file fits in a single block. The
default stays at 8 MiB: it is the fastest and scales better on medium files,
where 16 MiB leaves only two blocks.

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

The stream format does not depend on which build is used: the BWT is computed
in Pascal from the suffix array, both suffix array backends produce the same
array, and the format is specified in [`docs/FORMAT.md`](docs/FORMAT.md).

## Status

| piece | state |
|---|---|
| measurement model and design | done (`docs/DESIGN.md`) |
| suffix array, SA-IS in Pascal | done, tested |
| optional libsais accelerator | done, tested against the Pascal backend |
| BWT forward and inverse | done, round-trip tested |
| QLFC entropy stage (libbsc) | done, 17.46 % on the text corpus |
| format v3, CLI, C API | done, specified in `docs/FORMAT.md` |
| decoder hardening | CRCs, bounded coder, fuzzing, truncation tests |
| Linux, Windows, macOS builds | done, byte-identical output |

Single mode, on the 85 MB text corpus. Blocks are independent, so `-T` emits
byte-identical output with the blocks compressed in parallel:

| | ratio | compress | decompress |
|---|---|---|---|
| **tovyCT, default (8 threads)** | **17.46 %** | **62.0 MB/s** | **71.9 MB/s** |
| tovyCT, one thread (`-T 1`) | 17.46 % | 16.4 MB/s | 30.4 MB/s |
| **tovyCT, `-T 8`** | **17.46 %** | **62.0 MB/s** | **71.9 MB/s** |
| **tovyCT, `-T 16`** | **17.46 %** | **72.4 MB/s** | **97.3 MB/s** |
| tovyCT, max ratio (`-b 32 -a -s`) | 16.93 % | 10.7 MB/s | 9.4 MB/s |
| bsc 3.3.12, one thread | 17.33 % | 17.5 MB/s | 29.5 MB/s |
| bzip3 | 16.90 % | 7 MB/s | 9 MB/s |
| xz -6 | 20.19 % | 6 MB/s | ~80 MB/s |
| bzip2 -9 | 20.78 % | 11 MB/s | 35 MB/s |
| zstd -19 | 20.18 % | 4 MB/s | 1087 MB/s |

The ratio already beats xz, zstd -19, bzip2 and brotli -9 on this corpus;
bzip3 is 3 % smaller: it is the same block-sorting family, with a stronger
context model and a different transform pipeline. Decoding runs in C kernels: the encoder stores the LF-chain row of every
4096-byte output chunk (taken from the inverse suffix array, about 0.1 % of the
block), so the decoder walks eight independent chains instead of one serial one.
That took decompression from 9.5 to 42.4 MB/s on the same corpus. Smaller blocks
trade a little ratio for more speed: 4 MB blocks give 20.77 % at 50 MB/s, 2 MB
blocks 21.25 % at 52 MB/s.

## Decoder safety

Each block carries a CRC-32C of its compressed payload, checked before anything
is decoded, and the decoder validates the stream header, the BWT primary index
and every sample row against the sizes it was given. A declared total size is
also checked for plausibility before any buffer is allocated: real data does not
compress better than about 1000:1 (16 MiB of zeros is 997:1), so anything above
4096:1 plus 1 MiB is treated as corruption. A 16-byte fabricated header cannot
ask for a gigabyte.

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
deterministic). The coder
takes an explicit output limit and input end, checks every run and every rank,
and has a bounded entry point (`bsc_coder_decompress_bounded`) that validates its
own block table. The output limit and the end of the input are parameters of
the decode call, so parallel blocks share no state; a thread-local copy was the
first attempt, but it did not survive the Windows static-library link and made
two-block decodes fail there.

The evidence is measurement, not proof:

- `tests/fuzz_qlfc.c` fuzzes the coder with coverage, AddressSanitizer and UBSan.
  This is the only target where libFuzzer sees the code it mutates, because the
  Pascal side cannot be instrumented. Eight workers, seeded with payloads from
  real streams, plus the inputs that found the bugs above. The last campaign ran
  ~400,000 executions across eight workers with no findings after the fixes.
- `tests/test_payload.c` keeps the container valid, flips bits in a real payload,
  recomputes its CRC and checks that the API returns an error or exactly the
  original file (1,500 mutations per run, in CI).
- `tests/test_truncate.c` walks every prefix, appends bytes and flips bits.
- `tests/test_hostile.c` feeds fabricated headers: absurd totals, blocks larger
  than the stream, and a 4 KiB stream claiming an 8 KiB block.

An earlier round of "80 million executions" turned out to be worthless: the seed
corpus was from format v2, which the current decoder rejects at the version
byte, and the shared library was not instrumented, so the coverage counter only
saw the harness. Both are fixed; the corpus is regenerated on every run.

## Licence## Licence

MIT. See [`LICENSE`](LICENSE).

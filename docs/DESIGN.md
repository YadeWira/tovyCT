# Design

Status: **implemented and released as 1.0**, format v4 frozen.

This document records what was measured before the codec was written, why the
first design was dropped, what was built instead, and which ideas were measured
and rejected along the way.

## 1. Corpus and baseline

All numbers below are single-threaded on an Intel Xeon E5-2697A v4 (2.6 GHz,
AVX2), 62 GB RAM, warm cache, on **85,230,031 bytes of text**: the Silesia files
`dickens` (prose), `reymont` (prose), `webster` (dictionary), `samba` (C source)
and `xml` (markup). Ratio is compressed size over original size; lower is better.
Speed is uncompressed MB/s.

| codec | ratio | compress | decompress |
|---|---|---|---|
| gzip -1 | 34.31 % | — | — |
| gzip -6 | 28.26 % | ~27 | ~310 |
| zstd -1 | 30.82 % | 557 | 1351 |
| zstd -3 | 27.33 % | 356 | 1257 |
| zstd -5 | 25.72 % | 224 | 1172 |
| zstd -8 | 23.90 % | 131 | 1301 |
| zstd -12 | 22.83 % | 44 | 1268 |
| zstd -19 | 20.18 % | 4 | 1087 |
| brotli -9 | 22.02 % | 5 | 443 |
| xz -6 | 20.19 % | 6 | ~80 |
| xz -9 | 19.54 % | 1 | ~80 |
| bzip2 -9 | 20.78 % | 11 | 35 |
| **bzip3 (16 MB blocks)** | **16.90 %** | **7** | **9** |

The last row is the important one. `bzip3` is LZP + BWT + MTF/RLE + rANS; on text
it is 3.3 points (16 %) smaller than `xz -6` and 6.9 points (29 %) smaller than
`zstd -12`, and it does that at 7 MB/s.

## 2. The first design, and why it was dropped

The original plan was LZ77 + four recent offsets + an LZP predictor + 4-way
interleaved rANS with context-conditioned literals: the zstd/LZFSE family with a
better literal model.

A measurement model was written (`research/model/model.c`, not shipped). It
parses exactly as the planned encoder would, computes the ideal entropy of every
stream under several literal context schemes, adds an estimate of the table cost,
and replays the parse to prove it decodes. Results on the 85 MB corpus:

| parse | literals | literal ctx | ratio | model speed |
|---|---|---|---|---|
| greedy, depth 1 | 8.2 % | 512 | 26.97 % | 28 MB/s |
| greedy, depth 4 | 7.6 % | 512 | 25.30 % | 25 MB/s |
| greedy, depth 16 | 8.7 % | 16 | 24.08 % | 11 MB/s |
| greedy, depth 32 | 8.0 % | 16 | 23.52 % | 7 MB/s |
| optimal DP, depth 128 | 10.8 % | 512 | 22.16 % | 1.1 MB/s |

Against the same corpus:

- 23.52 % beats `zstd -8` (23.90 %) by 1.6 % and loses to `zstd -12` (22.83 %).
- 22.16 % beats `zstd -12` by 2.9 %, ties `brotli -9` (22.02 %), and loses to
  `xz -6` (20.19 %) by 10 %.
- Every point of the curve is slower than the zstd point with the same ratio:
  the bare matchfinder (hash chains, one lazy step, no entropy coding) runs at
  18.8 MB/s at depth 16 and 9.8 MB/s at depth 32 in plain C.

Detailed measurements on individual files confirm the shape: on `dickens` the
best LZ model reaches 30.31 %, while `xz -6` takes 27.78 % and `bzip3` 21.92 %.

**Verdict: the LZ+rANS design cannot reach its target.** It lands between
`zstd -8` and `zstd -12` in ratio and is several times slower than both. There is
no configuration of it that produces the ratio of `zstd -8` at the speed of
`zstd -5`; zstd itself needs 131 MB/s to reach 23.90 %.

The same corpus through BWT-family compressors:

| file | bzip3 | bzip2 -9 | xz -6 | best LZ model |
|---|---|---|---|---|
| dickens | 21.92 % | — | 27.78 % | 30.31 % |
| webster | 16.37 % | — | 21.01 % | 24.25 % |
| samba | 18.40 % | — | 17.52 % | 20.17 % |
| xml | 7.59 % | — | 9.68 % | 9.57 % |
| whole corpus | 16.90 % | 20.78 % | 20.19 % | 22.16 % |

On text, the block-sorting family is not a small improvement over LZ: it is 20
to 30 % smaller.

## 3. The design being built instead

**LZP + BWT + MTF/RLE + rANS**, in blocks, with the speed being the differentiator
rather than the ratio (the ratio is already established by bzip3; what nobody has
is a fast implementation of it, especially a decoder — bzip3 decodes at 9 MB/s).

Pipeline per block:

1. **LZP prefilter** (optional, on by default for text): a hash of the last four
   bytes predicts the next match; repeated substrings that BWT would turn into
   long runs are removed cheaply first. This is what separates bzip3's 16.9 %
   from bzip2's 20.8 % as much as the entropy coder does.
2. **BWT** over the block, built with SA-IS (linear time), inducing the BWT
   directly to avoid materialising both arrays.
3. **MTF + RLE**: the classic rank transform, with the zero runs coded as
   (run length, next rank). This is the part that vectorises best.
4. **rANS**, 4-way interleaved: order-0 over the RLE token stream, with separate
   contexts for the rank and the run-length symbols; tables per block, normalised
   to 12 bits.

Block size is the main speed/ratio knob: 1 MB for the fast levels, 16 MB for the
high ones.

### Why this can be fast

- SA-IS is linear and memory-bound; `bz2-ng`, a C bzip2 rewrite, builds 50 MB
  blocks at 66 MB/s with `libsais`, so the algorithm is not the limit.
- Inverse BWT with a segmented LF table and software prefetch reaches 243 MB/s in
  `bz2-ng`; a Pascal version with AVX2/NEON gathering can aim for 150–250 MB/s.
- rANS decoding is table-driven and branch-free; 4-way interleaving hides the
  dependency chain.
- bzip3 is slow because its pipeline is scalar, not because BWT is slow.

Target for the Pascal implementation:

| level | block | ratio (text corpus) | compress | decompress |
|---|---|---|---|---|
| 1 (fast) | 1 MB | ~19 % | 8–12 MB/s | 250+ MB/s |
| 5 (default) | 8 MB | ~17.5 % | 6–9 MB/s | 200+ MB/s |
| 9 (max) | 16 MB | ~16.9 % | 5–7 MB/s | 200+ MB/s |

These are targets, not measurements; M1 establishes the real numbers, and the
first SA-IS measurement has already moved them down.

### SA-IS in Pascal: first measurement

`src/tvct.sais.pas` implements the paper's compact variant over Int32 symbols,
with the sentinel. Correctness is checked against a naive sort on 4001 random
strings and with an O(n) order-and-permutation check on real text blocks.

Throughput on the same machine, single thread:

| block | tovyCT SA-IS (Pascal) | libsais (C, reference) |
|---|---|---|
| 1 MB | 8.6 MB/s | 30.1 MB/s |
| 4 MB | 7.8 MB/s | 32.1 MB/s |
| 8 MB | 6.4 MB/s | 24.9 MB/s |
| 16 MB | 5.6 MB/s | 20.3 MB/s |

The gap is about 4x. libsais is the state of the art and is what `bz2-ng` links.

A byte-level rewrite was then measured (input read directly, no widened copy):
7.7 MB/s at 1 MB and 6.2 MB/s at 16 MB, and 9.8 MB/s even at 64 KB blocks. The
copy was not the bottleneck: the limit is the dependency chain of random accesses
inside the induced-sorting loops and the branch misses they cause (perf: 0.80
instructions per cycle, 200 M cache misses and 179 M branch misses over the run).
Closing the remaining 3x would mean restructuring the passes the way libsais
does, which is a project of its own.

The reference row also sets the ceiling honestly: on this CPU even libsais builds
a 16 MB suffix array at 20 MB/s, so a BWT codec in C would compress at roughly
15 MB/s here. The 66 MB/s figure `bz2-ng` reports comes from newer CPUs.

This means the compression-speed targets above are too optimistic: with an 8 MB/s
suffix array and a pipeline that costs 1.5-2x, compression lands at 4-6 MB/s,
below bzip3 (7) and xz (6). Decompression is unaffected: it does not build suffix
arrays, so the 200+ MB/s target stands.

The two ways out, to be decided before M1 continues:

- **Optional libsais.** Vendor libsais (Apache-2.0 WITH LLVM-exception, MIT
  compatible, the same arrangement `bz2-ng` uses), keep the pure-Pascal SA as the
  default fallback, and let a build flag select the C one. Everything else — the
  format, BWT wiring, CLI and C API — stays Pascal; the heavy loops move to C.
- **Go back to LZ.** The measured LZ+rANS model gives 23.5 % at an estimated
  15-25 MB/s in Pascal, with 400+ MB/s decode. Worse ratio than BWT by 25 %,
  better compression speed by 2-4x.

### Kernels

The table below was written for the MTF + rANS design. The current codec links
only the inverse-BWT kernel; the rANS and MTF/RLE kernels remain in the tree but
are not called, and ARMv7 was dropped by decision.

| target | what is written in C |
|---|---|
| x86-64 | rANS decode, MTF/RLE decode (SSE2/AVX2), inverse-BWT chain walk, CRC32C |
| i386 | the same, scalar or SSE2 |
| AArch64 | rANS decode, MTF/RLE (NEON), inverse BWT, CRC32 |
| ARMv7 | dropped |

SA-IS stays in Pascal: it is pointer-chasing and memory-bound, and hand-written
assembly does not pay there; the bucket-sum passes are the only vectorisable
part.

### M1 progress

| piece | measured |
|---|---|
| suffix array, libsais (1 MB / 8 MB blocks) | 35.6 / 26.7 MB/s |
| suffix array, pure Pascal | 8.6 / 6.4 MB/s |
| BWT forward on top of the suffix array | adds less than 10 % |
| BWT inverse, simple LF walk | 35.9 / 25.9 MB/s |

The inverse transform is now the decode bottleneck and the next optimisation
target. It is a single dependent chain of random reads, so its speed is one
memory latency per byte. The fix is the one `bz2-ng` uses: the encoder records
the row at each chunk boundary and the decoder walks several independent chains
in parallel, which turns a serial latency chain into memory-level parallelism.
That plan is what the inverse-BWT kernel implements (`src/c/tvct_kernels.c`).

### M1 end-to-end

Single mode: BWT + QLFC, 85 MB text corpus, one thread.

| blocks | ratio | compress | decompress |
|---|---|---|---|
| 8 MB, one thread | 17.46 % | 16.4 MB/s | 30.4 MB/s |
| 8 MB, `-T 8` | 17.46 % | 62.0 MB/s | 71.9 MB/s |
| 8 MB, `-T 16` | 17.46 % | 72.4 MB/s | 97.3 MB/s |
| 16 MB, one thread | 17.21 % | 13.1 MB/s | 24.0 MB/s |

Against bsc itself on the same corpus and block size: 17.33 % at 17.5/29.5 on
one thread. The single-thread gap is about 1 % of size and 7 % of compression
speed; the parallel path is 3.5 to 5 times faster than bsc's CLI, which in this
build does not scale. The encoder gets the BWT, the primary index and the sample
rows from one `libsais_bwt_aux` call, which removed the separate SA pass and the
inverse-suffix-array scan; the BWT inverse stays in this project's kernel, which
measures 93 MB/s against libsais's 74.

Blocks are independent, so the parallel path is a pool of workers over one chunk
of blocks and a sequential writer; the output is byte-identical to the
sequential path. Compression is suffix-array bound (62 % of the single-thread
time) and decompression is QLFC bound (68 %), which is why the threads scale
almost linearly.

Reference on the same corpus: bzip3 16.90 % at 7/9, bsc 17.06 % at 13.9/27,
xz -6 20.19 % at 6/~80, bzip2 -9 20.78 % at 11/35.

### Where the ratio stands

The question for 1.0 was whether the pipeline can beat libbsc, the library its
entropy coder comes from. Measured again with the 3.4.0 reference CLI, one
thread, on the 85 MB text corpus:

| setting | ratio |
|---|---|
| tovyCT `fast` (8 MB, static, transform) | 17.35 % |
| bsc `-b8` (8 MB, static, LZP) | 17.33 % |
| bsc `-b8 -p` (no preprocessing) | 17.36 % |
| tovyCT `compact` (16 MB, static, transform) | 17.10 % |
| bsc `-b16` | 17.06 % |
| bsc `-b16 -p` | 17.11 % |
| tovyCT `max` (16 MB, adaptive, transform) | 16.84 % |
| bsc `-b16 -e2` (adaptive) | 16.90 % |
| bsc `-b16 -e2 -p` | 16.95 % |
| tovyCT `max -b 64` | 16.67 % |

Against the coder alone tovyCT wins at every size: the text transform and the
container more than pay for the header. Against the full bsc CLI the difference
is its LZP stage, worth 0.03-0.05 points here. Wiring libbsc's LZP in was
considered and rejected: it adds a preprocessing layer and its decoder for less
than the text transform already returns, and the format was about to freeze.
Block size is the lever that is left: 64 MB blocks reach 16.67 % for twice the
compression time, which is what `-b` is for.

A stronger entropy model was measured earlier in the project: context mixing on
the BWT bytes reached 17.23 % at 8 MB, 0.23 points below the QLFC coder at half
the speed, and it does not scale to the 16 MB and adaptive presets that already
reach 16.84 %. The `max` preset beats both, so a CM stage would add a decoder
path without moving the ratio.

The entropy stage went through three designs, each measured:

1. **MTF + static rANS** (the bzip2 architecture with a better alphabet coder):
   20.48 % at 13.9/41.6. Fast, but 15 % behind the field.
2. **Context mixing on the BWT bytes** (order-1/2 bit models, mixed, with an
   APM): 17.23 % at 7.8/10.7. Matched bzip3's ratio, but half its speed.
3. **QLFC** (libbsc's coder, Apache-2.0): 17.46 % at 14.6/27.1. Delivers the
   ratio of the context-mixing coder at twice its speed.

QLFC does its own RLE, MTF and context-conditioned arithmetic coding over the BWT
output. Its advantage over the static rANS is not LZP — libbsc's LZP only shrinks
this corpus by 0.06 % — it is the coder itself. That measurement is what settled
the design: entropy modelling, not preprocessing.

Decoding runs in C kernels. The encoder stores the LF-chain row of every
4096-byte output chunk, taken from the inverse suffix array (0.1 % of the block),
so the decoder walks eight independent chains instead of one serial one.
## 4. What is still open

- **The entropy decoder is hardened, not proved.** QLFC used to trust what it
  decoded. A coverage-instrumented fuzzer of the coder (the Pascal container
  cannot be instrumented) found seven ways to make it misbehave: run writes past
  the output, reads past the input, an MTF rank of 691 in a 256-entry stack
  table, a block table read past a short payload, an unbounded run width
  indexing a 32-entry model (seen as a use-after-free when the index landed in a
  freed chunk), an `i + runSize` overflow that let a 2 GB write pass the check,
  and a zero output size in the block table, which disabled the coder's bound
  because zero meant "no limit". The rank exponent loop is bounded too (it used
  to follow one bits when `maxRank` was 0), and four undefined behaviours were
  fixed: `__builtin_clz(0)` on a one-character alphabet, misaligned 16-bit
  loads, MTF-table entries a hostile rank could read before they were written,
  and signed overflow in the adaptive mixer on hostile streams. Each access now
  has a bound that comes from the caller, and the decoder has a bounded entry
  point for the block table. That is still an argument from measurement, so the
  decode path now also runs behind guard pages: the payload copy and every
  output buffer end at a `PROT_NONE` page, and a fault inside the stages comes
  back as a decode error (`src/c/tvct_guard.c`, `tvct_guard_run`). The cost
  measured 2-4 % of decode speed, inside the noise. It is per thread, restores
  the previous handler for faults that are not ours, and is opt-in for library
  callers because a library should not install a `SIGSEGV` handler behind its
  host's back; the command line turns it on. Windows has no implementation.
- **Fuzzing was initially misconfigured, and the numbers said so too late.** The
  first campaign reported 80M executions with the seed corpus of an older format
  and an uninstrumented shared library: coverage was 5 edges (the harness only)
  and every input was rejected at the version byte. The harness now builds the
  coder with `-fsanitize=fuzzer-no-link`, regenerates the corpus each run, and
  keeps the inputs that found real bugs as regression seeds. When a fuzzer runs
  80M inputs in a minute, that is the signal to check what it is measuring.
- **The Pascal container has no AddressSanitizer coverage.** Its bounds are
  checked by the deterministic tests (every truncation, appended bytes, bit
  flips, fabricated headers, payload mutations with recomputed CRCs), and a
  `--checked` build with range and overflow checks runs the whole suite in CI.
  That catches Pascal-level indexes and arithmetic, not the C-style buffer
  overruns ASan would; the entropy coder, where the bugs were, is covered by the
  C sanitizer fuzzers. An ASan-capable Pascal toolchain would close the gap.
- **Small files.** Since v4 the headers are varints: a 100-byte file becomes
  115 bytes and an empty one 8. The 64 KiB minimum block remains, so an archive
  of thousands of tiny files would still pay per file; tovyCT is for text, not
  for that.
- **BLAKE3 digest.** Implemented as `-H`: 16 bytes at the end, checked after
  decoding, and the stream must end right there. It is a stronger declared
  integrity check than CRC-32C, but it travels in the file and therefore cannot
  stop a deliberate forgery; the per-block CRC remains the corruption check.
- **Targets.** Linux x86-64, x86-32 and AArch64, macOS AArch64 and Windows
  x86-64 and x86 run in CI. The 32-bit Windows build is also validated in a
  Windows 7 VM. macOS x86-64 was discarded by decision and ARMv7 was dropped.
- **The text transform is ASCII-only.** It folds `A-Z` and builds its dictionary
  from ASCII words, so accented letters and Cyrillic do not participate. Measured
  on Gutenberg UTF-8 books (`-l fast`, `auto` vs `off`): Spanish −0.94 %, French
  −1.0 %, German −0.4/−0.75 %, Italian −0.08 %, Portuguese −1.0 %, Russian
  −1.3/−1.4 %; Chinese and Japanese blocks skip it. No measured file grew.
  A version that also accepted UTF-8 words into the dictionary was built and
  measured, and it made things worse: Russian grew 0.55 points (449,371 →
  451,847 bytes on the 2 MB book, 740,682 → 744,052 on the 3.3 MB one) and most
  Latin books 0.05-0.15 points, while Spanish and one French book gained 0.02.
  The BWT already models those words; a code that saves bytes before it does not
  save bits after it. Reverted, and the format never carried it.
- **Speed for a future v5.** [`V5-STUDY.md`](V5-STUDY.md) has the profiles, the
  byte-identical wins that landed (hardware CRC-32C, an AVX QLFC decoder the
  upstream build never compiles, reused guard scratch) and the measured cost of
  the format-level options: segmented QLFC costs 0.04 points for two streams,
  and a block size that follows the input buys twice the decode throughput on
  medium files at 0.5 points.
- **v5 can segment the entropy stage.** `-S K` splits a block's BWT output into
  K independently coded QLFC streams (format v5; v4 streams are unchanged and
  the reader takes both). Measured on a 16 MiB block: +0.03 points of ratio and
  +14 % decode with two streams at eight threads, +0.10 points and +46 % with
  eight. See [`V5-STUDY.md`](V5-STUDY.md).
- **Format v4 is frozen at 1.0.** Any 1.0 build decodes any 1.0 stream on any
  of the six targets, and the compressed bytes are identical across them. A
  change that needs new syntax, a new transform code or a different header
  becomes v5; v4 keeps its decoder. The C ABI follows the same rule: functions
  are only added.

## 5. Licence hygiene

No code is taken from bzip3 (LGPL-3.0) or the lpaq-derived context-mixing unit
that was only measured. The BWT comes from libsais and the entropy coder from
libbsc, both Apache-2.0, and their local changes are listed in
`third_party/*/README.md`. The rest is written from scratch and released under
MIT; the format is specified in `docs/FORMAT.md` so another implementation can
read it without copying code.

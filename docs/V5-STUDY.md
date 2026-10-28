# Studies for v5: speed

Format v4 is frozen, so anything that changes the compressed bytes needs a v5.
This document records what was measured while looking for speed **without**
paying ratio, and separates what is free (identical bytes, shipped in v4) from
what would need the new format.

## Method

- **Profiles** with `perf record` on an `-O3 -g` build (`scripts/build.sh
  --profile`), single thread, 16 MiB of the 85 MiB text corpus.
- **A/B runs** alternate the two binaries on the same input and report the best
  of seven wall-clock runs. On this machine, shared with other work, the noise
  floor between two identical builds measured 1.5-2 %, so anything below that is
  not a result.
- **Byte identity** for every change that claims not to touch the format: `cmp`
  of the compressed file against the previous build, plus the whole test suite,
  which hashes two samples.

## Where the time goes

85 MiB text corpus, one thread:

| stage | compress | decompress |
|---|---|---|
| suffix array (libsais) | 41 % | — |
| QLFC encode / decode | 24 % | 52-61 % |
| inverse BWT | — | 18-24 % |
| text transform | 12 % | 5 % |
| CRC-32C | 7 % | 0 % -> 12 % before the hardware change |
| guard copies and page faults | — | 5-8 % |

Compression is suffix-array bound; decompression is the entropy decoder. Any
serious decode speedup has to come from QLFC or from doing less work around it.

## Free wins (identical bytes, shipped in v4)

| change | effect | where |
|---|---|---|
| hardware CRC-32C (SSE4.2 / AArch64 `crc32cd`, slicing-by-8 fallback) | compress +8 %, decode +13 % | `src/c/tvct_crc.c` |
| QLFC decoder compiled for AVX and picked at run time | decode +4 % (the stage itself: 35 -> 43 MB/s) | `scripts/build.sh`, `coder.cpp` |
| guard-page scratch reused across blocks instead of mapped per block | decode +2 % | `tvct.codec.pas` |

End to end, against the 1.0.0 binary:

| corpus | metric | 1.0.0 | now |
|---|---|---|---|
| 85 MiB, T1 | compress | 16.4 MB/s | 18.0 MB/s |
| 85 MiB, T1 | decompress | 30.0 MB/s | 31.5 MB/s |
| 16 MiB, T1 | compress | 1092 ms | 1029 ms |
| 16 MiB, T1 | decompress | 647 ms | 604 ms |
| 16 MiB, T8 | decompress | 32.5 MB/s | 39.0 MB/s |

The AVX decoder is the interesting one: libbsc ships per-ISA QLFC decoders, but
its build compiles a single translation unit, so only the SSE2 one is ever
built and the rest is dead source. Compiling the same file again with `-mavx`
and renaming its symbols lets both live in one binary; the bounded entry picks
the fast one when CPUID says AVX. Every variant decodes the same stream, so the
format and the compressed bytes are untouched.

## Measured and rejected

Each of these was implemented, measured and reverted:

- **Fusing the LF packing into the build loop.** The separate pass
  `lf[i] |= bwt[i] << 24` is auto-vectorised; folding it into the (scalar) build
  loop made the inverse BWT 139 -> 100 MB/s at 4 MiB and 71 -> 46 MB/s at
  16 MiB.
- **More chains in the inverse BWT.** 4, 8, 16, 24 and 32 chains measured 37,
  67, 53, 53 and 49 MB/s: eight is the best, and more only spill registers.
- **Transparent huge pages for the 32 MiB LF table.** 101 vs 103 MB/s: TLB
  misses were not the bottleneck.
- **Dropping the `bp` copy** by reading the BWT through an index adjustment
  (saves 8 MiB and a copy per block). Kernel-neutral, end to end slightly worse,
  so the copy stays.
- **AVX2 encoder.** The same trick applied to the encoder gives 41 -> 44 MB/s on
  that stage, about 1.7 % of compression overall, with a second renamed object
  and a second byte-identity argument. Not worth it today; the encoder is
  suffix-array bound.

## What v5 would buy

### Segmented QLFC

The coder is serial: each symbol depends on the previous range and model state.
Splitting a block's BWT output into K independent streams costs very little
ratio, because QLFC adapts within a few hundred KiB:

| streams | static coder | adaptive coder |
|---|---|---|
| 1 (today) | 22.5011 % | 22.3538 % |
| 2 | 22.5438 % | 22.3840 % |
| 4 | 22.5389 % | 22.3804 % |
| 8 | 22.6100 % | 22.4310 % |

Two streams cost **0.04 points**. That buys two things: a block can be decoded
by several threads when there are fewer blocks than threads (today a 16 MiB file
at `-T 8` uses two threads), and — if the coder's loop is split so the streams
advance together — instruction-level parallelism inside one thread, which is
where the current speedup ceiling is. The ILP part is unproven and would be the
first thing to prototype: a two-way interleaved decode on a single core.

### Block size that follows the input

The 85 MiB corpus does not care, but a 16 MiB file at `-T 8` only has two
blocks:

| block | blocks | ratio | decode T1 | decode T8 |
|---|---|---|---|---|
| 8 MiB (today) | 2 | 19.72 % | 27.8 MB/s | 38.2 MB/s |
| 4 MiB | 4 | 20.22 % | 30.3 MB/s | 75.9 MB/s |
| 2 MiB | 8 | 20.82 % | 30.1 MB/s | 75.9 MB/s |
| 1 MiB | 16 | 21.78 % | 29.9 MB/s | 75.6 MB/s |

Doubling decode throughput costs 0.5 points at 4 MiB. Picking the block size
from the input length and the thread count (`min(8 MiB, input / threads)`, say)
needs **no format change**: it is a preset heuristic, and the block size already
travels in the header. That is the cheapest real speedup left for medium files.

### 32 MiB blocks and the 24-bit packing

The inverse BWT packs the LF row and the BWT byte into one 32-bit entry only
while `n < 2^24`. A 32 MiB block (what `max` uses when the input fits in one)
falls back to two arrays and two dependent loads per step: 16 MiB decodes at
66 MB/s against ~100 MB/s for 8 MiB. If large blocks stay, v5 should carry a
40-bit packed entry (or a second byte array laid out to be prefetched).

### What is not recommended

Replacing QLFC. The measured context-mixing coder reached 17.23 % at 8 MiB, and
`max` already reaches 16.84 % at 16 MiB; a faster coder that is also smaller
than QLFC is the one thing this project has not found.

## Next steps

1. Prototype two-way interleaved QLFC decode and measure the single-thread gain;
   if it is under 20 %, segmentation only pays for the thread case.
2. Try the block-size heuristic in the CLI (no format change) and measure the
   whole preset table again.
3. Only then decide whether v5 needs new syntax at all, or whether v4 keeps
   gaining speed without moving a byte.

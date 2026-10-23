# Design

Status: **M0 (measurement) complete — design changed.** No codec code exists yet.

This document records what was measured before writing the codec, why the first
design was dropped, and what is being built instead.

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
  format, LZP, BWT wiring, MTF/RLE, rANS, inverse BWT, CLI, C API — stays Pascal
  and assembly. Compression moves to an estimated 10-15 MB/s.
- **Go back to LZ.** The measured LZ+rANS model gives 23.5 % at an estimated
  15-25 MB/s in Pascal, with 400+ MB/s decode. Worse ratio than BWT by 25 %,
  better compression speed by 2-4x.

### Assembly kernels

| target | what is written in assembly |
|---|---|
| x86-64 | rANS decode, MTF/RLE decode (SSE2/AVX2), inverse-BWT chain walk, CRC32C |
| i386 | the same, scalar or SSE2 |
| AArch64 | rANS decode, MTF/RLE (NEON), inverse BWT, CRC32 |
| ARMv7 | NEON MTF/RLE, scalar fallback for the rest |

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
That plan is what the assembly kernels will implement.

### M1 end-to-end

The format, the CLI and the whole pipeline are working; 85 MB text corpus,
16 MB blocks, one thread:

| pipeline | ratio | compress | decompress |
|---|---|---|---|
| BWT + MTF/RLE + 3-context rANS | 20.36 % | 11.9 MB/s | 9.9 MB/s |

Measured alternatives on the same file: bzip3 16.90 %, xz -6 20.19 %, bzip2 -9
20.78 %, zstd -19 20.18 %, brotli -9 22.02 %.

Two findings from this phase:

- **LZP with a short minimum match hurts.** At 4 bytes it costs 12 % of the final
  size: it removes the repeats the BWT would have clustered. bzip3 uses aminimum
  match of 40, which only collapses long redundant data. Our LZP is implemented
  and off by default until it is re-tuned to that shape.
- **bzip3's ratio comes from the entropy coder, not from MTF.** Reading its
  source: it applies RLE, then LZP with a 40-byte minimum, then BWT, and codes
  bytes with a context-mixing arithmetic coder (order-1 and order-2 bit models,
  mixed and passed through an APM). MTF + rANS is the bzip2 architecture, and it
  measures at bzip2-plus-a-little, exactly as expected.

Decompression was the next problem: the inverse BWT is a dependent chain of
random reads, one memory latency per byte.

The fix is in `src/c/tvct_kernels.c`. The encoder computes the inverse suffix
array once and stores, for every 4096-byte chunk of the output, the LF-chain row
of that chunk's last position. That is 0.1 % of the block, and with it the
decoder starts eight chains at known rows and walks them interleaved, so the
out-of-order engine keeps eight loads in flight instead of one. The same file
carries the rANS and MTF/RLE decoders.

Measured, 85 MB text corpus, one thread:

| blocks | ratio | compress | decompress |
|---|---|---|---|
| 8 MB | 20.48 % | 14.6 MB/s | 42.4 MB/s |
| 4 MB | 20.77 % | 16.8 MB/s | 50.2 MB/s |
| 2 MB | 21.25 % | 16.1 MB/s | 51.6 MB/s |

Decode stage times at 8 MB blocks: inverse BWT 0.96 s, MTF/RLE 0.40 s, rANS
0.31 s, file write 0.28 s for the whole 85 MB.

### Context mixing: method 2

MTF + rANS is the bzip2 architecture and lands at bzip2 plus a little, as the
measurements showed. The coder that makes bzip3 small is context mixing on the
BWT bytes: three bit models (order-0, previous byte, the byte before that),
mixed with fixed weights and refined by an APM stage indexed by the bit-tree
context and a run flag.

`src/c/tvct_cm.c` implements it as a second block method, selected with `--cm`.
It is the same model, written from the published description (bzip3 is LGPL and
none of its code is used).

| blocks | ratio | compress | decompress |
|---|---|---|---|
| 16 MB, CM | 17.12 % | 7.3 MB/s | 9.8 MB/s |
| 8 MB, CM | 17.39 % | 8.0 MB/s | 10.2 MB/s |
| 4 MB, CM | 17.88 % | 8.2 MB/s | 10.6 MB/s |
| 8 MB, MTF + rANS | 20.48 % | 14.6 MB/s | 42.4 MB/s |

So the codec now sits at bzip3's ratio (16.90 %) with slightly better speed,
and keeps a fast mode 19 % larger but four times faster to decode. The remaining
1.3 % gap to bzip3 is inside its coder; its LZP only shrinks this corpus by 1 %,
so it is not the difference.

The next lever for the CM mode is decode speed: the bit-serial arithmetic coder
is the limit, not the BWT.

## 4. What is still open

- **SA-IS in Pascal at speed.** The one real risk. A 16 MB block needs a
  suffix array build at 30+ MB/s to keep the encoder above 15 MB/s overall.
  Fallback: smaller blocks at the fast levels and SA-IS tuning at the high ones.
- **LZP parameters.** Match length, hash size and the interaction with BWT need
  measuring; bzip3's choices are a starting point, not a spec.
- **Binary data.** BWT is weak on executables. The plan is a raw-block fallback
  chosen per block, plus documenting that the codec is tuned for text.
- **Small files.** Block overhead (SA-IS arrays, tables) dominates below ~64 KB.
  A smaller block mode and a reduced table format are needed for that range.

## 5. Licence hygiene

No code is taken from bzip3 (LGPL-3.0), PArc (GPL-2.0) or the lpaq-derived
context-mixing unit. The algorithms (LZP, BWT, MTF, RLE, rANS) are classic and
unencumbered; reference implementations that may be read for behaviour are
public domain or permissively licensed (libsais is Apache-2.0 WITH
LLVM-exception, ryg_rans is public domain, bzip2 is BSD-like). The code here is
written from scratch and released under MIT.

# libbsc

Quantized Local Frequency Coding (QLFC), the entropy coder of libbsc, by Ilya
Grebnov — the same author as libsais.

- Upstream: https://github.com/IlyaGrebnov/libbsc (version 3.3.12)
- Licence: Apache License 2.0 (see `LICENSE`). Not copyleft, compatible with
  this project's MIT licence; the files keep their own notice.
- `src/` is the upstream `libbsc/libbsc` tree with local hardening changes,
  each marked with a comment:

  | file | change |
  |---|---|
  | `platform/platform.cpp` | the Windows-only large-page path (`VirtualAlloc`, which pulls in kernel32 token imports Free Pascal's internal linker cannot resolve) is disabled when `TVCT_PORTABLE` is defined; the Windows builds pass it |
  | `coder/qlfc/qlfc.cpp` | the output limit is a parameter of the decode call: a stream that claims more output than the caller can hold is rejected before writing |
  | `coder/qlfc/qlfc.cpp` | every run write is checked against the output size (`i + runSize > n`), which closes a heap overflow the fuzzer found |
  | `coder/qlfc/qlfc.cpp`, `coder/common/rangecoder.h` | the end of the compressed block is a parameter too: the range coder stops there instead of reading past it, and its overrun flag turns into `LIBBSC_NOT_COMPRESSIBLE` |
  | `coder/qlfc/qlfc.cpp` | a decoded rank is rejected if it is not a valid MTF index (`rank >= ALPHABET_SIZE`); a crafted stream decoded rank 691 and read past the stack table |
  | `coder/qlfc/qlfc.cpp` | `bsc_rank_bits`: `floor(log2(rank - 1))` without the undefined `__builtin_clz(0)`, used by encoder and decoder; a one-character alphabet (rank 1) no longer depends on compiler luck |
  | `coder/qlfc/qlfc.cpp` | the exponent-size loop stops at `bitRankSize >= maxRank`; with `maxRank = 0` the old `==` test never fired and the loop followed one bits indefinitely |
  | `coder/qlfc/qlfc.cpp` | a run length is capped at 30 bits: the decoder's exponent loop followed one bits forever and indexed the 32-entry run model out of bounds (a use-after-free once the index landed in a freed chunk) |
  | `coder/qlfc/qlfc.cpp` | the run write check is `runSize > n - i` instead of `i + runSize > n`, which overflows for a hostile run length and lets a 2 GB write pass |
  | `coder/coder.cpp` | `bsc_coder_decompress_bounded` rejects a block with a zero input or output size: zero output used to switch the QLFC output limit off (that limit uses 0 for "no limit"), and the block then wrote past the caller's buffer |
  | `coder/qlfc/qlfc.cpp` | `bsc_floor_log2` for history contexts: `bsc_bit_scan_reverse(rank)` was called with rank 0 in the escape path, which is another `clz(0)` |
  | `coder/qlfc/qlfc.cpp` | the decoder clears the 256-entry MTF table before filling it: a hostile rank could move entries the stream never wrote, which Valgrind saw as an uninitialised read |
  | `coder/common/predictor.h` | the adaptive coder's mixer sums and weight updates use 64-bit intermediates and clamp to the range the model expects: a hostile stream drove the 32-bit arithmetic into signed overflow (UBSan, adaptive QLFC fuzzer) |
  | `coder/qlfc/qlfc.cpp` | no globals or thread-local state for the bounds: blocks decode in parallel, and the thread-local attempt did not link correctly into the Windows static binaries (two-block decodes failed there) |
  | `coder/qlfc/qlfc.cpp`, `coder/common/rangecoder.h` | `bsc_coder_decompress_bounded`: the caller passes the input and output sizes, and every block-table size and offset is validated before use; the old signature had no length and read past a short input |
  | `coder/common/rangecoder.h` | the range coder reads through `const unsigned char *` with `memcpy` instead of casting to `unsigned short *`: the stream has no alignment guarantee and the cast was undefined behaviour (UBSan found it) |

  Only the coder subset is compiled: `coder/coder.cpp`, `coder/qlfc/qlfc.cpp`,
  `coder/qlfc/qlfc_model.cpp`, `platform/platform.cpp`, `adler32/adler32.cpp`.

tovyCT uses it as the entropy stage: it takes the BWT output and applies its own
RLE, MTF and context-conditioned arithmetic coding. Measured against this
project's own static MTF + rANS on 85 MB of text, it is 15 % smaller at the same
speed.

LZP, the sort transform and the filters in the vendored tree are not compiled.

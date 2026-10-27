# libbsc

Quantized Local Frequency Coding (QLFC), the entropy coder of libbsc, by Ilya
Grebnov — the same author as libsais.

- Upstream: https://github.com/IlyaGrebnov/libbsc (version 3.4.0)
- Licence: Apache License 2.0 (see `LICENSE`). Not copyleft, compatible with
  this project's MIT licence; the files keep their own notice.
- `src/` is the upstream `libbsc/libbsc` tree with local hardening changes,
  each marked with a comment. tovyCT moved from 3.3.12 to 3.4.0 and kept the
  patches; on the 85 MB test corpus the encoder writes the same bytes as
  3.3.12, so the upgrade is transparent.

  | file | change |
  |---|---|
  | `platform/platform.cpp` | the Windows-only large-page path (`VirtualAlloc`, which pulls in kernel32 token imports Free Pascal's internal linker cannot resolve) is disabled when `TVCT_PORTABLE` is defined; the Windows builds pass it |
  | `coder/qlfc/qlfc.cpp`, `coder/common/rangecoder.h` | the output limit and the end of the compressed block are parameters of the decode call: a stream that claims more output than the caller can hold, or that runs past the payload, is rejected instead of writing or reading out of bounds |
  | `coder/qlfc/qlfc.cpp` | every run write is checked against the output size, in the form `runSize > n - i` (and a pointer difference in the fast decoder), which does not overflow for a hostile run length; the old `i + runSize > n` wrapped and let a 2 GB write pass |
  | `coder/qlfc/qlfc.cpp` | a decoded rank is rejected if it is not a valid MTF index (`rank >= ALPHABET_SIZE`); a crafted stream decoded rank 691 and read past the stack table |
  | `coder/qlfc/qlfc.cpp` | the rank exponent loop stops at `bitRankSize >= maxRank`; 3.4.0 already computes `maxRank` safely for a one-character alphabet, but the `==` test never fired for `maxRank = 0` and the loop followed one bits indefinitely |
  | `coder/qlfc/qlfc.cpp` | `bsc_floor_log2` for the history contexts: `bsc_bit_scan_reverse(rank)` was called with rank 0 in the escape path, which is `__builtin_clz(0)` undefined behaviour |
  | `coder/qlfc/qlfc.cpp` | a run length is capped at 30 bits: the run exponent loop could follow one bits forever and index the 32-entry run model out of bounds (a use-after-free once the index landed in a freed chunk) |
  | `coder/qlfc/qlfc.cpp` | the decoder clears the 256-entry MTF table before filling it: a hostile rank could move entries the stream never wrote, which Valgrind saw as an uninitialised read |
  | `coder/common/predictor.h` | the adaptive coder's mixer sums and weight updates use 64-bit intermediates and clamp to the range the model expects: a hostile stream drove the 32-bit arithmetic into signed overflow (UBSan, adaptive QLFC fuzzer) |
  | `coder/common/rangecoder.h` | the range coder reads through `const unsigned char *` with `memcpy` instead of casting to `unsigned short *`: the stream has no alignment guarantee and the cast was undefined behaviour (UBSan found it) |
  | `coder/coder.cpp`, `coder/coder.h` | `bsc_coder_decompress_bounded`: the caller passes the input and output sizes, every block-table size and offset is validated before use, and a zero input or output size is rejected; the old signature had no length and read past a short input |

  Only the coder subset is compiled: `coder/coder.cpp`, `coder/qlfc/qlfc.cpp`,
  `coder/qlfc/qlfc_model.cpp`, `platform/platform.cpp`, `adler32/adler32.cpp`.
  The CUDA sources (`bwt/libcubwt/libcubwt.cu`, `st/st.cu`) are not part of this
  copy; they are not compiled.
  The model-reuse API added by 3.4.0 (`bsc_qlfc_*_model`,
  `bsc_qlfc_decode_block_model`) is not called by tovyCT and keeps upstream's
  unbounded semantics; the entry point tovyCT uses is
  `bsc_coder_decompress_bounded`.

tovyCT uses it as the entropy stage: it takes the BWT output and applies its own
RLE, MTF and context-conditioned arithmetic coding.

LZP, the sort transform and the filters in the vendored tree are not compiled.

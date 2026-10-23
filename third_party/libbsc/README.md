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
  | `coder/qlfc/qlfc.cpp` | `bsc_qlfc_set_output_limit`: the decoder rejects a stream that claims more output than the caller can hold |
  | `coder/qlfc/qlfc.cpp` | every run write is checked against the output size (`i + runSize > n`), which closes a heap overflow the fuzzer found |
  | `coder/qlfc/qlfc.cpp`, `coder/common/rangecoder.h` | `bsc_qlfc_set_input_end`: the range coder stops at the end of the compressed block instead of reading past it, and `bsc_qlfc_overrun` turns that into `LIBBSC_NOT_COMPRESSIBLE` |

  Only the coder subset is compiled: `coder/coder.cpp`, `coder/qlfc/qlfc.cpp`,
  `coder/qlfc/qlfc_model.cpp`, `platform/platform.cpp`, `adler32/adler32.cpp`.

tovyCT uses it as the entropy stage: it takes the BWT output and applies its own
RLE, MTF and context-conditioned arithmetic coding. Measured against this
project's own static MTF + rANS on 85 MB of text, it is 15 % smaller at the same
speed.

LZP, the sort transform and the filters in the vendored tree are not compiled.

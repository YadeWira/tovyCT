# libbsc

Quantized Local Frequency Coding (QLFC), the entropy coder of libbsc, by Ilya
Grebnov — the same author as libsais.

- Upstream: https://github.com/IlyaGrebnov/libbsc (version 3.3.12)
- Licence: Apache License 2.0 (see `LICENSE`). Not copyleft, compatible with
  this project's MIT licence; the files keep their own notice.
- `src/` is the upstream `libbsc/libbsc` tree with one local change: in
  `platform/platform.cpp` the Windows-only allocation paths (large pages through
  `VirtualAlloc`, which pull in kernel32 token imports Free Pascal's internal
  linker cannot resolve) are disabled when `TVCT_PORTABLE` is defined, and the
  Windows builds pass that define. Everything else is untouched. Only the coder
  subset is compiled: `coder/coder.cpp`, `coder/qlfc/qlfc.cpp`,
  `coder/qlfc/qlfc_model.cpp`, `platform/platform.cpp`, `adler32/adler32.cpp`.

tovyCT uses it as the entropy stage: it takes the BWT output and applies its own
RLE, MTF and context-conditioned arithmetic coding. Measured against this
project's own static MTF + rANS on 85 MB of text, it is 15 % smaller at the same
speed.

LZP, the sort transform and the filters in the vendored tree are not compiled.

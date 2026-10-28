# Changelog

## 1.0.0 — 2026-10-28

The format is frozen: any 1.0 build decodes any 1.0 stream, on any of the six
targets, and the compressed bytes are identical across them.

- **Guard-page sandbox on the decode path.** The compressed payload and every
  output buffer end at a `PROT_NONE` page and the QLFC, inverse BWT and text
  stages run inside `tvct_guard_run()`: a read or write past a buffer is a failed
  block, not corruption. Per thread, 2-4 % of decode speed, no effect on the
  encoded bytes. The CLI turns it on and takes `--no-guard`; the C API exposes
  `tvct_set_guard()` and leaves the default to the host. Windows has no
  implementation and says so. `tvct --guard-check` proves the mechanism and CI
  runs it on every platform.
- **Ratio closed against libbsc 3.4.0**: tovyCT is smaller than bsc's coder at
  8 and 16 MB (17.35/17.10 % against 17.36/17.11 % without preprocessing) and
  within 0.03-0.05 points of the full bsc CLI, which spends an LZP stage for it;
  16.84 % against bsc's 16.90 % in the adaptive mode. The measurements are in
  `docs/DESIGN.md`; the LZP stage stays out by decision.
- **A UTF-8 dictionary extension was measured and rejected**: it made Russian
  0.55 points larger and most Latin books slightly worse, because the BWT already
  models those words. The ASCII-only transform that ships is the measured best.
- Documentation marked stable: `docs/FORMAT.md` is the frozen v4 layout.

## 0.2.2 — 2026-10-28

- `tvct --version` (and `-V`) prints the release version; the CLI and
  `tvct_version()` in the C API now read one constant in `src/tvct.version.pas`.
- The Linux x86 release binary is stripped, like the 64-bit one (the extracted
  32-bit compiler does not read `fpc.cfg`, so it was not stripped by default).

## 0.2.1 — 2026-10-28

- **Linux x86 (i386)** target, CI and release package; the compressed bytes are
  identical to the 64-bit build.
- CI now builds and tests six targets (Linux x86-64/x86/AArch64, macOS AArch64,
  Windows x86-64/x86) and compares the compressed hashes across all of them.
- A `--checked` build with Pascal range and overflow checks runs the whole test
  suite in CI.
- UTF-8 text was measured (Latin/Cyrillic books gain 0.1 to 1.4 %, CJK skips the
  transform) and is covered by a regression test.


## 0.2.0 — 2026-10-28

First tagged release; the format is still experimental.

- **Format v4.** Varint stream and block headers (a 100-byte file becomes 115
  bytes, an empty one 8), a method byte that carries the coder and the sample
  and text flags, a CRC-32C over the whole compressed body, and a block CRC
  seeded with the block index so a swapped or duplicated block fails.
- **Text transform.** Before the BWT, capitals are folded into CAP/UPPER flags
  and frequent words are replaced by one- or two-byte codes taken from bytes the
  block does not use. `-x off|auto|best`; it gains 1.7 % on English prose,
  0.2 % on source and 0.6 % on the 85 MB text corpus, and no file of the
  111-file mixed sample grows.
- **Optional BLAKE3-128 digest** (`-H`) of the whole input at the end of the
  stream, checked on decompression. The per-block CRC remains the corruption
  check; the digest adds cryptographic strength for archiving.
- **Presets** `-l fast|compact|max`: 17.35 / 17.10 / 16.84 % on the 85 MB text
  corpus, 57 / 50 / 37 MB/s compressing with eight threads.
- **libbsc 3.4.0** vendored instead of 3.3.12, with every local hardening patch
  ported: bounded input and output in the entropy coder, validated block table,
  rank and run-width checks, overflow-safe run writes, 64-bit mixer arithmetic
  and byte-based input. The encoder writes the same bytes as 3.3.12 on the
  measured corpora.
- **API 0.2**: `tvct_compress2` exposes the text transform and the digest;
  `tvct_compress` and `tvct_compress_ex` keep their behaviour.
- **Tests**: the text transform, its coverage fuzzer, v4 hostile headers,
  payload mutations, truncations and flips, the BLAKE3 known-answer test, and a
  generated prose sample in CI so the transform is on the tested path.
- **Windows** x86 and x64 are cross-built and validated in Windows 7 and 10
  virtual machines; Linux x86-64/AArch64 and macOS AArch64 run in CI, with
  byte-identical output checked by the determinism job.

Known limitations: the format may still change before 1.0; the text transform
is ASCII-only; the ratio mode ties libbsc's BWT + adaptive coder; there are no
release builds for macOS x86-64 or ARMv7 (the latter was dropped by decision).

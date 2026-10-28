# Changelog

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

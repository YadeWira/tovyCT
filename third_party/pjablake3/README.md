# pjablake3: BLAKE3-128 in Pascal (from PJA)

From https://github.com/YadeWira/PJA, commit 542504b, MIT (LICENSE).

- `pjablake3.pas`: BLAKE3 (the hash only, no keyed mode or key derivation),
  output truncated to 16 bytes. `Blake3_128(const a: TBytes): THash16`, a
  variant hashing two ranges one after the other, and the incremental
  `TBlake3` record (`Init`, `Update(const data; len)`, `Final`).
- `pja.inc`: the only thing the unit needs from PJA: `{$mode objfpc}`,
  `{$H+}`, `{$R+}`, `{$Q+}`. The unit refuses to compile without range
  and overflow checks.
- `tests/test_blake3.pas` and `tests/kat.txt`: the official implementation's
  vectors (sizes 0 to 1 MiB, across the 64-byte block and 1 KiB chunk
  boundaries); every size whole, split in two ranges, and fed in pieces.

```sh
cd tests && fpc -O2 -Fu.. -Fi.. test_blake3.pas && ./test_blake3 kat.txt
```

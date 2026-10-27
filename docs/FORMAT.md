# tovyCT stream format v4

Status: **version 4**, the current format, still experimental: it may change
again before a release, and there is no backward compatibility with v1-v3 (the
decoder rejects any other version byte).

Fixed-size integers are little-endian. A **varint** is unsigned LEB128: seven
bits per byte, least significant group first, the high bit set on every byte
but the last. A stream is a stream header, zero or more blocks, and, when the
digest flag is set, an end marker and a digest. Nothing else: no padding, no
trailing bytes. Blocks are independent, so they can be compressed and
decompressed in parallel, and the compressed bytes do not depend on the number
of threads.

## Stream header (7 to 16 bytes)

| size | field |
|---|---|
| 4 | magic `T V C T` |
| 1 | version, `4` |
| 1 | block log: log2 of the block size, 16..26 (64 KiB..64 MiB) |
| 1 | flags: bit 0 = total size present, bit 1 = digest at the end; other bits 0 |
| varint | total uncompressed size, only when flag bit 0 is set (at most 9 bytes, < 2^63) |

The block log is a maximum: the last block is shorter. A stream of zero bytes
is a header with total 0 and no blocks.

Writers set the total whenever the source size is known. It lets the decoder
reject a stream that ends early and lets `tvct i` report the original size
without decoding. Readers must accept a stream without it and then rely on the
block sizes.

## Block

| size | field |
|---|---|
| varint | original size of the block, 1..block size (at most 5 bytes) |
| 1 | method |
| varint | body size, at most 5 bytes |
| 4 | CRC-32C of the original bytes, seeded with the block index (see below) |
| 4 | CRC-32C of the body; **only for compressed methods** |
| body size | body |

The **method** byte:

| bits | meaning |
|---|---|
| 0-1 | coder: `0` stored, `1` BWT + QLFC static, `2` BWT + QLFC adaptive; `3` is invalid |
| 2 | sample rows present |
| 3 | text transform applied before the BWT |
| 4-7 | 0 |

A stored block (coder 0) has no flags, its body is the original bytes, its body
size equals its original size, and it has no body CRC: the block CRC already
covers the same bytes. The encoder stores a block when the compressed body plus
its CRC would not be smaller.

### Compressed body (coders 1 and 2)

| size | field |
|---|---|
| varint | BWT size `T`, **only with the text flag**: 1..original size - 1. Without it, `T` is the original size |
| varint | primary index, 0..`T` |
| 4 × `ceil(T / 4096)` | sample rows (u32), only with the samples flag |
| rest of the body | QLFC payload, at least one byte |

- **Primary index** is the BWT row of the rotation that starts at position 0.
- **Sample rows.** `samples[k]` is the LF-mapping row, in the sentinel-extended
  BWT, from which to start reconstructing the chunk that ends at output
  position `min((k + 1) * 4096, T) - 1`. The last row is 0: the final chunk ends
  at the sentinel row. The encoder takes them from libsais's auxiliary-index
  API (`libsais_bwt_aux`, sampling rate 4096); the portable path computes the
  same rows from the suffix array. They let the decoder walk up to eight chains
  at once (`src/c/tvct_kernels.c`); a decoder that ignores them can still invert
  the BWT serially from the primary index.
- **Payload** is the QLFC (quantized local frequency coding) stream produced by
  libbsc's `bsc_coder_compress` with the static (coder 1) or adaptive (coder 2)
  coder over the `T`-byte BWT. Its internal framing is libbsc's; a decoder must
  pass the payload length and `T` to the coder so it can bound its reads and
  writes (`bsc_coder_decompress_bounded`).

The BWT is the cyclic block transform over the `T` bytes, inverted with the
usual LF walk and the sentinel row. Without the text flag its output is the
block; with it, its output is a transformed block, described next, that decodes
to exactly the original size.

## Text transform

A reversible rewrite of a block, applied before the BWT, that folds capitals
and replaces frequent words by short codes. `src/c/tvct_text.c` implements both
directions. A **letter** is an ASCII letter, `A-Z` or `a-z`; a **word** is a
maximal run of letters.

Layout of the transformed block:

| size | field |
|---|---|
| 1 | flags: bit 0 = CAPS, bit 1 = DICT, bit 2 = ESC; other bits 0 |
| 1 | ESC byte, only with the ESC flag |
| 1 | `R`, the number of reserved bytes |
| `R` | the reserved bytes: distinct, never letters, never the ESC byte |
| 1 | `n1`, number of one-byte codes, only with DICT |
| 1 | `n2`, number of two-byte code prefixes, only with DICT |
| varint | `W`, number of dictionary words, only with DICT: 1..`n1 + 256 × n2` |
| | `W` words, each 1..64 lowercase letters followed by a zero byte |
| rest | body |

With CAPS, the first two reserved bytes are **CAP** and **UPPER**, and the
others are the **code bytes**; without CAPS every reserved byte is a code byte.
`n1 + n2` must not exceed the number of code bytes. Code byte `i` with
`i < n1` stands for word `i`; code byte `n1 + j` (`j < n2`) is a prefix: with
the byte `b` that follows it, it stands for word `n1 + 256 × j + b`. Code bytes
past `n1 + n2` are unused and invalid in the body.

The body decodes from left to right:

- **ESC** followed by any byte: that byte, literally.
- **CAP** or **UPPER** followed by a code: the word, with its first letter
  (CAP) or all its letters (UPPER) in upper case. Followed by letters: the run
  of letters up to the next non-letter, cased the same way. Anything else after
  them is invalid.
- A code (one byte, or a prefix and its index): the word, in lower case.
- Any other byte: itself.

The output must be exactly the block's original size, and a word index must be
below `W`. A decoder must reject every violation of the rules above.

How the encoder chooses (not part of the format, but the reference behaviour):
reserved bytes are the non-letter bytes absent from the block, highest first;
when fewer than 34 are free, the rarest non-letter bytes are reserved instead,
the rarest of all becomes ESC, and the transform is skipped if the escapes
would cover more than 1 % of the block. Words of 2 to 32 letters, entirely
lower case, Capitalised or UPPER, are counted; a word enters the dictionary if
it occurs at least `max(128, N / 65536)` times and saves more raw bytes than its
entry costs. Up to a quarter of the code bytes (at most 64) become two-byte
prefixes and the rest one-byte codes; the most valuable words take the one-byte
codes, and the others are grouped in tiers of 256 by value, sorted
alphabetically inside each tier.

When the encoder uses it (`-x auto`, the default): when the transformed block
is at most 90 % of the block, and, for blocks under 1 MiB, only if the
compressed block also comes out smaller than without it. Measured with 8 MiB
blocks: -1.5 % on English prose, -0.4 % on source code, -0.6 % on the 85 MB
text corpus, and no file of a mixed 111-file sample of text and documents comes
out larger.

## End of stream and digest

With flag bit 1 set, the last block is followed by a zero byte (a block cannot
have original size 0) and 16 bytes: the **BLAKE3-128** digest (the first 16
bytes of BLAKE3's output) of the whole original data, in order. The stream ends
right after it. Without the flag, the stream ends after the last block.

## CRC-32C

Standard CRC-32C (Castagnoli): reflected polynomial `0x82F63B78`, initial value
`0xFFFFFFFF`, final XOR `0xFFFFFFFF`.

The **block CRC** is the CRC-32C of the original bytes computed as a
continuation of the value `i`, the block's index in the stream (0 for the
first): in the usual `crc32c(previous, data)` interface, `crc32c(i, data)`.
For the first block that is the plain CRC; for the others it makes a reordered
or duplicated block fail even when its bytes are intact.

The **body CRC** covers every byte of a compressed body: the BWT size, the
primary index, the sample rows and the payload. It is checked **before**
anything is decoded, and the block CRC **after**; neither replaces the other.
The body CRC keeps random corruption away from the decoders; the block CRC is
the one that proves the output.

## Validation rules

A decoder must fail cleanly (an error, no output) on any of these:

- magic or version mismatch, a block log outside 16..26, unknown flag bits;
- a declared total of 2^63 or more, or implausible for the input size: real
  data does not compress better than about 1000:1, so a stream whose declared
  total exceeds `remaining_input × 4096 + 1 MiB` is rejected before any buffer
  is allocated;
- a varint longer than its limit;
- a block whose original size is 0 (except as the end marker), larger than the
  block size or than the buffers the declared total allows; a body size of 0
  or larger than the block size can need;
- an invalid method byte, a stored block with flags or with a body size
  different from its original size;
- a block that would take the decoded total past the declared total, or a
  stream whose decoded total does not match it;
- a BWT size out of range, a primary index above `T`, a sample row above `T`, a
  body too short for its sample rows and one payload byte;
- either CRC mismatch, or a digest mismatch;
- with the digest flag: a missing end marker, a short digest, or any byte after
  it;
- any error from the entropy decoder or the text transform (each has its own
  bounds).

Because the total is checked at the end, every truncation of a stream with a
total fails, including a cut exactly at a block boundary.

## Limits

| item | limit |
|---|---|
| block size | 64 KiB .. 64 MiB (`block log` 16..26) |
| total size | 2^63 - 1 bytes |
| blocks per stream | no limit; the CRC seed is the index modulo 2^32 |
| body per block | what the block size can need; larger results are stored instead |
| samples | 0 (serial inverse) or one row per 4096 bytes of `T` |
| dictionary | at most 255 + 256 × 255 words of at most 64 letters |

## Version history

- **v4**: compact headers (varints; a 100-byte file costs 15 bytes instead of
  36), the text transform (method bit 3), the sample rows as a method flag,
  a body CRC that covers the whole body, block CRCs seeded with the block
  index, and an optional BLAKE3-128 digest of the whole data.
- **v3**: 16-byte stream header with a 64-bit total; 20-byte block headers with
  CRCs of the data and of the QLFC payload; a 16-byte BWT extension; methods 1
  and 2 (static and adaptive QLFC); optional sample rows.
- **v2**: BWT + QLFC with per-block CRC-32C and no total size.
- **v1**: an MTF + rANS coder from the research phase. Removed.

## Reference implementation

`src/tvct.codec.pas` writes and reads every field above, `src/c/tvct_text.c`
is the text transform, and `include/tvct.h` is the C API. All MIT licensed, as
is this document. The digest is computed by `third_party/pjablake3` (MIT).

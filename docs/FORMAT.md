# tovyCT stream format v3

Status: **version 3**, the current format. There is no backward compatibility
with v1/v2: the decoder rejects any other version byte.

All integers are little-endian. A stream is a 16-byte header followed by zero or
more blocks and nothing else; there is no trailer and no padding. Blocks are
independent, so they can be compressed and decompressed in parallel, and the
compressed bytes do not depend on the number of threads.

## Stream header (16 bytes)

| offset | size | field |
|---|---|---|
| 0 | 4 | magic `T V C T` |
| 4 | 1 | version, `3` |
| 5 | 1 | block log: log2 of the block size, 16..26 (64 KiB..64 MiB) |
| 6 | 1 | flags: bit 0 = total size is known |
| 7 | 1 | reserved, 0 |
| 8 | 8 | total uncompressed size (u64), 0 when flag bit 0 is clear |

The block log is a maximum: the last block is shorter, and a stream may contain
fewer blocks than the total suggests. A stream of zero bytes has a header with
total 0 and no blocks.

Writers set the total size whenever the source size is known. It lets the
decoder reject a stream that ends early and lets `tvct i` report the original
size without decoding. Readers must accept a stream with the flag clear (size
unknown), but must then rely on the block sizes.

## Block

Each block is a 20-byte header followed by its payload:

| offset | size | field |
|---|---|---|
| 0 | 4 | uncompressed size of this block (1..block size) |
| 4 | 4 | payload size |
| 8 | 4 | method: `0` = stored, `1` = BWT + QLFC |
| 12 | 4 | CRC-32C of the uncompressed block |
| 16 | 4 | CRC-32C of the payload bytes |

### Method 0, stored

The payload is the uncompressed data, so `payload size == uncompressed size`.
The payload CRC is therefore the CRC of the same bytes as the block CRC. The
encoder uses this method when the compressed form plus its headers would not be
smaller.

### Method 1, BWT + QLFC

The block header is followed by a 16-byte extension:

| offset | size | field |
|---|---|---|
| 0 | 4 | BWT size, equal to the uncompressed size |
| 4 | 4 | primary index, 0..BWT size |
| 8 | 4 | reserved, 0 |
| 12 | 4 | sample count |

Then `sample count` u32 sample rows, then the payload.

- **Sample count** is `ceil(BWT size / 4096)`. The decoder rejects any other
  value.
- **Samples.** `samples[k]` is the LF-mapping row, in the sentinel-extended BWT,
  from which to start reconstructing the chunk that ends at output position
  `min((k + 1) * 4096, N) - 1`. The last sample is 0: the final chunk ends at the
  sentinel row. The encoder takes them from libsais's auxiliary-index API
  (`libsais_bwt_aux` with a sampling rate of 4096); the portable path computes
  the same rows from the suffix array. A decoder that ignores the samples can
  still invert the BWT by walking the LF mapping from the primary index, only
  more slowly.
- **Primary index** is the BWT row of the rotation that starts at position 0.
- **Payload** is the QLFC (quantized local frequency coding) stream produced by
  libbsc's `bsc_coder_compress` with the static coder. Its internal framing is
  libbsc's; a decoder must pass the payload length to the coder so it can bound
  its reads (`bsc_coder_decompress_bounded`).

The BWT is the cyclic block transform over the whole block of `N` bytes. The
inverse is the usual LF walk with the sentinel row; `src/c/tvct_kernels.c`
implements it and walks up to 64 chains at once.

## CRC-32C

Both checksums are standard CRC-32C (Castagnoli): reflected polynomial
`0x82F63B78`, initial value `0xFFFFFFFF`, final XOR `0xFFFFFFFF`. The block CRC
covers the uncompressed bytes of the block; the payload CRC covers the bytes
stored after the block header (for method 1, only the QLFC payload, not the
BWT extension or the samples).

The payload CRC is checked **before** anything is decoded, and the block CRC
**after**; neither replaces the other. The payload CRC protects the entropy
decoder from random corruption; the block CRC is the one that proves the output.

## Validation rules

A decoder must fail cleanly (an error, no output) on any of these:

- magic or version mismatch;
- block log outside 16..26;
- a declared total that is negative (bit 63 set) or implausible for the input
  size: real data does not compress better than about 1000:1, so a stream whose
  declared total exceeds `input_size * 4096 + 1 MiB` is rejected before any
  buffer is allocated;
- a block whose uncompressed or payload size exceeds the buffers implied by the
  block size or the remaining declared total, or a zero size;
- a block that would take the decoded total past the declared total, or a stream
  whose decoded total does not match it;
- sample count inconsistent with the BWT size, a sample row or primary index out
  of range;
- either CRC mismatch;
- any error from the entropy decoder (it has its own bounds).

Because the total is checked at the end, every truncation of a stream fails,
including a cut exactly at a block boundary.

## Limits

| item | limit |
|---|---|
| block size | 64 KiB .. 64 MiB (`block log` 16..26) |
| total size | 2^63 - 1 bytes |
| blocks per stream | derived from the total, no separate field |
| payload per block | block size at most; larger payloads are stored instead |

## Version history

- **v3**: the stream header carries the total uncompressed size (8 bytes) and a
  flag for unknown sizes, so a truncated stream is detected instead of being
  accepted as a shorter valid one. The header grew from 8 to 16 bytes.
- **v2**: BWT + QLFC with per-block CRC-32C and no total size. Rejected by v3
  decoders.
- **v1**: an MTF + rANS coder from the research phase. Removed.

## Reference implementation

`src/tvct.codec.pas` writes and reads every field above; `include/tvct.h` is the
C API. Both are MIT licensed, as is this document.

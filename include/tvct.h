/* tovyCT - C API.
 *
 * BWT + QLFC, with an optional text transform. Every call is self-contained;
 * blocks are independent. Stream format v4 (docs/FORMAT.md).
 *
 * Build: scripts/build.sh --libsais   -> build/libtvct.so, build/tvct.h
 */
#ifndef TVCT_H
#define TVCT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Version string, static storage. */
const char *tvct_version(void);

/* Worst-case compressed size for src_size bytes. */
size_t tvct_compress_bound(size_t src_size);

/* Uncompressed size of a tovyCT stream, read from the headers without decoding.
 * Returns -1 if the stream is not valid. */
int64_t tvct_get_size(const void *src, size_t src_size);

/* Compresses src_size bytes into dst.
 *
 * threads:   number of worker threads; <= 0 picks one per CPU up to 8.
 * block_log: log2 of the block size; <= 0 uses 23 (8 MiB).
 *
 * Returns the compressed size, or -1 if dst_cap is too small or on error. */
int64_t tvct_compress(const void *src, size_t src_size,
                      void *dst, size_t dst_cap,
                      int threads, int block_log);

/* Same, choosing the QLFC coder: 1 = static (default), 2 = adaptive.
 * Adaptive is about 1-2 % smaller and slower. Other values fail with -1.
 * no_samples: 1 omits the sample rows, which is ~0.1 % smaller and decodes
 * serially (slower) but compresses faster. 0 keeps them. */
int64_t tvct_compress_ex(const void *src, size_t src_size,
                         void *dst, size_t dst_cap,
                         int threads, int block_log, int coder, int no_samples);

/* Same, also choosing the text transform and the digest.
 * text:   0 = off, 1 = when it removes a tenth of the block (default),
 *         2 = compress both ways and keep the smaller (twice the time).
 * digest: 1 ends the stream with a BLAKE3-128 digest of the whole input,
 *         checked on decompression. 0 relies on the per-block CRC-32C.
 * Other values fail with -1. */
int64_t tvct_compress2(const void *src, size_t src_size,
                       void *dst, size_t dst_cap,
                       int threads, int block_log, int coder, int no_samples,
                       int text, int digest);

/* Decompresses a stream into dst. threads as above. Returns the number of
 * bytes written, or -1 on a corrupt stream or if dst_cap is too small. */
int64_t tvct_decompress(const void *src, size_t src_size,
                        void *dst, size_t dst_cap, int threads);

#ifdef __cplusplus
}
#endif

#endif /* TVCT_H */

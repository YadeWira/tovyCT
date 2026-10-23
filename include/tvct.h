/* tovyCT - C API.
 *
 * Single mode: BWT + QLFC. Every call is self-contained; blocks are independent.
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

/* Decompresses a stream into dst. threads as above. Returns the number of
 * bytes written, or -1 on a corrupt stream or if dst_cap is too small. */
int64_t tvct_decompress(const void *src, size_t src_size,
                        void *dst, size_t dst_cap, int threads);

#ifdef __cplusplus
}
#endif

#endif /* TVCT_H */

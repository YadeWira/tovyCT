/* Exercise the shared library through its C ABI. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "tvct.h"

static int failures = 0;

static void check(int cond, const char *what)
{
    if (!cond) { fprintf(stderr, "FAIL: %s\n", what); failures++; }
}

static double now_sec(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

/* Compresses with tvct_compress2, checks the round trip and returns the
   compressed size (or -1). The digest case is kept in out_digest/out_len so
   the caller can tamper with it. */
static int64_t roundtrip(const unsigned char *src, long n, unsigned char *dst,
                         size_t cap, int coder, int no_samples, int text,
                         int digest, const char *label, unsigned char **digest_buf,
                         int64_t *digest_len)
{
    unsigned char *out = malloc((size_t)n);
    int64_t c, size, d;

    c = tvct_compress2(src, (size_t)n, dst, cap, 0, 0, coder, no_samples,
                       text, digest);
    if (c <= 0 || (size_t)c > cap)
    {
        fprintf(stderr, "FAIL: %s: compress returned %lld\n", label, (long long)c);
        failures++;
        free(out);
        return -1;
    }
    size = tvct_get_size(dst, (size_t)c);
    if (size != n)
    {
        fprintf(stderr, "FAIL: %s: get_size %lld, expected %ld\n", label,
                (long long)size, n);
        failures++;
    }
    d = tvct_decompress(dst, (size_t)c, out, (size_t)n, 0);
    if (d != n || memcmp(src, out, (size_t)n) != 0)
    {
        fprintf(stderr, "FAIL: %s: round trip returned %lld\n", label,
                (long long)d);
        failures++;
    }
    if (digest && digest_buf)
    {
        *digest_buf = malloc((size_t)c);
        if (*digest_buf) memcpy(*digest_buf, dst, (size_t)c);
        *digest_len = c;
    }
    free(out);
    return c;
}

int main(int argc, char **argv)
{
    FILE *f;
    long n;
    unsigned char *src, *dst, *out, *digest_buf = NULL;
    size_t cap;
    int64_t c, size, d, digest_len = 0;
    double t0, t1;

    if (argc < 2) { fprintf(stderr, "usage: %s file\n", argv[0]); return 1; }
    f = fopen(argv[1], "rb");
    if (!f) { perror(argv[1]); return 1; }
    fseek(f, 0, SEEK_END); n = ftell(f); fseek(f, 0, SEEK_SET);
    src = malloc((size_t)n);
    if (fread(src, 1, (size_t)n, f) != (size_t)n) return 1;
    fclose(f);

    cap = tvct_compress_bound((size_t)n);
    dst = malloc(cap);
    out = malloc((size_t)n);

    t0 = now_sec();
    c = tvct_compress(src, (size_t)n, dst, cap, 0, 0);
    t1 = now_sec();
    if (c < 0) { fprintf(stderr, "compress failed\n"); return 1; }
    printf("%s: %ld -> %lld bytes (%.2f%%), %.1f MB/s (threads=auto)\n",
           argv[1], n, (long long)c, 100.0 * c / (double)n, n / 1e6 / (t1 - t0));

    size = tvct_get_size(dst, (size_t)c);
    if (size != n) { fprintf(stderr, "get_size=%lld, expected %ld\n", (long long)size, n); return 1; }

    t0 = now_sec();
    d = tvct_decompress(dst, (size_t)c, out, (size_t)n, 0);
    t1 = now_sec();
    if (d != n || memcmp(src, out, (size_t)n) != 0) { fprintf(stderr, "round-trip failed\n"); return 1; }
    printf("  round-trip ok, %.1f MB/s decompress, version %s\n",
           n / 1e6 / (t1 - t0), tvct_version());

    /* The old entry points keep the default behaviour. */
    {
        int64_t c2 = tvct_compress_ex(src, (size_t)n, dst, cap, 0, 0, 1, 0);
        check(c2 > 0 && c2 == c, "tvct_compress_ex matches tvct_compress");
    }

    /* Every combination of text transform, digest, sample rows and coder. */
    roundtrip(src, n, dst, cap, 1, 0, 0, 0, "static, text off", NULL, NULL);
    roundtrip(src, n, dst, cap, 1, 0, 1, 0, "static, text auto", NULL, NULL);
    roundtrip(src, n, dst, cap, 1, 0, 2, 0, "static, text best", NULL, NULL);
    roundtrip(src, n, dst, cap, 1, 0, 1, 1, "static, text auto, digest",
              &digest_buf, &digest_len);
    roundtrip(src, n, dst, cap, 1, 1, 1, 0, "static, no samples", NULL, NULL);
    roundtrip(src, n, dst, cap, 2, 1, 1, 1, "adaptive, no samples, digest",
              NULL, NULL);

    /* Invalid options must fail before writing anything. */
    check(tvct_compress2(src, (size_t)n, dst, cap, 0, 0, 1, 0, 3, 0) < 0,
          "text mode 3 rejected");
    check(tvct_compress2(src, (size_t)n, dst, cap, 0, 0, 1, 0, -1, 0) < 0,
          "negative text mode rejected");
    check(tvct_compress2(src, (size_t)n, dst, cap, 0, 0, 3, 0, 1, 0) < 0,
          "coder 3 rejected");
    check(tvct_compress2(src, (size_t)n, dst, cap, 0, 0, 0, 0, 1, 0) < 0,
          "coder 0 rejected");

    /* A tampered or truncated digest is a damaged stream. */
    if (digest_buf && digest_len > 0)
    {
        digest_buf[digest_len - 1] ^= 1;
        check(tvct_decompress(digest_buf, (size_t)digest_len, out, (size_t)n, 0) < 0,
              "tampered digest rejected");
        digest_buf[digest_len - 1] ^= 1;
        check(tvct_decompress(digest_buf, (size_t)(digest_len - 1), out, (size_t)n, 0) < 0,
              "truncated digest rejected");
        check(tvct_get_size(digest_buf, (size_t)digest_len) == n,
              "get_size on a digest stream");
        free(digest_buf);
    }

    /* A short destination must fail cleanly. */
    d = tvct_decompress(dst, (size_t)c, out, (size_t)n / 2, 0);
    check(d < 0, "short buffer rejected");

    free(out); free(dst); free(src);
    if (failures == 0) printf("  API checks: all ok\n");
    return failures ? 1 : 0;
}

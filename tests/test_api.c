/* Exercise the shared library through its C ABI. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "tvct.h"

static double now_sec(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

int main(int argc, char **argv)
{
    FILE *f;
    long n;
    unsigned char *src, *dst, *out;
    size_t cap;
    int64_t c, size, d;
    double t0, t1;

    if (argc < 2) { fprintf(stderr, "usage: %s file\n", argv[0]); return 1; }
    f = fopen(argv[1], "rb");
    fseek(f, 0, SEEK_END); n = ftell(f); fseek(f, 0, SEEK_SET);
    src = malloc(n);
    if (fread(src, 1, n, f) != (size_t)n) return 1;
    fclose(f);

    cap = tvct_compress_bound(n);
    dst = malloc(cap);

    t0 = now_sec();
    c = tvct_compress(src, n, dst, cap, 0, 0);
    t1 = now_sec();
    if (c < 0) { fprintf(stderr, "compress failed\n"); return 1; }
    printf("%s: %ld -> %lld bytes (%.2f%%), %.1f MB/s (threads=auto)\n",
           argv[1], n, (long long)c, 100.0 * c / n, n / 1e6 / (t1 - t0));

    size = tvct_get_size(dst, c);
    if (size != n) { fprintf(stderr, "get_size=%lld, expected %ld\n", (long long)size, n); return 1; }

    out = malloc(size);
    t0 = now_sec();
    d = tvct_decompress(dst, c, out, size, 0);
    t1 = now_sec();
    if (d != n || memcmp(src, out, n) != 0) { fprintf(stderr, "round-trip failed\n"); return 1; }
    printf("  round-trip ok, %.1f MB/s decompress, version %s\n",
           n / 1e6 / (t1 - t0), tvct_version());

    /* A short destination must fail cleanly. */
    d = tvct_decompress(dst, c, out, size / 2, 0);
    printf("  short buffer rejected: %s\n", d < 0 ? "yes" : "NO");
    return 0;
}

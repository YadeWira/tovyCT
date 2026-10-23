/* Truncation and extension test for the decoder.
 *
 * For every prefix of a compressed stream, and for the stream with extra bytes
 * appended, the decoder must either fail cleanly or return exactly the original
 * prefix. A stream truncated at a block boundary is a valid shorter stream by
 * design (the format carries no total size), so a prefix of the original is the
 * strongest invariant that holds.
 *
 * Build: cc -O2 -Ibuild tests/test_truncate.c -Lbuild -ltvct \
 *            -Wl,-rpath,$PWD/build -o build/test_truncate
 * Run:   ./build/test_truncate file
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "tvct.h"

int main(int argc, char **argv)
{
    FILE *f;
    long n, i;
    unsigned char *src, *comp, *out;
    size_t cap;
    int64_t c, r, got;
    long bad = 0, ok = 0, err = 0;

    if (argc < 2) { fprintf(stderr, "usage: %s file\n", argv[0]); return 1; }
    f = fopen(argv[1], "rb");
    if (!f) { perror(argv[1]); return 1; }
    fseek(f, 0, SEEK_END); n = ftell(f); fseek(f, 0, SEEK_SET);
    src = malloc(n);
    if (fread(src, 1, n, f) != (size_t)n) return 1;
    fclose(f);

    cap = tvct_compress_bound(n);
    comp = malloc(cap);
    c = tvct_compress(src, n, comp, cap, 1, 16);   /* 64 KiB blocks */
    if (c <= 0) { fprintf(stderr, "compress failed\n"); return 1; }
    printf("input %ld, compressed %lld\n", n, (long long)c);

    out = malloc(n);

    /* Every prefix. */
    for (i = 0; i <= c; i++)
    {
        got = tvct_decompress(comp, (size_t)i, out, n, 1);
        if (got < 0)
            err++;
        else if (got > n || memcmp(out, src, (size_t)got) != 0)
        {
            bad++;
            if (bad < 5)
                fprintf(stderr, "prefix %ld: returned %lld bytes that do not match\n",
                        i, (long long)got);
        }
        else
            ok++;
    }
    printf("prefixes: %ld clean errors, %ld matching prefixes, %ld wrong\n", err, ok, bad);

    /* Extra bytes appended. */
    {
        unsigned char *ext = malloc(c + 64);
        memcpy(ext, comp, c);
        for (i = 1; i <= 64; i++)
        {
            ext[c + i - 1] = (unsigned char)(i * 37);
            got = tvct_decompress(ext, (size_t)(c + i), out, n, 1);
            if (got >= 0 && (got != n || memcmp(out, src, n) != 0))
            {
                bad++;
                fprintf(stderr, "trailing %ld bytes: accepted with %lld bytes\n",
                        i, (long long)got);
            }
        }
        free(ext);
    }
    printf("trailing bytes: done\n");

    /* Arbitrary byte flips must never yield wrong output. */
    {
        unsigned char *tmp = malloc(c);
        unsigned seed = 12345;
        for (i = 0; i < 2000; i++)
        {
            long pos;
            memcpy(tmp, comp, c);
            seed = seed * 1103515245u + 12345u; pos = (long)(seed % (unsigned)c);
            tmp[pos] ^= (unsigned char)(1u << ((seed >> 8) & 7));
            got = tvct_decompress(tmp, (size_t)c, out, n, 1);
            if (got >= 0 && (got != n || memcmp(out, src, n) != 0))
            {
                bad++;
                if (bad < 10)
                    fprintf(stderr, "flip at %ld: accepted wrong output (%lld bytes)\n",
                            pos, (long long)got);
            }
        }
        free(tmp);
    }
    printf("flips: done\n");

    free(out); free(comp); free(src);
    if (bad == 0) { printf("ALL OK\n"); return 0; }
    printf("%ld FAILURES\n", bad);
    return 1;
}

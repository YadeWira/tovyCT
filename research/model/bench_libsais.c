/* Reference only: libsais throughput on the same blocks. Not part of tovyCT. */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <time.h>
#include "libsais.h"

int main(int argc, char **argv)
{
    FILE *f = fopen(argv[1], "rb");
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t *d = malloc(n);
    int32_t *sa = malloc((n + 1) * 4);
    if (fread(d, 1, n, f) != (size_t)n) return 1;
    fclose(f);
    int sizes[] = {1 << 20, 4 << 20, 8 << 20, 16 << 20};
    for (int k = 0; k < 4; k++) {
        int B = sizes[k];
        if (B > n) continue;
        long off = 0;
        struct timespec a, b;
        clock_gettime(CLOCK_MONOTONIC, &a);
        while (off + B <= n) {
            libsais(d + off, sa, B, 0, NULL);
            off += B;
        }
        clock_gettime(CLOCK_MONOTONIC, &b);
        double s = (b.tv_sec - a.tv_sec) + (b.tv_nsec - a.tv_nsec) / 1e9;
        printf("  block %2d MB: %6.1f MB/s\n", B >> 20, off / 1e6 / s);
    }
    return 0;
}

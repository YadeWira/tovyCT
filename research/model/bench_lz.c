/* Bare matchfinder speed probe: hash chains, one lazy step, no price model,
 * no statistics. Gives the throughput ceiling the real encoder can approach. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>

static inline uint32_t h4(const uint8_t *p, int log)
{
    uint32_t v; memcpy(&v, p, 4);
    return (v * 2654435761u) >> (32 - log);
}

static inline size_t mlen(const uint8_t *a, const uint8_t *b, size_t max)
{
    size_t i = 0;
    while (i + 8 <= max) {
        uint64_t x, y; memcpy(&x, a + i, 8); memcpy(&y, b + i, 8);
        uint64_t d = x ^ y;
        if (d) return i + (size_t)(__builtin_ctzll(d) >> 3);
        i += 8;
    }
    while (i < max && a[i] == b[i]) i++;
    return i;
}

int main(int argc, char **argv)
{
    int depth = argc > 2 ? atoi(argv[2]) : 16;
    int lazy = argc > 3 ? atoi(argv[3]) : 1;
    FILE *f = fopen(argv[1], "rb");
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t *d = malloc(n);
    if (fread(d, 1, n, f) != (size_t)n) return 1;
    fclose(f);

    const int LOG = 21;
    uint32_t *head = calloc(1u << LOG, 4);
    uint32_t *prev = calloc(n, 4);

    clock_t t0 = clock();
    size_t pos = 0, nm = 0, nl = 0, matched = 0;
    while (pos < n) {
        size_t avail = n - pos, best = 0, bd = 0;
        if (avail >= 4) {
            uint32_t c = head[h4(d + pos, LOG)];
            int k = depth;
            while (c && k--) {
                size_t cp = c - 1;
                if (cp >= pos) break;
                if (best < avail && d[cp + best] != d[pos + best]) { c = prev[cp]; continue; }
                size_t l = mlen(d + pos, d + cp, avail);
                if (l > best) { best = l; bd = pos - cp; if (l >= 128) break; }
                c = prev[cp];
            }
        }
        if (pos + 4 <= n) { uint32_t h = h4(d + pos, LOG); prev[pos] = head[h]; head[h] = pos + 1; }

        if (lazy && best >= 4 && pos + 1 < n) {
            size_t best2 = 0;
            uint32_t c = head[h4(d + pos + 1, LOG)];
            int k = depth;
            while (c && k--) {
                size_t cp = c - 1;
                if (cp > pos + 1) break;
                size_t l = mlen(d + pos + 1, d + cp, n - pos - 1);
                if (l > best2) { best2 = l; if (l >= 128) break; }
                c = prev[cp];
            }
            if (best2 > best + 1) best = 0;
        }

        if (best < 4) {
            nl++; pos++;
        } else {
            nm++; matched += best;
            for (size_t i = 1; i < best; i++)
                if (pos + i + 4 <= n) { uint32_t h = h4(d + pos + i, LOG); prev[pos + i] = head[h]; head[h] = pos + i + 1; }
            pos += best;
        }
    }
    double s = (double)(clock() - t0) / CLOCKS_PER_SEC;
    printf("depth %d lazy %d: %.1f MB/s  matches %zu (avg %.1f) literals %.1f%%\n",
           depth, lazy, n / 1e6 / s, nm, nm ? (double)matched / nm : 0,
           100.0 * nl / n);
    return 0;
}

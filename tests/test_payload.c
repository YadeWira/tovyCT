/* Payload mutation test through the public API.
 *
 * The libFuzzer target (tests/fuzz_qlfc.c) attacks the entropy decoder with
 * arbitrary bytes, but a random byte stream almost never gets past QLFC's own
 * framing. This test keeps the container valid: it flips bits only inside a
 * real QLFC payload and recomputes that block's payload CRC, so the mutated
 * stream reaches the entropy decoder exactly like a hostile file would.
 *
 * Invariant: the decoder returns an error or exactly the original file. No
 * crash, no partial output. Run it under valgrind or a sanitizer build for the
 * memory checks; the buffers here are exactly the declared sizes.
 *
 * Build: cc -O2 -Ibuild tests/test_payload.c -Lbuild -ltvct \
 *            -Wl,-rpath,$PWD/build -o build/test_payload
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include "tvct.h"

static uint32_t table[256];

static void crc_init(void)
{
    for (uint32_t i = 0; i < 256; i++)
    {
        uint32_t c = i;
        for (int k = 0; k < 8; k++)
            c = (c & 1) ? (c >> 1) ^ 0x82F63B78u : c >> 1;
        table[i] = c;
    }
}

static uint32_t crc32c(uint32_t crc, const unsigned char *p, size_t n)
{
    crc = ~crc;
    while (n--)
        crc = table[(crc ^ *p++) & 0xFF] ^ (crc >> 8);
    return ~crc;
}

static uint32_t rd32(const unsigned char *p)
{
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 |
           (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

static void wr32(unsigned char *p, uint32_t v)
{
    p[0] = (unsigned char)v; p[1] = (unsigned char)(v >> 8);
    p[2] = (unsigned char)(v >> 16); p[3] = (unsigned char)(v >> 24);
}

static unsigned char *slurp(const char *path, long *len)
{
    FILE *f = fopen(path, "rb");
    unsigned char *p;
    long n;

    if (!f) { perror(path); exit(2); }
    fseek(f, 0, SEEK_END); n = ftell(f); fseek(f, 0, SEEK_SET);
    p = malloc((size_t)n);
    if (!p || fread(p, 1, (size_t)n, f) != (size_t)n) { perror(path); exit(2); }
    fclose(f);
    *len = n;
    return p;
}

int main(int argc, char **argv)
{
    unsigned char *comp, *orig, *buf, *out;
    long complen, origlen;
    uint64_t total;
    size_t off, poff = 0, plen = 0;
    size_t pcrc_off = 0;
    int iterations = 1500, bad = 0;
    unsigned seed = 0x12345678;
    int64_t r;

    if (argc < 3)
    {
        fprintf(stderr, "usage: %s file.tvct original\n", argv[0]);
        return 2;
    }
    crc_init();
    comp = slurp(argv[1], &complen);
    orig = slurp(argv[2], &origlen);

    /* Walk the blocks and pick the first compressed (BWT) one. */
    off = 16;
    while (off + 20 <= (size_t)complen)
    {
        uint32_t payload = rd32(comp + off + 4);
        uint32_t method = rd32(comp + off + 8);
        size_t body;

        if (method == 0)
            body = off + 20;
        else if (method == 1 || method == 2)
        {
            uint32_t nsamples = rd32(comp + off + 32);
            body = off + 20 + 16 + (size_t)nsamples * 4;
        }
        else
            break;

        if ((method == 1 || method == 2) && payload > 0 &&
            body + payload <= (size_t)complen)
        {
            poff = body; plen = payload; pcrc_off = off + 16;
            break;
        }
        off = body + payload;
    }
    if (poff == 0)
    {
        fprintf(stderr, "no compressed block in %s\n", argv[1]);
        return 2;
    }

    total = 0;
    if (comp[6] & 1)
        for (int i = 7; i >= 0; i--)
            total = (total << 8) | comp[8 + i];
    if (total != (uint64_t)origlen)
    {
        fprintf(stderr, "total %llu != original %ld\n", (unsigned long long)total, origlen);
        return 2;
    }

    /* Baseline: the unmodified stream must round-trip. */
    out = malloc((size_t)total);
    buf = malloc((size_t)complen);
    if (!out || !buf) return 2;
    r = tvct_decompress(comp, (size_t)complen, out, (size_t)total, 1);
    if (r != (int64_t)total || memcmp(out, orig, (size_t)total) != 0)
    {
        fprintf(stderr, "baseline decode failed (%lld)\n", (long long)r);
        return 1;
    }

    for (int it = 0; it < iterations; it++)
    {
        int flips = 1 + (int)(seed % 4);
        memcpy(buf, comp, (size_t)complen);
        for (int k = 0; k < flips; k++)
        {
            seed = seed * 1103515245u + 12345u;
            buf[poff + seed % plen] ^= (unsigned char)(1u << ((seed >> 8) & 7));
        }
        wr32(buf + pcrc_off, crc32c(0, buf + poff, plen));

        r = tvct_decompress(buf, (size_t)complen, out, (size_t)total, 1);
        if (r >= 0 && (r != (int64_t)total || memcmp(out, orig, (size_t)total) != 0))
        {
            fprintf(stderr, "iteration %d: accepted wrong output (%lld bytes)\n",
                    it, (long long)r);
            bad++;
        }
    }

    printf("payload mutations: %d iterations, %d wrong outputs\n", iterations, bad);
    free(out); free(buf); free(comp); free(orig);
    return bad ? 1 : 0;
}

/* Hostile-header test.
 *
 * A stream header is attacker-controlled: the total size, the block size and
 * each block's declared output are all just numbers. This checks that a
 * fabricated header cannot make the decoder reserve unreasonable memory, walk
 * past its buffers or return output, before any real block is decoded.
 *
 * The bound is derived from the compressed size itself: nothing compresses
 * better than ~1000:1 (16 MiB of zeros is 997:1), so a declared total far
 * above 4096:1 plus 1 MiB is corruption, not data.
 *
 * Build: cc -O2 -Ibuild tests/test_hostile.c -Lbuild -ltvct \
 *            -Wl,-rpath,$PWD/build -o build/test_hostile
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <sys/resource.h>
#include "tvct.h"

static size_t putvar(unsigned char *p, uint64_t v)
{
    size_t n = 0;
    while (v >= 0x80) { p[n++] = (unsigned char)(v | 0x80); v >>= 7; }
    p[n++] = (unsigned char)v;
    return n;
}

static void put32(unsigned char *p, uint32_t v) { memcpy(p, &v, 4); }

/* Format v4 stream header; returns its length. */
static size_t header(unsigned char *p, int blocklog, int known, uint64_t total)
{
    memcpy(p, "TVCT", 4);
    p[4] = 4;                       /* version */
    p[5] = (unsigned char)blocklog;
    p[6] = (unsigned char)(known ? 1 : 0);
    return known ? 7 + putvar(p + 7, total) : 7;
}

/* Block header: orig, method, body size, crc and, for compressed methods, a
   body crc. Returns its length. */
static size_t block(unsigned char *p, uint64_t orig, int method, uint64_t body,
                    uint32_t crc, uint32_t body_crc)
{
    size_t n = putvar(p, orig);
    p[n++] = (unsigned char)method;
    n += putvar(p + n, body);
    put32(p + n, crc);
    n += 4;
    if (method != 0)
    {
        put32(p + n, body_crc);
        n += 4;
    }
    return n;
}

static uint32_t crc32c(const unsigned char *p, size_t n)
{
    uint32_t crc = 0xFFFFFFFFu;
    while (n--)
    {
        crc ^= *p++;
        for (int k = 0; k < 8; k++)
            crc = (crc & 1) ? (crc >> 1) ^ 0x82F63B78u : crc >> 1;
    }
    return ~crc;
}

static int decode(const unsigned char *in, size_t n, int threads)
{
    static unsigned char out[1 << 20];
    return (int)tvct_decompress(in, n, out, sizeof out, threads);
}

static int failures;

static void expect_reject(const char *what, const unsigned char *in, size_t n)
{
    int t;
    for (t = 1; t <= 4; t *= 4)
        if (decode(in, n, t) >= 0)
        {
            printf("FAIL: %s accepted (threads=%d)\n", what, t);
            failures++;
        }
}

int main(void)
{
    static unsigned char in[1 << 15];
    struct rusage a, b;
    long rss_kb;

    getrusage(RUSAGE_SELF, &a);

    size_t h, n;

    /* 1. A header on its own that claims 2^62 bytes. */
    h = header(in, 26, 1, 0x3FFFFFFFFFFFFFFFULL);
    expect_reject("2^62 total", in, h);

    /* 2. A plausible total with no blocks at all. */
    h = header(in, 26, 1, 1u << 20);
    expect_reject("empty stream with a total", in, h);

    /* 3. No total, and a block claiming 64 MiB. */
    memset(in, 0, sizeof in);
    h = header(in, 26, 0, 0);
    n = h + block(in + h, 64u << 20, 0, 64u << 20, 0, 0);
    expect_reject("ferocious block, unknown total", in, n + 32);

    /* 4. Pinned total of 4 KiB, block claiming 8 KiB with 8 KiB of payload:
       enough to overflow an output buffer sized from the total. */
    memset(in, 0, sizeof in);
    h = header(in, 26, 1, 4096);
    n = h + block(in + h, 8192, 0, 8192, 0, 0);
    expect_reject("block larger than the stream", in, n + 8192);

    /* 5. A stored block with a bad CRC. */
    memset(in, 'A', sizeof in);
    h = header(in, 16, 1, 16);
    n = h + block(in + h, 16, 0, 16, 0xDEADBEEF, 0);
    expect_reject("bad stored crc", in, n + 16);

    /* 6. Method bytes the format does not define: coder 3, flags on a stored
       block, unknown flag bits. The body CRC is valid, so only the method
       check stands in the way. */
    {
        static const int bad[] = { 3, 0x04, 0x08, 0x10, 0x81, 0x41 };
        for (size_t k = 0; k < sizeof bad / sizeof bad[0]; k++)
        {
            memset(in, 0, sizeof in);
            h = header(in, 16, 1, 64);
            n = h + block(in + h, 64, bad[k], 16, 0, crc32c(in + 4096, 16));
            expect_reject("undefined method byte", in, n + 16);
        }
    }

    /* 7. A text block whose BWT size is not smaller than the block, and one
       whose primary index is past the BWT: rejected before any decoding. */
    {
        unsigned char body[16];
        size_t b = putvar(body, 64);          /* bwt size == orig: invalid */
        b += putvar(body + b, 0);
        memset(body + b, 0x55, sizeof body - b);
        h = header(in, 16, 1, 64);
        n = h + block(in + h, 64, 1 | 8, sizeof body, 0, crc32c(body, sizeof body));
        memcpy(in + n, body, sizeof body);
        expect_reject("text block with bwt size >= block", in, n + sizeof body);

        b = putvar(body, 40);
        b += putvar(body + b, 41);            /* primary > bwt size */
        memset(body + b, 0x55, sizeof body - b);
        n = h + block(in + h, 64, 1 | 8, sizeof body, 0, crc32c(body, sizeof body));
        memcpy(in + n, body, sizeof body);
        expect_reject("primary past the BWT", in, n + sizeof body);
    }

    /* 8. Two stored blocks of the same size, swapped. Every CRC is still the
       CRC of its own bytes; only the block index in the seed tells them
       apart. */
    {
        static unsigned char src[2 << 16], comp[(2 << 16) + 1024], out[2 << 16];
        static unsigned char swapped[(2 << 16) + 1024];
        unsigned s = 12345;
        int64_t c;
        size_t L;
        for (size_t k = 0; k < sizeof src; k++)
        {
            s = s * 1103515245u + 12345u;
            src[k] = (unsigned char)(s >> 16);
        }
        c = tvct_compress(src, sizeof src, comp, sizeof comp, 1, 16);
        h = header(in, 16, 1, sizeof src);
        L = (size_t)(c - (int64_t)h) / 2;
        if (c <= 0 || (size_t)c != h + 2 * L)
        {
            printf("FAIL: expected two equal stored blocks\n");
            failures++;
        }
        else
        {
            memcpy(swapped, comp, h);
            memcpy(swapped + h, comp + h + L, L);
            memcpy(swapped + h + L, comp + h, L);
            if (tvct_decompress(swapped, (size_t)c, out, sizeof out, 1) >= 0 ||
                tvct_decompress(swapped, (size_t)c, out, sizeof out, 2) >= 0)
            {
                printf("FAIL: swapped blocks accepted\n");
                failures++;
            }
        }

        /* 9. The same data with a digest: intact it decodes, with one bit of
           the digest flipped or a byte appended it does not. */
        c = tvct_compress2(src, 4096, comp, sizeof comp, 1, 16, 1, 0, 1, 1);
        if (c <= 0 || tvct_decompress(comp, (size_t)c, out, sizeof out, 1) != 4096)
        {
            printf("FAIL: digest stream did not round-trip\n");
            failures++;
        }
        else
        {
            comp[c - 3] ^= 0x10;
            expect_reject("flipped digest", comp, (size_t)c);
            comp[c - 3] ^= 0x10;
            comp[c] = 0;
            expect_reject("byte after the digest", comp, (size_t)c + 1);
            expect_reject("digest cut short", comp, (size_t)c - 1);
        }
    }

    /* 10. A genuinely empty stream still decodes to zero bytes. */
    h = header(in, 26, 1, 0);
    if (decode(in, h, 1) != 0 || decode(in, h, 4) != 0)
    {
        printf("FAIL: empty stream did not decode\n");
        failures++;
    }

    getrusage(RUSAGE_SELF, &b);
#ifdef __linux__
    rss_kb = b.ru_maxrss - a.ru_maxrss;
#else
    rss_kb = (b.ru_maxrss - a.ru_maxrss) / 1024;   /* macOS reports bytes */
#endif
    printf("hostile headers: %d failures, peak rss +%ld KiB\n", failures, rss_kb);
    if (rss_kb > 64 * 1024)
    {
        printf("FAIL: %ld KiB of memory for a few-byte stream\n", rss_kb);
        failures++;
    }
    return failures ? 1 : 0;
}

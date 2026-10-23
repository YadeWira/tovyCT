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

static void put32(unsigned char *p, uint32_t v) { memcpy(p, &v, 4); }
static void put64(unsigned char *p, uint64_t v) { memcpy(p, &v, 8); }

static void header(unsigned char *p, int blocklog, int known, uint64_t total)
{
    memset(p, 0, 16);
    memcpy(p, "TVCT", 4);
    p[4] = 3;                       /* version */
    p[5] = (unsigned char)blocklog;
    p[6] = (unsigned char)(known ? 1 : 0);
    put64(p + 8, total);
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

    /* 1. A header on its own that claims 2^62 bytes. */
    header(in, 26, 1, 0x3FFFFFFFFFFFFFFFULL);
    expect_reject("2^62 total", in, 16);

    /* 2. A plausible total with no blocks at all. */
    header(in, 26, 1, 1u << 20);
    expect_reject("empty stream with a total", in, 16);

    /* 3. No total, and a block claiming 64 MiB. */
    memset(in, 0, sizeof in);
    header(in, 26, 0, 0);
    put32(in + 16, 64u << 20);
    put32(in + 20, 32);
    expect_reject("ferocious block, unknown total", in, 36);

    /* 4. Pinned total of 4 KiB, block claiming 8 KiB with 8 KiB of payload:
       enough to overflow an output buffer sized from the total. */
    memset(in, 0, sizeof in);
    header(in, 26, 1, 4096);
    put32(in + 16, 8192);
    put32(in + 20, 8192);
    in[24] = 0;                     /* raw */
    put32(in + 28 + 0, 0);          /* payload crc ignored: rejected earlier */
    expect_reject("block larger than the stream", in, 16 + 20 + 8192);

    /* 5. A block with a valid shape but a bad payload CRC. */
    memset(in, 0, sizeof in);
    header(in, 16, 1, 16);
    put32(in + 16, 16);
    put32(in + 20, 16);
    in[24] = 0;                     /* raw */
    put32(in + 32, 0xDEADBEEF);
    memset(in + 36, 'A', 16);
    expect_reject("bad payload crc", in, 36 + 16);

    /* 6. A genuinely empty stream still decodes to zero bytes. */
    header(in, 26, 1, 0);
    if (decode(in, 16, 1) != 0 || decode(in, 16, 4) != 0)
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

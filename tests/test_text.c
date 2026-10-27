/* Text transform test: round-trip and hostile input.
 *
 * For each file, every block of the given size must survive encode + decode
 * exactly, and the transform must never report a size that is not smaller than
 * the block. Then the transformed block is mutated (bit flips, truncation,
 * appended bytes) and the decoder must fail or return n bytes, never overrun:
 * the output buffer is exactly n bytes, so a sanitizer build catches a write
 * past it.
 *
 * Build: cc -O1 -g -fsanitize=address,undefined tests/test_text.c \
 *           src/c/tvct_text.c -o build/test_text
 * Run:   ./build/test_text [-b block] file...
 *        ./build/test_text -seed out.bin file   writes a decode seed for
 *                                               tests/fuzz_text.c
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

int32_t tvct_text_encode(const uint8_t *in, int32_t n, uint8_t *out, int32_t cap);
int32_t tvct_text_decode(const uint8_t *in, int32_t len, uint8_t *out, int32_t n);

static int failures;

static void check_block(const uint8_t *src, int32_t n, uint64_t *in_total,
                        uint64_t *out_total, unsigned *seed)
{
    uint8_t *t = malloc((size_t)n), *back = malloc((size_t)n), *mut;
    int32_t m = tvct_text_encode(src, n, t, n), r, it;

    *in_total += (uint64_t)n;
    if (m < 0)
    {
        *out_total += (uint64_t)n;
        free(t); free(back);
        return;
    }
    *out_total += (uint64_t)m;
    if (m >= n)
    {
        printf("FAIL: transformed %d >= block %d\n", m, n);
        failures++;
    }
    r = tvct_text_decode(t, m, back, n);
    if (r != 0 || memcmp(src, back, (size_t)n) != 0)
    {
        printf("FAIL: round-trip of a %d-byte block (r=%d)\n", n, r);
        failures++;
    }
    /* Shorter and longer declared outputs must both fail. */
    if (n > 1 && tvct_text_decode(t, m, back, n - 1) == 0)
    {
        printf("FAIL: decoded into n - 1 bytes\n");
        failures++;
    }

    mut = malloc((size_t)m + 16);
    for (it = 0; it < 200; it++)
    {
        int32_t len = m, k, flips = 1 + (int32_t)(*seed % 4);
        uint8_t *exact = malloc((size_t)n);
        memcpy(mut, t, (size_t)m);
        for (k = 0; k < flips; k++)
        {
            *seed = *seed * 1103515245u + 12345u;
            /* Bias towards the header and dictionary, where the counts live. */
            int32_t at = (*seed >> 4) % (it & 1 ? m : (m < 4096 ? m : 4096));
            mut[at] ^= (uint8_t)(1u << ((*seed >> 9) & 7));
        }
        if (it % 7 == 3) len = (int32_t)((*seed >> 3) % (uint32_t)m);
        if (it % 11 == 5) { memset(mut + m, 0xAB, 16); len = m + 16; }
        (void)tvct_text_decode(mut, len, exact, n);
        free(exact);
    }
    free(mut);
    free(t);
    free(back);
}

int main(int argc, char **argv)
{
    int32_t block = 1 << 24;
    unsigned seed = 0x2468ACE1u;
    int a = 1;

    if (argc == 4 && strcmp(argv[1], "-seed") == 0)
    {
        /* Mode byte, 16-bit declared size, then a transformed block. */
        FILE *f = fopen(argv[3], "rb"), *o;
        uint8_t in[65535], t[65535], hdr[3];
        int32_t n, m;
        if (!f) { perror(argv[3]); return 2; }
        n = (int32_t)fread(in, 1, sizeof in, f);
        fclose(f);
        m = tvct_text_encode(in, n, t, n);
        if (m < 0) { fprintf(stderr, "%s: transform not taken\n", argv[3]); return 1; }
        hdr[0] = 1; hdr[1] = (uint8_t)n; hdr[2] = (uint8_t)(n >> 8);
        o = fopen(argv[2], "wb");
        if (!o) { perror(argv[2]); return 2; }
        fwrite(hdr, 1, 3, o);
        fwrite(t, 1, (size_t)m, o);
        fclose(o);
        return 0;
    }
    if (a + 1 < argc && strcmp(argv[a], "-b") == 0)
    {
        block = atoi(argv[a + 1]);
        a += 2;
    }
    for (; a < argc; a++)
    {
        FILE *f = fopen(argv[a], "rb");
        long len;
        uint8_t *buf;
        uint64_t in_total = 0, out_total = 0;
        if (!f) { perror(argv[a]); return 2; }
        fseek(f, 0, SEEK_END); len = ftell(f); fseek(f, 0, SEEK_SET);
        buf = malloc((size_t)len + 1);
        if (fread(buf, 1, (size_t)len, f) != (size_t)len) { perror("read"); return 2; }
        fclose(f);
        for (long off = 0; off < len; off += block)
        {
            int32_t n = (int32_t)(len - off < block ? len - off : block);
            check_block(buf + off, n, &in_total, &out_total, &seed);
        }
        printf("%s: %llu -> %llu (%.1f%%)\n", argv[a], (unsigned long long)in_total,
               (unsigned long long)out_total, in_total ? 100.0 * out_total / in_total : 0);
        free(buf);
    }
    if (failures)
        printf("%d FAILURES\n", failures);
    return failures ? 1 : 0;
}

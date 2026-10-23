/* tovyCT run-length prefilter.
 *
 * Collapses runs before the BWT for the symbols where doing so pays, and leaves
 * the others alone. The decision is per block and per symbol: pass one counts,
 * for every symbol, one point per run byte saved and one point lost per
 * non-run occurrence (a collapsed symbol also needs its run length byte), and
 * only symbols with a positive score are collapsed.
 *
 * Output: a 32-byte bitmap of collapsed symbols, then the stream. A run of R
 * bytes is written as the symbol followed by R-1 in base 255, 255 meaning
 * "continue". The decoder restores the runs from the same bitmap.
 */
#include <stdint.h>
#include <string.h>

int tvct_rle_encode(const uint8_t *in, int32_t n, uint8_t *out, int32_t outcap,
                    int32_t *outlen)
{
    int32_t t[256];
    int32_t i, op = 0, c, pc = -1, run = 0;
    uint8_t bits[32];

    if (n <= 0 || outcap < 32)
        return 0;

    for (i = 0; i < 256; i++)
        t[i] = 0;

    /* Pass one: score each symbol. */
    for (i = 0; i < n; i++)
    {
        c = in[i];
        if (c == pc)
        {
            if ((++run % 255) != 0)
                t[c]++;
        }
        else
        {
            t[c]--;
            run = 0;
        }
        pc = c;
    }

    for (i = 0; i < 32; i++)
    {
        c = 0;
        for (int j = 0; j < 8; j++)
            c += (t[i * 8 + j] > 0) << j;
        bits[i] = (uint8_t)c;
    }

    if (32 > outcap)
        return 0;
    memcpy(out, bits, 32);
    op = 32;

    /* Pass two: emit. The first byte of a run is written when the run starts;
     * the repeats that follow are counted and written when the run ends. */
    pc = -1;
    run = 0;
    for (i = 0; i < n; i++)
    {
        c = in[i];
        if (c == pc)
        {
            run++;
            continue;
        }
        if (run > 0)
        {
            if ((bits[pc >> 3] >> (pc & 7)) & 1)
            {
                int32_t r = run;
                while (r >= 255)
                {
                    if (op >= outcap) return 0;
                    out[op++] = 255;
                    r -= 255;
                }
                if (op >= outcap) return 0;
                out[op++] = (uint8_t)r;
            }
            else
            {
                if (op + run > outcap) return 0;
                memset(out + op, pc, (size_t)run);
                op += run;
            }
            run = 0;
        }
        if (op >= outcap) return 0;
        out[op++] = (uint8_t)c;
        pc = c;
    }
    if (run > 0)
    {
        if ((bits[pc >> 3] >> (pc & 7)) & 1)
        {
            int32_t r = run;
            while (r >= 255)
            {
                if (op >= outcap) return 0;
                out[op++] = 255;
                r -= 255;
            }
            if (op >= outcap) return 0;
            out[op++] = (uint8_t)r;
        }
        else
        {
            if (op + run > outcap) return 0;
            memset(out + op, pc, (size_t)run);
            op += run;
        }
    }

    *outlen = op;
    return 1;
}

int tvct_rle_decode(const uint8_t *in, int32_t inlen, int32_t n, uint8_t *out)
{
    const uint8_t *bits;
    int32_t ip = 32, op = 0, c, r;
    int32_t run;

    if (inlen < 32)
        return 0;
    bits = in;

    while (ip < inlen && op < n)
    {
        c = in[ip++];
        if ((bits[c >> 3] >> (c & 7)) & 1)
        {
            run = 0;
            do
            {
                if (ip >= inlen) return 0;
                r = in[ip++];
                run += r;
            } while (r == 255);
            run += 1;
            if (op + run > n) return 0;
            memset(out + op, c, (size_t)run);
            op += run;
        }
        else
        {
            out[op++] = (uint8_t)c;
        }
    }
    return op == n;
}

/* tovyCT context-mixing coder.
 *
 * Alternative entropy backend for the BWT output. Instead of MTF + order-0 rANS
 * it codes each byte as eight binary decisions with three predictions mixed:
 * an order-0 bit-tree, the same tree conditioned on the previous byte, and one
 * conditioned on the byte before that, refined by an APM stage indexed by the
 * bit-tree context and a run flag.
 *
 * This is the model that makes bzip3 small; it costs speed, so it is a separate
 * block method and the fast levels keep MTF + rANS.
 *
 * The model is the standard DCE/lpaq arrangement, written from the published
 * description; no code is taken from bzip3.
 */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    uint16_t C0[256];
    uint16_t C1[256][256];
    uint16_t C2[512][66];
} cm_state;

static void cm_init(cm_state *s)
{
    int i, j, k;
    for (i = 0; i < 256; i++)
        s->C0[i] = 1 << 15;
    for (i = 0; i < 256; i++)
        for (j = 0; j < 256; j++)
            s->C1[i][j] = 1 << 15;
    for (i = 0; i < 2; i++)
        for (j = 0; j < 256; j++)
            for (k = 0; k < 66; k++)
                s->C2[2 * j + i][k] = (uint16_t)((k << 10) - (k == 64));
}

#define UPD0(p, x) ((p) = (uint16_t)((p) - ((p) >> (x))))
#define UPD1(p, x) ((p) = (uint16_t)((p) + (((p) ^ 65535) >> (x))))

int tvct_cm_encode(const uint8_t *buf, int32_t n, uint8_t *out, int32_t outcap,
                   int32_t *outlen)
{
    cm_state *s = (cm_state *)malloc(sizeof(cm_state));
    uint32_t low = 0, high = 0xFFFFFFFFu;
    uint32_t c1 = 0, c2 = 0, run = 0;
    int32_t i, op = 0;
    int bit, f, ctx, p0, p1, p2, p, j, x1, x2, ssep, pr;

    if (!s)
        return 0;
    cm_init(s);

    for (i = 0; i < n; i++)
    {
        uint32_t c = buf[i];
        if (c1 == c2)
            run++;
        else
            run = 0;
        f = run > 2;
        ctx = 1;
        for (bit = 7; bit >= 0; bit--)
        {
            p0 = s->C0[ctx];
            p1 = s->C1[c1][ctx];
            p2 = s->C1[c2][ctx];
            p = ((p0 + p1) * 7 + p2 + p2) >> 4;
            j = p >> 10;
            ssep = s->C2[2 * ctx + f][j];
            pr = ssep * 3 + p;

            if (c & (uint32_t)(1u << bit))
            {
                high = low + (uint32_t)(((uint64_t)(high - low) * pr) >> 18);
                while ((low ^ high) < (1u << 24))
                {
                    if (op >= outcap) { free(s); return 0; }
                    out[op++] = (uint8_t)(low >> 24);
                    low <<= 8;
                    high = (high << 8) | 0xFFu;
                }
                UPD1(s->C0[ctx], 2);
                UPD1(s->C1[c1][ctx], 4);
                UPD1(s->C2[2 * ctx + f][j], 6);
                ctx += ctx + 1;
            }
            else
            {
                low += (uint32_t)(((uint64_t)(high - low) * pr) >> 18) + 1u;
                while ((low ^ high) < (1u << 24))
                {
                    if (op >= outcap) { free(s); return 0; }
                    out[op++] = (uint8_t)(low >> 24);
                    low <<= 8;
                    high = (high << 8) | 0xFFu;
                }
                UPD0(s->C0[ctx], 2);
                UPD0(s->C1[c1][ctx], 4);
                UPD0(s->C2[2 * ctx + f][j], 6);
                ctx += ctx;
            }
        }
        c2 = c1;
        c1 = c;
    }

    for (i = 0; i < 4; i++)
    {
        if (op >= outcap) { free(s); return 0; }
        out[op++] = (uint8_t)(low >> 24);
        low <<= 8;
    }
    *outlen = op;
    free(s);
    return 1;
}

int tvct_cm_decode(const uint8_t *in, int32_t inlen, int32_t n, uint8_t *out)
{
    cm_state *s = (cm_state *)malloc(sizeof(cm_state));
    uint32_t low = 0, high = 0xFFFFFFFFu, code = 0;
    uint32_t c1 = 0, c2 = 0, run = 0;
    int32_t i, ip = 0;
    int bit, f, ctx, p0, p1, p2, p, j, x1, x2, ssep, pr;

    if (!s)
        return 0;
    cm_init(s);

    for (i = 0; i < 4; i++)
        code = (code << 8) | (ip < inlen ? in[ip++] : 0);

    for (i = 0; i < n; i++)
    {
        if (c1 == c2)
            run++;
        else
            run = 0;
        f = run > 2;
        ctx = 1;
        for (bit = 7; bit >= 0; bit--)
        {
            p0 = s->C0[ctx];
            p1 = s->C1[c1][ctx];
            p2 = s->C1[c2][ctx];
            p = ((p0 + p1) * 7 + p2 + p2) >> 4;
            j = p >> 10;
            ssep = s->C2[2 * ctx + f][j];
            pr = ssep * 3 + p;

            {
                uint32_t mid = low + (uint32_t)(((uint64_t)(high - low) * pr) >> 18);
                if (code <= mid)
                {
                    high = mid;
                    UPD1(s->C0[ctx], 2);
                    UPD1(s->C1[c1][ctx], 4);
                    UPD1(s->C2[2 * ctx + f][j], 6);
                    ctx += ctx + 1;
                }
                else
                {
                    low = mid + 1;
                    UPD0(s->C0[ctx], 2);
                    UPD0(s->C1[c1][ctx], 4);
                    UPD0(s->C2[2 * ctx + f][j], 6);
                    ctx += ctx;
                }
            }

            while ((low ^ high) < (1u << 24))
            {
                low <<= 8;
                high = (high << 8) | 0xFFu;
                code = (code << 8) | (ip < inlen ? in[ip++] : 0);
            }
        }
        out[i] = (uint8_t)(ctx & 255);
        c2 = c1;
        c1 = (uint32_t)(ctx & 255);
    }

    free(s);
    return 1;
}

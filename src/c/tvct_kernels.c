/* tovyCT decode kernels.
 *
 * Hot loops of the decoder, in C so the compiler can keep them tight and so
 * assembly can be dropped in where it pays. The inverse BWT is the important
 * one: it is a dependent chain of random reads, one memory latency per byte, so
 * the encoder stores the row of the LF chain at every chunk boundary and this
 * walks several independent chunks at once. Eight chains give the out-of-order
 * engine eight loads in flight where the straightforward walk has one.
 */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define BWT_CHAINS 8

/* Inverse BWT.
 *
 * bwt[0..n-1] is the transform with the sentinel row removed, primary is where
 * it was. samples[j] is the LF chain row of output position end(j), where
 * end(j) = min((j+1)*rate, n) - 1: the encoder computes it from the inverse
 * suffix array, so the decoder never has to walk to find a starting point.
 */
void tvct_bwt_inverse(const uint8_t *bwt, int32_t n, int32_t primary,
                      const int32_t *samples, int32_t nsamples, int32_t rate,
                      uint8_t *out)
{
    uint8_t *bp;
    uint32_t *lf, *start, *rank;
    uint32_t cnt[257];
    int32_t i, c, j, s, pos, row;
    int32_t ngroup;
    int packed;

    if (n <= 0)
        return;
    if (primary < 0 || primary > n)
        primary = 0;

    /* Materialise the sentinel-extended BWT: bp[i] for i != primary is the
     * byte, and bp[primary] is never read. */
    bp = (uint8_t *)malloc((size_t)n + 1);
    lf = (uint32_t *)malloc(((size_t)n + 1) * sizeof(uint32_t));
    start = (uint32_t *)malloc(257 * sizeof(uint32_t));
    rank = (uint32_t *)calloc(257, sizeof(uint32_t));
    if (!bp || !lf || !start || !rank)
    {
        free(bp); free(lf); free(start); free(rank);
        return;
    }

    memcpy(bp, bwt, (size_t)primary);
    bp[primary] = 0;
    memcpy(bp + primary + 1, bwt + primary, (size_t)(n - primary));

    for (i = 0; i < 257; i++)
        cnt[i] = 0;
    cnt[0] = 1;                             /* the sentinel */
    for (i = 0; i <= n; i++)
        if (i != primary)
            cnt[bp[i] + 1]++;

    start[0] = 0;
    for (i = 1; i < 257; i++)
        start[i] = start[i - 1] + cnt[i - 1];

    for (i = 0; i <= n; i++)
    {
        s = (i == primary) ? 0 : (int32_t)bp[i] + 1;
        lf[i] = start[s] + rank[s];
        rank[s]++;
    }

    if (!samples || nsamples <= 0 || rate <= 0)
    {
        /* Fallback: the plain walk. */
        row = 0;
        for (i = n - 1; i >= 0; i--)
        {
            out[i] = bp[row];
            row = (int32_t)lf[row];
        }
        free(bp); free(lf); free(start); free(rank);
        return;
    }

    /* Pack the BWT byte into the top bits of the LF entry: positions are below
     * 2^24 for every block this codec allows, so the walk needs one load per
     * step instead of two. Above that size, keep the two arrays. */
    packed = (n < (1 << 24));
    if (packed)
        for (i = 0; i <= n; i++)
            lf[i] |= ((uint32_t)bp[i]) << 24;

    /* Walk chunks in groups, so the chains interleave and the loads overlap. */
    j = 0;
    while (j < nsamples)
    {
        uint32_t rows[BWT_CHAINS];
        int32_t ends[BWT_CHAINS], starts[BWT_CHAINS], lens[BWT_CHAINS];
        int32_t maxlen = 0;

        ngroup = nsamples - j;
        if (ngroup > BWT_CHAINS)
            ngroup = BWT_CHAINS;

        for (c = 0; c < ngroup; c++)
        {
            int32_t chunk = j + c;
            int32_t e = (int32_t)(((int64_t)(chunk + 1) * rate) - 1);
            if (e > n - 1)
                e = n - 1;
            rows[c] = (uint32_t)samples[chunk];
            if ((int32_t)rows[c] > n)
                rows[c] = 0;
            ends[c] = e;
            starts[c] = chunk * rate;
            lens[c] = e - starts[c] + 1;
            if (lens[c] > maxlen)
                maxlen = lens[c];
        }

        for (i = 0; i < maxlen; i++)
        {
            for (c = 0; c < ngroup; c++)
            {
                if (i < lens[c])
                {
                    pos = ends[c] - i;
                    if (packed)
                    {
                        uint32_t v = lf[rows[c]];
                        out[pos] = (uint8_t)(v >> 24);
                        rows[c] = v & 0xFFFFFFu;
                    }
                    else
                    {
                        out[pos] = bp[rows[c]];
                        rows[c] = lf[rows[c]];
                    }
                }
            }
        }

        j += ngroup;
    }

    free(bp); free(lf); free(start); free(rank);
}

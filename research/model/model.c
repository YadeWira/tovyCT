/* tovyCT - M0 measurement model.
 *
 * Throwaway prototype: it is NOT the codec and is not shipped. It parses a file
 * the way the planned encoder would (hash-chain LZ77 + one-step lazy parse +
 * four recent offsets + LZP), then computes the ideal entropy of every token
 * stream under several literal context schemes, plus an estimate of the table
 * cost. The result bounds the ratio the real encoder can reach before any
 * Pascal is written.
 *
 * The parse is replayed into a buffer and compared with the input, so the
 * numbers describe a token stream that actually decodes.
 *
 * Build: cc -O3 -march=native -o model model.c -lm
 * Use:   ./model file [-b block_mb] [-w window_mb] [-d depth] [-m minmatch]
 *                     [-l lzp_min] [-r rep_min] [-n nice] [-c literal_bits] [-v]
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include <math.h>

#define MAX_LIT_CTX 2048
#define NLIT_SCHEMES 4
#define NSCHEMES 5

enum { TYPE_NONE = 0, TYPE_NORMAL, TYPE_REP0, TYPE_REP1, TYPE_REP2, TYPE_REP3,
       TYPE_LZP };
#define NTYPES 7

static uint8_t *g_data;
static size_t g_size;

static int g_depth = 32;
static int g_minmatch = 4;
static int g_lzp_min = 3;
static int g_rep_min = 3;
static int g_nice = 128;
static size_t g_window = 8u << 20;
static size_t g_block = 8u << 20;
static int g_hash_log = 22;
static int g_lzp_log = 20;
static int g_verify = 0;
static int g_print = 0;
static double g_lit_cost = 6.5;
static int g_optimal = 0;
static int g_quiet = 0;

/* Per-block token histograms. */
static uint32_t *g_lit[NLIT_SCHEMES];
static const int g_lit_ctx[NLIT_SCHEMES] = { 1, 16, 512, 2048 };
static uint32_t g_ll[4][64];
static uint32_t g_ml[4][64];
static uint32_t g_slot[4][32];
static uint32_t g_type[NTYPES];
static uint32_t g_hit[2];
static uint32_t g_litmiss[16][256];
static uint32_t g_last_dist;
static double g_mlit_bits, g_mlit_tab;

/* Accumulated costs over blocks. */
static double g_lit_bits[NLIT_SCHEMES], g_lit_tab[NLIT_SCHEMES];
static double g_ll_bits, g_ml_bits, g_slot_bits, g_type_bits;
static double g_ll_tab, g_ml_tab, g_slot_tab;
static double g_len_extra_bits, g_slot_extra_bits;

static uint64_t g_nlit, g_nmatch, g_nrep, g_nlzp, g_bytes_matched;
static uint64_t g_lit_hist[256];
static int g_last_mlbucket, g_last_llbucket, g_last_slotbucket;

static int g_hash_bytes = 4;

static inline uint32_t hash4(const uint8_t *p)
{
    uint32_t v;
    memcpy(&v, p, 4);
    if (g_hash_bytes == 3) v &= 0xFFFFFFu;
    return (v * 2654435761u) >> (32 - g_hash_log);
}

static inline uint32_t lzphash(const uint8_t *p)
{
    uint32_t v;
    memcpy(&v, p, 4);
    v ^= v >> 15;
    v *= 0x85ebca6bu;
    v ^= v >> 13;
    return v & ((1u << g_lzp_log) - 1);
}

/* Length of the common prefix of a[0..] and b[0..], at most max. */
static inline size_t mlen(const uint8_t *a, const uint8_t *b, size_t max)
{
    size_t i = 0;
    while (i + 8 <= max) {
        uint64_t x, y;
        memcpy(&x, a + i, 8);
        memcpy(&y, b + i, 8);
        uint64_t d = x ^ y;
        if (d)
            return i + (size_t)(__builtin_ctzll(d) >> 3);
        i += 8;
    }
    while (i < max && a[i] == b[i])
        i++;
    return i;
}

static inline int lit_class(uint8_t c)
{
    if (c >= 'a' && c <= 'z') return 0;
    if (c >= 'A' && c <= 'Z') return 1;
    if (c >= '0' && c <= '9') return 2;
    if (c == ' ' || c == '\t' || c == '\n' || c == '\r') return 3;
    if (c < 0x20) return 4;
    if (c < 0x80) return 5;                 /* ASCII punctuation and symbols */
    if ((c & 0xC0) == 0x80) return 6;       /* UTF-8 continuation */
    return 7;
}

static inline int lit_ctx(int scheme, uint8_t prev, uint8_t prev2, int after_match)
{
    switch (scheme) {
    case 0: return 0;
    case 1: return lit_class(prev) * 2 + after_match;
    case 2: return (int)prev * 2 + after_match;
    default:
        return (int)(((uint32_t)prev2 * 131u + prev * 7u + after_match * 0x9E37u)
                     & (MAX_LIT_CTX - 1));
    }
}

/* Length coding: 0..15 direct, then 16+ (log2 - 3) with the low bits raw. */
static inline int len_code(size_t v, int *extra_bits)
{
    if (v < 16) { *extra_bits = 0; return (int)v; }
    int e = 0;
    size_t t = v;
    while (t >>= 1) e++;
    *extra_bits = e - 3;
    return 16 + (e - 3);
}

static double entropy(const uint32_t *h, int n)
{
    uint64_t total = 0;
    for (int i = 0; i < n; i++) total += h[i];
    if (!total) return 0;
    double bits = 0;
    for (int i = 0; i < n; i++) {
        if (!h[i]) continue;
        bits += (double)h[i] * log2((double)total / (double)h[i]);
    }
    return bits;
}

/* Conditional entropy: every context row is normalised on its own total. */
static double entropy_ctx(const uint32_t *h, int ctx, int n)
{
    double bits = 0;
    for (int c = 0; c < ctx; c++)
        bits += entropy(h + (size_t)c * n, n);
    return bits;
}

static double table_bytes(const uint32_t *h, int ctx, int n)
{
    /* 4-byte header per table, 2 bytes per used symbol. Real serialisation is
     * better, so this estimate is on the safe side. */
    double b = 0;
    for (int c = 0; c < ctx; c++) {
        int nnz = 0;
        for (int i = 0; i < n; i++)
            if (h[c * n + i]) nnz++;
        if (nnz) b += 4 + 2.0 * nnz;
    }
    return b;
}

typedef struct {
    size_t len, dist;
    int type;
    double score;
} Best;

static double len_extra_bits(size_t v)
{
    if (v < 16) return 0;
    int e = 0;
    size_t t = v;
    while (t >>= 1) e++;
    return (double)(e - 3);
}

/* Rough price of a sequence, in bits: match-length symbol + its extra bits +
 * the type symbol, plus the offset for a normal match. Tuned against the
 * measured entropy; the parse only needs the ordering. */
static inline double seq_cost(int type, size_t len, size_t dist)
{
    double c = 4.0 + len_extra_bits(len) + 2.0;
    if (type == TYPE_NORMAL)
        c += 3.5 + (double)(63 - __builtin_clzll((unsigned long long)dist));
    return c;
}

static Best find_best(const uint8_t *p, size_t pos, size_t avail,
                      const uint32_t *head, const uint32_t *prev,
                      const uint32_t *lzp, const uint32_t *reps, int nreps)
{
    Best b = { 0, 0, TYPE_NONE, 0.0 };
    const double lit = g_lit_cost;

    for (int k = 0; k < nreps; k++) {
        size_t d = reps[k];
        if (d == 0 || d > pos) continue;
        size_t l = mlen(p + pos, p + pos - d, avail);
        if (l < (size_t)g_rep_min) continue;
        double sc = (double)l * lit - seq_cost(TYPE_REP0 + k, l, d);
        if (sc > b.score) { b.len = l; b.dist = d; b.type = TYPE_REP0 + k; b.score = sc; }
    }

    if (avail >= (size_t)g_hash_bytes) {
        uint32_t h = hash4(p + pos);
        uint32_t c = head[h];
        int depth = g_depth;
        while (c && depth-- > 0) {
            size_t cp = c - 1;
            if (cp >= pos) break;
            if (pos - cp > g_window) break;
            if (b.len < avail && p[cp + b.len] != p[pos + b.len]) { c = prev[cp]; continue; }
            size_t l = mlen(p + pos, p + cp, avail);
            if (l >= (size_t)g_minmatch) {
                double sc = (double)l * lit - seq_cost(TYPE_NORMAL, l, pos - cp);
                if (sc > b.score) {
                    b.len = l; b.dist = pos - cp; b.type = TYPE_NORMAL; b.score = sc;
                }
            }
            if (b.len >= (size_t)g_nice) break;
            c = prev[cp];
        }
    }

    if (pos >= 4) {
        uint32_t pr = lzp[lzphash(p + pos - 4)];
        if (pr && pr - 1 < pos && pos - (pr - 1) <= g_window) {
            size_t pp = pr - 1;
            size_t l = mlen(p + pos, p + pp, avail);
            if (l >= (size_t)g_lzp_min) {
                double sc = (double)l * lit - seq_cost(TYPE_LZP, l, l);
                if (sc > b.score) {
                    b.len = l; b.dist = pos - pp; b.type = TYPE_LZP; b.score = sc;
                }
            }
        }
    }
    return b;
}

static inline void insert_pos(const uint8_t *p, size_t len, size_t pos,
                              uint32_t *head, uint32_t *prev)
{
    if (pos + (size_t)g_hash_bytes <= len) {
        uint32_t h = hash4(p + pos);
        prev[pos] = head[h];
        head[h] = (uint32_t)(pos + 1);
    }
}

static inline void add_literal(uint8_t byte, uint8_t prev, uint8_t prev2,
                               int after_match, uint8_t pred, int has_pred)
{
    g_nlit++;
    if (g_quiet) return;
    g_lit_hist[byte]++;
    for (int s = 0; s < NLIT_SCHEMES; s++) {
        int c = lit_ctx(s, prev, prev2, after_match);
        g_lit[s][(size_t)c * 256 + byte]++;
    }
    /* Matched-literal scheme: a literal that follows a match is predicted by
     * the byte at the same offset inside the match source. */
    int hit = has_pred && byte == pred;
    g_hit[hit]++;
    if (!hit) {
        int c = lit_class(prev) * 2 + after_match;
        g_litmiss[c][byte]++;
    }
}

static inline int min_for(int type)
{
    if (type == TYPE_NORMAL) return g_minmatch;
    if (type == TYPE_LZP) return g_lzp_min;
    return g_rep_min;
}

static void add_sequence(size_t ll, size_t ml, size_t dist, int type)
{
    int e_ll = 0, e_ml = 0;
    int llc = len_code(ll, &e_ll);
    int mlc = len_code(ml, &e_ml);
    int slot = 0;
    if (dist) {
        size_t t = dist;
        while (t >>= 1) slot++;
    }

    if (g_quiet) return;
    if (llc < 64) g_ll[g_last_mlbucket][llc]++;
    if (mlc < 64) g_ml[g_last_llbucket][mlc]++;

    /* Only a normal match carries an explicit offset. Rep and LZP matches
     * derive it from state the decoder already has. */
    if (type == TYPE_NORMAL) {
        if (slot < 32) g_slot[g_last_slotbucket][slot]++;
        g_slot_extra_bits += (double)slot;
    } else {
        slot = 0;
    }
    if (type < NTYPES) g_type[type]++;

    g_len_extra_bits += (double)e_ll + (double)e_ml;

    g_last_mlbucket = ml < 8 ? 0 : ml < 16 ? 1 : ml < 32 ? 2 : 3;
    g_last_llbucket = ll < 4 ? 0 : ll < 8 ? 1 : ll < 16 ? 2 : 3;
    if (type == TYPE_NORMAL)
        g_last_slotbucket = slot < 8 ? 0 : slot < 12 ? 1 : slot < 16 ? 2 : 3;
}

static void block_stats(void)
{
    for (int s = 0; s < NLIT_SCHEMES; s++) {
        g_lit_bits[s] += entropy_ctx(g_lit[s], g_lit_ctx[s], 256);
        g_lit_tab[s] += table_bytes(g_lit[s], g_lit_ctx[s], 256);
        memset(g_lit[s], 0, sizeof(uint32_t) * (size_t)g_lit_ctx[s] * 256);
    }
    double ll = 0, ml = 0, sl = 0, tll = 0, tml = 0, tsl = 0;
    for (int c = 0; c < 4; c++) {
        ll += entropy(g_ll[c], 64);
        ml += entropy(g_ml[c], 64);
        sl += entropy(g_slot[c], 32);
        tll += table_bytes(g_ll[c], 1, 64);
        tml += table_bytes(g_ml[c], 1, 64);
        tsl += table_bytes(g_slot[c], 1, 32);
    }
    g_ll_bits += ll;
    g_ml_bits += ml;
    g_slot_bits += sl;
    g_type_bits += entropy(g_type, NTYPES);
    g_ll_tab += tll;
    g_ml_tab += tml;
    g_slot_tab += tsl + 4 + 2.0 * NTYPES;
    if (getenv("DBG")) fprintf(stderr, "hits %u/%u nlit %llu\n", g_hit[0], g_hit[1], (unsigned long long)g_nlit);
    g_mlit_bits += entropy(g_hit, 2);
    double mtab = 0;
    for (int c = 0; c < 16; c++) mtab += table_bytes(g_litmiss[c], 1, 256);
    g_mlit_tab += mtab;
    memset(g_litmiss, 0, sizeof(g_litmiss));
    memset(g_hit, 0, sizeof(g_hit));
    memset(g_ll, 0, sizeof(g_ll));
    memset(g_ml, 0, sizeof(g_ml));
    memset(g_slot, 0, sizeof(g_slot));
    memset(g_type, 0, sizeof(g_type));
    memset(g_hit, 0, sizeof(g_hit));
    memset(g_litmiss, 0, sizeof(g_litmiss));
    g_last_mlbucket = g_last_llbucket = g_last_slotbucket = 0;
}


typedef struct {
    uint32_t dist;
    uint16_t len;
    uint8_t type;
    uint8_t pad;
} Cand;

/* Optimal parse: a first pass records the best candidate at every position,
 * then a forward DP picks the cheapest tokenisation, then the path is emitted
 * through the same bookkeeping as the greedy parser. */
static int process_block_optimal(const uint8_t *p, size_t len, uint8_t *out)
{
    uint32_t *head = calloc((size_t)1 << g_hash_log, sizeof(uint32_t));
    uint32_t *prev = calloc(len, sizeof(uint32_t));
    uint32_t *lzp = calloc((size_t)1 << g_lzp_log, sizeof(uint32_t));
    Cand *cand = calloc(len, sizeof(Cand));
    float *cost = malloc((len + 1) * sizeof(float));
    int32_t *from = malloc((len + 1) * sizeof(int32_t));
    uint32_t *tdist = malloc((len + 1) * sizeof(uint32_t));
    uint8_t *ttype = malloc(len + 1);
    if (!head || !prev || !lzp || !cand || !cost || !from || !tdist || !ttype) {
        fprintf(stderr, "out of memory\n");
        return 1;
    }

    uint32_t reps[4] = { 0, 0, 0, 0 };
    int nreps = 0;

    /* Pass 1: best candidate per position (no rep history: path independent). */
    for (size_t pos = 0; pos < len; pos++) {
        uint32_t dummy[4] = { 0, 0, 0, 0 };
        Best b = find_best(p, pos, len - pos, head, prev, lzp, dummy, 0);
        cand[pos].len = (uint16_t)(b.len > 65535 ? 65535 : b.len);
        cand[pos].dist = (uint32_t)b.dist;
        cand[pos].type = (uint8_t)b.type;
        insert_pos(p, len, pos, head, prev);
        if (pos >= 4) lzp[lzphash(p + pos - 4)] = (uint32_t)(pos + 1);
    }

    /* Pass 2: forward DP. */
    const float INF = 1e30f;
    for (size_t i = 0; i <= len; i++) { cost[i] = INF; from[i] = -1; tdist[i] = 0; ttype[i] = TYPE_NONE; }
    cost[0] = 0;
    for (size_t pos = 0; pos < len; pos++) {
        if (cost[pos] >= INF) continue;
        float c0 = cost[pos] + (float)g_lit_cost;
        if (c0 < cost[pos + 1]) { cost[pos + 1] = c0; from[pos + 1] = (int32_t)pos; ttype[pos + 1] = TYPE_NONE; }
        Cand b = cand[pos];
        if (b.type != TYPE_NONE && b.len >= 4) {
            size_t maxl = b.len;
            if (maxl > len - pos) maxl = len - pos;
            /* Try the full length and a few shorter ones. */
            for (size_t l = maxl; l >= maxl - 2 && l >= 3; l--) {
                float c = cost[pos] + (float)seq_cost(b.type, l, b.dist);
                if (cost[pos] + (float)c0 < 0) { }
                if (c < cost[pos + l]) {
                    cost[pos + l] = c;
                    from[pos + l] = (int32_t)pos;
                    ttype[pos + l] = b.type;
                    tdist[pos + l] = b.dist;
                }
            }
        }
    }

    /* Walk the path backwards, then emit forwards with the normal bookkeeping. */
    size_t *path = malloc((len + 1) * sizeof(size_t));
    size_t npath = 0;
    for (int32_t at = (int32_t)len; at > 0; at = from[at]) {
        if (from[at] < 0) { fprintf(stderr, "DP failed at %d\n", at); return 1; }
        path[npath++] = (size_t)at;
    }

    size_t outpos = 0, litrun = 0;
    int after_match = 0;
    for (size_t k = npath; k-- > 0; ) {
        size_t end = path[k];
        int32_t st = from[end];
        size_t pos = (size_t)st;
        size_t l = end - pos;

        if (ttype[end] == TYPE_NONE) {
            {
                int hp = after_match && g_last_dist && g_last_dist <= pos;
                add_literal(p[pos], pos ? p[pos - 1] : 0, pos > 1 ? p[pos - 2] : 0,
                            after_match, hp ? p[pos - g_last_dist] : 0, hp);
            }
            if (out) out[outpos] = p[pos];
            outpos++;
            litrun++;
            after_match = 0;
            continue;
        }

        int type = ttype[end];
        size_t dist = tdist[end];

        /* Reclassify a normal match as rep or LZP when the decoder can derive
         * the distance for free. */
        if (type == TYPE_NORMAL) {
            for (int r = 0; r < nreps; r++)
                if (reps[r] == dist) { type = TYPE_REP0 + r; break; }
            if (type == TYPE_NORMAL) {
                uint32_t pr = lzp[lzphash(p + pos - 4)];
                if (pos >= 4 && pr == (uint32_t)(pos - dist + 1))
                    type = TYPE_LZP;
            }
        }

        add_sequence(litrun, l, dist, type);

        g_last_dist = (uint32_t)dist;
        if (type == TYPE_NORMAL) {
            for (int r = 3; r > 0; r--) reps[r] = reps[r - 1];
            reps[0] = (uint32_t)dist;
            if (nreps < 4) nreps++;
        } else if (type >= TYPE_REP0 && type <= TYPE_REP3) {
            int r = type - TYPE_REP0;
            uint32_t d = reps[r];
            for (int j = r; j > 0; j--) reps[j] = reps[j - 1];
            reps[0] = d;
        }

        if (out) {
            for (size_t i = 0; i < l; i++)
                out[outpos + i] = out[outpos + i - dist];
            outpos += l;
        }
        for (size_t i = 1; i < l; i++)
            if (pos + i >= 4) lzp[lzphash(p + pos + i - 4)] = (uint32_t)(pos + i + 1);

        (void)reps;
        g_nmatch++;
        g_bytes_matched += l;
        if (type >= TYPE_REP0 && type <= TYPE_REP3) g_nrep++;
        if (type == TYPE_LZP) g_nlzp++;

        litrun = 0;
        after_match = 1;
    }

    block_stats();
    free(path); free(head); free(prev); free(lzp); free(cand);
    free(cost); free(from); free(tdist); free(ttype);
    return 0;
}

static int process_block(const uint8_t *p, size_t len)
{
    uint32_t *head = calloc((size_t)1 << g_hash_log, sizeof(uint32_t));
    uint32_t *prev = calloc(len, sizeof(uint32_t));
    uint32_t *lzp = calloc((size_t)1 << g_lzp_log, sizeof(uint32_t));
    uint8_t *out = g_verify ? malloc(len) : NULL;
    if (!head || !prev || !lzp || (g_verify && !out)) {
        fprintf(stderr, "out of memory\n");
        return 1;
    }

    uint32_t reps[4] = { 0, 0, 0, 0 };
    int nreps = 0;
    size_t pos = 0, litrun = 0, outpos = 0;
    int after_match = 0;

    while (pos < len) {
        size_t avail = len - pos;
        Best b = find_best(p, pos, avail, head, prev, lzp, reps, nreps);
        insert_pos(p, len, pos, head, prev);

        /* One-step lazy evaluation, now that pos itself is in the chains. */
        if (b.type != TYPE_NONE && pos + 1 < len) {
            Best b2 = find_best(p, pos + 1, len - pos - 1, head, prev, lzp, reps, nreps);
            if (b2.type != TYPE_NONE && b2.score > b.score)
                b.type = TYPE_NONE;
        }

        if (b.type == TYPE_NONE || b.score <= 0.0) {
            {
                int hp = after_match && g_last_dist && g_last_dist <= pos;
                add_literal(p[pos], pos ? p[pos - 1] : 0, pos > 1 ? p[pos - 2] : 0,
                            after_match, hp ? p[pos - g_last_dist] : 0, hp);
            }
            if (out) out[outpos] = p[pos];
            if (pos >= 4) lzp[lzphash(p + pos - 4)] = (uint32_t)(pos + 1);
            litrun++;
            after_match = 0;
            pos++;
            outpos++;
            continue;
        }

        if (g_print && g_nmatch < (uint64_t)g_print)
            printf("tok %8zu type %d len %6zu dist %8zu\n", pos, b.type, b.len, b.dist);
        add_sequence(litrun, b.len, b.dist, b.type);

        g_last_dist = (uint32_t)b.dist;
        if (b.type == TYPE_NORMAL) {
            for (int k = 3; k > 0; k--) reps[k] = reps[k - 1];
            reps[0] = (uint32_t)b.dist;
            if (nreps < 4) nreps++;
        } else if (b.type >= TYPE_REP0 && b.type <= TYPE_REP3) {
            int k = b.type - TYPE_REP0;
            uint32_t d = reps[k];
            for (int j = k; j > 0; j--) reps[j] = reps[j - 1];
            reps[0] = d;
        }

        if (out) {
            for (size_t i = 0; i < b.len; i++)
                out[outpos + i] = out[outpos + i - b.dist];
            outpos += b.len;
        }

        for (size_t i = 1; i < b.len; i++) {
            insert_pos(p, len, pos + i, head, prev);
            if (pos + i >= 4)
                lzp[lzphash(p + pos + i - 4)] = (uint32_t)(pos + i + 1);
        }

        g_nmatch++;
        g_bytes_matched += b.len;
        if (b.type >= TYPE_REP0 && b.type <= TYPE_REP3) g_nrep++;
        if (b.type == TYPE_LZP) g_nlzp++;

        pos += b.len;
        litrun = 0;
        after_match = 1;
    }

    block_stats();

    if (out) {
        if (outpos != len || memcmp(out, p, len) != 0) {
            size_t i = 0;
            while (i < len && out[i] == p[i]) i++;
            fprintf(stderr, "VERIFY FAILED at %zu (outpos %zu, len %zu)\n",
                    i, outpos, len);
            return 1;
        }
        free(out);
    }

    free(head); free(prev); free(lzp);
    return 0;
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s file [-b MB] [-w MB] [-d depth] [-m min] "
                        "[-l lzpmin] [-r repmin] [-n nice] [-c literal_bits] [-v]\n", argv[0]);
        return 1;
    }
    for (int i = 2; i < argc; i++) {
        if (!strcmp(argv[i], "-v")) g_verify = 1;
        else if (!strcmp(argv[i], "-o")) g_optimal = 1;
        else if (!strcmp(argv[i], "-q")) g_quiet = 1;
        else if (!strcmp(argv[i], "-p") && i + 1 < argc) g_print = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-b") && i + 1 < argc) g_block = (size_t)atoi(argv[++i]) << 20;
        else if (!strcmp(argv[i], "-w") && i + 1 < argc) g_window = (size_t)atoi(argv[++i]) << 20;
        else if (!strcmp(argv[i], "-d") && i + 1 < argc) g_depth = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-m") && i + 1 < argc) g_minmatch = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-l") && i + 1 < argc) g_lzp_min = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-r") && i + 1 < argc) g_rep_min = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-n") && i + 1 < argc) g_nice = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-c") && i + 1 < argc) g_lit_cost = atof(argv[++i]);
        else if (!strcmp(argv[i], "-H") && i + 1 < argc) g_hash_log = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-k") && i + 1 < argc) g_hash_bytes = atoi(argv[++i]);
        else { fprintf(stderr, "bad option %s\n", argv[i]); return 1; }
    }

    FILE *f = fopen(argv[1], "rb");
    if (!f) { perror(argv[1]); return 1; }
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    g_size = (size_t)sz;
    g_data = malloc(g_size ? g_size : 1);
    if (g_size && fread(g_data, 1, g_size, f) != g_size) { perror("read"); return 1; }
    fclose(f);

    for (int s = 0; s < NLIT_SCHEMES; s++) {
        g_lit[s] = calloc((size_t)g_lit_ctx[s] * 256, sizeof(uint32_t));
        if (!g_lit[s]) { fprintf(stderr, "out of memory\n"); return 1; }
    }

    clock_t t0 = clock();
    size_t blocks = 0;
    for (size_t off = 0; off < g_size; off += g_block) {
        size_t len = g_size - off < g_block ? g_size - off : g_block;
        if (g_optimal) {
            uint8_t *out = g_verify ? malloc(len) : NULL;
            if (process_block_optimal(g_data + off, len, out)) return 1;
            if (out) {
                if (memcmp(out, g_data + off, len)) { fprintf(stderr, "VERIFY FAILED (optimal)\n"); return 1; }
                free(out);
            }
        } else if (process_block(g_data + off, len)) return 1;
        blocks++;
    }
    double secs = (double)(clock() - t0) / CLOCKS_PER_SEC;

    double tab_tokens = g_ll_tab + g_ml_tab + g_slot_tab;
    printf("file             %s\n", argv[1]);
    printf("size             %zu\n", g_size);
    printf("blocks           %zu x %zu (window %zu)\n", blocks, g_block, g_window);
    printf("parse            depth %d, minmatch %d, lzp_min %d, rep_min %d\n",
           g_depth, g_minmatch, g_lzp_min, g_rep_min);
    printf("parse speed      %.1f MB/s (C, histograms included)\n", g_size / 1e6 / secs);
    printf("tokens           %llu matches (%llu normal, %llu rep, %llu lzp), "
           "%.2f bytes/match\n",
           (unsigned long long)g_nmatch,
           (unsigned long long)(g_nmatch - g_nrep - g_nlzp),
           (unsigned long long)g_nrep, (unsigned long long)g_nlzp,
           g_nmatch ? (double)g_bytes_matched / g_nmatch : 0.0);
    printf("literals         %llu (%.2f%% of input)\n", (unsigned long long)g_nlit,
           100.0 * (double)g_nlit / (double)g_size);
    printf("entropy bits     ll %.0f  ml %.0f  slot %.0f  type %.0f  "
           "len_extra %.0f  slot_extra %.0f\n", g_ll_bits, g_ml_bits, g_slot_bits,
           g_type_bits, g_len_extra_bits, g_slot_extra_bits);

    double seq_bits = g_ll_bits + g_ml_bits + g_slot_bits + g_type_bits +
                      g_len_extra_bits + g_slot_extra_bits;
    for (int s = 0; s < NLIT_SCHEMES; s++) {
        double total_bits = g_lit_bits[s] + seq_bits;
        double bytes = total_bits / 8.0 + g_lit_tab[s] + tab_tokens + 16.0 * blocks;
        printf("scheme %d         ctx %5d  lit %.2f bits  tables %9.0f  "
               "projected %10.0f  ratio %6.2f%%\n",
               s, g_lit_ctx[s], g_lit_bits[s] / (g_nlit ? g_nlit : 1),
               g_lit_tab[s], bytes, 100.0 * bytes / (double)g_size);
    }
    {
        double total_bits = g_mlit_bits + seq_bits;
        double bytes = total_bits / 8.0 + g_mlit_tab + tab_tokens + 16.0 * blocks;
        printf("scheme 4         matched-lit    %.2f bits  tables %9.0f  "
               "projected %10.0f  ratio %6.2f%%\n",
               g_mlit_bits / (g_nlit ? g_nlit : 1), g_mlit_tab, bytes,
               100.0 * bytes / (double)g_size);
    }
    return 0;
}

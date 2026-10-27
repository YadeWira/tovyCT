/* tovyCT text transform.
 *
 * A reversible rewrite of a block before the BWT, for text:
 *
 *  - capitals: "The" becomes CAP "the" and "THE" becomes UPPER "the", so the
 *    BWT sees one spelling of each word;
 *  - dictionary: the words that pay for their entry are replaced by a one-byte
 *    code or a two-byte (prefix, index) code.
 *
 * Flags and codes are "reserved" bytes. They are taken from the bytes that do
 * not occur in the block; when too few are free, the rarest non-letter bytes are
 * reserved as well and their literal occurrences are escaped by ESC. The
 * dictionary travels in front of the body, inside the BWT input, so it is
 * compressed with everything else. The layout is in docs/FORMAT.md.
 *
 * The decoder is the attack surface: every count, index and length it reads is
 * checked against the buffers it was given, and it either writes exactly the
 * declared size or fails.
 */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define TT_CAPS 1
#define TT_DICT 2
#define TT_ESC  4

#define WORD_MIN 2
#define WORD_MAX 32          /* longest dictionary word the encoder picks */
#define WORD_LIMIT 64        /* longest dictionary word the decoder accepts */
#define RESERVE_WANT 34      /* CAP, UPPER and 32 code bytes */
#define TABLE_LOG 18         /* 4 MiB of slots: stays mostly in cache */
#define SEL_BITS 19          /* bitset of the chosen words' hashes, 64 KiB */
#define MIN_FREQ 128         /* fewer occurrences do not pay for the entry */

static int is_letter(int c) { return (unsigned)((c | 32) - 'a') < 26; }
static int lower(int c) { return (unsigned)(c - 'A') < 26 ? c + 32 : c; }
static int upper(int c) { return (unsigned)(c - 'a') < 26 ? c - 32 : c; }

/* 1 for the 52 letters: the scanning loops look bytes up instead of testing. */
static const uint8_t letter[256] = {
    ['A'] = 1, ['B'] = 1, ['C'] = 1, ['D'] = 1, ['E'] = 1, ['F'] = 1, ['G'] = 1,
    ['H'] = 1, ['I'] = 1, ['J'] = 1, ['K'] = 1, ['L'] = 1, ['M'] = 1, ['N'] = 1,
    ['O'] = 1, ['P'] = 1, ['Q'] = 1, ['R'] = 1, ['S'] = 1, ['T'] = 1, ['U'] = 1,
    ['V'] = 1, ['W'] = 1, ['X'] = 1, ['Y'] = 1, ['Z'] = 1,
    ['a'] = 1, ['b'] = 1, ['c'] = 1, ['d'] = 1, ['e'] = 1, ['f'] = 1, ['g'] = 1,
    ['h'] = 1, ['i'] = 1, ['j'] = 1, ['k'] = 1, ['l'] = 1, ['m'] = 1, ['n'] = 1,
    ['o'] = 1, ['p'] = 1, ['q'] = 1, ['r'] = 1, ['s'] = 1, ['t'] = 1, ['u'] = 1,
    ['v'] = 1, ['w'] = 1, ['x'] = 1, ['y'] = 1, ['z'] = 1,
};

/* Scans the word at in[p..n): returns its end, its FNV-1a hash in lower case
   and its case class: 0 lower, 1 Capitalised, 2 UPPER (two letters or more),
   3 mixed. Letters only, so lower case is c | 32. */
static int32_t scan_word(const uint8_t *in, int32_t p, int32_t n, uint32_t *hash,
                         int *cc)
{
    int32_t s = p;
    uint32_t h = 2166136261u;
    int nup = 0;
    while (p < n && letter[in[p]])
    {
        nup += in[p] < 'a';
        h = (h ^ (uint32_t)(in[p] | 32)) * 16777619u;
        p++;
    }
    *hash = h;
    if (nup == 0) *cc = 0;
    else if (nup == 1 && in[s] < 'a') *cc = 1;
    else if (nup == p - s && p - s > 1) *cc = 2;
    else *cc = 3;
    return p;
}

/* 16 bytes, so the table stays small enough to live in cache. */
typedef struct
{
    uint32_t pos;            /* first occurrence in the block */
    uint32_t hash;
    uint32_t freq;
    int32_t code : 24;       /* -1 until the word gets a code */
    uint32_t len : 8;        /* 0 marks an empty slot */
} Word;

typedef struct
{
    const uint8_t *src;
    Word *slot;
    uint32_t mask, count, limit;
} Table;

/* A dictionary candidate, sorted with no global state. */
typedef struct
{
    const uint8_t *w;
    Word *slot;
    uint32_t freq;
    int len;
} Cand;

static int same_word(const uint8_t *a, const uint8_t *b, int len)
{
    int i;
    for (i = 0; i < len; i++)
        if ((a[i] | 32) != (b[i] | 32)) return 0;
    return 1;
}

/* Finds a word, case-insensitively; adds it when add is set and the table is
   not full. A full table only stops new words from being counted, which keeps
   the result deterministic. */
static Word *table_find(Table *t, const uint8_t *w, int len, uint32_t hash, int add)
{
    uint32_t i = hash & t->mask;
    while (t->slot[i].len)
    {
        Word *s = &t->slot[i];
        if (s->hash == hash && (int)s->len == len && same_word(t->src + s->pos, w, len))
            return s;
        i = (i + 1) & t->mask;
    }
    if (!add || t->count >= t->limit) return NULL;
    t->slot[i].pos = (uint32_t)(w - t->src);
    t->slot[i].hash = hash;
    t->slot[i].len = (uint8_t)len;
    t->slot[i].freq = 0;
    t->slot[i].code = -1;
    t->count++;
    return &t->slot[i];
}

static int cmp_lex(const Cand *x, const Cand *y)
{
    int n = x->len < y->len ? x->len : y->len, i, d;
    for (i = 0; i < n; i++)
    {
        d = lower(x->w[i]) - lower(y->w[i]);
        if (d) return d;
    }
    return (int)x->len - (int)y->len;
}

/* By the bytes a word saves, then alphabetically: a total order. */
static int cmp_gain(const void *a, const void *b)
{
    const Cand *x = (const Cand *)a, *y = (const Cand *)b;
    uint64_t gx = (uint64_t)x->freq * (x->len - 1), gy = (uint64_t)y->freq * (y->len - 1);
    if (gx != gy) return gx > gy ? -1 : 1;
    return cmp_lex(x, y);
}

static int cmp_alpha(const void *a, const void *b)
{
    return cmp_lex((const Cand *)a, (const Cand *)b);
}

/* Keys are count << 8 | byte: rarest first, then by value. */
static int cmp_key(const void *a, const void *b)
{
    uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
    return x < y ? -1 : x > y;
}

static int put_varint(uint8_t *p, uint32_t v)
{
    int n = 0;
    while (v >= 0x80) { p[n++] = (uint8_t)(v | 0x80); v >>= 7; }
    p[n++] = (uint8_t)v;
    return n;
}

/* Transforms in[0..n) into out, which has room for limit bytes. Returns the
   transformed size, always below limit (and limit at most n), or -1 when the
   transform does not apply or would not get under the limit. The size is
   known exactly before the body is written, so a block that would miss the
   limit costs only the counting pass. Reentrant: blocks are transformed in
   parallel. */
int32_t tvct_text_encode(const uint8_t *in, int32_t n, uint8_t *out, int32_t limit)
{
    uint32_t cnt[256];
    uint64_t order[256];
    int nord = 0, i, c, tlog;
    uint8_t res[256];
    int nres = 0, esc = -1, caps, dict = 0, n1 = 0, n2 = 0;
    uint8_t is_res[256];
    Table t;
    Cand *sel = NULL;
    uint64_t *chosen = NULL;
    uint32_t nsel = 0, nw;
    int32_t o, p, s, len, minf, result = -1;
    uint64_t escaped = 0, flags_n = 0, size;
    uint32_t hash;
    int cc;

    if (n < 64 || limit > n || limit < 16)
        return -1;

    memset(cnt, 0, sizeof cnt);
    for (p = 0; p < n; p++)
        cnt[in[p]]++;

    /* Reserved bytes: free non-letters, high values first. */
    for (c = 255; c >= 0; c--)
        if (!cnt[c] && !is_letter(c))
            res[nres++] = (uint8_t)c;
    if (nres < RESERVE_WANT)
    {
        for (c = 0; c < 256; c++)
            if (cnt[c] && !is_letter(c))
                order[nord++] = (uint64_t)cnt[c] << 8 | (uint64_t)c;
        if (nord < RESERVE_WANT - nres + 1)
            return -1;
        qsort(order, (size_t)nord, sizeof order[0], cmp_key);
        esc = (int)(order[0] & 0xFF);
        escaped = cnt[esc];
        for (i = 1; nres < RESERVE_WANT; i++)
        {
            res[nres++] = (uint8_t)(order[i] & 0xFF);
            escaped += cnt[order[i] & 0xFF];
        }
        /* Escapes cost a byte each; past 1 % of the block they eat the gain. */
        if (escaped * 100 > (uint64_t)n)
            return -1;
    }
    memset(is_res, 0, sizeof is_res);
    for (i = 0; i < nres; i++)
        is_res[res[i]] = 1;
    if (esc >= 0)
        is_res[esc] = 1;
    caps = 1;

    /* Count the words that could take a dictionary entry. */
    /* A block of n bytes has at most n / 3 distinct words of two letters. */
    tlog = 10;
    while (tlog < TABLE_LOG && (1u << tlog) < (uint32_t)n / 2)
        tlog++;
    t.src = in;
    t.mask = (1u << tlog) - 1;
    t.count = 0;
    t.limit = (t.mask + 1) / 4 * 3;
    t.slot = (Word *)calloc((size_t)t.mask + 1, sizeof(Word));
    if (!t.slot)
        return -1;
    for (p = 0; p < n; )
    {
        if (!letter[in[p]]) { p++; continue; }
        s = p;
        p = scan_word(in, p, n, &hash, &cc);
        len = p - s;
        flags_n += cc == 1 || cc == 2;
        if (len >= WORD_MIN && len <= WORD_MAX && cc != 3)
        {
            Word *w = table_find(&t, in + s, len, hash, 1);
            if (w) w->freq++;
        }
    }

    /* Pick the dictionary. A word must occur often enough to beat the cost of
       its own entry after compression; the threshold grows with the block
       (128 for blocks up to 8 MiB, measured on prose and on a mixed corpus). */
    minf = n >> 16;
    if (minf < MIN_FREQ) minf = MIN_FREQ;
    nsel = 0;
    for (i = 0; i <= (int)t.mask; i++)
        if (t.slot[i].len && t.slot[i].freq >= (uint32_t)minf)
            nsel++;
    sel = (Cand *)malloc(((size_t)nsel + 1) * sizeof(Cand));
    chosen = (uint64_t *)calloc((size_t)1 << (SEL_BITS - 6), sizeof(uint64_t));
    if (!sel || !chosen)
        goto done;
    nsel = 0;
    for (i = 0; i <= (int)t.mask; i++)
        if (t.slot[i].len && t.slot[i].freq >= (uint32_t)minf)
        {
            sel[nsel].w = in + t.slot[i].pos;
            sel[nsel].slot = &t.slot[i];
            sel[nsel].freq = t.slot[i].freq;
            sel[nsel].len = (int)t.slot[i].len;
            nsel++;
        }
    qsort(sel, nsel, sizeof(Cand), cmp_gain);
    {
        int avail = nres - 2;
        int n2max = avail / 4 > 64 ? 64 : avail / 4;
        uint32_t maxw, k = 0, j;
        n1 = avail - n2max;
        maxw = (uint32_t)n1 + (uint32_t)n2max * 256;
        for (j = 0; j < nsel && k < maxw; j++)
        {
            int cl = k < (uint32_t)n1 ? 1 : 2;
            int64_t save = (int64_t)sel[j].freq * (sel[j].len - cl) - (sel[j].len + 1);
            if (save > 0)
                sel[k++] = sel[j];
        }
        nsel = k;
        if (nsel <= (uint32_t)n1) { n1 = (int)nsel; n2 = 0; }
        else n2 = (int)((nsel - (uint32_t)n1 + 255) / 256);
        /* Two-byte codes: the prefix keeps the frequency tier, the index is
           alphabetical inside it, which compresses the entries better. */
        for (j = (uint32_t)n1; j < nsel; j += 256)
            qsort(sel + j, nsel - j < 256 ? nsel - j : 256, sizeof(Cand), cmp_alpha);
        for (j = 0; j < nsel; j++)
        {
            uint32_t b = sel[j].slot->hash & ((1u << SEL_BITS) - 1);
            sel[j].slot->code = (int32_t)j;
            chosen[b >> 6] |= (uint64_t)1 << (b & 63);
        }
    }
    dict = nsel > 0;

    /* The exact output size: every byte, plus escapes and case flags, minus
       what the codes save, plus the header and the dictionary. */
    size = (uint64_t)n + escaped + flags_n + 2 + (uint64_t)nres + (esc >= 0);
    if (dict)
    {
        uint8_t tmp[5];
        uint32_t j;
        size += 2 + (uint64_t)put_varint(tmp, nsel);
        for (j = 0; j < nsel; j++)
        {
            int cl = j < (uint32_t)n1 ? 1 : 2;
            size += (uint64_t)sel[j].len + 1;
            size -= (uint64_t)sel[j].freq * (uint64_t)(sel[j].len - cl);
        }
    }
    if (size >= (uint64_t)limit)
        goto done;

    /* Header: flags, ESC, the reserved bytes, n1, n2 and a varint word count. */
    o = 0;
    if (1 + 1 + 1 + nres + 2 + 5 >= limit)
        goto done;
    out[o++] = (uint8_t)((caps ? TT_CAPS : 0) | (dict ? TT_DICT : 0) | (esc >= 0 ? TT_ESC : 0));
    if (esc >= 0)
        out[o++] = (uint8_t)esc;
    out[o++] = (uint8_t)nres;
    memcpy(out + o, res, (size_t)nres);
    o += nres;
    if (dict)
    {
        out[o++] = (uint8_t)n1;
        out[o++] = (uint8_t)n2;
        o += put_varint(out + o, nsel);
        for (nw = 0; nw < nsel; nw++)
        {
            if (o + sel[nw].len + 1 >= limit)
                goto done;
            for (i = 0; i < sel[nw].len; i++)
                out[o++] = (uint8_t)lower(sel[nw].w[i]);
            out[o++] = 0;
        }
    }

    /* Body. The size was checked above; every write is still checked against
       the limit, so a mistake there can only lose the transform. */
    {
        const uint8_t *code = res + 2;
        int cap_flag = res[0], up_flag = res[1];
        for (p = 0; p < n; )
        {
            Word *w;
            if (o + 3 >= limit)
                goto done;
            if (!letter[in[p]])
            {
                if (is_res[in[p]])
                    out[o++] = (uint8_t)esc;
                out[o++] = in[p++];
                continue;
            }
            s = p;
            p = scan_word(in, p, n, &hash, &cc);
            len = p - s;
            if (cc == 1 || cc == 2)
                out[o++] = (uint8_t)(cc == 1 ? cap_flag : up_flag);
            w = NULL;
            if (dict && len >= WORD_MIN && len <= WORD_MAX && cc != 3)
            {
                uint32_t b = hash & ((1u << SEL_BITS) - 1);
                if (chosen[b >> 6] >> (b & 63) & 1)
                    w = table_find(&t, in + s, len, hash, 0);
            }
            if (w && w->code >= 0)
            {
                int k = w->code;
                if (k < n1)
                    out[o++] = code[k];
                else
                {
                    k -= n1;
                    out[o++] = code[n1 + k / 256];
                    out[o++] = (uint8_t)(k % 256);
                }
            }
            else
            {
                if (o + len >= limit)
                    goto done;
                if (cc == 1 || cc == 2)
                    for (i = 0; i < len; i++) out[o++] = (uint8_t)lower(in[s + i]);
                else
                {
                    memcpy(out + o, in + s, (size_t)len);
                    o += len;
                }
            }
        }
    }
    result = o < limit && (uint64_t)o == size ? o : -1;

done:
    free(chosen);
    free(sel);
    free(t.slot);
    return result;
}

static int get_varint(const uint8_t *in, int32_t len, int32_t *pos, uint32_t *v)
{
    uint32_t r = 0;
    int shift = 0;
    while (*pos < len && shift <= 28)
    {
        uint8_t b = in[(*pos)++];
        r |= (uint32_t)(b & 0x7F) << shift;
        if (!(b & 0x80)) { *v = r; return 1; }
        shift += 7;
    }
    return 0;
}

/* Inverse transform: in[0..len) back to exactly n bytes at out. Returns 0, or
   -1 on anything malformed; out is then garbage, never overrun. */
int32_t tvct_text_decode(const uint8_t *in, int32_t len, uint8_t *out, int32_t n)
{
    int role[256];          /* -1 literal, -2 CAP, -3 UPPER, -4 ESC, -5 unused, k code byte */
    int32_t p = 0, o = 0, *woff = NULL, i, k;
    int flags, esc = -1, nres, ncode, n1 = 0, n2 = 0, caps;
    uint32_t nwords = 0;
    uint8_t *wlen = NULL;
    int32_t result = -1;

    if (len < 2 || n < 0)
        return -1;
    flags = in[p++];
    if (flags & ~(TT_CAPS | TT_DICT | TT_ESC))
        return -1;
    caps = flags & TT_CAPS;
    for (i = 0; i < 256; i++) role[i] = -1;
    if (flags & TT_ESC)
    {
        esc = in[p++];
        if (is_letter(esc)) return -1;
        role[esc] = -4;
    }
    if (p >= len) return -1;
    nres = in[p++];
    if (len - p < nres) return -1;
    for (i = 0; i < nres; i++)
    {
        int b = in[p + i];
        if (is_letter(b) || role[b] != -1) return -1;     /* letters, ESC, duplicates */
        role[b] = -5;
    }
    if (caps)
    {
        if (nres < 2) return -1;
        role[in[p]] = -2;
        role[in[p + 1]] = -3;
    }
    ncode = nres - (caps ? 2 : 0);
    if (flags & TT_DICT)
    {
        const uint8_t *code = in + p + (caps ? 2 : 0);
        p += nres;
        if (len - p < 2) return -1;
        n1 = in[p++];
        n2 = in[p++];
        if (n1 + n2 > ncode || n1 + n2 == 0) return -1;
        if (!get_varint(in, len, &p, &nwords)) return -1;
        if (nwords == 0 || nwords > (uint32_t)n1 + 256u * (uint32_t)n2) return -1;
        for (i = 0; i < n1 + n2; i++)
            role[code[i]] = i;
        woff = (int32_t *)malloc(nwords * sizeof(int32_t));
        wlen = (uint8_t *)malloc(nwords);
        if (!woff || !wlen) goto done;
        for (k = 0; k < (int32_t)nwords; k++)
        {
            int32_t s = p;
            while (p < len && in[p] != 0)
            {
                if ((unsigned)(in[p] - 'a') >= 26 || p - s >= WORD_LIMIT) goto done;
                p++;
            }
            if (p >= len || p - s < 1) goto done;
            woff[k] = s;
            wlen[k] = (uint8_t)(p - s);
            p++;
        }
    }
    else
        p += nres;

    while (p < len)
    {
        int b = in[p], r = role[b], cs = 0;
        int32_t start = o;
        if (r == -1)
        {
            if (o >= n) goto done;
            out[o++] = (uint8_t)b;
            p++;
            continue;
        }
        if (r == -4)
        {
            if (p + 1 >= len || o >= n) goto done;
            out[o++] = in[p + 1];
            p += 2;
            continue;
        }
        if (r == -2 || r == -3)
        {
            cs = r == -2 ? 1 : 2;
            if (++p >= len) goto done;
            b = in[p];
            r = role[b];
        }
        if (r >= 0)
        {
            uint32_t idx;
            if (r < n1) { idx = (uint32_t)r; p++; }
            else
            {
                if (p + 1 >= len) goto done;
                idx = (uint32_t)n1 + (uint32_t)(r - n1) * 256u + in[p + 1];
                p += 2;
            }
            if (idx >= nwords || wlen[idx] > n - o) goto done;
            memcpy(out + o, in + woff[idx], wlen[idx]);
            o += wlen[idx];
        }
        else if (cs && is_letter(b))
        {
            while (p < len && is_letter(in[p]))
            {
                if (o >= n) goto done;
                out[o++] = in[p++];
            }
        }
        else
            goto done;          /* a flag before nothing, or an unused reserved byte */
        if (cs == 1)
            out[start] = (uint8_t)upper(out[start]);
        else if (cs == 2)
            for (i = start; i < o; i++) out[i] = (uint8_t)upper(out[i]);
    }
    result = o == n ? 0 : -1;

done:
    free(woff);
    free(wlen);
    return result;
}

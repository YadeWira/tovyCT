/* tovyCT CRC-32C (Castagnoli).
 *
 * Three implementations, picked once per process:
 *
 *  - SSE4.2 `crc32` (x86-64, i386) or AArch64 `crc32cd`, the hardware
 *    instruction, about 8-15 GB/s;
 *  - slicing-by-8, table driven, about 1.5 GB/s, used when the instruction is
 *    missing (old CPUs, and the 32-bit build on a machine without SSE4.2);
 *  - the same table one byte at a time is what it replaces.
 *
 * The polynomial and the reflected convention are CRC-32C, so the hardware path
 * and the table path produce the same bytes: the compressed stream does not
 * depend on which one runs.
 */
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#define CRC32C_POLY 0x82F63B78u

static uint32_t table[8][256];
static int table_ready = 0;

static void build_table(void)
{
    uint32_t i, k, c;
    for (i = 0; i < 256; i++)
    {
        c = i;
        for (k = 0; k < 8; k++)
            c = (c & 1) ? (c >> 1) ^ CRC32C_POLY : c >> 1;
        table[0][i] = c;
    }
    for (i = 0; i < 256; i++)
        for (k = 1; k < 8; k++)
            table[k][i] = (table[k - 1][i] >> 8) ^ table[0][table[k - 1][i] & 0xFF];
    table_ready = 1;
}

static uint32_t crc_table(uint32_t crc, const uint8_t *p, size_t n)
{
    if (!table_ready) build_table();
    crc = ~crc;
    while (n >= 8)
    {
        uint32_t lo, hi;
        memcpy(&lo, p, 4);
        memcpy(&hi, p + 4, 4);
        lo ^= crc;
        crc = table[7][lo & 0xFF] ^ table[6][(lo >> 8) & 0xFF] ^
              table[5][(lo >> 16) & 0xFF] ^ table[4][lo >> 24] ^
              table[3][hi & 0xFF] ^ table[2][(hi >> 8) & 0xFF] ^
              table[1][(hi >> 16) & 0xFF] ^ table[0][hi >> 24];
        p += 8;
        n -= 8;
    }
    while (n--)
        crc = (crc >> 8) ^ table[0][(crc ^ *p++) & 0xFF];
    return ~crc;
}

#if defined(__x86_64__) || defined(_M_X64) || defined(__i386__) || defined(_M_IX86)

#include <nmmintrin.h>
#if defined(__GNUC__) || defined(__clang__)
#include <cpuid.h>
#endif

#define HAVE_HW 1

static int hw_ok = -1;

/* CPUID leaf 1, ECX bit 20. Spelled out instead of __builtin_cpu_supports so
 * the object needs no libgcc helpers: Free Pascal does not link them. */
static int cpu_has_sse42(void)
{
#if defined(__GNUC__) || defined(__clang__)
    unsigned a = 0, b = 0, c = 0, d = 0;
    if (!__get_cpuid(1, &a, &b, &c, &d))
        return 0;
    return (int)((c >> 20) & 1);
#else
    return 0;
#endif
}

#if defined(__GNUC__) || defined(__clang__)
__attribute__((target("sse4.2")))
#endif
static uint32_t crc_sse42(uint32_t crc, const uint8_t *p, size_t n)
{
    crc = ~crc;
#if defined(__x86_64__) || defined(_M_X64)
    while (n >= 8)
    {
        uint64_t v;
        memcpy(&v, p, 8);
        crc = (uint32_t)_mm_crc32_u64(crc, v);
        p += 8;
        n -= 8;
    }
#endif
    while (n--)
        crc = _mm_crc32_u8(crc, *p++);
    return ~crc;
}

#elif defined(__aarch64__)

#include <arm_acle.h>

#ifdef __ARM_FEATURE_CRC32
#define HAVE_HW 1
#define HW_OK 1
static uint32_t crc_arm(uint32_t crc, const uint8_t *p, size_t n)
{
    crc = ~crc;
    while (n >= 8)
    {
        uint64_t v;
        memcpy(&v, p, 8);
        crc = (uint32_t)__crc32cd(crc, v);
        p += 8;
        n -= 8;
    }
    while (n--)
        crc = __crc32cb(crc, *p++);
    return ~crc;
}
#endif

#endif

#ifndef HAVE_HW
#define HAVE_HW 0
#endif

uint32_t tvct_crc32c(uint32_t crc, const void *data, size_t n)
{
#if HAVE_HW
#if defined(__aarch64__)
    return crc_arm(crc, (const uint8_t *)data, n);
#else
    if (hw_ok < 0) hw_ok = cpu_has_sse42();
    if (hw_ok) return crc_sse42(crc, (const uint8_t *)data, n);
#endif
#endif
    return crc_table(crc, (const uint8_t *)data, n);
}

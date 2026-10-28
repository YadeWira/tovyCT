/* tovyCT guard-page sandbox for the decode path.
 *
 * The entropy decoder and the inverse BWT read a stream the caller may not
 * trust. Their bounds are checked and fuzzed, but a check is an argument and a
 * guard page is a fact: every buffer the decode path writes to, and the copy of
 * the compressed payload it reads from, ends exactly at a page that is mapped
 * PROT_NONE. A write past the end, or a read past the payload, faults instead
 * of touching whatever follows the allocation.
 *
 * tvct_guard_run() catches that fault and returns -1, so a hostile stream is a
 * decode error rather than a crash. The mechanism is per thread (each worker
 * decodes blocks in parallel) and restores the previous signal disposition when
 * the fault is not ours.
 *
 * Windows has no implementation: the allocations stay plain and the coder's own
 * bounds remain the only guard there, which keeps the build free of win32
 * import libraries. The command line reports the sandbox as unavailable.
 *
 * Recovery is off unless tvct_guard_enable(1) is called; the command line turns
 * it on because it owns the process. A library that installs a SIGSEGV handler
 * behind its host's back would be rude, so the C API leaves it to the caller.
 */
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

#if defined(_WIN32)

/* No sandbox on Windows: the coder's own bounds are the only guard there. The
 * allocations stay plain so the build needs no win32 import library. */
void *tvct_guard_alloc(size_t n)
{
    return malloc(n == 0 ? 1 : n);
}

void tvct_guard_free(void *p, size_t n)
{
    (void)n;
    free(p);
}

int tvct_guard_run(void (*fn)(void *), void *ctx)
{
    if (fn) fn(ctx);
    return 0;
}

int tvct_guard_available(void) { return 0; }

int tvct_guard_enable(int on) { (void)on; return 0; }

int tvct_guard_selftest(void) { return 0; }

#else

#include <signal.h>
#include <setjmp.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <pthread.h>

#ifndef MAP_ANONYMOUS
#define MAP_ANONYMOUS MAP_ANON
#endif

#define GUARD_MAX 256
#define ALTSTACK_BYTES 65536

static volatile sig_atomic_t g_enabled = 0;
static int g_installed = 0;
static struct sigaction g_prev_segv, g_prev_bus;
static pthread_once_t g_once = PTHREAD_ONCE_INIT;
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;

/* Guard pages currently mapped, so the handler can tell our faults from the
 * host program's. A miss here only means the process dies as it would have. */
static struct { char *lo, *hi; } g_guard[GUARD_MAX];
static int g_guard_n = 0;

typedef struct
{
    sigjmp_buf jb;
    volatile sig_atomic_t active;
} GuardTls;

static __thread GuardTls tls;
static __thread char altstack_mem[ALTSTACK_BYTES] __attribute__((aligned(16)));
static __thread int altstack_set = 0;

static size_t page_size(void)
{
    static size_t pg = 0;
    if (pg == 0)
    {
        long v = sysconf(_SC_PAGESIZE);
        pg = v > 0 ? (size_t)v : 4096;
    }
    return pg;
}

static void guard_register(char *lo, char *hi)
{
    pthread_mutex_lock(&g_lock);
    if (g_guard_n < GUARD_MAX)
    {
        g_guard[g_guard_n].lo = lo;
        g_guard[g_guard_n].hi = hi;
        g_guard_n++;
    }
    pthread_mutex_unlock(&g_lock);
}

static void guard_unregister(char *lo)
{
    pthread_mutex_lock(&g_lock);
    for (int i = g_guard_n - 1; i >= 0; i--)
        if (g_guard[i].lo == lo)
        {
            g_guard[i] = g_guard[--g_guard_n];
            break;
        }
    pthread_mutex_unlock(&g_lock);
}

static int guard_owns(void *addr)
{
    const char *p = (const char *)addr;
    for (int i = 0; i < g_guard_n; i++)
        if (p >= g_guard[i].lo && p < g_guard[i].hi)
            return 1;
    return 0;
}

static void fault_handler(int sig, siginfo_t *si, void *uc)
{
    (void)uc;
    if (tls.active && guard_owns(si->si_addr))
    {
        tls.active = 0;
        siglongjmp(tls.jb, 1);
    }
    /* Someone else's fault: put back what was there and let it happen again. */
    g_installed = 0;
    sigaction(sig, sig == SIGBUS ? &g_prev_bus : &g_prev_segv, NULL);
}

static void install_handler(void)
{
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = fault_handler;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigemptyset(&sa.sa_mask);
    if (sigaction(SIGSEGV, &sa, &g_prev_segv) == 0)
    {
#ifdef SIGBUS
        sigaction(SIGBUS, &sa, &g_prev_bus);
#endif
        g_installed = 1;
    }
}

void *tvct_guard_alloc(size_t n)
{
    size_t pg = page_size(), body, total;
    char *base;
    if (n == 0) n = 1;
    body = (n + pg - 1) / pg * pg;
    total = body + pg;
    base = (char *)mmap(NULL, total, PROT_READ | PROT_WRITE,
                        MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (base == MAP_FAILED) return NULL;
    if (mprotect(base + body, pg, PROT_NONE) != 0)
    {
        munmap(base, total);
        return NULL;
    }
    guard_register(base + body, base + body + pg);
    return base + body - n;
}

void tvct_guard_free(void *p, size_t n)
{
    size_t pg = page_size(), body;
    char *base;
    if (!p) return;
    if (n == 0) n = 1;
    body = (n + pg - 1) / pg * pg;
    base = (char *)p - (body - n);
    guard_unregister(base + body);
    munmap(base, body + pg);
}

static void ensure_altstack(void)
{
    stack_t ss;
    if (altstack_set) return;
    ss.ss_sp = altstack_mem;
    ss.ss_size = sizeof altstack_mem;
    ss.ss_flags = 0;
    if (sigaltstack(&ss, NULL) == 0) altstack_set = 1;
}

int tvct_guard_run(void (*fn)(void *), void *ctx)
{
    if (!fn) return 0;
    if (!g_enabled) { fn(ctx); return 0; }
    ensure_altstack();
    pthread_once(&g_once, install_handler);
    if (!g_installed) { fn(ctx); return 0; }
    if (sigsetjmp(tls.jb, 1) == 0)
    {
        tls.active = 1;
        fn(ctx);
        tls.active = 0;
        return 0;
    }
    return -1;
}

int tvct_guard_available(void) { return 1; }

int tvct_guard_enable(int on)
{
    int prev = g_enabled;
    g_enabled = on ? 1 : 0;
    return prev;
}

/* One byte past a guarded buffer, inside tvct_guard_run: the sandbox must turn
 * that into -1. The command line's --guard-check and the test suite call it. */
static void selftest_write(void *ctx)
{
    volatile char *p = (volatile char *)ctx;
    p[0] = 1;
}

int tvct_guard_selftest(void)
{
    char *p;
    int r, prev;
    if (!tvct_guard_available()) return 0;
    p = (char *)tvct_guard_alloc(64);
    if (!p) return 0;
    prev = tvct_guard_enable(1);
    r = tvct_guard_run(selftest_write, p + 64);
    tvct_guard_enable(prev);
    tvct_guard_free(p, 64);
    return r == -1;
}

#endif

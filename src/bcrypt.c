/* SPDX-License-Identifier: GPL-2.0-or-later OR LGPL-2.1-or-later */
/*
 * bcrypt.dll stand-in for Altium (X2.EXE) under Wine.
 *
 * Simbeor's license manager (simbeor_sdk.dll) decrypts with BCryptDecrypt(BCRYPT_PAD_NONE), raw RSA,
 * which Wine's bcrypt doesn't implement. This DLL is installed in Altium's program folder and selected
 * for X2.EXE only (AppDefaults override). It loads Wine's real bcrypt.dll from the system directory and
 * forwards all of its exports to it (jump stubs in bcrypt-thunks.S), except:
 *   - BCryptImportKeyPair: forwarded, and RSA private keys are also remembered here;
 *   - BCryptDecrypt with BCRYPT_PAD_NONE on such a key: c^d mod n computed here;
 *   - BCryptDestroyKey: forwarded, and the remembered key is dropped.
 * Optional log: set ALTIUM_BCRYPT_LOG to a file path (Windows path) to append one line per handled call.
 */
#include <windows.h>
#include <bcrypt.h>
#include <stdint.h>
#include <string.h>
#include <stdarg.h>

#ifndef STATUS_BUFFER_TOO_SMALL
#define STATUS_BUFFER_TOO_SMALL ((NTSTATUS)0xC0000023L)
#endif
#ifndef STATUS_INVALID_PARAMETER
#define STATUS_INVALID_PARAMETER ((NTSTATUS)0xC000000DL)
#endif

#include "bcrypt-exports.h"

#define EXPORT_COUNT (sizeof(export_names) / sizeof(export_names[0]))

/* Real entry points, indexed like export_names; used by the jump stubs. */
void *real_bcrypt[EXPORT_COUNT];

/* ---- minimal unsigned bignum, little-endian 32-bit limbs ---- */
#define NL 72 /* up to 2304 bits; enough for products of 1024-bit values */
typedef struct { uint32_t w[NL]; } bn;

static void bn_zero(bn *a) { memset(a, 0, sizeof(*a)); }
static int bn_bits(const bn *a)
{
    for (int i = NL - 1; i >= 0; i--)
        if (a->w[i]) { int b = 32; while (!(a->w[i] >> (b - 1))) b--; return i * 32 + b; }
    return 0;
}
static int bn_cmp(const bn *a, const bn *b)
{
    for (int i = NL - 1; i >= 0; i--)
        if (a->w[i] != b->w[i]) return a->w[i] > b->w[i] ? 1 : -1;
    return 0;
}
static void bn_sub(bn *r, const bn *a, const bn *b) /* r = a - b, a >= b */
{
    uint64_t borrow = 0;
    for (int i = 0; i < NL; i++) {
        uint64_t t = (uint64_t)a->w[i] - b->w[i] - borrow;
        r->w[i] = (uint32_t)t; borrow = (t >> 63) & 1;
    }
}
static void bn_shl1(bn *a)
{
    for (int i = NL - 1; i > 0; i--) a->w[i] = (a->w[i] << 1) | (a->w[i - 1] >> 31);
    a->w[0] <<= 1;
}
static void bn_mul(bn *r, const bn *a, const bn *b)
{
    bn t; bn_zero(&t);
    for (int i = 0; i < NL; i++) {
        if (!a->w[i]) continue;
        uint64_t carry = 0;
        for (int j = 0; i + j < NL; j++) {
            uint64_t cur = (uint64_t)a->w[i] * b->w[j] + t.w[i + j] + carry;
            t.w[i + j] = (uint32_t)cur; carry = cur >> 32;
        }
    }
    *r = t;
}
static void bn_mod(bn *r, const bn *a, const bn *m) /* r = a mod m, shift-subtract */
{
    bn rem; bn_zero(&rem);
    for (int i = bn_bits(a) - 1; i >= 0; i--) {
        bn_shl1(&rem);
        rem.w[0] |= (a->w[i / 32] >> (i % 32)) & 1;
        if (bn_cmp(&rem, m) >= 0) bn_sub(&rem, &rem, m);
    }
    *r = rem;
}
static void bn_modexp(bn *r, const bn *base, const bn *exp, const bn *m)
{
    bn res, b; bn_zero(&res); res.w[0] = 1;
    bn_mod(&b, base, m);
    for (int i = bn_bits(exp) - 1; i >= 0; i--) {
        bn_mul(&res, &res, &res); bn_mod(&res, &res, m);
        if ((exp->w[i / 32] >> (i % 32)) & 1) { bn_mul(&res, &res, &b); bn_mod(&res, &res, m); }
    }
    *r = res;
}
static uint32_t bn_mod_small(const bn *a, uint32_t m)
{
    uint64_t r = 0;
    for (int i = NL - 1; i >= 0; i--) r = ((r << 32) | a->w[i]) % m;
    return (uint32_t)r;
}
static void bn_mul_small_add(bn *r, const bn *a, uint32_t k, uint32_t add)
{
    uint64_t carry = add;
    for (int i = 0; i < NL; i++) {
        uint64_t cur = (uint64_t)a->w[i] * k + carry;
        r->w[i] = (uint32_t)cur; carry = cur >> 32;
    }
}
static void bn_div_small(bn *r, const bn *a, uint32_t d)
{
    uint64_t rem = 0;
    for (int i = NL - 1; i >= 0; i--) {
        uint64_t cur = (rem << 32) | a->w[i];
        r->w[i] = (uint32_t)(cur / d); rem = cur % d;
    }
}
static int bn_from_be(bn *a, const UCHAR *p, ULONG n)
{
    if (n > NL * 4) return 0;
    bn_zero(a);
    for (ULONG i = 0; i < n; i++) {
        ULONG bit = (n - 1 - i);
        a->w[bit / 4] |= (uint32_t)p[i] << (8 * (bit % 4));
    }
    return 1;
}
static void bn_to_be(const bn *a, UCHAR *p, ULONG n)
{
    for (ULONG i = 0; i < n; i++) {
        ULONG bit = (n - 1 - i);
        p[i] = bit / 4 < NL ? (UCHAR)(a->w[bit / 4] >> (8 * (bit % 4))) : 0;
    }
}

/* ---- remembered RSA private keys ---- */
typedef struct { BCRYPT_KEY_HANDLE h; bn n, d; ULONG cbModulus; } rsakey;
#define MAXKEYS 64
static rsakey keys[MAXKEYS];
static CRITICAL_SECTION cs;

static int derive_key(rsakey *k, const UCHAR *blob, ULONG cb)
{
    const BCRYPT_RSAKEY_BLOB *h = (const BCRYPT_RSAKEY_BLOB *)blob;
    if (cb < sizeof(*h)) return 0;
    if (h->Magic != BCRYPT_RSAPRIVATE_MAGIC && h->Magic != BCRYPT_RSAFULLPRIVATE_MAGIC) return 0;
    if (h->cbPublicExp > 4) return 0; /* small exponent only (e.g. 65537) */
    ULONG need = sizeof(*h) + h->cbPublicExp + h->cbModulus + h->cbPrime1 + h->cbPrime2;
    if (cb < need) return 0;
    const UCHAR *p = blob + sizeof(*h);
    uint32_t e = 0;
    for (ULONG i = 0; i < h->cbPublicExp; i++) e = (e << 8) | p[i];
    p += h->cbPublicExp;
    bn P, Q, phi, one; bn_zero(&one); one.w[0] = 1;
    if (!bn_from_be(&k->n, p, h->cbModulus)) return 0; p += h->cbModulus;
    if (!bn_from_be(&P, p, h->cbPrime1)) return 0; p += h->cbPrime1;
    if (!bn_from_be(&Q, p, h->cbPrime2)) return 0;
    if (e < 3) return 0;
    bn_sub(&P, &P, &one); bn_sub(&Q, &Q, &one);
    bn_mul(&phi, &P, &Q);
    /* d = (1 + k*phi) / e for the k in [1, e) making it divisible */
    uint32_t pm = bn_mod_small(&phi, e), kk;
    for (kk = 1; kk < e; kk++)
        if ((uint32_t)((1 + (uint64_t)kk * pm) % e) == 0) break;
    if (kk == e) return 0;
    bn t; bn_mul_small_add(&t, &phi, kk, 1);
    bn_div_small(&k->d, &t, e);
    k->cbModulus = h->cbModulus;
    return 1;
}

/* ---- forwarding to Wine's bcrypt ---- */
typedef NTSTATUS (WINAPI *pImport)(BCRYPT_ALG_HANDLE, BCRYPT_KEY_HANDLE, LPCWSTR, BCRYPT_KEY_HANDLE *, PUCHAR, ULONG, ULONG);
typedef NTSTATUS (WINAPI *pDecrypt)(BCRYPT_KEY_HANDLE, PUCHAR, ULONG, VOID *, PUCHAR, ULONG, PUCHAR, ULONG, ULONG *, ULONG);
typedef NTSTATUS (WINAPI *pDestroy)(BCRYPT_KEY_HANDLE);
#define real_import ((pImport)real_bcrypt[IDX_BCryptImportKeyPair])
#define real_decrypt ((pDecrypt)real_bcrypt[IDX_BCryptDecrypt])
#define real_destroy ((pDestroy)real_bcrypt[IDX_BCryptDestroyKey])

static HANDLE log_file = INVALID_HANDLE_VALUE;

static void log_call(const char *fmt, ...)
{
    char buf[512];
    va_list ap;
    DWORD written;
    int n;

    if (log_file == INVALID_HANDLE_VALUE)
        return;
    n = wsprintfA(buf, "%lu ", GetTickCount());
    va_start(ap, fmt);
    n += wvsprintfA(buf + n, fmt, ap);
    va_end(ap);
    buf[n++] = '\n';
    EnterCriticalSection(&cs);
    WriteFile(log_file, buf, n, &written, NULL);
    LeaveCriticalSection(&cs);
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID reserved)
{
    if (reason == DLL_PROCESS_ATTACH)
    {
        WCHAR path[MAX_PATH];
        HMODULE real;
        UINT len;
        size_t i;

        len = GetSystemDirectoryW(path, MAX_PATH - 12);
        if (!len || len >= MAX_PATH - 12)
            return FALSE;
        lstrcpyW(path + len, L"\\bcrypt.dll");
        /* Must be Wine's bcrypt, not this module again. */
        if (!(real = LoadLibraryW(path)) || real == (HMODULE)inst)
            return FALSE;
        for (i = 0; i < EXPORT_COUNT; ++i)
        {
            if (!(real_bcrypt[i] = (void *)GetProcAddress(real, export_names[i])))
                return FALSE;
        }
        InitializeCriticalSection(&cs);
        DisableThreadLibraryCalls(inst);
        {
            char logpath[MAX_PATH];
            if (GetEnvironmentVariableA("ALTIUM_BCRYPT_LOG", logpath, sizeof(logpath)))
                log_file = CreateFileA(logpath, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
                        OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
        }
        log_call("loaded; real bcrypt at %p", real);
    }
    return TRUE;
}

NTSTATUS WINAPI BCryptImportKeyPair(BCRYPT_ALG_HANDLE alg, BCRYPT_KEY_HANDLE dec, LPCWSTR type,
        BCRYPT_KEY_HANDLE *key, PUCHAR input, ULONG cb, ULONG flags)
{
    NTSTATUS st = real_import(alg, dec, type, key, input, cb, flags);
    if (st == 0 && key && input && type &&
        (!wcscmp(type, BCRYPT_RSAPRIVATE_BLOB) || !wcscmp(type, BCRYPT_RSAFULLPRIVATE_BLOB))) {
        rsakey k;
        if (derive_key(&k, input, cb)) {
            k.h = *key;
            EnterCriticalSection(&cs);
            for (int i = 0; i < MAXKEYS; i++) if (!keys[i].h) { keys[i] = k; break; }
            LeaveCriticalSection(&cs);
            log_call("BCryptImportKeyPair %ls size=%lu (remembered)", type, cb);
        }
    }
    return st;
}

NTSTATUS WINAPI BCryptDecrypt(BCRYPT_KEY_HANDLE key, PUCHAR in, ULONG cbIn, VOID *pad, PUCHAR iv, ULONG cbIv,
        PUCHAR out, ULONG cbOut, ULONG *cbResult, ULONG flags)
{
    if (flags == BCRYPT_PAD_NONE) {
        rsakey k; int found = 0;
        EnterCriticalSection(&cs);
        for (int i = 0; i < MAXKEYS; i++) if (keys[i].h && keys[i].h == key) { k = keys[i]; found = 1; break; }
        LeaveCriticalSection(&cs);
        if (found) {
            if (!cbResult) return STATUS_INVALID_PARAMETER;
            *cbResult = k.cbModulus;
            if (!out) return 0;
            if (cbOut < k.cbModulus) return STATUS_BUFFER_TOO_SMALL;
            bn c, m;
            if (!in || !bn_from_be(&c, in, cbIn) || bn_cmp(&c, &k.n) >= 0) return STATUS_INVALID_PARAMETER;
            bn_modexp(&m, &c, &k.d, &k.n);
            bn_to_be(&m, out, k.cbModulus);
            log_call("BCryptDecrypt PAD_NONE in=%lu (handled)", cbIn);
            return 0;
        }
    }
    return real_decrypt(key, in, cbIn, pad, iv, cbIv, out, cbOut, cbResult, flags);
}

NTSTATUS WINAPI BCryptDestroyKey(BCRYPT_KEY_HANDLE key)
{
    EnterCriticalSection(&cs);
    for (int i = 0; i < MAXKEYS; i++) if (keys[i].h == key) memset(&keys[i], 0, sizeof(keys[i]));
    LeaveCriticalSection(&cs);
    return real_destroy(key);
}

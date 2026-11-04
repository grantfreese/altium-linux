/* SPDX-License-Identifier: GPL-2.0-or-later OR LGPL-2.1-or-later */
/*
 * msimg32.dll replacement for Altium (X2.EXE) under Wine.
 *
 * Wine's AlphaBlend with AC_SRC_ALPHA doesn't saturate: for source pixels whose color exceeds
 * their alpha (not premultiplied), the per-channel sum overflows into the neighboring channel,
 * which shows as red/yellow pixels on Altium's hover icons. Windows saturates at 255.
 *
 * AlphaBlend passes through to gdi32.GdiAlphaBlend, except for a 1:1 AC_SRC_ALPHA blend from a
 * 32-bit DIB section that contains such pixels; that case is blended here with saturation.
 * GradientFill and TransparentBlt are forwarded to gdi32 (see msimg32.def).
 *
 * Also hides the resize frame of Altium's maximized main window. Altium draws its own title bar and
 * removes the caption in WM_NCCALCSIZE, but keeps the frame; on Windows a maximized window is placed
 * so that the frame is off-screen. Under Wine with window-manager decorations off (X11 Driver
 * Decorated=N), the window manager fits the whole window, frame included, into the work area, so
 * the frame shows as a light border. A hook on Altium's main thread subclasses its top-level
 * windows and, for a maximized window without a caption, makes the client area cover the window.
 */
#include <windows.h>
#include <tlhelp32.h>
#include <stdint.h>

static BYTE sat(unsigned int v)
{
    return v > 255 ? 255 : (BYTE)v;
}

/* Returns the top-down row pointer for a 32-bit DIB section, or NULL. */
static const DWORD *dib_row(const DIBSECTION *ds, int y)
{
    int height = ds->dsBmih.biHeight, stride = ds->dsBm.bmWidthBytes;
    const BYTE *bits = ds->dsBm.bmBits;

    if (height > 0)
        return (const DWORD *)(bits + (size_t)(height - 1 - y) * stride);
    return (const DWORD *)(bits + (size_t)y * stride);
}

static BOOL needs_saturation(const DIBSECTION *ds, int x, int y, int w, int h)
{
    int i, j;

    for (j = 0; j < h; ++j)
    {
        const DWORD *row = dib_row(ds, y + j) + x;
        for (i = 0; i < w; ++i)
        {
            DWORD p = row[i];
            BYTE a = p >> 24;
            if ((BYTE)p > a || (BYTE)(p >> 8) > a || (BYTE)(p >> 16) > a)
                return TRUE;
        }
    }
    return FALSE;
}

static BOOL blend_saturated(HDC dst_dc, int xd, int yd, HDC src_dc, const DIBSECTION *src,
        int xs, int ys, int w, int h, BYTE constant_alpha)
{
    BITMAPINFO bi = {{sizeof(BITMAPINFOHEADER), w, -h, 1, 32, BI_RGB}};
    DWORD *dst_bits;
    HBITMAP tmp;
    HDC tmp_dc;
    int i, j;

    if (!(tmp_dc = CreateCompatibleDC(dst_dc)))
        return FALSE;
    if (!(tmp = CreateDIBSection(dst_dc, &bi, DIB_RGB_COLORS, (void **)&dst_bits, NULL, 0)))
    {
        DeleteDC(tmp_dc);
        return FALSE;
    }
    SelectObject(tmp_dc, tmp);
    BitBlt(tmp_dc, 0, 0, w, h, dst_dc, xd, yd, SRCCOPY);
    GdiFlush();

    for (j = 0; j < h; ++j)
    {
        const DWORD *s = dib_row(src, ys + j) + xs;
        DWORD *d = dst_bits + (size_t)j * w;

        for (i = 0; i < w; ++i)
        {
            DWORD sp = s[i], dp = d[i];
            unsigned int sb = ((BYTE)sp * constant_alpha + 127) / 255;
            unsigned int sg = ((BYTE)(sp >> 8) * constant_alpha + 127) / 255;
            unsigned int sr = ((BYTE)(sp >> 16) * constant_alpha + 127) / 255;
            unsigned int sa = ((BYTE)(sp >> 24) * constant_alpha + 127) / 255;
            unsigned int inv = 255 - sa;

            d[i] = sat(sb + ((BYTE)dp * inv + 127) / 255)
                    | sat(sg + ((BYTE)(dp >> 8) * inv + 127) / 255) << 8
                    | sat(sr + ((BYTE)(dp >> 16) * inv + 127) / 255) << 16
                    | (DWORD)sat(sa + ((BYTE)(dp >> 24) * inv + 127) / 255) << 24;
        }
    }

    BitBlt(dst_dc, xd, yd, w, h, tmp_dc, 0, 0, SRCCOPY);
    DeleteDC(tmp_dc);
    DeleteObject(tmp);
    return TRUE;
}

BOOL WINAPI shim_AlphaBlend(HDC dst_dc, int xd, int yd, int wd, int hd,
        HDC src_dc, int xs, int ys, int ws, int hs, BLENDFUNCTION blend)
{
    DIBSECTION ds;
    HBITMAP bmp;
    POINT org;

    if (blend.BlendOp == AC_SRC_OVER && (blend.AlphaFormat & AC_SRC_ALPHA) && wd == ws && hd == hs
            && wd > 0 && hd > 0 && !GetLayout(dst_dc) && !GetLayout(src_dc)
            && GetMapMode(dst_dc) == MM_TEXT && GetMapMode(src_dc) == MM_TEXT
            && GetGraphicsMode(src_dc) == GM_COMPATIBLE
            && GetWindowOrgEx(src_dc, &org) && !org.x && !org.y
            && GetViewportOrgEx(src_dc, &org) && !org.x && !org.y
            && (bmp = GetCurrentObject(src_dc, OBJ_BITMAP))
            && GetObjectW(bmp, sizeof(ds), &ds) == sizeof(ds)
            && ds.dsBm.bmBits && ds.dsBm.bmBitsPixel == 32
            && ds.dsBmih.biCompression == BI_RGB
            && xs >= 0 && ys >= 0 && xs + ws <= ds.dsBm.bmWidth && ys + hs <= ds.dsBm.bmHeight)
    {
        GdiFlush();
        if (needs_saturation(&ds, xs, ys, ws, hs)
                && blend_saturated(dst_dc, xd, yd, src_dc, &ds, xs, ys, ws, hs, blend.SourceConstantAlpha))
            return TRUE;
    }
    return GdiAlphaBlend(dst_dc, xd, yd, wd, hd, src_dc, xs, ys, ws, hs, blend);
}

VOID WINAPI vSetDdrawflag(void)
{
}

static const WCHAR prop_name[] = L"AltiumWineOrigProc";

static LRESULT CALLBACK frame_wndproc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    WNDPROC orig = (WNDPROC)GetPropW(hwnd, prop_name);
    NCCALCSIZE_PARAMS *params = (NCCALCSIZE_PARAMS *)lp;
    RECT window;
    LRESULT ret;

    if (!orig)
        return DefWindowProcW(hwnd, msg, wp, lp);
    if (msg == WM_NCDESTROY)
    {
        RemovePropW(hwnd, prop_name);
        if ((WNDPROC)GetWindowLongPtrW(hwnd, GWLP_WNDPROC) == frame_wndproc)
            SetWindowLongPtrW(hwnd, GWLP_WNDPROC, (LONG_PTR)orig);
        return CallWindowProcW(orig, hwnd, msg, wp, lp);
    }
    if (msg != WM_NCCALCSIZE || !wp || !IsZoomed(hwnd))
        return CallWindowProcW(orig, hwnd, msg, wp, lp);

    window = params->rgrc[0];
    ret = CallWindowProcW(orig, hwnd, msg, wp, lp);
    /* Only windows that draw their own caption; standard windows keep their title bar. */
    if (params->rgrc[0].top - window.top < GetSystemMetrics(SM_CYCAPTION))
        params->rgrc[0] = window;
    return ret;
}

static void subclass(HWND hwnd)
{
    LONG style = GetWindowLongW(hwnd, GWL_STYLE);
    WNDPROC orig;

    if ((style & WS_CHILD) || !(style & WS_THICKFRAME) || GetPropW(hwnd, prop_name))
        return;
    if (!(orig = (WNDPROC)GetWindowLongPtrW(hwnd, GWLP_WNDPROC)) || orig == frame_wndproc)
        return;
    SetPropW(hwnd, prop_name, (HANDLE)orig);
    SetWindowLongPtrW(hwnd, GWLP_WNDPROC, (LONG_PTR)frame_wndproc);
}

/* Subclasses when a window is about to be moved or resized: by then the VCL has installed its own
 * window procedure (it does so on the first message), so it doesn't replace this one. */
static LRESULT CALLBACK callwndproc_hook(int code, WPARAM wp, LPARAM lp)
{
    const CWPSTRUCT *cwp = (const CWPSTRUCT *)lp;

    if (code == HC_ACTION && cwp->message == WM_WINDOWPOSCHANGING)
        subclass(cwp->hwnd);
    return CallNextHookEx(NULL, code, wp, lp);
}

/* The process's first thread, which runs Altium's UI. msimg32 may be loaded from another thread. */
static DWORD main_thread_id(void)
{
    DWORD pid = GetCurrentProcessId(), tid = 0;
    FILETIME best = {~0u, ~0u}, created, unused;
    THREADENTRY32 te = {sizeof(te)};
    HANDLE snap, thread;

    if ((snap = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0)) == INVALID_HANDLE_VALUE)
        return GetCurrentThreadId();
    for (BOOL ok = Thread32First(snap, &te); ok; ok = Thread32Next(snap, &te))
    {
        if (te.th32OwnerProcessID != pid || !(thread = OpenThread(THREAD_QUERY_LIMITED_INFORMATION, FALSE, te.th32ThreadID)))
            continue;
        if (GetThreadTimes(thread, &created, &unused, &unused, &unused) && CompareFileTime(&created, &best) < 0)
        {
            best = created;
            tid = te.th32ThreadID;
        }
        CloseHandle(thread);
    }
    CloseHandle(snap);
    return tid ? tid : GetCurrentThreadId();
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID reserved)
{
    WCHAR exe[MAX_PATH];
    const WCHAR *name;

    if (reason != DLL_PROCESS_ATTACH)
        return TRUE;
    DisableThreadLibraryCalls(inst);
    /* This DLL is also in system32; only hook Altium itself. */
    GetModuleFileNameW(NULL, exe, MAX_PATH);
    name = wcsrchr(exe, '\\') ? wcsrchr(exe, '\\') + 1 : exe;
    if (!lstrcmpiW(name, L"X2.EXE"))
        SetWindowsHookExW(WH_CALLWNDPROC, callwndproc_hook, inst, main_thread_id());
    return TRUE;
}

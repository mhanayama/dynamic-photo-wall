using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Windows.Interop;

namespace DynamicPhotoWall.DesktopIntegration;

public sealed class DesktopWindowHost : IDisposable
{
    private Window? window;
    private nint hwnd, parent;
    private nint iconLayer, wallpaperLayer;
    private bool raisedDesktop;
    public bool IsAlive => Native.IsWindow(hwnd) && Native.IsWindow(parent) && Native.GetParent(hwnd) == parent;
    public nint Handle => hwnd;
    public string Strategy { get; private set; } = "";

    public void Attach(Window target, MonitorDescriptor monitor)
    {
        var progman = Native.FindWindow("Progman", null);
        if (progman == 0) throw new InvalidOperationException("ExplorerのProgmanが見つかりません。");
        Native.SendMessageTimeout(progman, 0x052C, 0xD, 0x1, 2, 1000, out _);
        // Windows 11 24H2+ places wallpaper WorkerW inside Progman.
        var defview = Native.FindWindowEx(progman, 0, "SHELLDLL_DefView", null);
        var childWorker = Native.FindWindowEx(progman, 0, "WorkerW", null);
        raisedDesktop = (Native.GetWindowLongPtr(progman, Native.GwlExStyle).ToInt64() & Native.NoRedirectionBitmap) != 0;
        nint insertAfter = 1; // HWND_BOTTOM for classic wallpaper-only WorkerW.
        if (defview != 0 && childWorker != 0)
        {
            parent = progman;
            insertAfter = defview; // behind desktop icons, ahead of wallpaper WorkerW.
            iconLayer = defview; wallpaperLayer = childWorker;
            Strategy = raisedDesktop ? "Progman / layered opaque child" : "Progman / child layering";
        }
        else
        {
            Native.EnumWindows((top, _) =>
            {
                if (Native.FindWindowEx(top, 0, "SHELLDLL_DefView", null) == 0) return true;
                var candidate = Native.FindWindowEx(0, top, "WorkerW", null);
                if (candidate != 0 && Native.FindWindowEx(candidate, 0, "SHELLDLL_DefView", null) == 0) parent = candidate;
                return parent == 0;
            }, 0);
            Strategy = "Classic WorkerW";
        }
        if (parent == 0 || !Native.IsWindowVisible(parent)) throw new InvalidOperationException("安全な背面描画用Shell階層を確認できません。表示を停止しました。");
        window = target;
        target.ShowInTaskbar = false;
        target.ShowActivated = false;
        target.WindowStyle = WindowStyle.None;
        target.ResizeMode = ResizeMode.NoResize;
        var oldContext = Native.SetThreadDpiAwarenessContext(Native.GetWindowDpiAwarenessContext(parent));
        try
        {
            hwnd = new WindowInteropHelper(target).EnsureHandle();
            HwndSource.FromHwnd(hwnd)?.AddHook(Hook);
            var style = Native.GetWindowLongPtr(hwnd, Native.GwlStyle).ToInt64();
            Native.SetWindowLongPtr(hwnd, Native.GwlStyle, new nint((style & ~Native.Popup) | Native.Child));
            var ex = Native.GetWindowLongPtr(hwnd, Native.GwlExStyle).ToInt64();
            Native.SetWindowLongPtr(hwnd, Native.GwlExStyle, new nint(ex | Native.ToolWindow | Native.NoActivate | Native.Transparent));
            ConfigureCompositing();
            Native.SetParent(hwnd, parent);
            if (Native.GetParent(hwnd) != parent) throw new Win32Exception(Marshal.GetLastWin32Error(), "Shellへの接続に失敗しました。");
        }
        finally { Native.SetThreadDpiAwarenessContext(oldContext); }
        var context = Native.SetThreadDpiAwarenessContext(new nint(-4));
        try
        {
            var origin = new Native.Point { X = monitor.X, Y = monitor.Y };
            Native.ScreenToClient(parent, ref origin);
            if (!Native.SetWindowPos(hwnd, insertAfter, origin.X, origin.Y, monitor.Width, monitor.Height,
                    Native.NoActivatePos | Native.FrameChanged)) throw new Win32Exception(Marshal.GetLastWin32Error());
            if (!Native.GetWindowRect(hwnd, out var actual) || actual.Left != monitor.X || actual.Top != monitor.Y ||
                actual.Width != monitor.Width || actual.Height != monitor.Height)
                throw new InvalidOperationException("接続後の物理座標がモニター領域と一致しません。DPI互換性を確認してください。");
            Native.GetClientRect(parent, out var client);
            if (origin.X < 0 || origin.Y < 0 || origin.X + monitor.Width > client.Width || origin.Y + monitor.Height > client.Height)
                throw new InvalidOperationException("選択モニターがShell親の描画領域外です。");
            target.Show();
            ConfigureCompositing();
            EnsureZOrder();
            Native.ShowWindow(hwnd, 4); // SW_SHOWNOACTIVATE
        }
        catch { Dispose(); throw; }
        finally { Native.SetThreadDpiAwarenessContext(context); }
    }

    private void ConfigureCompositing()
    {
        if (!raisedDesktop) return;
        // Progman has no redirection surface on raised desktops. Our child must
        // supply its own opaque layered surface; a normal WPF HWND is invisible.
        var ex = Native.GetWindowLongPtr(hwnd, Native.GwlExStyle).ToInt64();
        Native.SetWindowLongPtr(hwnd, Native.GwlExStyle, new nint(ex | Native.Layered));
        if (!Native.SetLayeredWindowAttributes(hwnd, 0, 255, 2))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "デスクトップ用の不透明合成を設定できません。");
    }

    public void EnsureZOrder()
    {
        if (!IsAlive || iconLayer == 0 || !Native.IsWindow(iconLayer)) return;
        var flags = Native.NoMove | Native.NoSize | Native.NoActivatePos;
        if (!Native.SetWindowPos(hwnd, iconLayer, 0, 0, 0, 0, flags)) throw new Win32Exception(Marshal.GetLastWin32Error());
        // Insert only our HWND, preserving Explorer's sibling order and visibility.
        if (wallpaperLayer != 0 && Native.IsWindow(wallpaperLayer) && !IsBefore(hwnd, wallpaperLayer))
            throw new InvalidOperationException("写真ウィンドウが壁紙レイヤーの背後にあります。");
    }

    private static bool IsBefore(nint first, nint second)
    {
        for (var next = Native.GetWindow(first, 2); next != 0; next = Native.GetWindow(next, 2)) if (next == second) return true;
        return false;
    }

    private nint Hook(nint h, int msg, nint w, nint l, ref bool handled)
    {
        if (raisedDesktop && msg == 0x7C && w.ToInt64() == Native.GwlExStyle && l != 0)
        {
            // WPF normally strips WS_EX_LAYERED for opaque render targets.
            // Keep a global-alpha layered surface, without opting into WPF's
            // per-pixel transparent/software path.
            var styleNew = Marshal.ReadInt32(l, sizeof(int));
            Marshal.WriteInt32(l, sizeof(int), styleNew | (int)Native.Layered);
            handled = true;
        }
        if (msg == 0x84) { handled = true; return new nint(-1); } // HTTRANSPARENT
        if (msg == 0x21) { handled = true; return new nint(3); } // MA_NOACTIVATE
        return 0;
    }
    public object Inspect() => new
    {
        Strategy, Parent = $"0x{parent:X}", Window = $"0x{hwnd:X}", IsAlive,
        Child = (Native.GetWindowLongPtr(hwnd, Native.GwlStyle).ToInt64() & Native.Child) != 0,
        ExtendedStyles = $"0x{Native.GetWindowLongPtr(hwnd, Native.GwlExStyle).ToInt64():X}",
        RaisedDesktop = raisedDesktop,
        LayeredOpaque = Native.GetLayeredWindowAttributes(hwnd, out _, out var alpha, out var flags) && alpha == 255 && (flags & 2) != 0,
        BehindIcons = iconLayer != 0 && IsBefore(iconLayer, hwnd),
        AheadOfWallpaper = wallpaperLayer != 0 && IsBefore(hwnd, wallpaperLayer),
        Dpi = Native.GetDpiForWindow(hwnd)
    };
    public void Dispose()
    {
        if (window != null) { try { window.Close(); } catch (InvalidOperationException) { } window = null; }
        hwnd = parent = iconLayer = wallpaperLayer = 0;
    }
}

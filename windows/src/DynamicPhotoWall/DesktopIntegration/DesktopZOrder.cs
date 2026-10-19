namespace DynamicPhotoWall.DesktopIntegration;

// All photo outputs share the interval between Explorer's icons and wallpaper.
// Being anywhere in that interval is sufficient; repeatedly inserting every
// output immediately after the icons makes sibling HWNDs trade places per frame.
internal sealed class DesktopZOrder(Func<nint, nint> nextWindow, Action<nint, nint> insertAfter)
{
    public void Ensure(nint window, nint icons, nint wallpaper)
    {
        if (IsBefore(icons, window) && (wallpaper == 0 || IsBefore(window, wallpaper))) return;
        insertAfter(window, icons);
        if (!IsBefore(icons, window) || (wallpaper != 0 && !IsBefore(window, wallpaper)))
            throw new InvalidOperationException("写真ウィンドウをアイコンと壁紙の間へ配置できません。");
    }

    public bool IsBefore(nint first, nint second)
    {
        for (var next = nextWindow(first); next != 0; next = nextWindow(next))
            if (next == second) return true;
        return false;
    }
}

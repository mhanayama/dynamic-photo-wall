using System.Runtime.InteropServices;

namespace DynamicPhotoWall.DesktopIntegration;

public sealed record MonitorDescriptor(string Id, string Device, string Name, int X, int Y, int Width, int Height, bool Primary)
{
    public override string ToString() => $"{Name} — {Width} × {Height} ({X}, {Y}) 接続中{(Primary ? " / メイン" : "")}";
}

public static class MonitorManager
{
    public static double RefreshRate(MonitorDescriptor monitor)
    {
        var mode = new Native.DisplayMode { Size = 220 };
        return Native.EnumDisplaySettings(monitor.Device, -1, ref mode) && mode.Frequency > 1 ? mode.Frequency : 60;
    }
    public static IReadOnlyList<MonitorDescriptor> Enumerate()
    {
        var list = new List<MonitorDescriptor>();
        var previous = Native.SetThreadDpiAwarenessContext(new nint(-4));
        try
        {
            Native.EnumDisplayMonitors(0, 0, (nint h, nint dc, ref Native.Rect rect, nint p) =>
            {
                var info = new Native.MonitorInfo { Size = Marshal.SizeOf<Native.MonitorInfo>(), Device = "" };
                if (!Native.GetMonitorInfo(h, ref info)) return true;
                var d = new Native.DisplayDevice { Size = Marshal.SizeOf<Native.DisplayDevice>() };
                var found = Native.EnumDisplayDevices(info.Device, 0, ref d, 1);
                list.Add(new(found && !string.IsNullOrWhiteSpace(d.Id) ? d.Id : info.Device, info.Device,
                    found ? d.Description : info.Device, info.Monitor.Left, info.Monitor.Top,
                    info.Monitor.Width, info.Monitor.Height, (info.Flags & 1) != 0));
                return true;
            }, 0);
        }
        finally { Native.SetThreadDpiAwarenessContext(previous); }
        return list;
    }
}

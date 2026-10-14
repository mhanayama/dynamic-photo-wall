using System.Windows.Interop;
using System.Windows.Threading;
using Microsoft.Win32;

namespace DynamicPhotoWall.DesktopIntegration;

public sealed class ExplorerRecovery : IDisposable
{
    private readonly HwndSource notifications;
    private readonly DispatcherTimer settle;
    private readonly DispatcherTimer health;
    private readonly uint taskbarCreated;
    private readonly Native.WinEventProc winEvent;
    private readonly List<nint> hooks = [];
    public event Action? EnvironmentChanged;
    public event Action<bool>? PowerSuspended;
    public event Action? OcclusionChanged;
    public ExplorerRecovery()
    {
        taskbarCreated = Native.RegisterWindowMessage("TaskbarCreated");
        notifications = new HwndSource(new HwndSourceParameters("DynamicPhotoWall.Notifications") { Width = 0, Height = 0, WindowStyle = unchecked((int)0x80000000) });
        notifications.AddHook(OnMessage);
        settle = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        settle.Tick += (_, _) => { settle.Stop(); EnvironmentChanged?.Invoke(); };
        health = new DispatcherTimer { Interval = TimeSpan.FromSeconds(15) };
        health.Tick += (_, _) => EnvironmentChanged?.Invoke(); health.Start();
        SystemEvents.DisplaySettingsChanged += DisplayChanged;
        SystemEvents.PowerModeChanged += PowerChanged;
        winEvent = (_, evt, hwnd, obj, _, _, _) =>
        {
            if (hwnd == 0 || obj != 0) return;
            if (evt == 0x800B && hwnd != Native.GetForegroundWindow()) return;
            notifications.Dispatcher.BeginInvoke(() => OcclusionChanged?.Invoke());
        };
        foreach (var (min, max) in new (uint, uint)[] { (3, 3), (0x16, 0x17), (0x800B, 0x800B) })
        {
            var hook = Native.SetWinEventHook(min, max, 0, winEvent, 0, 0, 2); // OUTOFCONTEXT | SKIPOWNPROCESS
            if (hook != 0) hooks.Add(hook);
        }
    }
    private nint OnMessage(nint hwnd, int msg, nint w, nint l, ref bool handled)
    {
        if ((uint)msg == taskbarCreated || msg is 0x7E or 0x2E0) Schedule();
        return 0;
    }
    private void Schedule() { settle.Stop(); settle.Start(); }
    private void DisplayChanged(object? sender, EventArgs e) => notifications.Dispatcher.BeginInvoke(Schedule);
    private void PowerChanged(object sender, PowerModeChangedEventArgs e) => notifications.Dispatcher.BeginInvoke(() =>
    {
        PowerSuspended?.Invoke(e.Mode == PowerModes.Suspend);
        if (e.Mode == PowerModes.Resume) Schedule();
    });
    public static bool IsCovered(MonitorDescriptor monitor)
    {
        var hwnd = Native.GetForegroundWindow();
        if (hwnd == 0 || !Native.IsWindowVisible(hwnd) || Native.IsIconic(hwnd)) return false;
        if (Native.ClassName(hwnd) is "Progman" or "WorkerW" or "Shell_TrayWnd") return false;
        Native.GetWindowThreadProcessId(hwnd, out var pid);
        if (pid == Environment.ProcessId) return false;
        if (Native.DwmGetWindowAttribute(hwnd, 14, out int cloaked, sizeof(int)) == 0 && cloaked != 0) return false;
        if (Native.DwmGetWindowRect(hwnd, 9, out Native.Rect rect, System.Runtime.InteropServices.Marshal.SizeOf<Native.Rect>()) != 0 && !Native.GetWindowRect(hwnd, out rect)) return false;
        // Use the work area too: a maximized app may leave the taskbar uncovered.
        var screen = System.Windows.Forms.Screen.AllScreens.FirstOrDefault(s => s.DeviceName == monitor.Device);
        var work = screen?.WorkingArea ?? new System.Drawing.Rectangle(monitor.X, monitor.Y, monitor.Width, monitor.Height);
        return rect.Left <= work.Left + 2 && rect.Top <= work.Top + 2 && rect.Right >= work.Right - 2 && rect.Bottom >= work.Bottom - 2;
    }
    public void Dispose()
    {
        health.Stop(); settle.Stop();
        SystemEvents.DisplaySettingsChanged -= DisplayChanged; SystemEvents.PowerModeChanged -= PowerChanged;
        foreach (var hook in hooks) Native.UnhookWinEvent(hook);
        notifications.Dispose();
    }
}

using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
using DynamicPhotoWall.Configuration;

namespace DynamicPhotoWall.DesktopIntegration;

public sealed record TaskbarDescriptor(long Handle, bool Visible);

// Taskbar changes are monitor-local and guarded by a separate process so that
// even an unexpected owner-process exit restores Explorer's original window.
public sealed class TaskbarVisibility : IDisposable
{
    private sealed record Lease(nint Handle, Process Guard, EventWaitHandle Release);
    private readonly Dictionary<nint, Lease> leases = new();
    public static IReadOnlyList<TaskbarDescriptor> Query(MonitorDescriptor monitor)
    {
        var result = new List<TaskbarDescriptor>();
        Native.EnumWindows((hwnd, _) =>
        {
            if (Native.ClassName(hwnd) is not ("Shell_TrayWnd" or "Shell_SecondaryTrayWnd")) return true;
            var info = new Native.MonitorInfo { Size = Marshal.SizeOf<Native.MonitorInfo>(), Device = "" };
            if (Native.GetMonitorInfo(Native.MonitorFromWindow(hwnd, 2), ref info) && info.Device == monitor.Device)
                result.Add(new(hwnd.ToInt64(), Native.IsWindowVisible(hwnd)));
            return true;
        }, 0);
        return result;
    }
    public void Update(MonitorDescriptor? monitor, bool hide)
    {
        if (monitor == null || !hide) { Restore(); return; }
        var bars = Query(monitor);
        var handles = bars.Select(b => new nint(b.Handle)).ToHashSet();
        foreach (var item in leases.Values.Where(l => !handles.Contains(l.Handle)).ToArray()) Release(item);
        foreach (var bar in bars)
        {
            var hwnd = new nint(bar.Handle);
            if (leases.TryGetValue(hwnd, out var existing))
            {
                if (existing.Guard.HasExited) { Release(existing); continue; }
                if (bar.Visible) Native.ShowWindow(hwnd, 0);
                continue;
            }
            if (!bar.Visible) continue; // Never claim or restore an already-hidden bar.
            try
            {
                var eventName = $"Local\\DynamicPhotoWall.Taskbar.{Guid.NewGuid():N}";
                var release = new EventWaitHandle(false, EventResetMode.ManualReset, eventName);
                using var ready = new EventWaitHandle(false, EventResetMode.ManualReset, eventName + ".Ready");
                // Relaunch the original bundle, including after the user moves
                // or renames a portable single-file executable. Test runners
                // and dotnet-hosted builds use the adjacent application host.
                var processPath = Environment.ProcessPath;
                var executable = System.Reflection.Assembly.GetEntryAssembly() == typeof(TaskbarVisibility).Assembly
                    && processPath != null && !Path.GetFileNameWithoutExtension(processPath).Equals("dotnet", StringComparison.OrdinalIgnoreCase)
                    ? processPath : Path.Combine(AppContext.BaseDirectory, "DynamicPhotoWall.exe");
                Process? guard = null;
                try
                {
                    var start = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true, WindowStyle = ProcessWindowStyle.Hidden };
                    foreach (var argument in new[] { "--taskbar-guard", Environment.ProcessId.ToString(), bar.Handle.ToString(), eventName }) start.ArgumentList.Add(argument);
                    guard = Process.Start(start) ?? throw new InvalidOperationException("タスクバー復元用プロセスを起動できません。");
                    if (!ready.WaitOne(TimeSpan.FromSeconds(3)) || guard.HasExited) throw new InvalidOperationException("タスクバー復元用プロセスを確認できません。");
                    leases.Add(hwnd, new(hwnd, guard, release));
                    Native.ShowWindow(hwnd, 0);
                }
                catch
                {
                    release.Set(); release.Dispose(); guard?.Dispose(); throw;
                }
            }
            catch (Exception e) { Log.Write("タスクバーは表示したままにします。", e); }
        }
    }
    private void Release(Lease lease)
    {
        if (Native.IsWindow(lease.Handle)) Native.ShowWindow(lease.Handle, 4);
        lease.Release.Set();
        // Avoid the previous guard restoring a bar just hidden by a new lease.
        try { lease.Guard.WaitForExit(1500); } catch (InvalidOperationException) { }
        lease.Guard.Dispose(); lease.Release.Dispose(); leases.Remove(lease.Handle);
    }
    public void Restore() { foreach (var lease in leases.Values.ToArray()) Release(lease); }
    public void Dispose() => Restore();

    public static int RunGuard(string[] args)
    {
        if (args.Length != 4 || !int.TryParse(args[1], out var ownerId) || !long.TryParse(args[2], out var hwnd)) return 1;
        try
        {
            using var release = EventWaitHandle.OpenExisting(args[3]);
            using var ready = EventWaitHandle.OpenExisting(args[3] + ".Ready");
            using var owner = Process.GetProcessById(ownerId);
            using var ownerExited = new EventWaitHandle(false, EventResetMode.ManualReset);
            ownerExited.SafeWaitHandle = new SafeWaitHandle(owner.Handle, false);
            ready.Set();
            WaitHandle.WaitAny([ownerExited, release]);
            var handle = new nint(hwnd);
            if (Native.IsWindow(handle) && Native.ClassName(handle) is "Shell_TrayWnd" or "Shell_SecondaryTrayWnd") Native.ShowWindow(handle, 4);
            return 0;
        }
        catch (Exception e) { Log.Write("タスクバー復元処理", e); return 1; }
    }
}

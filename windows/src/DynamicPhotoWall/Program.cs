using System.Text.Json;
using System.Windows.Threading;
using DynamicPhotoWall.DesktopIntegration;
using DynamicPhotoWall.Configuration;
using DynamicPhotoWall.UI;

namespace DynamicPhotoWall;

internal static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        if (args.FirstOrDefault() == "--taskbar-guard") return TaskbarVisibility.RunGuard(args);
        if (args.FirstOrDefault() == "--taskbar-test-owner")
        {
            using var taskbar = new TaskbarVisibility();
            var selected = MonitorManager.Enumerate().OrderByDescending(m => (double)m.Width / m.Height).First();
            taskbar.Update(selected, true);
            var report = Value(args, "--output") ?? throw new ArgumentException("--output is required");
            File.WriteAllText(report, JsonSerializer.Serialize(TaskbarVisibility.Query(selected)));
            Thread.Sleep(Timeout.Infinite);
            return 0;
        }
        var data = Value(args, "--data-dir");
        if (data != null) Log.DataDirectory = Path.GetFullPath(data);
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        if (args.Contains("--probe"))
        {
            var exit = 0;
            app.Startup += (_, _) =>
            {
                var host = new DesktopWindowHost();
                var output = Value(args, "--output") ?? Path.Combine(Log.DataDirectory, "probe-result.json");
                try
                {
                    Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(output))!);
                    var monitors = MonitorManager.Enumerate();
                    var id = Value(args, "--monitor");
                    var monitor = id == null ? monitors.First() : monitors.First(m => m.Id == id || m.Device == id);
                    var window = new Window { Background = Brushes.Black, Content = new TextBlock
                    { Text = "Dynamic Photo Wall · Desktop integration probe", Foreground = Brushes.White, FontSize = 32,
                        HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center } };
                    host.Attach(window, monitor);
                    var details = host.Inspect();
                    var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(4) };
                    timer.Tick += (_, _) =>
                    {
                        timer.Stop();
                        var hwnd = host.Handle;
                        host.Dispose();
                        File.WriteAllText(output, JsonSerializer.Serialize(new { Success = true, Monitor = monitor, Monitors = monitors,
                            Details = details, Cleanup = !Native.IsWindow(hwnd) }, new JsonSerializerOptions { WriteIndented = true }));
                        app.Shutdown();
                    };
                    timer.Start();
                }
                catch (Exception e)
                {
                    host.Dispose(); exit = 1;
                    File.WriteAllText(output, JsonSerializer.Serialize(new { Success = false, Error = e.ToString() }, new JsonSerializerOptions { WriteIndented = true }));
                    app.Shutdown();
                }
            };
            app.Run();
            return exit;
        }
        using var mutex = new Mutex(true, "Local\\DynamicPhotoWall.App", out var first);
        if (!first) { MessageBox.Show("Dynamic Photo Wallは既に起動しています。タスクトレイから設定を開いてください。"); return 0; }
        TrayController? tray = null;
        WallController? controller = null;
        app.DispatcherUnhandledException += (_, e) =>
        {
            Log.Write("UI操作エラー", e.Exception); e.Handled = true;
            if (controller != null) _ = WallController.GuardAsync(controller.StopAsync);
        };
        TaskScheduler.UnobservedTaskException += (_, e) => { Log.Write("バックグラウンド処理エラー", e.Exception); e.SetObserved(); };
        app.Startup += async (_, _) =>
        {
            try
            {
                var manager = new SettingsManager(); var settings = manager.Load();
                if (!File.Exists(manager.FilePath))
                {
                    var adjacentPhotos = Path.Combine(AppContext.BaseDirectory, "photos");
                    var workPhotos = Path.Combine(Environment.CurrentDirectory, "photos");
                    var folder = Directory.Exists(workPhotos) ? workPhotos : adjacentPhotos;
                    if (Directory.Exists(folder)) settings.Folders.Add(folder);
                }
                controller = new(settings); tray = new(controller, manager);
                if (!args.Contains("--tray") || !settings.HasDisplaySelection) tray.OpenSettings();
                await controller.InitializeAsync();
            }
            catch (Exception e) { Log.Write("起動に失敗しました。", e); MessageBox.Show(e.Message, "Dynamic Photo Wall"); if (tray != null) await tray.ExitAsync(); else app.Shutdown(1); }
        };
        app.Run();
        tray?.Dispose();
        return 0;
    }
    internal static string? Value(string[] args, string name) { var i = Array.IndexOf(args, name); return i >= 0 && i + 1 < args.Length ? args[i + 1] : null; }
}

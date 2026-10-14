using DynamicPhotoWall.Configuration;
using Forms = System.Windows.Forms;

namespace DynamicPhotoWall.UI;

public sealed class TrayController : IDisposable
{
    private readonly Forms.NotifyIcon icon;
    private readonly Forms.ToolStripMenuItem pause;
    private readonly WallController controller;
    private readonly SettingsManager manager;
    private SettingsWindow? settings;
    private bool exiting;
    private bool disposed;
    public TrayController(WallController controller, SettingsManager manager)
    {
        this.controller = controller; this.manager = manager;
        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add("スライドショー開始", null, async (_, _) => await WallController.GuardAsync(controller.StartAsync));
        pause = new Forms.ToolStripMenuItem("一時停止", null, (_, _) => controller.TogglePause()); menu.Items.Add(pause);
        menu.Items.Add("次の写真 / 構成", null, (_, _) => controller.Next());
        menu.Items.Add("表示停止", null, async (_, _) => await WallController.GuardAsync(controller.StopAsync));
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("設定を開く", null, (_, _) => OpenSettings());
        menu.Items.Add("終了", null, async (_, _) => await ExitAsync());
        icon = new Forms.NotifyIcon { Text = "Dynamic Photo Wall", Icon = System.Drawing.SystemIcons.Application, ContextMenuStrip = menu, Visible = true };
        icon.DoubleClick += (_, _) => OpenSettings(); controller.Changed += Update;
    }
    private void Update()
    {
        pause.Text = controller.IsPaused ? "再開" : "一時停止";
        var text = $"Dynamic Photo Wall — {controller.Status}"; icon.Text = text[..Math.Min(text.Length, 63)];
    }
    public void OpenSettings()
    {
        if (settings == null) { settings = new(controller, manager); settings.Closed += (_, _) => settings = null; }
        settings.Show(); if (settings.WindowState == WindowState.Minimized) settings.WindowState = WindowState.Normal; settings.Activate();
    }
    public async Task ExitAsync()
    {
        if (exiting) return; exiting = true;
        settings?.Close(); icon.Visible = false; await controller.DisposeAsync(); Dispose(); Application.Current.Shutdown();
    }
    public void Dispose() { if (disposed) return; disposed = true; controller.Changed -= Update; icon.Visible = false; icon.ContextMenuStrip?.Dispose(); icon.Dispose(); }
}

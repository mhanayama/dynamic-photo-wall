using DynamicPhotoWall.Configuration;
using System.Windows.Controls.Primitives;
using System.Windows.Interop;
using Forms = System.Windows.Forms;

namespace DynamicPhotoWall.UI;

public sealed class TrayController : IDisposable
{
    private readonly Forms.NotifyIcon icon;
    private readonly System.Drawing.Icon trayIcon;
    private readonly TrayMenu menu;
    private readonly WallController controller;
    private readonly SettingsManager manager;
    private SettingsWindow? settings;
    private bool exiting;
    private bool disposed;
    public TrayController(WallController controller, SettingsManager manager)
    {
        this.controller = controller; this.manager = manager;
        menu = new TrayMenu(controller.StartAsync, controller.TogglePause, controller.Next,
            controller.StopAsync, OpenSettings, ExitAsync);
        menu.Opened += (_, _) =>
        {
            // A tray popup has no owner window. Foreground it so outside clicks
            // and keyboard navigation work even when settings are closed.
            if (PresentationSource.FromVisual(menu) is HwndSource source)
                DesktopIntegration.Native.SetForegroundWindow(source.Handle);
            menu.Focus();
        };
        using (var stream = Application.GetResourceStream(new Uri("/DynamicPhotoWall;component/Assets/PhotoWall.ico", UriKind.Relative))!.Stream)
        using (var source = new System.Drawing.Icon(stream, Forms.SystemInformation.SmallIconSize))
            trayIcon = (System.Drawing.Icon)source.Clone();
        // Keep WinForms only for the shell icon. Its dropdown window and error
        // dialog bypass WPF's dispatcher exception handling.
        icon = new Forms.NotifyIcon { Text = "Dynamic Photo Wall", Icon = trayIcon, Visible = true };
        icon.MouseUp += (_, e) =>
        {
            if (e.Button == Forms.MouseButtons.Right)
                menu.Dispatcher.BeginInvoke(new Action(() =>
                {
                    if (disposed || exiting) return;
                    Update();
                    menu.Placement = PlacementMode.MousePoint;
                    menu.IsOpen = true;
                }));
        };
        icon.DoubleClick += (_, _) => OpenSettings(); controller.Changed += Update;
        controller.Network.Notification += NetworkNotification;
    }
    private void Update()
    {
        menu.UpdatePause(controller.IsPaused);
        var text = $"Dynamic Photo Wall — {controller.Status}"; icon.Text = text[..Math.Min(text.Length, 63)];
    }
    private void NetworkNotification(string title, string text) => icon.ShowBalloonTip(5000, title, text, Forms.ToolTipIcon.Info);
    public void OpenSettings()
    {
        if (settings == null) { settings = new(controller, manager); settings.Closed += (_, _) => settings = null; }
        settings.Show(); if (settings.WindowState == WindowState.Minimized) settings.WindowState = WindowState.Normal; settings.Activate();
    }
    public async Task ExitAsync()
    {
        if (exiting) return; exiting = true;
        menu.IsOpen = false; settings?.Close(); icon.Visible = false; await controller.DisposeAsync(); Dispose(); Application.Current.Shutdown();
    }
    public void Dispose() { if (disposed) return; disposed = true; controller.Changed -= Update; controller.Network.Notification -= NetworkNotification; menu.IsOpen = false; icon.Visible = false; icon.Dispose(); trayIcon.Dispose(); }
}

using System.Windows;
using System.Windows.Controls;
using DynamicPhotoWall.UI;

namespace DynamicPhotoWall.Tests;

internal static class TrayMenuTests
{
    // Exercise routed commands on objects only; never open a popup or shell icon.
    public static async Task CommandsWithoutWindows()
    {
        var calls = new List<string>();
        var started = new TaskCompletionSource();
        var releaseStart = new TaskCompletionSource();
        var menu = new TrayMenu(async () =>
        {
            started.SetResult();
            await releaseStart.Task;
            calls.Add("start");
        }, () => calls.Add("pause"), () => calls.Add("next"),
            () => { calls.Add("stop"); return Task.CompletedTask; },
            () => calls.Add("settings"), () => { calls.Add("exit"); return Task.CompletedTask; });
        if (menu.Items.Count != 7 || menu.Items[4] is not Separator)
            throw new Exception("Tray commands and separator must remain available.");
        void Click(int index) => ((MenuItem)menu.Items[index]).RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));
        Click(0);
        await started.Task;
        if (calls.Count != 0) throw new Exception("Start must await its asynchronous operation.");
        releaseStart.SetResult();
        await menu.Dispatcher.InvokeAsync(() => { });
        menu.UpdatePause(true);
        if (!Equals(((MenuItem)menu.Items[1]).Header, "再開")) throw new Exception("Paused playback must offer resume.");
        Click(1);
        menu.UpdatePause(false);
        if (!Equals(((MenuItem)menu.Items[1]).Header, "一時停止")) throw new Exception("Playing playback must offer pause.");
        foreach (var index in new[] { 2, 3, 5, 6 }) Click(index);
        if (!calls.SequenceEqual(new[] { "start", "pause", "next", "stop", "settings", "exit" }))
            throw new Exception("Tray commands must invoke the corresponding action exactly once.");
        if (menu.IsOpen || PresentationSource.FromVisual(menu) != null)
            throw new Exception("Command verification must not create a popup window.");
    }
}

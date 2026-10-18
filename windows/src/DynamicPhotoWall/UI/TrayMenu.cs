namespace DynamicPhotoWall.UI;

internal sealed class TrayMenu : ContextMenu
{
    private readonly MenuItem pause;

    internal TrayMenu(Func<Task> start, Action togglePause, Action next,
        Func<Task> stop, Action openSettings, Func<Task> exit)
    {
        Add("スライドショー開始", start);
        pause = Add("一時停止", () => { togglePause(); return Task.CompletedTask; });
        Add("次の写真 / 構成", () => { next(); return Task.CompletedTask; });
        Add("表示停止", stop);
        Items.Add(new Separator());
        Add("設定を開く", () => { openSettings(); return Task.CompletedTask; });
        Add("終了", exit);
    }

    internal void UpdatePause(bool paused) => pause.Header = paused ? "再開" : "一時停止";

    private MenuItem Add(string header, Func<Task> action)
    {
        var item = new MenuItem { Header = header };
        item.Click += async (_, _) => await WallController.GuardAsync(action);
        Items.Add(item);
        return item;
    }
}

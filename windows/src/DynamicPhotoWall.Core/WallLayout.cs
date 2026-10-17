namespace DynamicPhotoWall.Core;

// Wall coordinates are physical pixels, independent of Windows desktop coordinates.
public sealed class DisplayPlacement
{
    public string Id { get; set; } = "";
    public int X { get; set; }
    public int Y { get; set; }
    public int Width { get; set; }
    public int Height { get; set; }
    // Missing fields in older settings retain the previous single-wall behavior.
    public string? GroupId { get; set; } = "グループ1";
    public bool? HideTaskbar { get; set; }
}

public sealed record DisplayGroup(string Name, bool Independent, IReadOnlyList<DisplayPlacement> Displays);

public static class DisplayGroups
{
    public static IReadOnlyList<DisplayGroup> Create(IReadOnlyList<DisplayPlacement> displays) => displays
        .GroupBy(d => (Independent: string.IsNullOrWhiteSpace(d.GroupId), Key: string.IsNullOrWhiteSpace(d.GroupId) ? d.Id : d.GroupId.Trim()))
        .Select(g => new DisplayGroup(g.Key.Independent ? "独立画面" : g.Key.Key, g.Key.Independent, g.ToArray())).ToArray();
}

public sealed class WallLayout
{
    public Viewport Viewport { get; }
    public IReadOnlyDictionary<string, FrameRect> Regions { get; }

    public WallLayout(IReadOnlyList<DisplayPlacement> displays)
    {
        if (displays.Count == 0 || displays.Any(d => d.Width <= 0 || d.Height <= 0))
            throw new InvalidOperationException("画面の解像度を確認してください。");
        var left = displays.Min(d => (long)d.X); var top = displays.Min(d => (long)d.Y);
        var width = displays.Max(d => (long)d.X + d.Width) - left;
        var height = displays.Max(d => (long)d.Y + d.Height) - top;
        if (width > 32768 || height > 32768)
            throw new InvalidOperationException("キャンバスの幅・高さは32768px以内に配置してください。");
        Viewport = new(width, height);
        Regions = displays.ToDictionary(d => d.Id, d => new FrameRect(d.X - left, d.Y - top, d.Width, d.Height));
    }
}

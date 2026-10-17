namespace DynamicPhotoWall.Core;

public enum CompositionMode { Gallery, VerticalPan, HorizontalPan, Zoom, GalleryScroll }
public sealed record FaceRegion(double X, double Y, double Width, double Height);
public sealed record PhotoInfo(string Path, int RawWidth, int RawHeight, int Orientation, DateTime? TakenAt, long Length, long ModifiedTicks, IReadOnlyList<FaceRegion>? Faces = null)
{
    public int Width => Orientation is >= 5 and <= 8 ? RawHeight : RawWidth;
    public int Height => Orientation is >= 5 and <= 8 ? RawWidth : RawHeight;
    public double Aspect => (double)Width / Height;
}
public sealed record Viewport(double Width, double Height)
{
    public double Aspect => Width / Height;
}
public sealed record FrameRect(double X, double Y, double Width, double Height);
public sealed record MotionPlan(double Width, double Height, double FromX, double FromY, double ToX, double ToY,
    double FromScale, double ToScale, double CenterX, double CenterY, double Seconds);

public sealed class WallSettings
{
    public string? MonitorId { get; set; }
    public List<DisplayPlacement> Displays { get; set; } = [];
    public List<string> DisplayGroupNames { get; set; } = [];
    public bool DisplayTestPattern { get; set; }
    [System.Text.Json.Serialization.JsonIgnore]
    public bool HasDisplaySelection => Displays.Count > 0 || MonitorId != null;
    public List<string> Folders { get; set; } = [];
    public bool Recursive { get; set; } = true;
    public bool RandomOrder { get; set; } = true;
    public int RecentCount { get; set; } = 30;
    public bool AutoStart { get; set; }
    public bool StartOnLaunch { get; set; } = true;
    public bool HideTaskbar { get; set; } = true;
    public bool GalleryEnabled { get; set; } = true;
    public bool GalleryScrollEnabled { get; set; } = true;
    public bool VerticalPanEnabled { get; set; } = true;
    public bool HorizontalPanEnabled { get; set; } = true;
    public bool ZoomEnabled { get; set; } = true;
    public int GalleryWeight { get; set; } = 45;
    public int PanWeight { get; set; } = 35;
    public int ZoomWeight { get; set; } = 20;
    public int GalleryMax { get; set; } = 5;
    public double PanPixelsPerSecond { get; set; } = 120;
    public double MaxPanUpscale { get; set; } = 4;
    public double PanWidthFraction { get; set; } = .96;
    public bool StopAtFace { get; set; } = true;
    public bool FaceAwarePanDirection { get; set; } = true;
    public bool FaceAwareFraming { get; set; } = true;
    public double GalleryScrollPixelsPerSecond { get; set; } = 40;
    public bool GlassBackground { get; set; } = true;
    public double ZoomSeconds { get; set; } = 45;
    public double MaxZoom { get; set; } = 1.08;
    public double FadeSeconds { get; set; } = 1.2;
    public double GalleryMinSeconds { get; set; } = 30;
    public double GalleryMaxSeconds { get; set; } = 60;
    public string Background { get; set; } = "#101116";
    public double Gap { get; set; } = 8;
    public double CornerRadius { get; set; } = 8;
    public bool ExifOverlay { get; set; }
    public int CacheMegabytes { get; set; } = 256;
    public void Normalize()
    {
        Displays = (Displays ?? []).Where(d => !string.IsNullOrWhiteSpace(d.Id)).DistinctBy(d => d.Id).ToList();
        foreach (var display in Displays) display.GroupId = string.IsNullOrWhiteSpace(display.GroupId) ? null : display.GroupId.Trim();
        DisplayGroupNames = (DisplayGroupNames ?? []).Concat(Displays.Select(d => d.GroupId!))
            .Where(n => !string.IsNullOrWhiteSpace(n)).Select(n => n.Trim()).Distinct(StringComparer.Ordinal).ToList();
        Folders = (Folders ?? []).Where(f => !string.IsNullOrWhiteSpace(f)).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
        RecentCount = Math.Clamp(RecentCount, 0, 10000);
        GalleryMax = Math.Clamp(GalleryMax, 1, 5);
        GalleryWeight = Math.Clamp(GalleryWeight, 0, 1000);
        PanWeight = Math.Clamp(PanWeight, 0, 1000);
        ZoomWeight = Math.Clamp(ZoomWeight, 0, 1000);
        PanPixelsPerSecond = Clamp(PanPixelsPerSecond, 5, 500, 120);
        MaxPanUpscale = Clamp(MaxPanUpscale, 1, 12, 4);
        PanWidthFraction = Clamp(PanWidthFraction, .3, 1, .96);
        GalleryScrollPixelsPerSecond = Clamp(GalleryScrollPixelsPerSecond, 5, 200, 40);
        ZoomSeconds = Clamp(ZoomSeconds, 10, 600, 45);
        MaxZoom = Clamp(MaxZoom, 1, 1.15, 1.08);
        FadeSeconds = Clamp(FadeSeconds, .2, 10, 1.2);
        GalleryMinSeconds = Clamp(GalleryMinSeconds, 5, 600, 30);
        GalleryMaxSeconds = Clamp(GalleryMaxSeconds, GalleryMinSeconds, 1200, 60);
        Gap = Clamp(Gap, 0, 200, 8);
        CornerRadius = Clamp(CornerRadius, 0, 100, 8);
        CacheMegabytes = Math.Clamp(CacheMegabytes, 64, 1024);
        Background ??= "#101116";
    }
    private static double Clamp(double v, double min, double max, double fallback) => double.IsFinite(v) ? Math.Clamp(v, min, max) : fallback;
}

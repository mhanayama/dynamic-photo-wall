namespace DynamicPhotoWall.Networking;

public enum SceneMode { Gallery, GalleryScroll, VerticalPan, HorizontalPan, Zoom }
public sealed record ScenePlacement(int Id, SharedAssetKey Asset, string? DisplayId, FrameRect Clip,
    double Width, double Height, double FromX, double FromY, double ToX, double ToY,
    double FromScale, double ToScale, double CenterX, double CenterY,
    double StartSeconds, double MotionSeconds, double VisibleFrom, double VisibleUntil,
    double FadeSeconds, double CornerRadius, bool Ease);
public sealed record AmbientFrame(double At, byte[] Png) { public string? DisplayId { get; init; } }
public sealed record SharedScenePlan(Guid Id, Guid GroupId, Guid SessionId, long SettingsRevision,
    SceneMode Mode, Viewport Viewport, PeerDisplay[] Displays, double Duration, double FadeSeconds,
    string Background, ScenePlacement[] Placements, AmbientFrame[] Ambient)
{
    public void Validate()
    {
        PeerProtocol.Require(Id != Guid.Empty && GroupId != Guid.Empty && SessionId != Guid.Empty && SettingsRevision >= 0,
            "Invalid scene identity.");
        PeerProtocol.Require(Viewport != null && double.IsFinite(Viewport.Width + Viewport.Height)
            && Viewport.Width > 0 && Viewport.Height > 0 && Viewport.Width <= 32768 && Viewport.Height <= 32768,
            "Invalid scene canvas.");
        PeerProtocol.Require(double.IsFinite(Duration) && Duration > 0 && Duration <= 3600 && double.IsFinite(FadeSeconds)
            && FadeSeconds >= 0 && FadeSeconds <= Duration && Enum.IsDefined(Mode), "Invalid scene timing.");
        PeerProtocol.Require(Displays != null && Displays.Length is > 0 and <= 128
            && Placements != null && Placements.Length is > 0 and <= 1024 && Ambient != null && Ambient.Length <= 64,
            "Invalid scene size.");
        foreach (var d in Displays!) d.Validate();
        foreach (var p in Placements!)
        {
            p.Asset.Validate();
            var values = new[] { p.Clip.X, p.Clip.Y, p.Clip.Width, p.Clip.Height, p.Width, p.Height, p.FromX,
                p.FromY, p.ToX, p.ToY, p.FromScale, p.ToScale, p.CenterX, p.CenterY, p.StartSeconds, p.MotionSeconds,
                p.VisibleFrom, p.VisibleUntil, p.FadeSeconds, p.CornerRadius };
            PeerProtocol.Require(values.All(double.IsFinite) && p.Width > 0 && p.Height > 0 && p.Clip.Width > 0
                && p.Clip.Height > 0 && p.FromScale > 0 && p.ToScale > 0 && p.MotionSeconds > 0
                && p.VisibleFrom >= 0 && p.VisibleUntil >= p.VisibleFrom && p.VisibleUntil <= Duration
                && p.FadeSeconds >= 0 && p.CornerRadius >= 0, "Invalid photo placement.");
        }
        PeerProtocol.Require(Placements.Select(p => p.Id).Distinct().Count() == Placements.Length, "Duplicate placement ID.");
        foreach (var frame in Ambient!) PeerProtocol.Require(double.IsFinite(frame.At) && frame.At >= 0
            && frame.At <= Duration && frame.Png.Length <= 131072, "Invalid ambient frame.");
    }
}
public sealed record SceneCommit(Guid PlanId, Guid GroupId, double StartAt);
public sealed record SceneReady(Guid PlanId, Guid GroupId);
public sealed record EvaluatedPlacement(double X, double Y, double Scale, double Opacity);

public static class SceneEvaluation
{
    public static EvaluatedPlacement Evaluate(ScenePlacement p, double elapsed)
    {
        var progress = Math.Clamp((elapsed - p.StartSeconds) / p.MotionSeconds, 0, 1);
        if (p.Ease) progress = .5 - Math.Cos(progress * Math.PI) / 2;
        var opacity = elapsed < p.VisibleFrom || elapsed >= p.VisibleUntil ? 0 : p.FadeSeconds <= 0 ? 1
            : Math.Min(Math.Clamp((elapsed - p.VisibleFrom) / p.FadeSeconds, 0, 1), Math.Clamp((p.VisibleUntil - elapsed) / p.FadeSeconds, 0, 1));
        return new(p.FromX + (p.ToX - p.FromX) * progress, p.FromY + (p.ToY - p.FromY) * progress,
            p.FromScale + (p.ToScale - p.FromScale) * progress, opacity);
    }
}

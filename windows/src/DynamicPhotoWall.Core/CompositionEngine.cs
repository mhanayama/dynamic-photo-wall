namespace DynamicPhotoWall.Core;

public sealed record CompositionPlan(CompositionMode Mode, IReadOnlyList<PhotoInfo> Photos)
{
    // Automatic fallback repeats one photograph, unlike the user's per-display
    // mode which selects a separate photograph for each output.
    public bool MirrorPerDisplay { get; init; }
}
public interface ICompositionPolicy
{
    bool Suitable(PhotoInfo photo, Viewport viewport, CompositionMode mode, WallSettings settings);
}
public sealed class MetadataCompositionPolicy : ICompositionPolicy
{
    public bool Suitable(PhotoInfo p, Viewport v, CompositionMode mode, WallSettings settings) => mode switch
    {
        CompositionMode.Gallery or CompositionMode.GalleryScroll => true,
        CompositionMode.VerticalPan => p.Aspect < .95 && v.Width * settings.PanWidthFraction / p.Width <= settings.MaxPanUpscale && v.Width * settings.PanWidthFraction / p.Aspect > v.Height + 20,
        CompositionMode.HorizontalPan => p.Aspect > v.Aspect * 1.05 && v.Height / p.Height <= settings.MaxPanUpscale,
        CompositionMode.Zoom => p.Aspect >= 1,
        _ => false
    };
}
public sealed class CompositionEngine(PhotoSelector selector, Random? random = null, ICompositionPolicy? policy = null)
{
    private readonly Random random = random ?? new Random();
    private readonly ICompositionPolicy policy = policy ?? new MetadataCompositionPolicy();
    private CompositionMode? previous;
    private int repeats;
    public CompositionPlan? Next(IReadOnlyList<PhotoInfo> photos, Viewport viewport, WallSettings s, ISet<string>? excluded = null,
        IReadOnlyList<Viewport>? displayViewports = null)
    {
        var modes = new List<(CompositionMode Mode, PhotoInfo[] Photos, double Weight)>();
        bool NeedsMirror(PhotoInfo p, CompositionMode mode) => MirrorPolicy.Supports(mode) && !s.IsPerDisplay(mode)
            && displayViewports?.Count > 0 && displayViewports.Any(v => v.Width < viewport.Width || v.Height < viewport.Height)
            && MirrorPolicy.IsBelowHalf(p.Width, p.Height, viewport);
        bool Mirror(PhotoInfo p, CompositionMode mode) => NeedsMirror(p, mode)
            && displayViewports!.All(v => policy.Suitable(p, v, mode, s));
        bool Suitable(PhotoInfo p, Viewport v, CompositionMode m) => NeedsMirror(p, m)
            ? Mirror(p, m) : policy.Suitable(p, v, m, s);
        void Add(CompositionMode m, bool enabled, double weight)
        {
            if (!enabled || weight <= 0) return;
            var targets = s.IsPerDisplay(m) && displayViewports?.Count > 0 ? displayViewports : new[] { viewport };
            // A group chooses one mode. Every connected display must have a
            // suitable candidate for that mode at its own physical dimensions.
            if (targets.Any(v => !photos.Any(p => Suitable(p, v, m) && (excluded == null || !excluded.Contains(p.Path))))) return;
            var suitable = photos.Where(p => Suitable(p, targets[0], m) && (excluded == null || !excluded.Contains(p.Path))).ToArray();
            if (suitable.Length > 0) modes.Add((m, suitable, weight));
        }
        Add(CompositionMode.Gallery, s.GalleryEnabled, s.GalleryWeight);
        Add(CompositionMode.GalleryScroll, s.GalleryScrollEnabled && photos.Count > 1, s.GalleryWeight);
        Add(CompositionMode.VerticalPan, s.VerticalPanEnabled, s.PanWeight);
        Add(CompositionMode.HorizontalPan, s.HorizontalPanEnabled, s.PanWeight);
        Add(CompositionMode.Zoom, s.ZoomEnabled, s.ZoomWeight);
        var panCount = modes.Count(m => m.Mode is CompositionMode.VerticalPan or CompositionMode.HorizontalPan);
        var galleryCount = modes.Count(m => m.Mode is CompositionMode.Gallery or CompositionMode.GalleryScroll);
        // Pan's total weight stays 35 even when both pan directions are possible.
        modes = modes.Select(m => (m.Mode, m.Photos, m.Weight / (m.Mode is CompositionMode.VerticalPan or CompositionMode.HorizontalPan ? panCount : m.Mode is CompositionMode.Gallery or CompositionMode.GalleryScroll ? galleryCount : 1))).ToList();
        if (modes.Count == 0) return null;
        if (repeats >= 2 && modes.Count > 1) modes.RemoveAll(m => m.Mode == previous);
        var ticket = random.NextDouble() * modes.Sum(m => m.Weight);
        var chosen = modes[^1];
        foreach (var mode in modes) { ticket -= mode.Weight; if (ticket < 0) { chosen = mode; break; } }
        repeats = previous == chosen.Mode ? repeats + 1 : 1;
        previous = chosen.Mode;
        var target = s.IsPerDisplay(chosen.Mode) && displayViewports?.Count > 0 ? displayViewports[0] : viewport;
        var plan = SelectPhotos(chosen.Mode, chosen.Photos, target, s, excluded);
        return plan != null && Mirror(plan.Photos[0], plan.Mode) ? plan with { MirrorPerDisplay = true } : plan;
    }
    public CompositionPlan? ForMode(IReadOnlyList<PhotoInfo> photos, Viewport viewport, WallSettings s, CompositionMode mode, ISet<string>? excluded = null)
    {
        var suitable = photos.Where(p => policy.Suitable(p, viewport, mode, s) && (excluded == null || !excluded.Contains(p.Path))).ToArray();
        return suitable.Length > 0 ? SelectPhotos(mode, suitable, viewport, s, excluded) : null;
    }
    private CompositionPlan? SelectPhotos(CompositionMode mode, PhotoInfo[] photos, Viewport viewport, WallSettings s, ISet<string>? excluded)
    {
        var selected = new List<PhotoInfo>();
        var used = new HashSet<string>(excluded ?? new HashSet<string>(), StringComparer.OrdinalIgnoreCase);
        var count = mode is CompositionMode.Gallery or CompositionMode.GalleryScroll ? Math.Clamp((int)Math.Round(viewport.Aspect / .68), 1, s.GalleryMax) : 1;
        if (mode == CompositionMode.GalleryScroll) count = Math.Min(24, photos.Length);
        var stripWidth = s.Gap;
        var preferred = photos.Where(p => p.Aspect < 1).ToArray();
        for (var i = 0; i < count; i++)
        {
            var photo = selector.Pick(mode is CompositionMode.Gallery or CompositionMode.GalleryScroll && preferred.Any(p => !used.Contains(p.Path)) ? preferred : photos, s, used);
            if (photo == null) break;
            selected.Add(photo); used.Add(photo.Path);
            stripWidth += Math.Max(1, viewport.Height - 2 * s.Gap) * photo.Aspect + s.Gap;
            if (mode == CompositionMode.GalleryScroll && selected.Count >= 2 && stripWidth >= viewport.Width + viewport.Height * 1.5) break;
        }
        return selected.Count > 0 ? new(mode, selected) : null;
    }
    public static IReadOnlyList<FrameRect> GalleryLayout(IReadOnlyList<PhotoInfo> photos, Viewport v, double gap)
    {
        if (photos.Count == 0) return [];
        gap = Math.Min(gap, Math.Min(v.Width / (photos.Count + 1), v.Height / 4));
        var height = Math.Max(1, Math.Min(v.Height - 2 * gap, (v.Width - (photos.Count + 1) * gap) / photos.Sum(p => p.Aspect)));
        var x = (v.Width - height * photos.Sum(p => p.Aspect) - gap * (photos.Count - 1)) / 2;
        var frames = new List<FrameRect>();
        foreach (var p in photos) { var width = height * p.Aspect; frames.Add(new(x, (v.Height - height) / 2, width, height)); x += width + gap; }
        return frames;
    }
}

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
    public bool LastDrawSkipped { get; private set; }
    public void ResetModeHistory() { previous = null; repeats = 0; LastDrawSkipped = false; }
    public CompositionPlan? Next(IReadOnlyList<PhotoInfo> photos, Viewport viewport, WallSettings s, ISet<string>? excluded = null,
        IReadOnlyList<Viewport>? displayViewports = null, IReadOnlyList<FrameRect>? displayRegions = null, bool allowGalleryRepeat = false)
    {
        LastDrawSkipped = false;
        var modes = new List<(CompositionMode Mode, PhotoInfo[] Photos)>();
        var weights = ModeSelection.Weights(s.GalleryWeight, s.PanWeight, s.ZoomWeight);
        bool SuitableAt(PhotoInfo p, Viewport v, CompositionMode m) => policy.Suitable(p, v, m, s)
            && (m == CompositionMode.Gallery
                ? FixedGalleryLayout.Arrange([p], v, s.Gap, s.AvoidFaceDisplayBoundaries && v == viewport && !s.IsPerDisplay(m) ? displayRegions : null).Count > 0
                : m == CompositionMode.GalleryScroll || FaceMotionSafety.TryPlan(m, p, v, s,
                    displays: v == viewport && !s.IsPerDisplay(m) ? displayRegions : null) != null);
        bool NeedsMirror(PhotoInfo p, CompositionMode mode) => MirrorPolicy.Supports(mode) && !s.IsPerDisplay(mode)
            && displayViewports?.Count > 0 && displayViewports.Any(v => v.Width < viewport.Width || v.Height < viewport.Height)
            && MirrorPolicy.IsBelowHalf(p.Width, p.Height, viewport);
        bool Mirror(PhotoInfo p, CompositionMode mode) => NeedsMirror(p, mode)
            && displayViewports!.All(v => SuitableAt(p, v, mode));
        bool Suitable(PhotoInfo p, Viewport v, CompositionMode m) => NeedsMirror(p, m)
            ? Mirror(p, m) : SuitableAt(p, v, m);
        void Add(CompositionMode m, bool enabled, double weight)
        {
            if (!enabled || weight <= 0) return;
            var targets = s.IsPerDisplay(m) && displayViewports?.Count > 0 ? displayViewports : new[] { viewport };
            // A group chooses one mode. Every connected display must have a
            // suitable candidate for that mode at its own physical dimensions.
            if (targets.Any(v => !photos.Any(p => Suitable(p, v, m) && (excluded == null || !excluded.Contains(p.Path))))) return;
            var suitable = photos.Where(p => Suitable(p, targets[0], m) && (excluded == null || !excluded.Contains(p.Path))).ToArray();
            if (suitable.Length > 0) modes.Add((m, suitable));
        }
        Add(CompositionMode.Gallery, s.GalleryEnabled, weights.Gallery);
        Add(CompositionMode.GalleryScroll, s.GalleryScrollEnabled && photos.Count > 1, weights.Gallery);
        Add(CompositionMode.VerticalPan, s.VerticalPanEnabled, weights.Motion);
        Add(CompositionMode.HorizontalPan, s.HorizontalPanEnabled, weights.Motion);
        Add(CompositionMode.Zoom, s.ZoomEnabled, weights.Motion);
        var selectedMode = ModeSelection.Pick(modes.Select(m => m.Mode).ToArray(), weights.Gallery, weights.Motion, previous, repeats, random, allowGalleryRepeat);
        if (selectedMode == null) { LastDrawSkipped = modes.Count > 0; return null; }
        var chosen = modes.First(m => m.Mode == selectedMode);
        var target = s.IsPerDisplay(chosen.Mode) && displayViewports?.Count > 0 ? displayViewports[0] : viewport;
        var plan = SelectPhotos(chosen.Mode, chosen.Photos, target, s, excluded,
            !s.IsPerDisplay(chosen.Mode) && s.AvoidFaceDisplayBoundaries ? displayRegions : null);
        if (plan == null) return null;
        repeats = previous == chosen.Mode ? repeats + 1 : 1;
        previous = chosen.Mode;
        return Mirror(plan.Photos[0], plan.Mode) ? plan with { MirrorPerDisplay = true } : plan;
    }
    public CompositionPlan? ForMode(IReadOnlyList<PhotoInfo> photos, Viewport viewport, WallSettings s, CompositionMode mode, ISet<string>? excluded = null)
    {
        var suitable = photos.Where(p => policy.Suitable(p, viewport, mode, s)
            && (mode is CompositionMode.Gallery or CompositionMode.GalleryScroll || FaceMotionSafety.TryPlan(mode, p, viewport, s) != null)
            && (excluded == null || !excluded.Contains(p.Path))).ToArray();
        return suitable.Length > 0 ? SelectPhotos(mode, suitable, viewport, s, excluded) : null;
    }
    private CompositionPlan? SelectPhotos(CompositionMode mode, PhotoInfo[] photos, Viewport viewport, WallSettings s, ISet<string>? excluded,
        IReadOnlyList<FrameRect>? displays = null)
    {
        var selected = new List<PhotoInfo>();
        var used = new HashSet<string>(excluded ?? new HashSet<string>(), StringComparer.OrdinalIgnoreCase);
        var count = mode == CompositionMode.Gallery ? s.GalleryMax : 1;
        if (mode == CompositionMode.GalleryScroll) count = Math.Min(24, photos.Length);
        var stripWidth = s.Gap;
        var preferred = photos.Where(p => viewport.Width >= viewport.Height ? p.Aspect < 1 : p.Aspect >= 1).ToArray();
        for (var i = 0; i < count; i++)
        {
            var fitting = mode == CompositionMode.Gallery
                ? photos.Where(p => !used.Contains(p.Path) && FixedGalleryLayout.Update(selected, p, viewport, s.Gap, displays ?? [], -1, s.GalleryMax)?.IsAddition == true).ToArray()
                : photos;
            var preferredFits = fitting.Where(p => preferred.Contains(p)).ToArray();
            var photo = selector.Pick(mode is CompositionMode.Gallery or CompositionMode.GalleryScroll && preferredFits.Any(p => !used.Contains(p.Path)) ? preferredFits : fitting, s, used);
            if (photo == null) break;
            if (mode == CompositionMode.Gallery)
                selected = FixedGalleryLayout.Update(selected, photo, viewport, s.Gap, displays ?? [], -1, s.GalleryMax)!.Photos.ToList();
            else selected.Add(photo);
            used.Add(photo.Path);
            stripWidth += Math.Max(1, viewport.Height - 2 * s.Gap) * photo.Aspect + s.Gap;
            if (mode == CompositionMode.GalleryScroll && selected.Count >= 2 && stripWidth >= viewport.Width + viewport.Height * 1.5) break;
        }
        if (mode == CompositionMode.Gallery)
            selected = FixedGalleryLayout.Arrange(selected, viewport, s.Gap, displays).Select(i => selected[i.Index]).ToList();
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

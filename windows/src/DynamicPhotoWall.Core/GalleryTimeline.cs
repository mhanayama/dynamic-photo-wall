namespace DynamicPhotoWall.Core;

// One scheduled replacement for the entire group, including per-display scenes.
// Geometry and event generation are independent of networking and WPF.
public static class GalleryTimeline
{
    public sealed record Surface(IReadOnlyList<PhotoInfo> Photos, Viewport Viewport, IReadOnlyList<FrameRect> Displays,
        IReadOnlyList<FrameRect>? Frames = null);
    public sealed record Segment(int SurfaceIndex, PhotoInfo Photo, FrameRect From, FrameRect To,
        double At, double Until, double MotionSeconds, double FadeIn, double FadeOut);
    public sealed record Timeline(IReadOnlyList<Segment> Segments, double Duration, double NextChangeSeconds, IReadOnlyList<string> Updated);
    private sealed record Track(PhotoInfo Photo, FrameRect From, FrameRect To, double At, double FadeIn, double MotionSeconds);
    public static IReadOnlyList<Segment> Build(IReadOnlyList<Surface> surfaces, double duration, WallSettings settings,
        Func<IReadOnlyList<PhotoInfo>, PhotoInfo?> replacement, Random random, IReadOnlyList<PhotoInfo>? candidates = null)
        => BuildPlan(surfaces, duration, settings, replacement, random, candidates, preserveTiming: false).Segments;
    public static Timeline BuildPlan(IReadOnlyList<Surface> surfaces, double duration, WallSettings settings,
        Func<IReadOnlyList<PhotoInfo>, PhotoInfo?> replacement, Random random, IReadOnlyList<PhotoInfo>? candidates = null,
        double? nextChangeSeconds = null, IEnumerable<string>? updated = null, bool preserveTiming = true)
    {
        var result = new List<Segment>();
        var rotation = new GalleryRotation(updated);
        var state = surfaces.Select(s => (s.Frames == null ? FixedGalleryLayout.Arrange(s.Photos, s.Viewport, settings.Gap, s.Displays)
            : s.Frames.Select((frame, index) => new FixedGalleryLayout.Item(index, frame)).ToArray())
            .Select(i => new Track(s.Photos[i.Index], i.Frame, i.Frame, 0, 0, .1)).ToList()).ToArray();
        double Interval() => settings.GalleryMinSeconds + random.NextDouble() * (settings.GalleryMaxSeconds - settings.GalleryMinSeconds);
        void End(int surface, Track track, double until, double fadeOut)
            => result.Add(new(surface, track.Photo, track.From, track.To, track.At, until,
                track.MotionSeconds, track.FadeIn, fadeOut));
        var at = nextChangeSeconds ?? Interval();
        for (; at + settings.FadeSeconds < duration; at += settings.FadeSeconds + Interval())
        {
            if (result.Count + state.Sum(s => s.Count) * 2 > 1000) break;
            var slots = state.SelectMany((s, surface) => s.Select((_, index) => (Surface: surface, Index: index))).ToArray();
            if (slots.Length == 0) break;
            var selected = slots[rotation.Choose(state.SelectMany(s => s.Select(t => t.Photo)).ToArray(), random)];
            var old = state[selected.Surface]; var surface = surfaces[selected.Surface];
            var active = state.SelectMany(s => s.Select(t => t.Photo)).ToArray();
            var excluded = active;
            if (candidates != null && old.Count < settings.GalleryMax)
            {
                var additions = candidates.Where(p => active.All(a => !string.Equals(a.Path, p.Path, StringComparison.OrdinalIgnoreCase))
                    && FixedGalleryLayout.Update(old.Select(t => t.Photo).ToArray(), p, surface.Viewport, settings.Gap, surface.Displays, -1, settings.GalleryMax)?.IsAddition == true).ToArray();
                if (additions.Length > 0) excluded = active.Concat(candidates.Except(additions)).ToArray();
            }
            var photo = replacement(excluded);
            if (photo == null || state.SelectMany(s => s).Any(t => t.Photo.Path == photo.Path)) continue;
            var change = FixedGalleryLayout.Update(old.Select(t => t.Photo).ToArray(), photo, surface.Viewport, settings.Gap,
                surface.Displays, selected.Index, settings.GalleryMax);
            if (change == null) continue;
            var proposed = change.Photos; var arranged = change.Items; var incoming = change.IncomingIndex;
            int Original(int index) => change.IsAddition && index > incoming ? index - 1 : index;
            var survivors = arranged.Where(i => i.Index != incoming).Select(i => Original(i.Index)).ToHashSet();
            for (var i = 0; i < old.Count; i++) End(selected.Surface, old[i], survivors.Contains(i) ? at : at + settings.FadeSeconds,
                survivors.Contains(i) ? 0 : settings.FadeSeconds);
            state[selected.Surface] = arranged.Select(item => new Track(proposed[item.Index],
                item.Index == incoming ? item.Frame : old[Original(item.Index)].To, item.Frame, at,
                item.Index == incoming ? settings.FadeSeconds : 0, Math.Max(.1, settings.FadeSeconds))).ToList();
            rotation.Inserted(photo);
        }
        // Never split a replacement across a planning boundary. Carry its due
        // time and rotation into the next chunk rather than drawing a new scene.
        var end = preserveTiming ? Math.Min(duration, at) : duration;
        for (var i = 0; i < state.Length; i++) foreach (var track in state[i]) End(i, track, end, 0);
        var activePaths = state.SelectMany(s => s.Select(t => t.Photo.Path)).ToHashSet(StringComparer.OrdinalIgnoreCase);
        return new(result.Where(s => s.Until > s.At).ToArray(), end, Math.Max(0, at - end), rotation.Updated.Where(activePaths.Contains).ToArray());
    }
}

namespace DynamicPhotoWall.Core;

// One scheduled replacement for the entire group, including per-display scenes.
// Geometry and event generation are independent of networking and WPF.
public static class GalleryTimeline
{
    public sealed record Surface(IReadOnlyList<PhotoInfo> Photos, Viewport Viewport, IReadOnlyList<FrameRect> Displays);
    public sealed record Segment(int SurfaceIndex, PhotoInfo Photo, FrameRect From, FrameRect To,
        double At, double Until, double MotionSeconds, double FadeIn, double FadeOut);
    private sealed record Track(PhotoInfo Photo, FrameRect From, FrameRect To, double At, double FadeIn);
    public static IReadOnlyList<Segment> Build(IReadOnlyList<Surface> surfaces, double duration, WallSettings settings,
        Func<IReadOnlyList<PhotoInfo>, PhotoInfo?> replacement, Random random, IReadOnlyList<PhotoInfo>? candidates = null)
    {
        var result = new List<Segment>();
        var rotation = new GalleryRotation();
        var state = surfaces.Select(s => FixedGalleryLayout.Arrange(s.Photos, s.Viewport, settings.Gap, s.Displays)
            .Select(i => new Track(s.Photos[i.Index], i.Frame, i.Frame, 0, 0)).ToList()).ToArray();
        double Interval() => settings.GalleryMinSeconds + random.NextDouble() * (settings.GalleryMaxSeconds - settings.GalleryMinSeconds);
        void End(int surface, Track track, double until, double fadeOut)
            => result.Add(new(surface, track.Photo, track.From, track.To, track.At, until,
                track.At == 0 ? .1 : Math.Max(.1, settings.FadeSeconds), track.FadeIn, fadeOut));
        for (var at = Interval(); at + settings.FadeSeconds < duration; at += settings.FadeSeconds + Interval())
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
                item.Index == incoming ? settings.FadeSeconds : 0)).ToList();
            rotation.Inserted(photo);
        }
        for (var i = 0; i < state.Length; i++) foreach (var track in state[i]) End(i, track, duration, 0);
        return result;
    }
}

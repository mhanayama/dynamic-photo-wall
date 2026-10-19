using Net = DynamicPhotoWall.Networking;
using Viewport = DynamicPhotoWall.Core.Viewport;
using FrameRect = DynamicPhotoWall.Core.FrameRect;
using FaceRegion = DynamicPhotoWall.Core.FaceRegion;

namespace DynamicPhotoWall.Networking.Windows;

public sealed class WindowsScenePlanner(Func<Net.SharedAssetKey, byte[]> readImage) : Net.IScenePlanner
{
    private readonly Dictionary<Guid, CompositionEngine> engines = [];
    private readonly Dictionary<Guid, PhotoSelector> selectors = [];
    private readonly Dictionary<Guid, (Guid Session, long Revision)> configurations = [];
    private readonly Random random = new();
    public Task<Net.SharedScenePlan?> PrepareAsync(Net.WallSnapshot wall, Guid groupId,
        IReadOnlyList<Net.SharedPhoto> source, CancellationToken cancellation)
        => PrepareAsync(wall, groupId, source, cancellation, null);
    public Task<Net.SharedScenePlan?> PrepareAsync(Net.WallSnapshot wall, Guid groupId,
        IReadOnlyList<Net.SharedPhoto> source, CancellationToken cancellation, Net.SharedScenePlan? previousPlan)
        => Task.Run(() => Prepare(wall, groupId, source, cancellation, previousPlan), cancellation);
    private Net.SharedScenePlan? Prepare(Net.WallSnapshot wall, Guid groupId, IReadOnlyList<Net.SharedPhoto> source, CancellationToken token,
        Net.SharedScenePlan? previousPlan)
    {
        var displays = wall.Displays.Where(d => d.Selected && (d.GroupId ?? Net.SceneCoordinator.StandaloneId(d.Key)) == groupId).ToArray();
        if (displays.Length == 0) return null;
        var left = displays.Min(d => d.X); var top = displays.Min(d => d.Y);
        var width = displays.Max(d => (double)d.X + d.Width) - left; var height = displays.Max(d => (double)d.Y + d.Height) - top;
        var viewport = new DynamicPhotoWall.Core.Viewport(width, height);
        var settings = WindowsPlaybackOptions.Import(wall.Playback);
        var usable = source.Where(p => p.IsReadyForPlanning).ToDictionary(p => p.Key.OpaqueId, p => p);
        var photos = usable.Values.Select(p => new PhotoInfo(p.Key.OpaqueId, p.PixelWidth, p.PixelHeight, 1, null, p.ByteLength, 0,
            p.FaceMetadata.Faces.Select(f => new DynamicPhotoWall.Core.FaceRegion(f.X, f.Y, f.Width, f.Height)).ToArray())).ToArray();
        if (!engines.TryGetValue(groupId, out var engine))
        { var selector = new PhotoSelector(); selectors[groupId] = selector; engines[groupId] = engine = new(selector); }
        var configuration = (wall.SessionId, wall.Revision);
        if (!configurations.TryGetValue(groupId, out var previous) || previous != configuration)
        { engine.ResetModeHistory(); configurations[groupId] = configuration; }
        var picking = selectors[groupId];
        var views = displays.Select(d => new DynamicPhotoWall.Core.Viewport(d.Width, d.Height)).ToArray();
        var regions = displays.Select(d => new DynamicPhotoWall.Core.FrameRect(d.X - left, d.Y - top, d.Width, d.Height)).ToArray();
        var previousGallery = previousPlan != null && previousPlan.GroupId == groupId && previousPlan.SessionId == wall.SessionId
            && previousPlan.SettingsRevision == wall.Revision && previousPlan.Displays.SequenceEqual(displays)
            && previousPlan.Mode is Net.SceneMode.Gallery or Net.SceneMode.GalleryScroll
            && previousPlan.Placements.Where(p => p.VisibleUntil == previousPlan.Duration).All(p => usable.ContainsKey(p.Asset.OpaqueId))
            ? previousPlan : null;
        // A repeated draw extends the committed gallery from its endpoint. It
        // must not pick a new set of initial photographs or fade the wall again.
        var composition = engine.Next(photos, viewport, settings, displayViewports: views, displayRegions: regions, allowGalleryRepeat: true,
            continuation: previousGallery == null ? null : new(Enum.Parse<CompositionMode>(previousGallery.Mode.ToString()), []));
        if (composition == null) return null;
        var continuing = previousGallery != null && previousGallery.Mode.ToString() == composition.Mode.ToString();
        var perDisplay = settings.IsPerDisplay(composition.Mode) || composition.MirrorPerDisplay;
        var placements = new List<Net.ScenePlacement>(); var duration = 0d;
        for (var surface = 0; surface < (perDisplay ? displays.Length : 1); surface++)
        {
            token.ThrowIfCancellationRequested();
            var offsetX = perDisplay ? regions[surface].X : 0; var offsetY = perDisplay ? regions[surface].Y : 0;
            var v = perDisplay ? views[surface] : viewport;
            var plan = continuing ? composition : perDisplay && !composition.MirrorPerDisplay
                ? engine.ForMode(photos, v, settings, composition.Mode) : composition;
            if (plan == null) return null;
            var displayId = perDisplay ? displays[surface].Key.LayoutId : null;
            var clip = new Net.FrameRect(offsetX, offsetY, v.Width, v.Height);
            var seconds = 0d;
            if (plan.Mode == CompositionMode.Gallery)
            {
                // Gallery is planned once below, across all surfaces.
                duration = Math.Max(90, settings.GalleryMaxSeconds * 3);
                continue;
            }
            else if (plan.Mode == CompositionMode.GalleryScroll)
            {
                seconds = Math.Max(120, settings.GalleryMaxSeconds * 3);
                var h = Math.Max(1, v.Height - 2 * settings.Gap); var x = settings.Gap; var index = 0;
                if (continuing)
                {
                    foreach (var p in previousGallery!.Placements.Where(p => p.DisplayId == displayId && p.ToX + p.Width > clip.X))
                    {
                        placements.Add(p with { Id = placements.Count, FromX = p.ToX, FromY = p.ToY,
                            ToX = p.ToX - seconds * settings.GalleryScrollPixelsPerSecond, StartSeconds = 0, MotionSeconds = seconds,
                            VisibleFrom = 0, VisibleUntil = seconds });
                        x = Math.Max(x, p.ToX - offsetX + p.Width + settings.Gap);
                    }
                }
                while (x < v.Width + seconds * settings.GalleryScrollPixelsPerSecond)
                {
                    var chosen = index < plan.Photos.Count ? plan.Photos[index] : picking.Pick(photos, settings) ?? photos[0];
                    var w = h * chosen.Aspect;
                    placements.Add(new(placements.Count, usable[chosen.Path].Key, displayId, clip, w, h,
                        offsetX + x, offsetY + (v.Height - h) / 2, offsetX + x - seconds * settings.GalleryScrollPixelsPerSecond,
                        offsetY + (v.Height - h) / 2, 1, 1, .5, .5, 0, seconds, 0, seconds, 0, settings.CornerRadius, false));
                    x += w + settings.Gap; index++;
                    if (index >= 128) break;
                }
            }
            else
            {
                var chosen = plan.Photos[0];
                var motion = FaceMotionSafety.Plan(plan.Mode, chosen, v, settings, random.Next(2) == 0,
                    .35 + random.NextDouble() * .3, .35 + random.NextDouble() * .3, perDisplay ? [] : regions);
                seconds = motion.Seconds + (plan.Mode == CompositionMode.VerticalPan && settings.StopAtFace && chosen.Faces?.Count > 0 ? 3 : 0);
                if (plan.Mode == CompositionMode.VerticalPan)
                    clip = new(offsetX + motion.FromX, offsetY + (motion.FrameTop ?? (v.Height - Math.Min(v.Height, motion.Height)) / 2),
                        motion.Width, Math.Min(v.Height, motion.Height));
                var frameTop = plan.Mode == CompositionMode.VerticalPan ? clip.Y - offsetY : motion.FrameTop ?? 0;
                placements.Add(new(placements.Count, usable[chosen.Path].Key, displayId, clip, motion.Width, motion.Height,
                    offsetX + motion.FromX, offsetY + frameTop + motion.FromY, offsetX + motion.ToX, offsetY + frameTop + motion.ToY,
                    motion.FromScale, motion.ToScale, motion.CenterX, motion.CenterY, 0, motion.Seconds, 0, seconds,
                    0, 0, plan.Mode == CompositionMode.Zoom));
            }
            duration = Math.Max(duration, seconds);
        }
        Net.GallerySchedule? gallerySchedule = null;
        if (composition.Mode == CompositionMode.Gallery)
        {
            var gallerySurfaces = new List<GalleryTimeline.Surface>();
            for (var i = 0; i < (perDisplay ? displays.Length : 1); i++)
            {
                var v = perDisplay ? views[i] : viewport;
                var selected = continuing ? composition : perDisplay ? engine.ForMode(photos, v, settings, CompositionMode.Gallery) : composition;
                if (selected == null) return null;
                var terminal = continuing ? previousGallery!.Placements.Where(p => p.VisibleUntil == previousGallery.Duration
                    && p.DisplayId == (perDisplay ? displays[i].Key.LayoutId : null)).ToArray() : [];
                var ox = perDisplay ? regions[i].X : 0; var oy = perDisplay ? regions[i].Y : 0;
                gallerySurfaces.Add(new(continuing ? terminal.Select(p => photos.First(photo => photo.Path == p.Asset.OpaqueId)).ToArray() : selected.Photos,
                    v, !perDisplay && settings.AvoidFaceDisplayBoundaries ? regions : [],
                    continuing ? terminal.Select(p => new DynamicPhotoWall.Core.FrameRect(p.ToX - ox, p.ToY - oy, p.Width, p.Height)).ToArray() : null));
            }
            var timeline = GalleryTimeline.BuildPlan(gallerySurfaces, duration, settings,
                active => picking.Pick(photos, settings, active.Select(p => p.Path).ToHashSet()), random, photos,
                continuing ? previousGallery!.GallerySchedule?.NextChangeSeconds : null,
                continuing ? previousGallery!.GallerySchedule?.UpdatedAssets : null);
            duration = timeline.Duration;
            gallerySchedule = new(timeline.NextChangeSeconds, timeline.Updated.ToArray());
            foreach (var segment in timeline.Segments)
            {
                var i = segment.SurfaceIndex;
                var x = perDisplay ? regions[i].X : 0; var y = perDisplay ? regions[i].Y : 0;
                var v = gallerySurfaces[i].Viewport;
                placements.Add(new(placements.Count, usable[segment.Photo.Path].Key, perDisplay ? displays[i].Key.LayoutId : null,
                    new(x, y, v.Width, v.Height), segment.To.Width, segment.To.Height,
                    x + segment.From.X, y + segment.From.Y, x + segment.To.X, y + segment.To.Y, 1, 1, .5, .5,
                    segment.At, segment.MotionSeconds, segment.At, segment.Until, 0, settings.CornerRadius, true)
                    { FadeInSeconds = segment.FadeIn, FadeOutSeconds = segment.FadeOut });
            }
            if (placements.Count == 0) return null;
        }
        // Short per-display motions hold their endpoints on the group's common timeline.
        placements = placements.Select(p => p.VisibleUntil < duration && composition.Mode is not CompositionMode.Gallery
            ? p with { VisibleUntil = duration } : p).ToList();
        var result = new Net.SharedScenePlan(Guid.NewGuid(), groupId, wall.SessionId, wall.Revision,
            Enum.Parse<Net.SceneMode>(composition.Mode.ToString()), new(width, height), displays, duration,
            settings.FadeSeconds, settings.Background, placements.ToArray(), [])
            { ContinuationOf = continuing ? previousGallery!.Id : null, GallerySchedule = gallerySchedule };
        if (settings.GlassBackground) result = result with { Ambient = WindowsAmbientBuilder.Build(result, usable, readImage, token) };
        return result;
    }
}

using DynamicPhotoWall.Core;
using DynamicPhotoWall.Networking.Windows;
using DynamicPhotoWall.Rendering;
using DynamicPhotoWall.Motion;
using Net = DynamicPhotoWall.Networking;

namespace DynamicPhotoWall.Tests;

internal static class GalleryFaceTests
{
    private static void Check(bool value, string message) { if (!value) throw new Exception(message); }
    private static PhotoInfo Photo(string id, int w, int h, params FaceRegion[] faces) => new(id, w, h, 1, null, 1, 0, faces);
    private static bool Contains(FrameRect outer, FrameRect inner) => inner.X >= outer.X - .001 && inner.Y >= outer.Y - .001
        && inner.X + inner.Width <= outer.X + outer.Width + .001 && inner.Y + inner.Height <= outer.Y + outer.Height + .001;
    public static Task MotionFacesFitPhysicalOutputs()
    {
        var settings = new WallSettings();
        foreach (var vertical in new[] { false, true })
        foreach (var reverse in new[] { false, true })
        {
            var v = vertical ? new Viewport(1200, 8000) : new Viewport(5760, 1080);
            var displays = vertical ? Enumerable.Range(0, 4).Select(i => new FrameRect(0, i * 2000, 1200, 2000)).ToArray()
                : Enumerable.Range(0, 3).Select(i => new FrameRect(i * 1920, 0, 1920, 1080)).ToArray();
            var photo = Photo("tall-face", 6000, 4000, new(.2, .1, .2, .8), new(.55, .2, .15, .3));
            var p = FaceMotionSafety.Plan(CompositionMode.Zoom, photo, v, settings, reverse, displays: displays);
            var bounds = FaceSafeLayout.Bounds(photo)!;
            Check(Math.Max(p.FromScale, p.ToScale) < 1.25 && Math.Abs(Math.Max(p.FromScale, p.ToScale) / Math.Min(p.FromScale, p.ToScale) - 1.25) < .0001,
                "oversized faces reduce the zoom start and end while preserving visible zoom travel");
            for (var i = 0; i <= 100; i++)
            {
                var scale = p.FromScale + (p.ToScale - p.FromScale) * i / 100;
                var face = new FrameRect(p.FromX + (1 - scale) * p.CenterX * p.Width + bounds.X * p.Width * scale,
                    p.FromY + (1 - scale) * p.CenterY * p.Height + bounds.Y * p.Height * scale, bounds.Width * p.Width * scale, bounds.Height * p.Height * scale);
                Check(displays.Any(d => Contains(d, face)), "all detected faces must fit one physical display throughout zoom");
            }
        }
        var viewport = new Viewport(1920, 1080);
        var verticalPhoto = Photo("vertical", 2000, 6000, new FaceRegion(.3, .05, .4, .5));
        var pan = FaceMotionSafety.Plan(CompositionMode.VerticalPan, verticalPhoto, viewport, settings);
        var faceBounds = FaceSafeLayout.Bounds(verticalPhoto)!;
        Check(pan.Width < viewport.Width && faceBounds.Height * pan.Height < viewport.Height, "vertical pan shrinks width until the full face height fits");
        var resting = new FrameRect(pan.ToX + faceBounds.X * pan.Width, (pan.FrameTop ?? 0) + pan.ToY + faceBounds.Y * pan.Height, faceBounds.Width * pan.Width, faceBounds.Height * pan.Height);
        Check(Contains(new(0, 0, 1920, 1080), resting), "pan rests with a complete face rectangle");
        var horizontalPhoto = Photo("horizontal", 16000, 2000, new FaceRegion(.4, .01, .1, .98));
        var outputs = Enumerable.Range(0, 3).Select(i => new FrameRect(i * 1920, 0, 1920, 1080)).ToArray();
        var horizontal = FaceMotionSafety.Plan(CompositionMode.HorizontalPan, horizontalPhoto, new(5760, 1080), settings, displays: outputs);
        var hf = FaceSafeLayout.Bounds(horizontalPhoto)!;
        var restFace = new FrameRect(horizontal.ToX + hf.X * horizontal.Width, (horizontal.FrameTop ?? 0) + hf.Y * horizontal.Height,
            hf.Width * horizontal.Width, hf.Height * horizontal.Height);
        Check(horizontal.Height < 1080 && hf.Height * horizontal.Height <= 1032.001 && outputs.Any(d => Contains(d, restFace)),
            "horizontal pan also shrinks a tall face and rests inside one physical output");
        Check(FaceMotionSafety.TryPlan(CompositionMode.VerticalPan, Photo("all-face", 1000, 2000, new FaceRegion(0, 0, 1, 1)), viewport, settings) == null,
            "a face-safe pan without meaningful remaining travel is skipped");
        return Task.CompletedTask;
    }
    public static Task GalleryKeepsItsShortAxisDuringRepacking()
    {
        foreach (var vertical in new[] { false, true })
        {
            var v = vertical ? new Viewport(1080, 6000) : new Viewport(6000, 1080);
            var photos = Enumerable.Range(0, 8).Select(i => vertical ? Photo(i.ToString(), 1800, 900) : Photo(i.ToString(), 900, 1800)).ToArray();
            var before = FixedGalleryLayout.Arrange(photos, v, 8);
            photos[3] = vertical ? Photo("replacement", 900, 2700) : Photo("replacement", 2700, 900);
            var after = FixedGalleryLayout.Arrange(photos, v, 8, pinned: 3);
            Check(before.Count > after.Count && after.Any(i => i.Index == 3), "a larger replacement evicts neighbours rather than shrinking the group");
            foreach (var item in before.Concat(after))
                Check(Math.Abs((vertical ? item.Frame.Width : item.Frame.Height) - 1064) < .001, "all photos keep the group's short axis nearly full");
            for (var i = 1; i < after.Count; i++)
                Check(vertical ? after[i - 1].Frame.Y + after[i - 1].Frame.Height + 7.999 <= after[i].Frame.Y
                    : after[i - 1].Frame.X + after[i - 1].Frame.Width + 7.999 <= after[i].Frame.X, "repacked photos preserve spacing without overlap");
            var huge = vertical ? Photo("huge", 100, 10000) : Photo("huge", 10000, 100);
            var oversized = FixedGalleryLayout.Arrange([huge], v, 8);
            Check(oversized.Count == 1 && Math.Abs((vertical ? oversized[0].Frame.Width : oversized[0].Frame.Height) - 1064) < .001,
                "an oversized single photo clips only its long axis and retains the fixed short-axis size");
        }
        return Task.CompletedTask;
    }
    public static async Task GroupTimelineChangesOnePhotoAfterEachQuietInterval()
    {
        var migrated = new WallSettings { GalleryMinSeconds = 30, GalleryMaxSeconds = 60 }; migrated.Normalize();
        Check(migrated.GalleryMinSeconds == 5 && migrated.GalleryMaxSeconds == 10, "the former default interval migrates to five-to-ten seconds");
        var settings = new WallSettings { GalleryScrollEnabled = false, VerticalPanEnabled = false, HorizontalPanEnabled = false, ZoomEnabled = false, GlassBackground = false };
        var all = Enumerable.Range(0, 30).Select(i => Photo(i.ToString("D2"), 800, 1600)).ToArray();
        var inputs = new[] { new GalleryTimeline.Surface(all.Take(2).ToArray(), new(1920, 1080), []), new GalleryTimeline.Surface(all.Skip(2).Take(2).ToArray(), new(1920, 1080), []) };
        var timeline = GalleryTimeline.Build(inputs, 150, settings, active => all.FirstOrDefault(p => active.All(a => a.Path != p.Path)), new Random(3));
        var born = timeline.Where(t => t.FadeIn > 0).OrderBy(t => t.At).ToArray();
        Check(born.Length >= 3 && born.Select(t => t.At).Distinct().Count() == born.Length, "only one photo starts changing at each group event");
        var previous = 0d;
        foreach (var t in born)
        {
            var quiet = t.At - previous;
            Check(quiet >= 5 - .001 && quiet <= 10 + .001, "each change starts five to ten seconds after the prior fade completes");
            previous = t.At + settings.FadeSeconds;
        }
        Check(timeline.All(t => t.To.Height == 1064 && t.From.Height == 1064), "timeline moves do not resize gallery height");
        var peer = Guid.NewGuid(); var group = Guid.NewGuid(); var source = Guid.NewGuid(); var generation = Guid.NewGuid();
        var sharedPhotos = all.Select((p, i) => new Net.SharedPhoto(new(peer, source, generation, i.ToString("x64")), p.Width, p.Height, 1,
            new(1, p.Width, p.Height, "fixture", "1", Net.FaceAnalysisState.Complete, []))).ToArray();
        settings.GalleryPerDisplay = true;
        var options = WindowsPlaybackOptions.Export(settings);
        var wall = new Net.WallSnapshot(Guid.NewGuid(), Guid.NewGuid(), peer, 0, [new(group, "gallery")],
            [new(new(peer, "left"), true, group, 0, 0, 1920, 1080), new(new(peer, "right"), true, group, 1920, 0, 1920, 1080)], [new(peer, source, generation)], options);
        var plan = await new WindowsScenePlanner(_ => throw new Exception("metadata-only test"))
            .PrepareAsync(wall, group, sharedPhotos, CancellationToken.None) ?? throw new Exception("gallery plan missing");
        plan.Validate();
        var json = System.Text.Json.JsonSerializer.SerializeToUtf8Bytes(plan, Net.PeerProtocol.Json);
        var received = System.Text.Json.JsonSerializer.Deserialize<Net.SharedScenePlan>(json, Net.PeerProtocol.Json)!;
        received.Validate();
        Check(received.Placements.Select(p => (p.FadeInSeconds, p.FadeOutSeconds)).SequenceEqual(plan.Placements.Select(p => (p.FadeInSeconds, p.FadeOutSeconds))),
            "independent incoming and outgoing fades survive the actual peer wire format");
        foreach (var survivor in received.Placements.Where(p => p.VisibleFrom > 0 && p.FadeInSeconds == 0))
            Check(Net.SceneEvaluation.Evaluate(survivor, survivor.VisibleFrom).Opacity == 1, "unchanged photos do not refade when a neighbour moves");
        var changes = plan.Placements.Where(p => p.FadeInSeconds > 0).OrderBy(p => p.VisibleFrom).ToArray();
        Check(changes.Length > 1 && changes.Select(p => p.VisibleFrom).Distinct().Count() == changes.Length, "the network plan also shares one timer across both displays");
        Check(plan.Placements.All(p => p.Height == 1064), "network galleries retain their full-height strips");
    }
    public static async Task LocalReplacementKeepsHeightWithoutShowingAWindow()
    {
        var settings = new WallSettings { GlassBackground = false, FadeSeconds = .08, AvoidFaceDisplayBoundaries = false, GalleryMax = 20 };
        var renderer = new PhotoRenderer(new(6000, 1080), settings, new TransitionController(), new AnimationScheduler());
        var bitmap = System.Windows.Media.Imaging.BitmapSource.Create(1, 1, 96, 96, System.Windows.Media.PixelFormats.Bgra32, null, new byte[] { 0, 0, 255, 255 }, 4); bitmap.Freeze();
        try
        {
            var photos = Enumerable.Range(0, 8).Select(i => Photo(i.ToString(), 900, 1800)).ToArray();
            var scene = renderer.Build(new(CompositionMode.Gallery, photos), Enumerable.Repeat(bitmap, photos.Length).ToArray(), new Random(1));
            await renderer.ShowAsync(scene, CancellationToken.None);
            var before = scene.Slots.Count;
            var replace = renderer.ReplaceSlotAsync(scene, 3, Photo("wide", 2700, 900), bitmap, CancellationToken.None);
            while (!replace.IsCompleted)
            {
                Check(scene.Slots.All(slot => Math.Abs(slot.Height - 1064) < .001), "local reflow never changes the fixed gallery height");
                await Task.Delay(5);
            }
            await replace;
            Check(scene.Slots.Count < before && scene.Slots.Count == scene.Photos.Count && scene.Slots.Count == scene.Bitmaps.Count,
                "reflow evicts neighbours and commits matching slot, photo and bitmap lists");
            Check(scene.Photos.Any(p => p.Path == "wide") && scene.Slots.All(slot => slot.Height == 1064), "the replacement remains present at full height");
            var retained = scene.Photos.Select(p => p.Path).ToArray();
            Check(await renderer.ReplaceSlotAsync(scene, 0, Photo("added", 60, 1800), bitmap, CancellationToken.None), "a ready incoming card is added into free padding");
            Check(scene.Photos.Count == retained.Length + 1 && retained.All(path => scene.Photos.Any(p => p.Path == path)),
                "the renderer keeps every previous photo when there is space to add one");
            Check(scene.Photos.Count == scene.Slots.Count && scene.Photos.Count == scene.Bitmaps.Count,
                "addition keeps the rendered slots, metadata and bitmaps aligned");
            Check(!await renderer.ReplaceSlotAsync(scene, 0, scene.Photos[0], bitmap, CancellationToken.None), "an active photo cannot trigger another update of itself");
        }
        finally { renderer.Clear(); renderer.Close(); }
    }
}

using System.Text.Json;
using DynamicPhotoWall.Core;
using DynamicPhotoWall.Networking.Windows;
using Net = DynamicPhotoWall.Networking;

namespace DynamicPhotoWall.Tests;

internal static class ZoomMotionTests
{
    private static void Check(bool value, string message) { if (!value) throw new Exception(message); }
    public static async Task Run()
    {
        var settings = new WallSettings { GalleryEnabled = false, GalleryScrollEnabled = false, VerticalPanEnabled = false,
            HorizontalPanEnabled = false, GlassBackground = false, FaceAwareFraming = false };
        settings.Normalize();
        Check(settings.ZoomSeconds == 30 && settings.MaxZoom == 1.25, "new defaults must visibly zoom by 25 percent over thirty seconds");
        var custom = JsonSerializer.Deserialize<WallSettings>("{\"ZoomSeconds\":20,\"MaxZoom\":1.08}")!; custom.Normalize();
        Check(custom.ZoomSeconds == 20 && custom.MaxZoom == 1.08, "saved preferences remain explicit and are not silently overwritten");
        custom.MaxZoom = 1.5; custom.Normalize(); Check(custom.MaxZoom == 1.5, "the range permits stronger zoom");
        custom.MaxZoom = double.NaN; custom.ZoomSeconds = double.NaN; custom.Normalize();
        Check(custom.MaxZoom == 1.25 && custom.ZoomSeconds == 30, "invalid numbers use the new defaults");
        var shared = WindowsPlaybackOptions.Export(settings); shared.Validate();
        Check(shared == new Net.PlaybackOptions { GalleryEnabled = false, GalleryScrollEnabled = false, VerticalPanEnabled = false,
            HorizontalPanEnabled = false, GlassBackground = false, FaceAwareFraming = false }, "native and protocol defaults agree");
        Check(WindowsPlaybackOptions.Import(shared).MaxZoom == 1.25, "shared settings keep the selected ratio");
        foreach (var reverse in new[] { false, true })
        {
            var motion = MotionEngine.Plan(CompositionMode.Zoom, new("fixture", 3000, 2000, 1, null, 1, 0), new(1920, 1080), settings, reverse);
            Check(motion.Seconds == 30 && Math.Abs(motion.ToScale - motion.FromScale) == .25
                && motion.FromScale == (reverse ? 1.25 : 1), "both local zoom directions traverse the full twenty-five percent range");
        }
        var peer = Guid.NewGuid(); var group = Guid.NewGuid(); var source = Guid.NewGuid(); var generation = Guid.NewGuid();
        foreach (var width in new[] { 3000, 1500 })
        {
            var key = new Net.SharedAssetKey(peer, source, generation, new string('a', 64));
            var photo = new Net.SharedPhoto(key, width, 1000, 1, new(1, width, 1000, "fixture", "1", Net.FaceAnalysisState.Complete, []));
            Net.PeerDisplay[] displays = [new(new(peer, "a"), true, group, 0, 0, 1920, 1080), new(new(peer, "b"), true, group, 1920, 0, 1920, 1080)];
            var wall = new Net.WallSnapshot(Guid.NewGuid(), Guid.NewGuid(), peer, 1, [new(group, "zoom")], displays, [new(peer, source, generation)], shared);
            var plan = await new WindowsScenePlanner(_ => throw new Exception("metadata-only planning must not decode photos"))
                .PrepareAsync(wall, group, [photo], CancellationToken.None) ?? throw new Exception("missing zoom plan");
            Check(plan.Duration == 30 && plan.Placements.Length == (width == 1500 ? 2 : 1), "both mirror and span keep the full zoom duration");
            foreach (var p in plan.Placements)
            {
                var start = Net.SceneEvaluation.Evaluate(p, 0).Scale;
                var middle = Net.SceneEvaluation.Evaluate(p, 15).Scale;
                var end = Net.SceneEvaluation.Evaluate(p, 30).Scale;
                Check(Math.Abs(start - end) == .25 && Math.Abs(middle - 1.125) < .000001, "the shared timeline reaches a visible midpoint and endpoint");
                Check(Math.Abs(Net.SceneEvaluation.Evaluate(p, 5).Scale - start) > .01, "zoom already moves more than one percent in the first five seconds");
            }
        }
    }
}

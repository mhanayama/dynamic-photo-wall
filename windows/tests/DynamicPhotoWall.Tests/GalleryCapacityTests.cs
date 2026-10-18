using DynamicPhotoWall.Configuration;
using DynamicPhotoWall.Core;
using DynamicPhotoWall.Networking.Windows;
using Net = DynamicPhotoWall.Networking;

namespace DynamicPhotoWall.Tests;

// Metadata-only checks: no window, screenshot, bitmap or real photo is needed.
internal static class GalleryCapacityTests
{
    private static void Check(bool value, string message) { if (!value) throw new Exception(message); }
    public static async Task Run()
    {
        var viewport = new Viewport(15360, 1080);
        var photos = Enumerable.Range(0, 40).Select(i => new PhotoInfo($"/fixture/{i:00}.jpg", 800, 1600, 1, null, 1, 0)).ToArray();
        var settings = new WallSettings { GalleryScrollEnabled = false, VerticalPanEnabled = false,
            HorizontalPanEnabled = false, ZoomEnabled = false, RandomOrder = false, GlassBackground = false, AvoidFaceDisplayBoundaries = false };
        foreach (var limit in new[] { 1, 5, 12, 20 })
        {
            settings.GalleryMax = limit; settings.Normalize();
            var composition = new CompositionEngine(new PhotoSelector(new Random(42))).Next(photos, viewport, settings)!;
            Check(composition.Photos.Count == limit, $"Gallery accepts a {limit}-photo limit");
            Check(composition.Photos.Select(p => p.Path).Distinct().Count() == limit, "all photos are distinct");
            var frames = CompositionEngine.GalleryLayout(composition.Photos, viewport, settings.Gap);
            Check(frames.Count == limit && frames.All(r => r.Width > 0 && r.Height > 0 && r.X >= 0 && r.Y >= 0
                && r.X + r.Width <= viewport.Width + 1e-7 && r.Y + r.Height <= viewport.Height + 1e-7), "all frames fit inside the wide group");
        }
        Check(new CompositionEngine(new PhotoSelector()).Next(photos.Take(3).ToArray(), viewport, settings)!.Photos.Count == 3, "small libraries remain usable");
        Check(SettingsManager.Clone(settings).GalleryMax == 20, "settings round trip preserves twenty");
        var options = WindowsPlaybackOptions.Export(settings); options.Validate();
        Check(WindowsPlaybackOptions.Import(options).GalleryMax == 20, "network conversion preserves twenty");
        var rejected = false;
        try { (options with { GalleryMax = 21 }).Validate(); } catch (System.IO.InvalidDataException) { rejected = true; }
        Check(rejected, "wire contract rejects counts over twenty");
        settings.GalleryMax = 21; settings.Normalize(); Check(settings.GalleryMax == 20, "local settings clamp at twenty");

        var peer = Guid.NewGuid(); var group = Guid.NewGuid(); var source = Guid.NewGuid(); var generation = Guid.NewGuid();
        var displays = Enumerable.Range(0, 4).Select(i => new Net.PeerDisplay(new(peer, i.ToString()), true, group, i * 3840, 0, 3840, 1080)).ToArray();
        var sharedPhotos = Enumerable.Range(0, 40).Select(i => new Net.SharedPhoto(new(peer, source, generation, i.ToString("x64")),
            800, 1600, 1, new(1, 800, 1600, "fixture", "1", Net.FaceAnalysisState.Complete, []))).ToArray();
        var wall = new Net.WallSnapshot(Guid.NewGuid(), Guid.NewGuid(), peer, 0, [new(group, "wide")], displays, [new(peer, source, generation)], options);
        wall.Validate();
        var plan = await new WindowsScenePlanner(_ => throw new Exception("Metadata planning must not read images"))
            .PrepareAsync(wall, group, sharedPhotos, CancellationToken.None) ?? throw new Exception("No network plan");
        plan.Validate();
        Check(plan.Placements.Count(p => p.VisibleFrom == 0) == 20, "shared playback starts with twenty photos across four displays");
    }
}

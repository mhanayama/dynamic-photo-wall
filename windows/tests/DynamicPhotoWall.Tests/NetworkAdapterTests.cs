using System.IO;
using System.Security.Cryptography;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using DynamicPhotoWall.Core;
using DynamicPhotoWall.Motion;
using DynamicPhotoWall.Rendering;
using DynamicPhotoWall.Networking.Windows;
using Net = DynamicPhotoWall.Networking;

namespace DynamicPhotoWall.Tests;

internal static class NetworkAdapterTests
{
    private static void Check(bool value, string message) { if (!value) throw new Exception(message); }
    public static async Task PlanningAndRendering(string root)
    {
        var peer = Guid.NewGuid(); var other = Guid.NewGuid(); var source = Guid.NewGuid(); var generation = Guid.NewGuid(); var group = Guid.NewGuid();
        var bytes = new Dictionary<string, byte[]>(); var bitmaps = new Dictionary<string, BitmapSource>();
        var photos = new List<Net.SharedPhoto>();
        foreach (var (w, h, color) in new[] { (1600, 400, Colors.Red), (400, 1600, Colors.Blue), (600, 800, Colors.Green) })
        {
            var pixels = new byte[w * h * 4];
            for (var i = 0; i < w * h; i++) { pixels[i * 4] = color.B; pixels[i * 4 + 1] = color.G; pixels[i * 4 + 2] = color.R; pixels[i * 4 + 3] = 255; }
            var bitmap = BitmapSource.Create(w, h, 96, 96, PixelFormats.Bgra32, null, pixels, w * 4); bitmap.Freeze();
            var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap)); using var data = new MemoryStream(); encoder.Save(data);
            var original = data.ToArray(); var key = new Net.SharedAssetKey(peer, source, generation, Convert.ToHexStringLower(SHA256.HashData(original)));
            bytes[key.OpaqueId] = original; bitmaps[key.OpaqueId] = bitmap;
            photos.Add(new(key, w, h, original.Length, new(1, w, h, "fixture", "1", Net.FaceAnalysisState.Complete, [])));
        }
        var displays = new[] { new Net.PeerDisplay(new(peer, "left"), true, group, 0, 0, 400, 400), new Net.PeerDisplay(new(other, "right"), true, group, 400, 0, 600, 400) };
        var planner = new WindowsScenePlanner(key => bytes[key.OpaqueId].ToArray());
        foreach (var mode in Enum.GetValues<Net.SceneMode>())
        foreach (var individual in new[] { false, true })
        {
            var options = new Net.PlaybackOptions { GalleryEnabled = mode == Net.SceneMode.Gallery, GalleryScrollEnabled = mode == Net.SceneMode.GalleryScroll,
                VerticalPanEnabled = mode == Net.SceneMode.VerticalPan, HorizontalPanEnabled = mode == Net.SceneMode.HorizontalPan, ZoomEnabled = mode == Net.SceneMode.Zoom,
                GalleryPerDisplay = individual, GalleryScrollPerDisplay = individual, VerticalPanPerDisplay = individual, HorizontalPanPerDisplay = individual, ZoomPerDisplay = individual,
                GlassBackground = true, FadeSeconds = .2, GalleryMinSeconds = 10, GalleryMaxSeconds = 15 };
            var wall = new Net.WallSnapshot(Guid.NewGuid(), Guid.NewGuid(), peer, 1, [new(group, "shared")], displays, [new(peer, source, generation)], options);
            var plan = await planner.PrepareAsync(wall, group, photos, CancellationToken.None);
            Check(plan != null && plan.Mode == mode, $"existing composition engine plans shared {mode}, per-display={individual}"); plan!.Validate();
            Check(plan.Ambient.Length > 0 && plan.Ambient.All(p => p.Png.Length > 0), "leader preloads shared ambient samples");
            var selected = photos.Single(p => p.Key == plan.Placements[0].Asset);
            var automaticMirror = !individual && mode is (Net.SceneMode.VerticalPan or Net.SceneMode.HorizontalPan or Net.SceneMode.Zoom)
                && MirrorPolicy.IsBelowHalf(selected.PixelWidth, selected.PixelHeight, new(1000, 400));
            Check(plan.Placements.All(p => (p.DisplayId != null) == (individual || automaticMirror)), "small motion photos mirror while other shared scenes span");
            if (automaticMirror) Check(plan.Placements.Select(p => p.Asset).Distinct().Count() == 1, "automatic mirrors share one photo");
            var renderer = new PhotoRenderer(new(1000, 400), WindowsPlaybackOptions.Import(options), new TransitionController(), new AnimationScheduler());
            try
            {
                var visual = renderer.BuildShared(plan, bitmaps, displays.Select(d => d.Key.LayoutId).ToArray());
                renderer.ShowShared(visual); renderer.PresentShared(visual, 3.5);
                var full = Snapshot((FrameworkElement)renderer.Content, 1000, 400);
                var localA = renderer.CreateDisplayRegion(new(0, 0, 400, 400), displays[0].Key.LayoutId);
                var localB = renderer.CreateDisplayRegion(new(400, 0, 600, 400), displays[1].Key.LayoutId);
                if (!individual && !automaticMirror)
                {
                    var a = Snapshot(localA, 400, 400); var b = Snapshot(localB, 600, 400);
                    Directory.CreateDirectory(Path.Combine(root, "network-adapters"));
                    Save(full, Path.Combine(root, "network-adapters", "full.png")); Save(a, Path.Combine(root, "network-adapters", "left.png"));
                    Check(Same(a, new CroppedBitmap(full, new(0, 0, 400, 400))) && Same(b, new CroppedBitmap(full, new(400, 0, 600, 400))),
                        $"{mode} native display crops match one timed shared canvas within WPF edge rounding");
                }
                var before = Net.SceneEvaluation.Evaluate(plan.Placements[0], 3.5);
                renderer.PresentShared(visual, 3.5); renderer.PresentShared(visual, 7.5);
                var after = Net.SceneEvaluation.Evaluate(plan.Placements[0], 7.5);
                Check(double.IsFinite(before.X + after.X), "rendering follows explicit elapsed time without a local receive anchor");
            }
            finally { renderer.Clear(); renderer.Close(); }
        }
        Directory.CreateDirectory(Path.Combine(root, "network-adapters"));
    }
    public static void ProtectedSecrets(string root)
    {
        var path = Path.Combine(root, "network-adapters", "protected"); var secret = RandomNumberGenerator.GetBytes(32);
        new WindowsSecretStore(path).Write("fixture-key", secret);
        Check(new WindowsSecretStore(path).Read("fixture-key")!.SequenceEqual(secret), "DPAPI key survives adapter restart");
        Check(File.ReadAllBytes(Path.Combine(path, "fixture-key.protected")).AsSpan().IndexOf(secret) < 0, "DPAPI store does not persist a raw key");
        CryptographicOperations.ZeroMemory(secret);
    }
    private static RenderTargetBitmap Snapshot(FrameworkElement element, int width, int height)
    { element.Measure(new(width, height)); element.Arrange(new Rect(0, 0, width, height)); element.UpdateLayout(); var image = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32); image.Render(element); return image; }
    private static bool Same(BitmapSource a, BitmapSource b)
    { var x = new byte[a.PixelWidth * a.PixelHeight * 4]; var y = new byte[x.Length]; a.CopyPixels(x, a.PixelWidth * 4, 0); b.CopyPixels(y, b.PixelWidth * 4, 0); var diffs = x.Zip(y).Select(p => Math.Abs(p.First - p.Second)).ToArray(); return diffs.Max() <= 2 && diffs.Average() < .01; }
    private static void Save(BitmapSource image, string path) { var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(image)); using var file = File.Create(path); encoder.Save(file); }
}

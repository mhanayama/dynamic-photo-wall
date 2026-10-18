using System.IO;
using System.Security.Cryptography;
using System.Text.Json;
using DynamicPhotoWall.Core;
using DynamicPhotoWall.Networking.Windows;
using DynamicPhotoWall.Rendering;
using SkiaSharp;
using Net = DynamicPhotoWall.Networking;

namespace DynamicPhotoWall.Tests;

internal static class MirrorAmbientTests
{
    private static void Check(bool value, string message) { if (!value) throw new Exception(message); }
    private static WallSettings Only(CompositionMode mode) => new()
    {
        GalleryEnabled = mode == CompositionMode.Gallery, GalleryScrollEnabled = mode == CompositionMode.GalleryScroll,
        VerticalPanEnabled = mode == CompositionMode.VerticalPan, HorizontalPanEnabled = mode == CompositionMode.HorizontalPan,
        ZoomEnabled = mode == CompositionMode.Zoom, RandomOrder = false, GlassBackground = false
    };
    private static PhotoInfo Photo(int width, int height, int orientation = 1) => new("/fixture/photo", width, height, orientation, null, 1, 0);
    public static async Task MotionMirrors()
    {
        using var fixture = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Fixtures", "MirrorPolicy.v1.json")));
        foreach (var sample in fixture.RootElement.GetProperty("cases").EnumerateArray())
            Check(MirrorPolicy.IsBelowHalf(sample.GetProperty("imageWidth").GetInt32(), sample.GetProperty("imageHeight").GetInt32(),
                new(sample.GetProperty("groupWidth").GetDouble(), sample.GetProperty("groupHeight").GetDouble())) == sample.GetProperty("mirror").GetBoolean(), "long-axis threshold fixture differs");
        foreach (var verticalGroup in new[] { false, true })
        foreach (var mode in new[] { CompositionMode.VerticalPan, CompositionMode.HorizontalPan, CompositionMode.Zoom })
        {
            var viewport = verticalGroup ? new Viewport(1200, 8000) : new Viewport(8000, 1200);
            var local = verticalGroup ? new Viewport(1200, 2000) : new Viewport(2000, 1200);
            var source = mode == CompositionMode.VerticalPan ? (verticalGroup ? Photo(1200, 3000) : Photo(1500, 4500))
                : mode == CompositionMode.HorizontalPan ? (verticalGroup ? Photo(4000, 1000) : Photo(3000, 900)) : Photo(2000, 1000);
            var settings = Only(mode); var views = Enumerable.Repeat(local, 4).ToArray();
            var composition = new CompositionEngine(new PhotoSelector()).Next([source], viewport, settings, displayViewports: views);
            Check(composition?.Mode == mode && composition.MirrorPerDisplay, $"{mode} must mirror a low resolution photo on {(verticalGroup ? "vertical" : "horizontal")} groups");
            var peer = Guid.NewGuid(); var group = Guid.NewGuid(); var provider = Guid.NewGuid(); var selectedSource = Guid.NewGuid(); var generation = Guid.NewGuid();
            var displays = Enumerable.Range(0, 4).Select(i => new Net.PeerDisplay(new(peer, i.ToString()), true, group,
                verticalGroup ? 0 : (int)local.Width * i, verticalGroup ? (int)local.Height * i : 0, (int)local.Width, (int)local.Height)).ToArray();
            var photo = new Net.SharedPhoto(new(provider, selectedSource, generation, new string('a', 64)), source.Width, source.Height, 1,
                new(1, source.Width, source.Height, "fixture", "1", Net.FaceAnalysisState.Complete, []));
            var wall = new Net.WallSnapshot(Guid.NewGuid(), Guid.NewGuid(), peer, 0, [new(group, "mirror")], displays,
                [new(provider, selectedSource, generation)], WindowsPlaybackOptions.Export(settings));
            var plan = await new WindowsScenePlanner(_ => throw new Exception("No image decode expected"))
                .PrepareAsync(wall, group, [photo], CancellationToken.None) ?? throw new Exception("Missing mirror plan");
            plan.Validate();
            Check(plan.Placements.Length == 4 && plan.Placements.Select(p => p.Asset).Distinct().Count() == 1
                && plan.Placements.Select(p => p.DisplayId).ToHashSet().SetEquals(displays.Select(d => d.Key.LayoutId)), "every display must receive the same original photo");
        }
        var horizontal = new Viewport(8000, 1200); Viewport[] panels = [new(2000, 1200), new(2000, 1200)];
        foreach (var mode in new[] { CompositionMode.VerticalPan, CompositionMode.HorizontalPan, CompositionMode.Zoom })
        {
            var boundary = mode == CompositionMode.VerticalPan ? Photo(4000, 12000) : mode == CompositionMode.HorizontalPan ? Photo(4000, 400) : Photo(4000, 2000);
            var plan = new CompositionEngine(new PhotoSelector()).Next([boundary], horizontal, Only(mode), displayViewports: panels);
            Check(plan != null && !plan.MirrorPerDisplay, "exactly half must keep spanning and ignore the short-axis pixel count");
        }
        var rotated = Photo(4500, 1500, 6);
        Check(new CompositionEngine(new PhotoSelector()).Next([rotated], horizontal, Only(CompositionMode.VerticalPan), displayViewports: panels)?.MirrorPerDisplay == true,
            "EXIF-oriented width is used for horizontal groups");
        Check(new CompositionEngine(new PhotoSelector()).Next([Photo(100, 300)], horizontal, Only(CompositionMode.VerticalPan), displayViewports: panels) == null,
            "photos that violate every display's enlargement limit are not stretched across the group");
    }

    public static async Task AmbientReachesEdges()
    {
        var pixels = new byte[257 * 19 * 4];
        for (var y = 6; y < 13; y++) { var i = (y * 257 + 128) * 4; pixels[i] = 40; pixels[i + 1] = 80; pixels[i + 2] = 200; pixels[i + 3] = 255; }
        Check(AmbientPixels.ExtendPadding(pixels, 257, 19), "narrow portrait sample must produce ambient color");
        for (var i = 0; i < pixels.Length; i += 4) Check(pixels[i] == 40 && pixels[i + 1] == 80 && pixels[i + 2] == 200 && pixels[i + 3] == 255,
            "all margins must remain fully opaque photo colors");
        Check(!AmbientPixels.ExtendPadding(new byte[16], 2, 2), "empty samples do not introduce black ambient frames");
        var peer = Guid.NewGuid(); var group = Guid.NewGuid(); var source = Guid.NewGuid(); var generation = Guid.NewGuid();
        foreach (var mode in Enum.GetValues<CompositionMode>())
        {
            var width = mode == CompositionMode.HorizontalPan ? 3000 : mode == CompositionMode.Zoom ? 1000 : 300;
            var height = mode == CompositionMode.HorizontalPan ? 400 : mode == CompositionMode.Zoom ? 500 : 1200;
            var originals = new Dictionary<string, byte[]>(); var photos = new List<Net.SharedPhoto>();
            for (var i = 0; i < 2; i++)
            {
                using var bitmap = new SKBitmap(8, 32); bitmap.Erase(new SKColor(200, 80, 40)); bitmap.SetPixel(3, 10, new SKColor((byte)(200 + i), 80, 40));
                using var image = SKImage.FromBitmap(bitmap); using var encoded = image.Encode(SKEncodedImageFormat.Png, 100); var bytes = encoded.ToArray();
                var key = new Net.SharedAssetKey(peer, source, generation, Convert.ToHexStringLower(SHA256.HashData(bytes))); originals[key.OpaqueId] = bytes;
                photos.Add(new(key, width, height, bytes.Length, new(1, width, height, "fixture", "1", Net.FaceAnalysisState.Complete, [])));
            }
            var settings = Only(mode); settings.GlassBackground = true; settings.FadeSeconds = .2;
            var displays = new[] { new Net.PeerDisplay(new(peer, "a"), true, group, 0, 0, 400, 400), new Net.PeerDisplay(new(peer, "b"), true, group, 400, 0, 600, 400) };
            var wall = new Net.WallSnapshot(Guid.NewGuid(), Guid.NewGuid(), peer, 0, [new(group, "ambient")], displays, [new(peer, source, generation)], WindowsPlaybackOptions.Export(settings));
            var plan = await new WindowsScenePlanner(key => originals[key.OpaqueId].ToArray()).PrepareAsync(wall, group, photos, CancellationToken.None)
                ?? throw new Exception($"Missing {mode} plan");
            Check(plan.Ambient.Length > 0, $"{mode} must have ambient frames");
            foreach (var frame in plan.Ambient)
            {
                using var decoded = SKBitmap.Decode(frame.Png);
                foreach (var x in new[] { 0, decoded.Width / 2, decoded.Width - 1 })
                foreach (var y in new[] { 0, decoded.Height / 2, decoded.Height - 1 })
                {
                    var color = decoded.GetPixel(x, y);
                    Check(color.Alpha >= 250 && color.Red >= 190 && color.Green >= 70 && color.Blue >= 30,
                        $"{mode} ambient must reach all edges without artificial black padding");
                }
            }
        }
    }
}

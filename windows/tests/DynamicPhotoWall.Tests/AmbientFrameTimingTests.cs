using System.Security.Cryptography;
using System.Text.Json;
using DynamicPhotoWall.Core;
using DynamicPhotoWall.Networking.Windows;
using SkiaSharp;
using Net = DynamicPhotoWall.Networking;

namespace DynamicPhotoWall.Tests;

internal static class AmbientFrameTimingTests
{
    private static void Check(bool value, string message) { if (!value) throw new Exception(message); }

    public static Task Run()
    {
        using var bitmap = new SKBitmap(32, 8); bitmap.Erase(new SKColor(190, 70, 40));
        using var image = SKImage.FromBitmap(bitmap); using var encoded = image.Encode(SKEncodedImageFormat.Png, 100);
        var original = encoded.ToArray();
        var peer = Guid.NewGuid(); var group = Guid.NewGuid();
        var key = new Net.SharedAssetKey(peer, Guid.NewGuid(), Guid.NewGuid(), Convert.ToHexStringLower(SHA256.HashData(original)));
        var photo = new Net.SharedPhoto(key, 32, 8, original.Length, new(1, 32, 8, "fixture", "1", Net.FaceAnalysisState.Complete, []));
        var catalog = new Dictionary<string, Net.SharedPhoto> { [key.OpaqueId] = photo };
        var durations = new List<double> { 100.42374576461677, 99.78163424403482, 103.44428091470351, 90, 120, 30, .125 };
        // Gallery chunks end before a replacement and therefore have fractional
        // durations even when their configured maximum duration is an integer.
        var pool = Enumerable.Range(0, 5).Select(i => new PhotoInfo(i.ToString(), 32, 8, 1, null, 1, 0)).ToArray();
        var settings = new WallSettings { GalleryMinSeconds = 5, GalleryMaxSeconds = 10, FadeSeconds = 1.2 };
        var galleryDurations = new List<double>();
        for (var seed = 0; seed < 256; seed++)
        {
            var timeline = GalleryTimeline.BuildPlan([new([pool[0]], new(128, 32), [])], 90, settings,
                active => pool.First(p => active.All(a => a.Path != p.Path)), new Random(seed), pool);
            galleryDurations.Add(timeline.Duration);
        }
        durations.AddRange(galleryDurations.Take(8));
        var galleryOvershoots = galleryDurations.Where(duration => duration * 23 / 23 > duration).ToArray();
        Console.WriteLine($"GalleryTimeline-produced durations with the original overflow: {galleryOvershoots.Length}");
        Check(galleryOvershoots.Length > 0, "the original overflow must also occur at an actual GalleryTimeline boundary");
        durations.Insert(0, galleryOvershoots[0]);
        var galleryEnd = galleryOvershoots[0];
        Console.WriteLine($"Gallery endpoint reproduction: duration={galleryEnd:R}, oldAt={galleryEnd * 23 / 23:R}, delta={galleryEnd * 23 / 23 - galleryEnd:R}");
        var rawOvershoots = durations.Count(duration => duration * 23 / 23 > duration);
        var framesChecked = 0;
        foreach (var surfaces in new[] { 1, 3, 4 })
        foreach (var duration in durations)
        {
            var displays = Enumerable.Range(0, surfaces).Select(i => new Net.PeerDisplay(new(peer, i.ToString()), true, group, i * 128, 0, 128, 32)).ToArray();
            var placements = displays.Select((display, i) => new Net.ScenePlacement(i, key, surfaces == 1 ? null : display.Key.LayoutId,
                new(i * 128, 0, 128, 32), 128, 32, i * 128, 0, i * 128, 0, 1, 1, .5, .5, 0, duration, 0, duration, 0, 0, false)).ToArray();
            var plan = new Net.SharedScenePlan(Guid.NewGuid(), group, Guid.NewGuid(), 0, Net.SceneMode.Gallery,
                new(128 * surfaces, 32), displays, duration, 0, "#000000", placements, []);
            plan = plan with { Ambient = WindowsAmbientBuilder.Build(plan, catalog, _ => original.ToArray(), default) };
            var last = plan.Ambient[^1];
            if (last.At > duration) Console.WriteLine($"Reproduced ambient overflow: at={last.At:R}, duration={duration:R}, delta={last.At - duration:R}, pngBytes={last.Png.Length}");
            plan.Validate(); // Reproduce the exact exception seen by SceneCoordinator.
            foreach (var surface in plan.Ambient.GroupBy(frame => frame.DisplayId))
            {
                var frames = surface.ToArray();
                Check(frames[0].At == 0 && frames[^1].At == duration, "each surface must have exact start and end timestamps");
                Check(frames.Zip(frames.Skip(1)).All(pair => pair.First.At < pair.Second.At), "interior samples stay strictly ordered");
                Check(frames.All(frame => frame.At <= duration && frame.Png.Length <= 131072), "generated frames satisfy both strict wire bounds");
            }
            var received = JsonSerializer.Deserialize<Net.SharedScenePlan>(JsonSerializer.Serialize(plan, Net.PeerProtocol.Json), Net.PeerProtocol.Json)!;
            received.Validate();
            Check(received.Ambient.Select(frame => frame.At).SequenceEqual(plan.Ambient.Select(frame => frame.At)), "peer JSON must retain the exact endpoint");
            foreach (var invalid in new[] { new Net.AmbientFrame(Math.BitIncrement(duration), []), new(double.NaN, []), new(-.01, []), new(0, new byte[131073]) })
            {
                try { (plan with { Ambient = [invalid] }).Validate(); throw new Exception("Invalid wire frame was accepted"); }
                catch (System.IO.InvalidDataException) { }
            }
            framesChecked += plan.Ambient.Length;
        }
        Console.WriteLine($"Validated {framesChecked} generated ambient frames; {rawOvershoots} durations exercise the original overflow.");
        return Task.CompletedTask;
    }
}

using System.Text.Json;
using DynamicPhotoWall.Core;
using DynamicPhotoWall.Networking.Windows;
using Net = DynamicPhotoWall.Networking;

namespace DynamicPhotoWall.Tests;

internal static class ModeWeightTests
{
    private static void Check(bool value, string message) { if (!value) throw new Exception(message); }
    private sealed class Ticket(double value, int index = 0) : Random
    {
        public override double NextDouble() => value;
        public override int Next(int maxValue) => Math.Min(index, maxValue - 1);
    }
    public static Task Run()
    {
        var all = Enum.GetValues<CompositionMode>();
        Check(ModeSelection.IsGallery(ModeSelection.Pick(all, 80, 20, null, 0, new Ticket(.799999))!.Value), "gallery owns the first eighty percent of the category draw");
        Check(!ModeSelection.IsGallery(ModeSelection.Pick(all, 80, 20, null, 0, new Ticket(.8))!.Value), "motion owns the remaining twenty percent");
        Check(ModeSelection.Pick([CompositionMode.Gallery, CompositionMode.Zoom], 80, 20, CompositionMode.Gallery, 1, new Ticket(.5)) == null,
            "a repeated gallery draw is skipped without forcing another category");
        Check(ModeSelection.Pick([CompositionMode.Gallery, CompositionMode.GalleryScroll], 80, 20, CompositionMode.Gallery, 1, new Ticket(.5, 1)) == CompositionMode.GalleryScroll,
            "the two different gallery modes may follow each other");
        Check(ModeSelection.Pick([CompositionMode.GalleryScroll], 80, 20, CompositionMode.GalleryScroll, 1, new Ticket(.5)) == null,
            "a scrolling gallery cannot start another scrolling gallery");
        Check(ModeSelection.Pick([CompositionMode.Zoom], 80, 20, null, 0, new Ticket(.01)) == CompositionMode.Zoom, "an unavailable family cannot leave the draw empty");
        Check(ModeSelection.Pick(all, 0, 0, null, 0, new Ticket(.5)) == null, "zero category weights disable the draw");
        var legacy = JsonSerializer.Deserialize<WallSettings>("{\"GalleryWeight\":45,\"PanWeight\":35,\"ZoomWeight\":20}")!;
        legacy.Normalize();
        Check(legacy.GalleryWeight == 80 && legacy.MotionWeight == 20 && legacy.ZoomWeight == 0, "old defaults migrate to two eighty-twenty categories");
        var custom = new WallSettings { GalleryWeight = 60, PanWeight = 10, ZoomWeight = 5 }; custom.Normalize();
        Check(custom.GalleryWeight == 60 && custom.MotionWeight == 15, "custom legacy pan and zoom weights combine into one category");
        var imported = WindowsPlaybackOptions.Import(new Net.PlaybackOptions { GalleryWeight = 45, PanWeight = 35, ZoomWeight = 20 });
        var shared = WindowsPlaybackOptions.Export(imported); shared.Validate();
        Check(shared.GalleryWeight == 80 && shared.PanWeight == 20 && shared.ZoomWeight == 0, "shared adapters carry both categories and migrate old defaults");
        var settings = new WallSettings { RandomOrder = false };
        PhotoInfo[] photos = [new("portrait", 3000, 5000, 1, null, 1, 0), new("wide", 8000, 1200, 1, null, 1, 0), new("landscape", 4000, 2400, 1, null, 1, 0)];
        foreach (var scroll in new[] { true, false })
        {
            settings.GalleryScrollEnabled = scroll;
            var engine = new CompositionEngine(new PhotoSelector(new Random(9)), new Random(1234));
            var counts = new int[all.Length]; const int draws = 50000;
            var skipped = 0; CompositionMode? last = null;
            for (var i = 0; i < draws; i++)
            {
                var plan = engine.Next(photos, new(1920, 1080), settings);
                if (plan == null) { Check(engine.LastDrawSkipped, "eligible draws only skip repeated galleries"); skipped++; continue; }
                Check(!ModeSelection.IsGallery(plan.Mode) || plan.Mode != last, "accepted gallery modes never repeat");
                counts[(int)plan.Mode]++; last = plan.Mode;
            }
            var gallery = (counts[(int)CompositionMode.Gallery] + counts[(int)CompositionMode.GalleryScroll] + skipped) / (double)draws;
            Check(Math.Abs(gallery - .8) < .01, $"gallery must stay eighty percent with scroll enabled={scroll}: {gallery:P2}");
            foreach (var mode in new[] { CompositionMode.VerticalPan, CompositionMode.HorizontalPan, CompositionMode.Zoom })
                Check(Math.Abs(counts[(int)mode] / (double)draws - .2 / 3) < .01, "all eligible motion modes share the motion category");
            Console.WriteLine($"Category draw (scroll={scroll}): gallery attempts={gallery:P2}, motion={1 - gallery:P2}, skipped={skipped}");
        }
        return Task.CompletedTask;
    }
}

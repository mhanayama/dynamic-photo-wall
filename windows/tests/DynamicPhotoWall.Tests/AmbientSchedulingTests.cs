using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using DynamicPhotoWall.Core;
using DynamicPhotoWall.Motion;
using DynamicPhotoWall.Rendering;

namespace DynamicPhotoWall.Tests;

// Offscreen WPF objects and synthetic pixels only. No windows, desktop capture,
// input injection, application settings, user photos or live playback are used.
internal static class AmbientSchedulingTests
{
    private static void Check(bool value, string message) { if (!value) throw new Exception(message); }
    private static async Task Until(Func<bool> ready)
    {
        var timeout = Stopwatch.StartNew();
        while (!ready()) { if (timeout.Elapsed.TotalSeconds > 5) throw new TimeoutException("Ambient refresh did not finish"); await Task.Delay(15); }
    }
    private static BitmapSource Bitmap(bool blue = false)
    {
        var pixels = new byte[32 * 32 * 4];
        for (var y = 0; y < 32; y++) for (var x = 0; x < 32; x++)
        {
            var i = (y * 32 + x) * 4;
            pixels[i] = (byte)(blue ? 255 : x * 4); pixels[i + 1] = (byte)(y * 4);
            pixels[i + 2] = (byte)(blue ? x * 4 : 255); pixels[i + 3] = 255;
        }
        var bitmap = BitmapSource.Create(32, 32, 96, 96, PixelFormats.Pbgra32, null, pixels, 128); bitmap.Freeze(); return bitmap;
    }
    private static byte[] Pixels(BitmapSource bitmap)
    {
        var pixels = new byte[bitmap.PixelWidth * bitmap.PixelHeight * 4]; bitmap.CopyPixels(pixels, bitmap.PixelWidth * 4, 0); return pixels;
    }
    private sealed class Fixture : IDisposable
    {
        public readonly AnimationScheduler Scheduler = new();
        public readonly TransitionController Transitions = new();
        public readonly Canvas Foreground = new() { Width = 640, Height = 360, ClipToBounds = true };
        public readonly System.Windows.Controls.Image Photo = new() { Width = 1280, Height = 720, Source = Bitmap(), Stretch = Stretch.Fill, RenderTransformOrigin = new(.5, .5) };
        public readonly GlassBackground Background;
        public Fixture(bool reference = false)
        {
            var transform = new TransformGroup(); transform.Children.Add(new ScaleTransform()); transform.Children.Add(new TranslateTransform());
            Photo.RenderTransform = transform; Foreground.Children.Add(Photo);
            Foreground.Measure(new Size(640, 360)); Foreground.Arrange(new Rect(0, 0, 640, 360)); Foreground.UpdateLayout();
            Background = new(Foreground, new(640, 360), Scheduler, new ImageBrush(), Transitions, reference);
        }
        public Storyboard Motion(double seconds, double distance = 100, bool zoom = false, bool vertical = false)
        {
            var board = Transitions.Create();
            var property = new PropertyPath("(0).(1)[" + (zoom ? "0" : "1") + "].(2)", UIElement.RenderTransformProperty,
                TransformGroup.ChildrenProperty, zoom ? ScaleTransform.ScaleXProperty : vertical ? TranslateTransform.YProperty : TranslateTransform.XProperty);
            TransitionController.Animate(board, Photo, property, zoom ? 1 : 0, zoom ? 1.25 : -distance, seconds, zoom);
            if (zoom)
                TransitionController.Animate(board, Photo, new PropertyPath("(0).(1)[0].(2)", UIElement.RenderTransformProperty,
                    TransformGroup.ChildrenProperty, ScaleTransform.ScaleYProperty), 1, 1.25, seconds);
            Transitions.Start(board, Photo); return board;
        }
        public void Pause(bool paused) { Scheduler.SetPaused(paused); Transitions.SetPaused(paused); }
        public void Dispose() { Background.Dispose(); Transitions.Clear(); }
    }

    public static async Task StaticAndReference()
    {
        using var current = new Fixture(); using var reference = new Fixture(reference: true);
        await current.Background.StartAsync(default); await reference.Background.StartAsync(default);
        Check(Pixels(current.Background.Texture!).SequenceEqual(Pixels(reference.Background.Texture!)), "initial capture, padding, blur and enhanced color must remain pixel-identical");
        var checks = current.Background.GeometryCheckCount;
        await Task.Delay(550);
        Check(current.Background.CaptureCount == 1 && current.Background.UpdateCount == 1 && !current.Background.IsSampling,
            "unchanged static content must stop capture and the timer");
        Check(current.Background.GeometryCheckCount == checks, "idle content must not even poll geometry");
        Check(reference.Background.CaptureCount >= 3, "the preserved continuous path must reproduce idle regeneration");
        current.Photo.Source = Bitmap(blue: true);
        for (var i = 0; i < 20; i++) current.Background.Invalidate();
        await Until(() => current.Background.UpdateCount == 2);
        Check(!current.Background.IsSampling && current.Background.CaptureCount == 2, "rapid scene invalidations coalesce into one target, with no interpolation captures");
        var pixels = Pixels(current.Background.Texture!);
        Check(pixels[0] > pixels[2] + 100 && pixels.Where((_, i) => i % 4 == 3).All(a => a == 255), "replacement retains enhanced color and opaque margin fill");
        await Task.Delay(350);
        Check(current.Background.UpdateCount == 2, "color response must not regenerate its target to settle");
    }

    public static async Task MotionPauseAndEndpoints()
    {
        foreach (var scenario in new[] { "horizontal-pan", "vertical-pan", "zoom", "scroll" })
        {
            using var fixture = new Fixture(); await fixture.Background.StartAsync(default);
            fixture.Motion(.85, 120, zoom: scenario == "zoom", vertical: scenario == "vertical-pan");
            await Until(() => fixture.Background.UpdateCount >= 3);
            fixture.Pause(true);
            var held = fixture.Background.UpdateCount; var captured = fixture.Background.CaptureCount;
            await Task.Delay(250);
            Check(!fixture.Background.IsSampling && fixture.Background.UpdateCount == held && fixture.Background.CaptureCount == captured,
                scenario + " must stop generation immediately during pause");
            fixture.Pause(false);
            await Until(() => !fixture.Background.IsSampling && fixture.Background.UpdateCount > held);
            var endpoint = fixture.Background.UpdateCount; await Task.Delay(220);
            Check(endpoint == fixture.Background.UpdateCount, scenario + " must retain its exact endpoint without a perpetual timer");
        }
        using var slow = new Fixture(); await slow.Background.StartAsync(default);
        slow.Motion(.8, .1); await Until(() => !slow.Background.IsSampling);
        await Task.Delay(40);
        Check(slow.Background.GeometryCheckCount > slow.Background.CaptureCount && slow.Background.CaptureCount <= 3,
            "subpixel motion must deduplicate readback but still sample its start and exact end");
    }

    public static async Task InFlightChangesAndDisposal()
    {
        using (var fixture = new Fixture())
        {
            var initial = fixture.Background.StartAsync(default);
            fixture.Photo.Source = Bitmap(blue: true); fixture.Background.Invalidate();
            await initial; await Until(() => fixture.Background.UpdateCount == 1);
            Check(fixture.Background.DiscardedCount >= 1 && Pixels(fixture.Background.Texture!)[0] > 200,
                "a stale in-flight frame must never overwrite a newer photo");
        }
        using (var fixture = new Fixture())
        {
            var initial = fixture.Background.StartAsync(default); fixture.Pause(true); await initial;
            Check(fixture.Background.UpdateCount == 0, "pause must reject an in-flight publication");
            fixture.Pause(false); await Until(() => fixture.Background.UpdateCount == 1);
        }
        using (var fixture = new Fixture())
        {
            var initial = fixture.Background.StartAsync(default); fixture.Background.Dispose(); await initial;
            fixture.Pause(true); fixture.Pause(false); fixture.Motion(.1);
            await Task.Delay(180);
            Check(fixture.Background.UpdateCount == 0 && !fixture.Background.IsSampling, "retired scenes must cancel work and detach all clock subscriptions");
        }
        using (var fixture = new Fixture())
        using (var cancellation = new CancellationTokenSource())
        {
            cancellation.Cancel();
            try { await fixture.Background.StartAsync(cancellation.Token); throw new Exception("Cancellation was swallowed"); }
            catch (OperationCanceledException) { }
            Check(fixture.Background.CaptureCount == 0, "cancelled preparation cannot perform a capture");
        }
    }

    public static async Task RendererReplacementAndDisplayIsolation()
    {
        var scheduler = new AnimationScheduler(); var transitions = new TransitionController();
        var settings = new WallSettings { FadeSeconds = .18, GlassBackground = true, GalleryScrollPixelsPerSecond = 2000, AvoidFaceDisplayBoundaries = false };
        var renderer = new PhotoRenderer(new(640, 360), settings, transitions, scheduler);
        PhotoInfo Photo(string path) => new(path, 640, 360, 1, null, 1, 0);
        void Layout()
        {
            var content = (FrameworkElement)renderer.Content;
            content.Measure(new Size(640, 360)); content.Arrange(new Rect(0, 0, 640, 360)); content.UpdateLayout();
        }
        try
        {
            var scene = renderer.BuildPerDisplay(new[] { new DisplayScene("a", new(0, 0, 320, 360), new(CompositionMode.Gallery, [Photo("red-a")]), [Bitmap()]),
                new DisplayScene("b", new(320, 0, 320, 360), new(CompositionMode.Gallery, [Photo("red-b")]), [Bitmap()]) }, new Random(1));
            Layout(); await renderer.ShowAsync(scene, default); Layout();
            var first = scene.Displays[0]; var second = scene.Displays[1];
            var untouched = second.Ambient!.CaptureCount;
            await renderer.ReplaceSlotAsync(first, 0, Photo("blue"), Bitmap(blue: true), default);
            await Until(() => !first.Ambient!.IsSampling && first.Ambient.UpdateCount >= 2); await Task.Delay(40);
            Check(second.Ambient.CaptureCount == untouched, "one display's slot replacement must not invalidate another display");
            Check(Pixels(first.Ambient!.Texture!)[0] > 200, "real Gallery final child replacement must refresh the target");
            var beforeCancellation = first.Ambient.UpdateCount;
            using (var cancellation = new CancellationTokenSource())
            {
                var replacement = renderer.ReplaceSlotAsync(first, 0, Photo("cancelled-red"), Bitmap(), cancellation.Token);
                cancellation.Cancel();
                try { await replacement; throw new Exception("Replacement cancellation was swallowed"); }
                catch (OperationCanceledException) { }
            }
            await Until(() => first.Ambient.UpdateCount > beforeCancellation && !first.Ambient.IsSampling);
            Check(Pixels(first.Ambient.Texture!)[2] > 200, "cancelled reflow must capture its committed final child after removing animation clocks");
            var retired = first.Ambient.CaptureCount;
            var scroll = renderer.Build(new(CompositionMode.GalleryScroll, [Photo("one"), Photo("two")]), [Bitmap(), Bitmap(true)], new Random(1));
            await renderer.ShowAsync(scroll, default); Layout();
            await renderer.AdvanceGalleryAsync(scroll, Photo("three"), Bitmap(), default);
            await Until(() => !scroll.Ambient!.IsSampling); await Task.Delay(60);
            Check(scroll.Ambient!.UpdateCount >= 3, "real scrolling must sample the visible crop and final structural change");
            Check(first.Ambient.CaptureCount == retired, "a replaced scene must stop all background work");
            var final = scroll.Ambient.CaptureCount; renderer.Clear(); await Task.Delay(160);
            Check(scroll.Ambient.CaptureCount == final, "renderer cleanup must stop queued and active work");
        }
        finally { renderer.Clear(); renderer.Close(); }
    }

    public static async Task Benchmark(string output, string scenario, bool reference, double seconds)
    {
        using var first = new Fixture(reference); using var second = scenario == "multi-display" ? new Fixture(reference) : null;
        var fixtures = second == null ? new[] { first } : new[] { first, second };
        if (scenario != "ambient-off") foreach (var fixture in fixtures) await fixture.Background.StartAsync(default);
        if (scenario is "horizontal-pan" or "vertical-pan" or "zoom" or "scroll")
            first.Motion(seconds + 3, 500, scenario == "zoom", scenario == "vertical-pan");
        if (scenario == "paused") { first.Motion(seconds + 3); first.Pause(true); }
        await Task.Delay(1000); // Warm-up is excluded from all deltas.
        using var process = Process.GetCurrentProcess();
        var captures = fixtures.Sum(f => f.Background.CaptureCount); var updates = fixtures.Sum(f => f.Background.UpdateCount);
        var checks = fixtures.Sum(f => f.Background.GeometryCheckCount);
        var captureMs = fixtures.Sum(f => f.Background.TotalCaptureMilliseconds); var processMs = fixtures.Sum(f => f.Background.TotalProcessMilliseconds);
        var allocated = GC.GetTotalAllocatedBytes(); var cpu = process.TotalProcessorTime; var clock = Stopwatch.StartNew();
        if (scenario == "replacement")
        {
            await Task.Delay(TimeSpan.FromSeconds(seconds / 2));
            first.Photo.Source = Bitmap(true); first.Background.Invalidate();
            await Task.Delay(TimeSpan.FromSeconds(seconds / 2));
        }
        else await Task.Delay(TimeSpan.FromSeconds(seconds));
        var elapsed = clock.Elapsed.TotalSeconds; process.Refresh();
        var cpuSeconds = (process.TotalProcessorTime - cpu).TotalSeconds;
        var report = new { Scenario = scenario, Mode = scenario == "ambient-off" ? "disabled" : reference ? "continuous-reference" : "event-driven", Gui = false,
            Stopwatch.Frequency, Environment.ProcessorCount, Runtime = Environment.Version.ToString(), OS = Environment.OSVersion.ToString(),
            RenderingTier = RenderCapability.Tier >> 16, ProcessRenderMode = RenderOptions.ProcessRenderMode.ToString(),
            WallSeconds = elapsed, CpuSeconds = cpuSeconds, CpuPercentOfOneCore = 100 * cpuSeconds / elapsed,
            Captures = fixtures.Sum(f => f.Background.CaptureCount) - captures,
            Publications = fixtures.Sum(f => f.Background.UpdateCount) - updates,
            GeometryChecks = fixtures.Sum(f => f.Background.GeometryCheckCount) - checks,
            CaptureMilliseconds = fixtures.Sum(f => f.Background.TotalCaptureMilliseconds) - captureMs,
            ProcessMilliseconds = fixtures.Sum(f => f.Background.TotalProcessMilliseconds) - processMs,
            AllocatedBytes = GC.GetTotalAllocatedBytes() - allocated, PeakWorkingSetBytes = process.PeakWorkingSet64,
            Notes = "Synthetic offscreen fixture only; excludes full-screen composition, GPU, DWM, power and frame-presentation measurements." };
        File.WriteAllText(Path.Combine(output, "ambient-benchmark.json"), JsonSerializer.Serialize(report, new JsonSerializerOptions { WriteIndented = true }));
        Console.WriteLine(JsonSerializer.Serialize(report));
    }
}

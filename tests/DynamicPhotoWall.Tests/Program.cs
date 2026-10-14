using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Text.Json;
using DynamicPhotoWall;
using DynamicPhotoWall.Core;
using DynamicPhotoWall.Configuration;
using DynamicPhotoWall.PhotoLibrary;
using DynamicPhotoWall.Motion;
using DynamicPhotoWall.Rendering;
using DynamicPhotoWall.DesktopIntegration;
using SkiaSharp;

namespace DynamicPhotoWall.Tests;

internal static class Program
{
    private static readonly List<object> results = [];
    private static int failures;
    private static string root = "";
    [STAThread]
    public static int Main(string[] args)
    {
        root = Path.GetFullPath(args.FirstOrDefault(a => !a.StartsWith("--")) ?? "artifacts/smoke-data");
        Directory.CreateDirectory(root); Log.DataDirectory = Path.Combine(root, "profile");
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        app.Startup += async (_, _) =>
        {
            if (!args.Contains("--scan-only")) await RunAsync(args.Contains("--desktop"));
            var photoFolder = args.FirstOrDefault(a => a.StartsWith("--inspect="))?[10..];
            if (photoFolder != null) await Test("supplied photo metadata inspection", () => InspectAsync(photoFolder));
            var actualFolder = args.FirstOrDefault(a => a.StartsWith("--actual="))?[9..];
            if (actualFolder != null) await Test("supplied photos full decode and desktop rendering", () => ActualPhotosAsync(actualFolder));
            if (args.Contains("--compositor")) await Test("desktop compositor actually presents child surface", CompositorAsync);
            if (args.Contains("--taskbar")) await Test("monitor taskbar hide, normal restore and crash restore", TaskbarAsync);
            if (args.Contains("--pan-metrics")) await Test("actual-photo pan animation metrics", PanMetricsAsync);
            if (args.Contains("--features")) await Test("real-photo face stop, glass and scrolling gallery", FeaturesAsync);
            if (args.Contains("--ambient")) await Test("ambient follows visible crop, scroll and replacement; pauses and disposes", AmbientAsync);
            var motionFolder = args.FirstOrDefault(a => a.StartsWith("--motion-library="))?[17..];
            if (motionFolder != null) await Test("all supplied photo dimensions tolerate face-aware motion rounding", () => MotionLibraryAsync(motionFolder));
            if (args.Contains("--retry-recovery")) await Test("layout failure skips failed preparation and clears retry status", RetryRecoveryAsync);
            var output = Path.Combine(root, "test-results.json");
            File.WriteAllText(output, JsonSerializer.Serialize(new { Failed = failures, Results = results }, new JsonSerializerOptions { WriteIndented = true }));
            Console.WriteLine($"Results: {output}"); app.Shutdown(failures == 0 ? 0 : 1);
        };
        return app.Run();
    }
    private static void Check(bool value, string message) { if (!value) throw new Exception(message); }
    private static PhotoInfo Photo(string name, int w, int h) => new(name, w, h, 1, null, 1, 1);
    private static async Task Test(string name, Func<Task> test)
    {
        try { await test(); Console.WriteLine($"PASS {name}"); results.Add(new { Name = name, Passed = true }); }
        catch (Exception e) { failures++; Console.WriteLine($"FAIL {name}: {e}"); results.Add(new { Name = name, Passed = false, Error = e.ToString() }); }
    }
    private static Task Sync(Action action) { action(); return Task.CompletedTask; }
    private static string Fixture(string name, int w, int h, int orientation = 1)
    {
        var path = Path.Combine(root, name);
        var pixels = new byte[w * h * 4];
        for (var y = 0; y < h; y++) for (var x = 0; x < w; x++)
        {
            var i = (y * w + x) * 4;
            var color = y < h / 2 ? (x < w / 2 ? Colors.Red : Colors.Lime) : (x < w / 2 ? Colors.Blue : Colors.Yellow);
            pixels[i] = color.B; pixels[i + 1] = color.G; pixels[i + 2] = color.R; pixels[i + 3] = 255;
        }
        var source = BitmapSource.Create(w, h, 96, 96, PixelFormats.Bgra32, null, pixels, w * 4);
        if (Path.GetExtension(path) == ".webp")
        {
            using var bitmap = new SKBitmap(new SKImageInfo(w, h, SKColorType.Bgra8888, SKAlphaType.Opaque));
            System.Runtime.InteropServices.Marshal.Copy(pixels, 0, bitmap.GetPixels(), pixels.Length);
            using var image = SKImage.FromBitmap(bitmap); using var data = image.Encode(SKEncodedImageFormat.Webp, 100);
            using var stream = File.Create(path); data.SaveTo(stream);
        }
        else
        {
            BitmapEncoder encoder;
            BitmapMetadata? meta = null;
            if (Path.GetExtension(path) == ".jpg")
            {
                encoder = new JpegBitmapEncoder { QualityLevel = 100 }; meta = new BitmapMetadata("jpg");
                meta.SetQuery("/app1/ifd/{ushort=274}", (ushort)orientation);
                meta.SetQuery("/app1/ifd/exif/{ushort=36867}", "2025:02:03 04:05:06");
            }
            else encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(source, null, meta, null)); using var file = File.Create(path); encoder.Save(file);
        }
        return path;
    }
    private static async Task RunAsync(bool desktop)
    {
        await Test("pan distance and constant physical speed", () => Sync(() =>
        {
            var settings = new WallSettings { PanWidthFraction = 1 }; var v = new Viewport(3840, 1100);
            var plan = MotionEngine.Plan(CompositionMode.VerticalPan, Photo("portrait", 1200, 1800), v, settings);
            Check(plan.FromY == 1100 - 5760 && plan.ToY == 0, "bottom-to-top viewport endpoints");
            Check(Math.Abs((plan.ToY - plan.FromY) / plan.Seconds - 120) < .001, "physical speed");
            var horizontal = MotionEngine.Plan(CompositionMode.HorizontalPan, Photo("wide", 8000, 1000), v, settings, true);
            Check(horizontal.FromX < 0 && horizontal.ToX == 0, "reverse pan");
            Check(MotionEngine.Plan(CompositionMode.HorizontalPan, Photo("same", 3840, 1100), v, settings).FromX == 0, "no overflow no pan");
        }));
        await Test("sub-native images accepted by configurable enlargement", () => Sync(() =>
        {
            var p = new MetadataCompositionPolicy(); var s = new WallSettings { PanWidthFraction = 1 }; var v = new Viewport(3840, 1100);
            Check(p.Suitable(Photo("small", 1200, 1800), v, CompositionMode.VerticalPan, s), "3.2x portrait should pan");
            s.MaxPanUpscale = 2; Check(!p.Suitable(Photo("small", 1200, 1800), v, CompositionMode.VerticalPan, s), "configured limit respected");
            Check(p.Suitable(Photo("small", 1200, 1800), v, CompositionMode.Gallery, s), "gallery fallback");
        }));
        await Test("gallery fits viewport and preserves aspect", () => Sync(() =>
        {
            var photos = Enumerable.Range(0, 5).Select(i => Photo(i.ToString(), 800 + i * 70, 1400)).ToArray();
            foreach (var v in new[] { new Viewport(3840, 1100), new Viewport(1920, 1080), new Viewport(800, 1200) })
            {
                var frames = CompositionEngine.GalleryLayout(photos, v, 20);
                for (var i = 0; i < frames.Count; i++)
                {
                    var f = frames[i]; Check(f.X >= 0 && f.Y >= 0 && f.X + f.Width <= v.Width + .001 && f.Y + f.Height <= v.Height + .001, "bounds");
                    Check(Math.Abs(f.Width / f.Height - photos[i].Aspect) < .001, "aspect");
                    if (i > 0) Check(f.X > frames[i - 1].X + frames[i - 1].Width, "gap");
                }
            }
        }));
        await Test("selection excludes active images and avoids immediate repeats", () => Sync(() =>
        {
            var selector = new PhotoSelector(new Random(10)); var s = new WallSettings { RecentCount = 20 };
            var photos = Enumerable.Range(0, 5).Select(i => Photo(i.ToString(), 100, 200)).ToArray();
            string? last = null;
            for (var i = 0; i < 100; i++) { var p = selector.Pick(photos, s, new HashSet<string> { "4" })!; Check(p.Path != "4" && p.Path != last, "exclusion or repeat"); last = p.Path; }
            var plan = new CompositionEngine(selector, new Random(2)).Next(photos, new(3840, 1100), new WallSettings { PanWeight = 0, ZoomWeight = 0, GalleryScrollEnabled = false })!;
            Check(plan.Photos.Select(p => p.Path).Distinct().Count() == plan.Photos.Count, "duplicate gallery");
        }));
        await Test("weighted modes and pan grouping", () => Sync(() =>
        {
            var engine = new CompositionEngine(new PhotoSelector(new Random(9)), new Random(3));
            var photos = new[] { Photo("portrait", 3000, 5000), Photo("wide", 8000, 1200), Photo("landscape", 4000, 2400) };
            var totals = new int[5]; var s = new WallSettings();
            for (var i = 0; i < 20000; i++) totals[(int)engine.Next(photos, new(3840, 1100), s)!.Mode]++;
            // Repetition suppression deliberately shifts exact raw ratios slightly.
            var gallery = (totals[0] + totals[4]) / 20000d; var pan = (totals[1] + totals[2]) / 20000d; var zoom = totals[3] / 20000d;
            Console.WriteLine($"Observed weights: gallery={gallery:P1}, pan={pan:P1}, zoom={zoom:P1}");
            Check(gallery > .35 && gallery < .5 && pan > .29 && pan < .45 && zoom > .15 && zoom < .3, "distribution");
            s.GalleryWeight = s.PanWeight = 0;
            for (var i = 0; i < 20; i++) Check(engine.Next(photos, new(3840, 1100), s)!.Mode == CompositionMode.Zoom, "zero weights");
            s.ZoomEnabled = false; Check(engine.Next(photos, new(3840, 1100), s) == null, "all disabled");
        }));
        await Test("face-aware pan endpoint and centered padding", () => Sync(() =>
        {
            var photo = Photo("person", 1200, 1800) with { Faces = [new FaceRegion(.3, .2, .3, .15)] };
            var viewport = new Viewport(3840, 1100); var settings = new WallSettings();
            var plan = MotionEngine.Plan(CompositionMode.VerticalPan, photo, viewport, settings);
            var faceCenter = (.2 + .15 / 2) * plan.Height + plan.ToY;
            Check(plan.Width < viewport.Width && plan.FromX == (viewport.Width - plan.Width) / 2, "centered padding");
            Check(plan.ToY < 0 && faceCenter > 0 && faceCenter < viewport.Height, "face stop inside viewport");
            var closeFace = Photo("close-up", 1200, 1800) with { Faces = [new FaceRegion(.2, .1, .6, .5)] };
            var closePlan = MotionEngine.Plan(CompositionMode.VerticalPan, closeFace, viewport, settings);
            var closeTop = .1 * closePlan.Height + closePlan.ToY;
            Check(.5 * closePlan.Height <= viewport.Height * .920001 && closeTop >= -.001 && closeTop + .5 * closePlan.Height <= viewport.Height + .001,
                "close-up face must fit vertically without clamp rounding errors");
            settings.StopAtFace = false; Check(MotionEngine.Plan(CompositionMode.VerticalPan, photo, viewport, settings).ToY == 0, "full pan option");
            var landscape = Photo("face-near-top", 4096, 3463) with { Faces = [new FaceRegion(.4, .08, .15, .12)] };
            var full = MotionEngine.Plan(CompositionMode.Zoom, landscape, viewport, settings);
            Check(full.Width >= viewport.Width && full.Height >= viewport.Height, "full-bleed coverage");
            var faceTop = landscape.Faces[0].Y * full.Height + full.FromY;
            var faceBottom = faceTop + landscape.Faces[0].Height * full.Height;
            Check(faceTop >= 0 && faceBottom <= viewport.Height, "face-aware full-width vertical framing");
            settings.FaceAwareFraming = false;
            Check(MotionEngine.Plan(CompositionMode.Zoom, landscape, viewport, settings).FromY < full.FromY, "face alignment toggle");
            var selector = new PhotoSelector(new Random(11)); var engine = new CompositionEngine(selector, new Random(1));
            var photos = Enumerable.Range(0, 12).Select(i => Photo(i.ToString(), 800, 1200)).ToArray();
            var scrollOnly = new WallSettings { GalleryEnabled = false, GalleryScrollEnabled = true, PanWeight = 0, ZoomWeight = 0 };
            var scroll = engine.Next(photos, viewport, scrollOnly)!; Check(scroll.Mode == CompositionMode.GalleryScroll && scroll.Photos.Count >= 6, "scroll mode plus preload slots");
            scrollOnly.GalleryEnabled = true; scrollOnly.GalleryScrollEnabled = false;
            Check(engine.Next(photos, viewport, scrollOnly)!.Mode == CompositionMode.Gallery, "original gallery preserved");
        }));
        await Test("face-aware zoom at floating-point cover boundaries", () => Sync(() =>
        {
            var face = new FaceRegion(.4, .2, .2, .1);
            var viewport = new Viewport(3840, 1100);
            // This width reproduces the logged positive clamp minimum:
            // 3840 - 298 * (3840 / 298) == 4.547473508864641E-13.
            var photo = Photo("rounding-boundary", 298, 200) with { Faces = [face] };
            foreach (var reverse in new[] { false, true })
            {
                var plan = MotionEngine.Plan(CompositionMode.Zoom, photo, viewport, new WallSettings(), reverse);
                Check(plan.Width >= viewport.Width && plan.Height >= viewport.Height, "rounded cover dimensions below viewport");
                Check(plan.FromX <= 0 && plan.FromX >= viewport.Width - plan.Width, "invalid horizontal crop");
                Check(plan.FromY <= 0 && plan.FromY >= viewport.Height - plan.Height, "invalid vertical crop");
            }
            // Exercise both width- and height-limited cover calculations.
            foreach (var view in new[] { viewport, new Viewport(1920, 1080), new Viewport(1100, 3840) })
                foreach (var width in Enumerable.Range(256, 3841))
                {
                    var p = Photo("boundary", width, 1000) with { Faces = [face] };
                    foreach (var oriented in new[] { p, p with { Orientation = 6 } })
                    {
                        var plan = MotionEngine.Plan(CompositionMode.Zoom, oriented, view, new WallSettings());
                        Check(plan.Width >= view.Width && plan.Height >= view.Height && double.IsFinite(plan.FromX) && double.IsFinite(plan.FromY), "cover boundary");
                    }
                }
        }));
        await Test("EXIF all 8 orientations, pixels, dates", async () =>
        {
            var cache = new ImageCache();
            var expected = new[] { "RGBY", "GRYB", "YBGR", "BYRG", "RBGY", "BRYG", "YGBR", "GYRB" };
            for (var o = 1; o <= 8; o++)
            {
                var path = Fixture($"orientation-{o}.jpg", 80, 40, o); var photo = MetadataExtractor.Read(path);
                Check(photo.Orientation == o && photo.Width == (o >= 5 ? 40 : 80) && photo.TakenAt?.Year == 2025, "EXIF metadata");
                var image = await cache.LoadAsync(photo, photo.Width, CancellationToken.None) ?? throw new Exception("decode failed");
                Check(image.IsFrozen && image.PixelWidth == photo.Width && image.PixelHeight == photo.Height, "frozen oriented dimensions");
                var bgra = new FormatConvertedBitmap(image, PixelFormats.Bgra32, null, 0); var corners = "";
                foreach (var (x, y) in new[] { (5, 5), (image.PixelWidth - 6, 5), (5, image.PixelHeight - 6), (image.PixelWidth - 6, image.PixelHeight - 6) })
                {
                    var pixel = new byte[4]; bgra.CopyPixels(new Int32Rect(x, y, 1, 1), pixel, 4, 0);
                    corners += pixel[0] > 170 ? 'B' : pixel[2] > 170 && pixel[1] > 170 ? 'Y' : pixel[2] > 170 ? 'R' : 'G';
                }
                Check(corners == expected[o - 1], $"orientation {o}: {corners} expected {expected[o - 1]}");
            }
            await cache.ClearAsync(); Check(cache.CachedBytes == 0, "cache clear");
        });
        await Test("JPEG PNG WebP decode and corrupt/deleted skip", async () =>
        {
            var cache = new ImageCache();
            foreach (var ext in new[] { ".jpg", ".png", ".webp" })
            {
                var p = MetadataExtractor.Read(Fixture("decode" + ext, 240, 160));
                var image = await cache.LoadAsync(p, 120, CancellationToken.None);
                Check(image != null && image.PixelWidth <= 240 && image.IsFrozen, "decode " + ext);
            }
            var broken = Path.Combine(root, "broken.jpg"); File.WriteAllText(broken, "not a picture");
            Check(await cache.LoadAsync(Photo(broken, 100, 100), 100, CancellationToken.None) == null, "corrupt skip");
            Check(await cache.LoadAsync(Photo(Path.Combine(root, "missing.png"), 100, 100), 100, CancellationToken.None) == null, "deleted skip");
        });
        await Test("settings roundtrip and corruption recovery", () => Sync(() =>
        {
            var manager = new SettingsManager(); var s = new WallSettings { MonitorId = "negative-coordinate-screen", Folders = [root], MaxPanUpscale = 5, PanPixelsPerSecond = 90 };
            manager.Save(s); var loaded = manager.Load(); Check(loaded.MonitorId == s.MonitorId && loaded.MaxPanUpscale == 5 && loaded.Folders.SequenceEqual(s.Folders), "roundtrip");
            File.WriteAllText(manager.FilePath, "{broken"); Check(manager.Load().PanPixelsPerSecond == 120 && manager.Warning != null, "recover");
            File.WriteAllText(Path.Combine(Log.DataDirectory, "metadata.json"), "[null,{}]");
            using var invalidCache = new PhotoScanner(); Check(invalidCache.Photos.Count == 0, "invalid cache entries ignored");
        }));
        await Test("folder watcher add/delete and overlapping roots deduplicated", async () =>
        {
            var folder = Path.Combine(root, "watch"); Directory.CreateDirectory(folder);
            var added = Path.Combine(folder, "added.png"); if (File.Exists(added)) File.Delete(added);
            using var scanner = new PhotoScanner(); await scanner.ConfigureAsync(new WallSettings { Folders = [folder, folder], Recursive = true }, CancellationToken.None);
            var original = Fixture("watch-source.png", 100, 200); File.Copy(original, added, true);
            await Until(() => scanner.Photos.Count == 1, 8000); Check(scanner.Photos.Count == 1, "watch add");
            File.Delete(added); await Until(() => scanner.Photos.Count == 0, 8000); Check(scanner.Photos.Count == 0, "watch delete");
        });
        await Test("pause scheduler freezes elapsed motion", async () =>
        {
            var scheduler = new AnimationScheduler(); var delay = scheduler.DelayAsync(.4, CancellationToken.None);
            await Task.Delay(100); scheduler.SetPaused(true); await Task.Delay(500); Check(!delay.IsCompleted, "advanced while paused");
            scheduler.SetPaused(false); await delay.WaitAsync(TimeSpan.FromSeconds(2));
        });
        if (desktop) await Test("desktop ultrawide negative coordinates + all modes + settings UI", DesktopAsync);
    }
    private static async Task Until(Func<bool> condition, int milliseconds)
    {
        var until = DateTime.UtcNow.AddMilliseconds(milliseconds);
        while (!condition() && DateTime.UtcNow < until) await Task.Delay(100);
    }
    private static async Task InspectAsync(string folder)
    {
        using var scanner = new PhotoScanner();
        await scanner.ConfigureAsync(new WallSettings { Folders = [Path.GetFullPath(folder)] }, CancellationToken.None);
        var photos = scanner.Photos;
        var widths = photos.Select(p => p.Width).Order().ToArray();
        var policy = new MetadataCompositionPolicy(); var v = new Viewport(3840, 1100);
        var counts = new[] { 2d, 4d, 6d, 8d, 12d }.Select(scale => new { MaxUpscale = scale,
            VerticalPan = photos.Count(p => policy.Suitable(p, v, CompositionMode.VerticalPan, new WallSettings { MaxPanUpscale = scale })),
            HorizontalPan = photos.Count(p => policy.Suitable(p, v, CompositionMode.HorizontalPan, new WallSettings { MaxPanUpscale = scale })) }).ToArray();
        var report = new { Total = photos.Count, Portraits = photos.Count(p => p.Aspect < .95), Landscapes = photos.Count(p => p.Aspect >= 1),
            MinWidth = widths.FirstOrDefault(), MedianWidth = widths.Length == 0 ? 0 : widths[widths.Length / 2], MaxWidth = widths.LastOrDefault(), Eligible = counts };
        File.WriteAllText(Path.Combine(root, "photo-summary.json"), JsonSerializer.Serialize(report, new JsonSerializerOptions { WriteIndented = true }));
        Console.WriteLine(JsonSerializer.Serialize(report));
    }
    private static async Task MotionLibraryAsync(string folder)
    {
        using var scanner = new PhotoScanner();
        await scanner.ConfigureAsync(new WallSettings { Folders = [Path.GetFullPath(folder)] }, CancellationToken.None);
        var settings = new WallSettings(); var count = 0;
        foreach (var photo in scanner.Photos)
        {
            // The failing cover arithmetic depends on dimensions, not face
            // detection confidence. Include small and large framing bounds.
            foreach (var face in new[] { new FaceRegion(.35, .1, .2, .12), new FaceRegion(.1, .1, .7, .7) })
                foreach (var viewport in new[] { new Viewport(3840, 1100), new Viewport(1920, 1080), new Viewport(1100, 3840) })
                    foreach (var mode in new[] { CompositionMode.Zoom, CompositionMode.VerticalPan, CompositionMode.HorizontalPan })
                    {
                        var plan = MotionEngine.Plan(mode, photo with { Faces = [face] }, viewport, settings);
                        Check(new[] { plan.Width, plan.Height, plan.FromX, plan.FromY, plan.ToX, plan.ToY, plan.Seconds }.All(double.IsFinite), "nonfinite motion: " + photo.Path);
                        if (mode == CompositionMode.Zoom) Check(plan.Width >= viewport.Width && plan.Height >= viewport.Height, "zoom cover: " + photo.Path);
                        count++;
                    }
        }
        File.WriteAllText(Path.Combine(root, "motion-library-results.json"), JsonSerializer.Serialize(new { Photos = scanner.Photos.Count, MotionPlans = count, Failed = 0 }));
        Console.WriteLine($"Validated {count} motion plans for {scanner.Photos.Count} supplied photographs.");
    }
    private static async Task RetryRecoveryAsync()
    {
        var folder = Path.Combine(root, "retry-photos"); Directory.CreateDirectory(folder);
        var fixture = Fixture("retry-landscape.png", 298, 200);
        File.Copy(fixture, Path.Combine(folder, "photo.png"), true);
        var monitor = MonitorManager.Enumerate().OrderByDescending(m => (double)m.Width / m.Height).First();
        var settings = new WallSettings { MonitorId = monitor.Id, Folders = [folder], GalleryEnabled = true,
            GalleryScrollEnabled = false, VerticalPanEnabled = false, HorizontalPanEnabled = false, ZoomEnabled = false,
            PanWeight = 0, GalleryWeight = 100, FadeSeconds = .2, HideTaskbar = false, FaceAwareFraming = false,
            CornerRadius = -1 }; // Inject a one-mode layout failure without changing production APIs.
        await using var controller = new WallController(settings);
        var retries = 0;
        controller.Changed += () =>
        {
            if (retries > 0 || !controller.Status.StartsWith("画像表示を再試行中")) return;
            retries++;
            // Leave Gallery's invalid radius in place, but make the next valid
            // plan a Zoom. Reusing the failed prepared Gallery would never recover.
            settings.GalleryEnabled = false; settings.ZoomEnabled = true; settings.ZoomWeight = 100;
        };
        await controller.InitializeAsync();
        await Until(() => retries > 0 && controller.CurrentMode == CompositionMode.Zoom && controller.Status.StartsWith("再生中"), 7000);
        Check(retries == 1 && controller.CurrentMode == CompositionMode.Zoom && controller.Status.StartsWith("再生中"),
            $"controller pinned to failed plan or stale retry status: retries={retries}, mode={controller.CurrentMode}, status={controller.Status}");
        File.WriteAllText(Path.Combine(root, "retry-recovery-results.json"), JsonSerializer.Serialize(new { FailuresInjected = retries,
            RecoveredMode = controller.CurrentMode.ToString(), Status = controller.Status, FailedPlanSkipped = true }));
    }
    private static async Task DesktopAsync()
    {
        var monitor = MonitorManager.Enumerate().OrderByDescending(m => (double)m.Width / m.Height).First();
        var s = new WallSettings { FadeSeconds = .2, GalleryMinSeconds = 5, GalleryMaxSeconds = 5, MaxPanUpscale = 12 };
        var scheduler = new AnimationScheduler(); var transitions = new TransitionController();
        var renderer = new PhotoRenderer(new(monitor.Width, monitor.Height), s, transitions, scheduler);
        using var host = new DesktopWindowHost();
        host.Attach(renderer, monitor); Check(host.IsAlive, "host alive");
        var cache = new ImageCache();
        var portrait = MetadataExtractor.Read(Fixture("desktop-portrait.jpg", 1200, 1800));
        var landscape = MetadataExtractor.Read(Fixture("desktop-landscape.jpg", 1600, 1000));
        var wide = MetadataExtractor.Read(Fixture("desktop-wide.webp", 4000, 600));
        var photos = new[] { portrait, landscape, wide };
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        foreach (var mode in Enum.GetValues<CompositionMode>())
        {
            var items = mode == CompositionMode.Gallery ? photos : new[] { mode == CompositionMode.VerticalPan ? portrait : mode == CompositionMode.HorizontalPan ? wide : landscape };
            var bitmaps = new List<BitmapSource>();
            foreach (var item in items) bitmaps.Add((await cache.LoadAsync(item, 1200, timeout.Token))!);
            var scene = renderer.Build(new(mode, items), bitmaps, new Random(1)); await renderer.ShowAsync(scene, timeout.Token);
            await Task.Delay(400); renderer.UpdateLayout();
            var width = (int)renderer.ActualWidth; var height = (int)renderer.ActualHeight;
            Check(width > 0 && height > 0, "render size");
            var screenshot = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32); screenshot.Render(renderer);
            var png = new PngBitmapEncoder(); png.Frames.Add(BitmapFrame.Create(screenshot)); using (var f = File.Create(Path.Combine(root, $"mode-{mode}.png"))) png.Save(f);
            if (mode == CompositionMode.Gallery)
            {
                var replacement = MetadataExtractor.Read(Fixture("replacement.png", 800, 1200));
                var bitmap = (await cache.LoadAsync(replacement, 800, timeout.Token))!;
                await renderer.ReplaceSlotAsync(scene, 0, replacement, bitmap, timeout.Token);
                Check(scene.Photos[0].Path == replacement.Path && scene.Photos[1].Path == landscape.Path, "individual gallery replacement");
            }
            transitions.SetPaused(true); scheduler.SetPaused(true); await Task.Delay(100); transitions.SetPaused(false); scheduler.SetPaused(false);
        }
        File.WriteAllText(Path.Combine(root, "desktop-details.json"), JsonSerializer.Serialize(new { Monitor = monitor, Host = host.Inspect() }, new JsonSerializerOptions { WriteIndented = true }));
        renderer.Clear(); host.Dispose();
        var controller = new WallController(new WallSettings());
        var window = new DynamicPhotoWall.UI.SettingsWindow(controller, new SettingsManager());
        window.Show(); await Task.Delay(300); window.UpdateLayout();
        var ui = new RenderTargetBitmap((int)window.ActualWidth, (int)window.ActualHeight, 96, 96, PixelFormats.Pbgra32); ui.Render(window);
        var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(ui)); using (var f = File.Create(Path.Combine(root, "settings.png"))) encoder.Save(f);
        window.Close(); await controller.DisposeAsync();
        var runSettings = new WallSettings { MonitorId = monitor.Id, Folders = [root], GalleryMax = 2, GalleryMinSeconds = 5, GalleryMaxSeconds = 5, GalleryScrollEnabled = false,
            GalleryWeight = 100, PanWeight = 0, ZoomWeight = 0, FadeSeconds = .2, MaxPanUpscale = 12 };
        await using var running = new WallController(runSettings);
        await running.InitializeAsync(); await Until(() => running.CurrentMode == CompositionMode.Gallery, 5000);
        Check(running.IsRunning && running.CurrentMode == CompositionMode.Gallery, "controller startup gallery");
        var initial = running.DisplayedPhotoPaths.ToArray(); await Task.Delay(6500);
        Check(!running.DisplayedPhotoPaths.SequenceEqual(initial), "controller asynchronous gallery update");
        running.TogglePause(); Check(running.IsPaused, "controller pause");
        running.Next(); await Task.Delay(100); running.Next(); await Task.Delay(100); running.TogglePause();
        await Until(() => running.CurrentMode == CompositionMode.Gallery, 3000);
        var zoomSettings = SettingsManager.Clone(runSettings); zoomSettings.GalleryWeight = 0; zoomSettings.ZoomWeight = 100;
        await running.ApplyAsync(zoomSettings); await Until(() => running.CurrentMode == CompositionMode.Zoom, 5000);
        Check(running.CurrentMode == CompositionMode.Zoom, "controller apply settings/restart/zoom");
        await running.StopAsync(); Check(!running.IsRunning && running.CurrentMode == null, "controller stop");
        var absent = SettingsManager.Clone(runSettings); absent.MonitorId = "disconnected-monitor-test";
        await running.ApplyAsync(absent); await running.StartAsync();
        Check(!running.IsRunning && running.Status.Contains("未接続"), "disconnected monitor safe stop");
    }
    private static async Task ActualPhotosAsync(string folder)
    {
        using var scanner = new PhotoScanner();
        var settings = new WallSettings { Folders = [Path.GetFullPath(folder)], FadeSeconds = 1.2, GalleryMax = 5 };
        await scanner.ConfigureAsync(settings, CancellationToken.None);
        var photos = scanner.Photos.ToArray(); Check(photos.Length > 0, "no photos");
        var monitor = MonitorManager.Enumerate().OrderByDescending(m => (double)m.Width / m.Height).First();
        var viewport = new Viewport(monitor.Width, monitor.Height);
        var policy = new MetadataCompositionPolicy();
        var cache = new ImageCache { BudgetBytes = 64 * 1024L * 1024 };
        var decoded = 0; var failed = new List<string>();
        var started = System.Diagnostics.Stopwatch.StartNew();
        foreach (var photo in photos)
        {
            var image = await cache.LoadAsync(photo, Math.Min(photo.Width, monitor.Width), CancellationToken.None);
            if (image == null) failed.Add(photo.Path); else decoded++;
            if ((decoded + failed.Count) % 100 == 0) Console.WriteLine($"Actual photos: {decoded + failed.Count}/{photos.Length}, decode failures={failed.Count}");
        }
        var decodeSeconds = started.Elapsed.TotalSeconds;
        var scheduler = new AnimationScheduler(); var transitions = new TransitionController();
        var renderer = new PhotoRenderer(viewport, settings, transitions, scheduler);
        using var host = new DesktopWindowHost(); host.Attach(renderer, monitor);
        var portrait = photos.Where(p => policy.Suitable(p, viewport, CompositionMode.VerticalPan, settings)).OrderBy(p => Math.Abs(p.Width - 1536)).First();
        var landscape = photos.Where(p => policy.Suitable(p, viewport, CompositionMode.Zoom, settings)).OrderByDescending(p => (long)p.Width * p.Height).First();
        var galleryPhotos = photos.Where(p => p.Aspect < .95).OrderBy(p => p.Width).ToArray();
        var gallery = Enumerable.Range(0, 5).Select(i => galleryPhotos[i * (galleryPhotos.Length - 1) / 4]).DistinctBy(p => p.Path).ToArray();
        var scenes = new[] { new CompositionPlan(CompositionMode.Gallery, gallery), new CompositionPlan(CompositionMode.VerticalPan, [portrait]), new CompositionPlan(CompositionMode.Zoom, [landscape]) };
        var renderResults = new List<object>();
        try
        {
            foreach (var plan in scenes)
            {
                var bitmaps = new List<BitmapSource>();
                foreach (var photo in plan.Photos) bitmaps.Add((await cache.LoadAsync(photo, Math.Min(photo.Width, monitor.Width), CancellationToken.None))!);
                var scene = renderer.Build(plan, bitmaps, new Random(12)); await renderer.ShowAsync(scene, CancellationToken.None);
                await Task.Delay(2500); SaveRender(renderer, "actual-" + plan.Mode + ".png");
                if (plan.Mode == CompositionMode.Gallery)
                {
                    var replacement = photos.First(p => p.Aspect < .95 && gallery.All(g => g.Path != p.Path));
                    var image = (await cache.LoadAsync(replacement, 1400, CancellationToken.None))!;
                    var untouched = scene.Photos.Skip(1).Select(p => p.Path).ToArray();
                    await renderer.ReplaceSlotAsync(scene, 0, replacement, image, CancellationToken.None);
                    Check(scene.Photos.Skip(1).Select(p => p.Path).SequenceEqual(untouched), "other slots changed");
                    SaveRender(renderer, "actual-gallery-updated.png");
                }
                renderResults.Add(new { Mode = plan.Mode.ToString(), Count = plan.Photos.Count, SourceDimensions = plan.Photos.Select(p => new { p.Width, p.Height }).ToArray(), PlannedMotionSeconds = scene.Seconds });
                Console.WriteLine($"Actual desktop: {plan.Mode} passed");
            }
            var horizontalCandidates = photos.Count(p => policy.Suitable(p, viewport, CompositionMode.HorizontalPan, settings));
            var report = new { Scanned = photos.Length, Decoded = decoded, Failed = failed.Count, DecodeSeconds = Math.Round(decodeSeconds, 2),
                Monitor = new { monitor.Width, monitor.Height, monitor.X, monitor.Y }, HorizontalPanCandidates = horizontalCandidates,
                CacheBytes = cache.CachedBytes, Scenes = renderResults, FailurePaths = failed };
            File.WriteAllText(Path.Combine(root, "actual-photo-results.json"), JsonSerializer.Serialize(report, new JsonSerializerOptions { WriteIndented = true }));
            Check(failed.Count == 0, $"{failed.Count} photos failed decoding; see report");
            Console.WriteLine($"Actual photos complete: {decoded}/{photos.Length} decoded in {decodeSeconds:F1}s, horizontal candidates={horizontalCandidates}");
        }
        finally { renderer.Clear(); host.Dispose(); await cache.ClearAsync(); }
    }
    private static void SaveRender(Window window, string name)
    {
        window.UpdateLayout();
        var image = new RenderTargetBitmap((int)window.ActualWidth, (int)window.ActualHeight, 96, 96, PixelFormats.Pbgra32); image.Render(window);
        var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(image));
        using var stream = File.Create(Path.Combine(root, name)); encoder.Save(stream);
    }

    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern nint GetDC(nint hwnd);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern int ReleaseDC(nint hwnd, nint dc);
    [System.Runtime.InteropServices.DllImport("gdi32.dll")] private static extern uint GetPixel(nint dc, int x, int y);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern nint GetForegroundWindow();
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern nint SetThreadDpiAwarenessContext(nint context);
    private static async Task CompositorAsync()
    {
        var monitor = MonitorManager.Enumerate().OrderByDescending(m => (double)m.Width / m.Height).First();
        var window = new Window { Background = Brushes.Magenta, Focusable = false, IsHitTestVisible = false };
        var foreground = GetForegroundWindow();
        using var host = new DesktopWindowHost(); host.Attach(window, monitor);
        int Sample(uint color)
        {
            var previous = SetThreadDpiAwarenessContext(new nint(-4));
            var dc = GetDC(0);
            try
            {
                var count = 0;
                foreach (var x in new[] { .2, .5, .8 }) foreach (var y in new[] { .2, .5, .8 })
                    if (GetPixel(dc, monitor.X + (int)(monitor.Width * x), monitor.Y + (int)(monitor.Height * y)) == color) count++;
                return count;
            }
            finally { ReleaseDC(0, dc); SetThreadDpiAwarenessContext(previous); }
        }
        await Task.Delay(1000); var magenta = Sample(0xFF00FF);
        window.Background = Brushes.Cyan; await Task.Delay(700); var cyan = Sample(0xFFFF00);
        var retainedFocus = GetForegroundWindow() == foreground;
        var details = host.Inspect();
        File.WriteAllText(Path.Combine(root, "compositor-result.json"), JsonSerializer.Serialize(new { Monitor = monitor, Host = details,
            Samples = 9, MagentaVisible = magenta, CyanVisible = cyan, RetainedFocus = retainedFocus }, new JsonSerializerOptions { WriteIndented = true }));
        Console.WriteLine($"Compositor pixels: magenta={magenta}/9, cyan={cyan}/9, retainedFocus={retainedFocus}");
        Check(magenta > 0 && cyan > 0, "No rendered pixels reached desktop composition. See compositor-result.json; target screen must be uncovered.");
    }
    private static async Task TaskbarAsync()
    {
        var monitors = MonitorManager.Enumerate();
        var target = monitors.OrderByDescending(m => (double)m.Width / m.Height).First();
        var before = TaskbarVisibility.Query(target);
        var others = monitors.Where(m => m.Id != target.Id).SelectMany(TaskbarVisibility.Query).ToArray();
        Check(before.Any(b => b.Visible), "target screen must have a visible taskbar for this test");
        using (var visibility = new TaskbarVisibility())
        {
            visibility.Update(target, true); await Task.Delay(300);
            Check(TaskbarVisibility.Query(target).All(b => !b.Visible), "taskbar not hidden");
            foreach (var m in monitors.Where(m => m.Id != target.Id))
                Check(TaskbarVisibility.Query(m).All(b => others.Any(o => o.Handle == b.Handle && o.Visible == b.Visible)), "another screen's taskbar changed");
            visibility.Restore(); await Task.Delay(200);
            Check(TaskbarVisibility.Query(target).All(b => before.Any(o => o.Handle == b.Handle && o.Visible == b.Visible)), "normal restore failed");
        }
        var output = Path.Combine(root, "taskbar-test-owner.json");
        if (File.Exists(output)) File.Delete(output);
        var start = new System.Diagnostics.ProcessStartInfo(Path.Combine(AppContext.BaseDirectory, "DynamicPhotoWall.exe"))
            { UseShellExecute = false, CreateNoWindow = true, WindowStyle = System.Diagnostics.ProcessWindowStyle.Hidden };
        foreach (var arg in new[] { "--taskbar-test-owner", "--output", output }) start.ArgumentList.Add(arg);
        using var owner = System.Diagnostics.Process.Start(start)!;
        try
        {
            await Until(() => File.Exists(output), 6000);
            Check(File.Exists(output) && TaskbarVisibility.Query(target).All(b => !b.Visible), "crash-test owner did not hide taskbar");
            owner.Kill(); await owner.WaitForExitAsync();
            await Until(() => TaskbarVisibility.Query(target).All(b => before.Any(o => o.Handle == b.Handle && o.Visible == b.Visible)), 5000);
            Check(TaskbarVisibility.Query(target).All(b => before.Any(o => o.Handle == b.Handle && o.Visible == b.Visible)), "crash guard did not restore taskbar");
            File.WriteAllText(Path.Combine(root, "taskbar-result.json"), JsonSerializer.Serialize(new { Target = target.Device,
                Taskbars = before.Count, Hide = true, OtherMonitorsUnchanged = true, NormalRestore = true, CrashRestore = true }));
        }
        finally { if (!owner.HasExited) { owner.Kill(); await owner.WaitForExitAsync(); } }
    }
    private static async Task PanMetricsAsync()
    {
        using var scanner = new PhotoScanner();
        await scanner.ConfigureAsync(new WallSettings { Folders = [Path.GetFullPath("photos")] }, CancellationToken.None);
        var photo = scanner.Photos.Where(p => p.Aspect < .8 && p.Width >= 1000).OrderBy(p => Math.Abs(p.Width - 1536)).First();
        var monitor = MonitorManager.Enumerate().OrderByDescending(m => (double)m.Width / m.Height).First();
        var settings = new WallSettings { FadeSeconds = .2, HideTaskbar = false };
        var cache = new ImageCache(); var bitmap = (await cache.LoadAsync(photo, monitor.Width, CancellationToken.None))!;
        var scheduler = new AnimationScheduler(); var transitions = new TransitionController();
        var renderer = new PhotoRenderer(new(monitor.Width, monitor.Height), settings, transitions, scheduler);
        using var host = new DesktopWindowHost(); host.Attach(renderer, monitor);
        var scene = renderer.Build(new(CompositionMode.VerticalPan, [photo]), [bitmap], new Random(1));
        await renderer.ShowAsync(scene, CancellationToken.None); await Task.Delay(1000);
        var image = scene.MotionImage!;
        var positions = new List<double>(); var times = new List<double>(); var updates = new List<double>();
        var layoutPasses = 0; var clock = System.Diagnostics.Stopwatch.StartNew();
        EventHandler layout = (_, _) => layoutPasses++;
        EventHandler render = (_, _) =>
        {
            // Independent render transforms are sampled on the render thread;
            // TransformToAncestor can contain a cached UI-side visual matrix.
            var position = image.RenderTransform is TransformGroup group
                ? group.Children.OfType<TranslateTransform>().Last().Y : System.Windows.Controls.Canvas.GetTop(image);
            var time = clock.Elapsed.TotalMilliseconds;
            times.Add(time);
            if (positions.Count == 0 || Math.Abs(position - positions[^1]) > .01) updates.Add(time);
            positions.Add(position);
        };
        scene.Canvas.LayoutUpdated += layout; CompositionTarget.Rendering += render;
        try { await Task.Delay(6000); }
        finally { CompositionTarget.Rendering -= render; scene.Canvas.LayoutUpdated -= layout; }
        var elapsed = clock.Elapsed.TotalSeconds;
        var intervals = updates.Zip(updates.Skip(1), (a, b) => b - a).Order().ToArray();
        var report = new { Width = monitor.Width, Height = monitor.Height, MonitorHz = MonitorManager.RefreshRate(monitor),
            RenderTier = RenderCapability.Tier >> 16, Seconds = elapsed, RenderingCallbacks = times.Count,
            PositionUpdates = updates.Count, PositionUpdatesPerSecond = updates.Count / elapsed, LayoutPasses = layoutPasses,
            MedianUpdateMilliseconds = intervals.Length > 0 ? intervals[intervals.Length / 2] : 0,
            P95UpdateMilliseconds = intervals.Length > 0 ? intervals[(int)((intervals.Length - 1) * .95)] : 0,
            TravelPixels = positions.Count > 1 ? positions[^1] - positions[0] : 0,
            RequestedFrameRate = System.Windows.Media.Animation.Timeline.GetDesiredFrameRate((System.Windows.Media.Animation.Storyboard)scene.Canvas.Tag),
            UsesRenderTranslation = image.RenderTransform is TransformGroup,
            AmbientUpdates = scene.Ambient?.UpdateCount, AmbientMaximumCaptureMilliseconds = scene.Ambient?.MaximumCaptureMilliseconds };
        File.WriteAllText(Path.Combine(root, "pan-metrics.json"), JsonSerializer.Serialize(report, new JsonSerializerOptions { WriteIndented = true }));
        Console.WriteLine(JsonSerializer.Serialize(report));
        Check(updates.Count > 50, "pan did not advance");
        Check(report.RequestedFrameRate == null && report.UsesRenderTranslation && layoutPasses < 5, "render thread pan regressed to capped/layout animation");
        renderer.Clear(); await cache.ClearAsync();
    }
    private static async Task FeaturesAsync()
    {
        using var scanner = new PhotoScanner();
        await scanner.ConfigureAsync(new WallSettings { Folders = [Path.GetFullPath("photos")] }, CancellationToken.None);
        var candidates = scanner.Photos.Where(p => p.Aspect < .8 && p.Width >= 1000).ToArray();
        var cache = new ImageCache(); var analyzer = new FaceAnalyzer();
        var inspected = 0; var detected = 0; PhotoInfo? person = null;
        var galleryPhotos = Enumerable.Range(0, 7).Select(i => candidates[i * (candidates.Length - 1) / 7]).ToArray();
        foreach (var candidate in galleryPhotos.Concat(candidates.Take(12)).DistinctBy(p => p.Path))
        {
            var source = (await cache.LoadAsync(candidate, 640, CancellationToken.None))!;
            var result = await analyzer.AnalyzeAsync(candidate, source, CancellationToken.None); inspected++;
            if (result.Faces?.Count > 0) { detected++; person ??= result; }
            if (detected >= 3) break;
        }
        Check(person != null, "Windows face detector did not find a face in the test samples; inspect profile/app.log");
        await analyzer.SaveAsync();
        var monitor = MonitorManager.Enumerate().OrderByDescending(m => (double)m.Width / m.Height).First();
        var viewport = new Viewport(monitor.Width, monitor.Height);
        var settings = new WallSettings { FadeSeconds = .3, GalleryScrollPixelsPerSecond = 200, HideTaskbar = false };
        var scheduler = new AnimationScheduler(); var transitions = new TransitionController();
        var renderer = new PhotoRenderer(viewport, settings, transitions, scheduler);
        using var host = new DesktopWindowHost(); host.Attach(renderer, monitor);
        var image = (await cache.LoadAsync(person!, 3000, CancellationToken.None))!;


        var scene = renderer.Build(new(CompositionMode.VerticalPan, [person!]), [image], new Random(1));
        await renderer.ShowAsync(scene, CancellationToken.None);
        Check(scene.Ambient?.Texture is { IsFrozen: true, PixelWidth: 160 }, "dynamic background did not initialize");
        var motion = MotionEngine.Plan(CompositionMode.VerticalPan, person!, viewport, settings);
        var board = (System.Windows.Media.Animation.Storyboard)scene.Canvas.Tag;
        board.SeekAlignedToLastTick(scene.Canvas, TimeSpan.FromSeconds(motion.Seconds), System.Windows.Media.Animation.TimeSeekOrigin.BeginTime);
        await Task.Delay(400); SaveRender(renderer, "face-pan-end.png");
        var visibleFace = person!.Faces!.OrderBy(f => f.Y).First();
        var faceTop = visibleFace.Y * motion.Height + motion.ToY; var faceBottom = faceTop + visibleFace.Height * motion.Height;
        Check(motion.ToY <= 0 && faceTop >= 0 && faceBottom <= viewport.Height, "face bounds not visible at stop");
        PhotoInfo? fullPerson = null;
        foreach (var photo in scanner.Photos.Where(p => p.Aspect >= 1).Take(30))
        {
            var small = (await cache.LoadAsync(photo, 800, CancellationToken.None))!;
            var analyzed = await analyzer.AnalyzeAsync(photo, small, CancellationToken.None);
            if (analyzed.Faces?.Count > 0)
            {
                var candidateMotion = MotionEngine.Plan(CompositionMode.Zoom, analyzed, viewport, settings);
                if (analyzed.Faces.Max(f => f.Height) * candidateMotion.Height * settings.MaxZoom < viewport.Height * .85) { fullPerson = analyzed; break; }
            }
        }
        Check(fullPerson != null, "no face detected in landscape samples for full-width test");
        var fullImage = (await cache.LoadAsync(fullPerson!, monitor.Width, CancellationToken.None))!;
        var fullScene = renderer.Build(new(CompositionMode.Zoom, [fullPerson!]), [fullImage], new Random(5));
        await renderer.ShowAsync(fullScene, CancellationToken.None); await Task.Delay(300); SaveRender(renderer, "full-width-face.png");
        var fullMotion = MotionEngine.Plan(CompositionMode.Zoom, fullPerson!, viewport, settings);
        var fullFace = fullPerson!.Faces!.OrderByDescending(f => f.Width * f.Height).First();
        var fullFaceTop = fullFace.Y * fullMotion.Height + fullMotion.FromY;
        Check(fullFaceTop >= -.01 && fullFaceTop + fullFace.Height * fullMotion.Height <= viewport.Height + .01, "full-width face is cropped vertically");
        var images = new List<BitmapSource>(); foreach (var photo in galleryPhotos) images.Add((await cache.LoadAsync(photo, 1200, CancellationToken.None))!);

        var scroll = renderer.Build(new(CompositionMode.GalleryScroll, galleryPhotos), images, new Random(2));
        await renderer.ShowAsync(scroll, CancellationToken.None); SaveRender(renderer, "scroll-before.png");
        Check(scroll.Slots.All(s => Math.Abs(s.Height - viewport.Height + 2 * settings.Gap) < .01), "scroll has excessive vertical padding");
        var originalFirst = scroll.Photos[0].Path;
        var next = candidates.First(p => galleryPhotos.All(g => g.Path != p.Path));
        var bitmap = (await cache.LoadAsync(next, 1200, CancellationToken.None))!;
        await renderer.AdvanceGalleryAsync(scroll, next, bitmap, CancellationToken.None);
        Check(scroll.Photos[0].Path != originalFirst && scroll.Photos[^1].Path == next.Path, "scroll replacement");
        Check(scroll.Photos.Select(p => p.Path).Distinct().Count() == scroll.Photos.Count, "scroll duplicates");
        SaveRender(renderer, "scroll-after.png");
        var original = renderer.Build(new(CompositionMode.Gallery, galleryPhotos.Take(5).ToArray()), images.Take(5).ToArray(), new Random(3));
        await renderer.ShowAsync(original, CancellationToken.None); SaveRender(renderer, "gallery-glass.png");
        Check(original.Mode == CompositionMode.Gallery && original.ScrollStrip == null, "original gallery replaced");
        renderer.Clear(); host.Dispose();
        var onlyScroll = new WallSettings { MonitorId = monitor.Id, Folders = [Path.GetFullPath("photos")], GalleryEnabled = false,
            GalleryScrollEnabled = true, PanWeight = 0, ZoomWeight = 0, GalleryScrollPixelsPerSecond = 200, FadeSeconds = .2, HideTaskbar = false };
        await using var controller = new WallController(onlyScroll); await controller.InitializeAsync();
        await Until(() => controller.CurrentMode == CompositionMode.GalleryScroll, 5000);
        Check(controller.CurrentMode == CompositionMode.GalleryScroll, "controller scroll startup");
        var active = controller.DisplayedPhotoPaths.ToArray(); await Task.Delay(8000);
        Check(!controller.DisplayedPhotoPaths.SequenceEqual(active), "controller did not stream new photos");
        var originalSettings = SettingsManager.Clone(onlyScroll); originalSettings.GalleryScrollEnabled = false; originalSettings.GalleryEnabled = true;
        await controller.ApplyAsync(originalSettings); await Until(() => controller.CurrentMode == CompositionMode.Gallery, 5000);
        Check(controller.CurrentMode == CompositionMode.Gallery, "controller original gallery option");
        File.WriteAllText(Path.Combine(root, "feature-results.json"), JsonSerializer.Serialize(new { InspectedForFaces = inspected, PhotosWithFaces = detected,
            DetectedFaceCount = person.Faces!.Count, FaceTop = faceTop, FaceBottom = faceBottom, ViewportHeight = viewport.Height,
            PanWidth = motion.Width, PanEndY = motion.ToY, ScrollReplacement = true, OriginalGalleryRetained = true, GlassTextureWidth = scene.Ambient!.Texture!.PixelWidth }, new JsonSerializerOptions { WriteIndented = true }));
        Console.WriteLine($"Faces found in {detected}/{inspected} photos; face visible at stop, glass and scrolling gallery passed.");
    }

    private static async Task AmbientAsync()
    {
        static BitmapSource Blocks(int w, int h, Color top, Color bottom)
        {
            var bytes = new byte[w * h * 4];
            for (var y = 0; y < h; y++) for (var x = 0; x < w; x++)
            {
                var c = y < h / 2 ? top : bottom; var i = (y * w + x) * 4;
                bytes[i] = c.B; bytes[i + 1] = c.G; bytes[i + 2] = c.R; bytes[i + 3] = 255;
            }
            var b = BitmapSource.Create(w, h, 96, 96, PixelFormats.Pbgra32, null, bytes, w * 4); b.Freeze(); return b;
        }
        static Color Pixel(SceneVisual s, double x = .5, double y = .5)
        {
            var b = s.Ambient!.Texture!; var pixel = new byte[4];
            b.CopyPixels(new Int32Rect(Math.Min(b.PixelWidth - 1, (int)(x * b.PixelWidth)), Math.Min(b.PixelHeight - 1, (int)(y * b.PixelHeight)), 1, 1), pixel, 4, 0);
            return Color.FromArgb(pixel[3], pixel[2], pixel[1], pixel[0]);
        }
        var monitor = MonitorManager.Enumerate().OrderByDescending(m => (double)m.Width / m.Height).First();
        var viewport = new Viewport(monitor.Width, monitor.Height);
        var settings = new WallSettings { FadeSeconds = .2, PanWidthFraction = .35, StopAtFace = false,
            GalleryScrollPixelsPerSecond = 200, HideTaskbar = false, CornerRadius = 0 };
        var scheduler = new AnimationScheduler(); var transitions = new TransitionController();
        var renderer = new PhotoRenderer(viewport, settings, transitions, scheduler);
        using var host = new DesktopWindowHost(); host.Attach(renderer, monitor);
        try
        {
            var photo = Photo("red-top-blue-bottom", 256, 2048);
            var scene = renderer.Build(new(CompositionMode.VerticalPan, [photo]), [Blocks(256, 2048, Colors.Red, Colors.Blue)], new Random(1));
            await renderer.ShowAsync(scene, CancellationToken.None); await Task.Delay(250);
            var bottom = Pixel(scene); var padding = Pixel(scene, 0);
            Check(bottom.B > bottom.R + 150 && padding.B > padding.R + 150, "background does not match visible bottom or empty margins");
            var motion = MotionEngine.Plan(CompositionMode.VerticalPan, photo, viewport, settings);
            var board = (System.Windows.Media.Animation.Storyboard)scene.Canvas.Tag;
            board.SeekAlignedToLastTick(scene.Canvas, TimeSpan.FromSeconds(motion.Seconds), System.Windows.Media.Animation.TimeSeekOrigin.BeginTime);
            await Task.Delay(1200);
            var top = Pixel(scene);
            Check(top.R > top.B + 150, "ambient remains fixed when pan crop changes");
            Check(scene.Foreground.Children.OfType<System.Windows.Controls.Canvas>().All(c => c.OpacityMask == null), "pan edge mask still active");
            scheduler.SetPaused(true); transitions.SetPaused(true); await Task.Delay(200);
            var paused = scene.Ambient!.UpdateCount; await Task.Delay(450);
            Check(scene.Ambient.UpdateCount == paused, "ambient updates during pause");
            scheduler.SetPaused(false); transitions.SetPaused(false);

            var colors = new[] { Colors.Red, Colors.Blue, Colors.Red, Colors.Blue, Colors.Lime, Colors.Lime };
            var photos = colors.Select((_, i) => Photo("scroll-" + i, 256, 256)).ToArray();
            var bitmaps = colors.Select(c => Blocks(256, 256, c, c)).ToArray();
            var scroll = renderer.Build(new(CompositionMode.GalleryScroll, photos), bitmaps, new Random(1));
            await renderer.ShowAsync(scroll, CancellationToken.None); await Task.Delay(500);
            var leftBefore = Pixel(scroll, .05); var rightBefore = Pixel(scroll, .95);
            Check(leftBefore.R > 200 && rightBefore.G < 30, "ambient sampled offscreen photo or stale scene");
            var oldUpdates = scene.Ambient.UpdateCount; await Task.Delay(300);
            Check(scene.Ambient.UpdateCount == oldUpdates, "old scene ambient timer still running");
            await renderer.AdvanceGalleryAsync(scroll, Photo("new", 256, 256), Blocks(256, 256, Colors.Yellow, Colors.Yellow), CancellationToken.None);
            await Task.Delay(700);
            var leftAfter = Pixel(scroll, .05); var rightAfter = Pixel(scroll, .95);
            Check(leftAfter.B > 200 && rightAfter.G > 150, "ambient did not follow horizontal scroll");
            Check(scroll.Slots.All(s => s.OpacityMask == null), "gallery edge mask still active");
            SaveRender(renderer, "ambient-scroll.png");

            var gallery = renderer.Build(new(CompositionMode.Gallery, [photos[0]]), [bitmaps[0]], new Random(1));
            await renderer.ShowAsync(gallery, CancellationToken.None); await Task.Delay(300);
            Check(Pixel(gallery).R > 200, "gallery initial ambient");
            await renderer.ReplaceSlotAsync(gallery, 0, photos[1], bitmaps[1], CancellationToken.None); await Task.Delay(1000);
            Check(Pixel(gallery).B > 200, "ambient did not follow independent gallery replacement");
            var finalUpdates = gallery.Ambient!.UpdateCount; renderer.Clear(); await Task.Delay(400);
            Check(gallery.Ambient.UpdateCount == finalUpdates, "ambient timer survives renderer disposal");
            settings.GlassBackground = false;
            var plain = renderer.Build(new(CompositionMode.Gallery, [photos[0]]), [bitmaps[0]], new Random(1));
            Check(plain.Ambient == null, "ambient disable ignored");
            File.WriteAllText(Path.Combine(root, "ambient-results.json"), JsonSerializer.Serialize(new {
                Bottom = bottom.ToString(), Top = top.ToString(), Padding = padding.ToString(), LeftBefore = leftBefore.ToString(),
                LeftAfter = leftAfter.ToString(), RightBefore = rightBefore.ToString(), RightAfter = rightAfter.ToString(),
                PanCropTracks = true, ScrollTracks = true, GalleryReplacementTracks = true, PauseAndCleanup = true,
                EdgeMasksRemoved = true, ScrollHeight = scroll.Slots[0].Height, Gap = settings.Gap,
                MaximumCaptureMilliseconds = Math.Max(scene.Ambient.MaximumCaptureMilliseconds, scroll.Ambient!.MaximumCaptureMilliseconds)
            }, new JsonSerializerOptions { WriteIndented = true }));
        }
        finally { renderer.Clear(); }
    }
}

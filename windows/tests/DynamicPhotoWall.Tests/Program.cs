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
using Canvas = System.Windows.Controls.Canvas;

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
            if (args.Contains("--multi-display")) await Test("multi-display desktop lifecycle and common canvas", MultiDisplayDesktopAsync);
            if (args.Contains("--display-groups")) await Test("independent display groups and per-display taskbar settings", DisplayGroupsDesktopAsync);
            if (args.Contains("--settings-ui")) await Test("settings pages visual review", SettingsPagesAsync);
            if (args.Contains("--test-pattern-toggle")) await Test("test pattern button previews draft without saving and restores playback", TestPatternToggleAsync);
            if (args.Contains("--group-deletion")) await Test("group delete buttons preserve screens and survive refresh, save and reopen", GroupDeletionAsync);
            if (args.Contains("--per-display-modes")) await Test("per-mode display routing, face-safe rendering and lifecycle", PerDisplayModesAsync);
            if (args.Contains("--mirror-gallery")) await Test("automatic same-photo vertical mirrors and smooth face-safe Gallery reflow", MirrorGalleryAsync);
            if (args.Contains("--gallery-fill")) await Test("cached faces improve Gallery filling at start and replacement", GalleryFillAsync);
            if (args.Contains("--scan-only") && args.Contains("--gallery-capacity")) await Test("Gallery supports twenty photos across a wide display group", GalleryCapacityTests.Run);
            if (args.Contains("--scan-only") && args.Contains("--network-responsiveness")) await Test("network update bursts yield to dispatcher input without windows", NetworkResponsivenessTests.NotificationsYieldToInput);
            if (args.Contains("--scan-only") && args.Contains("--network-responsiveness")) await Test("cached originals bypass redundant provider face analysis after restart", () => NetworkResponsivenessTests.CachedOriginalSkipsFaceAnalysis(root));
            if (args.Contains("--scan-only") && args.Contains("--mirror-ambient"))
            {
                await Test("long-axis resolution mirrors all three motion modes locally and across peers", MirrorAmbientTests.MotionMirrors);
                await Test("ambient color reaches edges in every mode without GUI captures", MirrorAmbientTests.AmbientReachesEdges);
            }
            if (args.Contains("--scan-only") && args.Contains("--scene-transitions")) await SceneTransitions();
            if (args.Contains("--scan-only") && args.Contains("--zoom-motion")) await Test("visible zoom defaults, saved settings and shared span or mirror timelines", ZoomMotionTests.Run);
            if (args.Contains("--scan-only") && args.Contains("--mode-weights")) await Test("two-stage eighty-twenty categories preserve ratios, eligibility and legacy settings", ModeWeightTests.Run);
            if (args.Contains("--scan-only") && args.Contains("--ambient-transitions")) await AmbientTransitions();
            if (args.Contains("--scan-only") && args.Contains("--gallery-face")) await GalleryFaces();
            if (args.Contains("--scan-only") && args.Contains("--tray-menu")) await Test("WPF tray menu routes every command without opening windows", TrayMenuTests.CommandsWithoutWindows);
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
    private static async Task GalleryFaces()
    {
        await Test("motion face rectangles fit physical outputs or skip unsafe pans", GalleryFaceTests.MotionFacesFitPhysicalOutputs);
        await Test("gallery repacking retains near-full height or width", GalleryFaceTests.GalleryKeepsItsShortAxisDuringRepacking);
        await Test("one group gallery timeline changes a photo every ten to thirty seconds", GalleryFaceTests.GroupTimelineChangesOnePhotoAfterEachQuietInterval);
        await Test("local gallery replacement reflows at fixed height without a visible window", GalleryFaceTests.LocalReplacementKeepsHeightWithoutShowingAWindow);
    }
    private static async Task AmbientTransitions()
    {
        await Test("ambient color changes follow time without flashing or losing vividness", AmbientTransitionTests.ColorsFollowTimeWithoutFlashingOrLosingSaturation);
        await Test("live ambient fades retarget from the visible mix without replacing the brush", AmbientTransitionTests.LiveTextureRetargetsFromTheVisibleMix);
        await Test("shared ambient sample boundaries keep stable sources and opaque coverage", AmbientTransitionTests.SharedFrameBoundariesNeverSwapImageSources);
    }
    private static async Task SceneTransitions()
    {
        await Test("physical outputs survive mode changes, peer loss and reconnection", SharedSceneTransitionTests.PhysicalOutputsSurviveLogicalCanvasChanges);
        await Test("all mode handoffs retain outgoing trees and independent canvas regions without captures", SharedSceneTransitionTests.HandoffsRetainTreesAndMapEachScenesOwnCanvas);
        await Test("Gallery endpoints and isolation repeats keep opaque coverage", SharedSceneTransitionTests.GalleryEndpointAndIsolationRepeatKeepCoverage);
    }
    private static async Task RunAsync(bool desktop)
    {
        await Test("WPF tray menu routes every command without opening windows", TrayMenuTests.CommandsWithoutWindows);
        await GalleryFaces();
        await AmbientTransitions();
        await Test("two-stage eighty-twenty categories preserve ratios, eligibility and legacy settings", ModeWeightTests.Run);
        await Test("visible zoom defaults, saved settings and shared span or mirror timelines", ZoomMotionTests.Run);
        await SceneTransitions();
        await Test("long-axis resolution mirrors all three motion modes locally and across peers", MirrorAmbientTests.MotionMirrors);
        await Test("ambient color reaches edges in every mode without GUI captures", MirrorAmbientTests.AmbientReachesEdges);
        await Test("network update bursts yield to dispatcher input without windows", NetworkResponsivenessTests.NotificationsYieldToInput);
        await Test("cached originals bypass redundant provider face analysis after restart", () => NetworkResponsivenessTests.CachedOriginalSkipsFaceAnalysis(root));
        await Test("Gallery supports twenty photos across a wide display group", GalleryCapacityTests.Run);
        await Test("network native planning and timed crops across all five modes", () => NetworkAdapterTests.PlanningAndRendering(root));
        await Test("network keys are protected by the Windows user", () => Sync(() => NetworkAdapterTests.ProtectedSecrets(root)));
        await Test("Gallery compacts rows and resamples only known face geometry", () => Sync(() =>
        {
            var viewport = new Viewport(800, 300); FrameRect[] displays = [new(0, 0, 400, 300), new(400, 0, 400, 300)];
            var a = Photo("portrait", 400, 800) with { Faces = [new(.25, .1, .5, .3)] };
            var bad = Photo("center-face", 1600, 800) with { Faces = [new(.25, .1, .5, .3)] };
            var good = bad with { Path = "right-face", Faces = [new(.6, .1, .2, .3)] };
            var frames = FaceSafeLayout.Gallery(new[] { a, bad }, viewport, 8, displays);
            Check(Math.Abs(frames[1].X - frames[0].X - frames[0].Width - 8) < .001 && frames[0].Y == frames[1].Y,
                "a feasible compact row preserves spacing and a common baseline");
            var replacement = GalleryComposition.Improve(new[] { a, bad }, new[] { good }, viewport, 8, displays, 1);
            Check(replacement is { Index: 1 } && replacement.Photo.Path == good.Path, "choose a cached face position that avoids shrinking the row");
            Check(GalleryComposition.Loss(new[] { a, good }, viewport, 8, displays) < GalleryComposition.Loss(new[] { a, bad }, viewport, 8, displays) - .02,
                "chosen candidate improves spacing, size or balance materially");
            Check(GalleryComposition.Improve(new[] { a, good }, new[] { bad }, viewport, 8, displays) == null, "a good arrangement is not rerolled");
            Check(GalleryComposition.Improve(new[] { a, bad }, new[] { good with { Faces = null } }, viewport, 8, displays) == null,
                "an unknown face cache is not interpreted as no faces");
            Check(GalleryComposition.Improve(new[] { a, bad }, new[] { good with { Faces = [] } }, viewport, 8, displays, 1) != null,
                "a cached no-face result is a valid candidate");
            Check(GalleryComposition.Improve(new[] { a, bad }, new[] { good with { Path = bad.Path.ToUpperInvariant() } }, viewport, 8, displays) == null,
                "trials never duplicate a displayed path");
            Check(GalleryComposition.Improve(new[] { a, bad }, Enumerable.Repeat(good with { Faces = null }, 12).Append(good).ToArray(), viewport, 8, displays) == null,
                "trial work is bounded to twelve candidates");
            using var cancellation = new CancellationTokenSource(); cancellation.Cancel();
            try { GalleryComposition.Improve(new[] { a, bad }, new[] { good }, viewport, 8, displays, token: cancellation.Token); Check(false, "cancelled layout trials must stop"); }
            catch (OperationCanceledException) { }
            var selector = new PhotoSelector(new Random(10)); var settings = new WallSettings();
            var sample = selector.Sample(new[] { a, bad, good }, settings, new HashSet<string> { a.Path }, 12);
            Check(sample.Count == 2 && sample.All(p => p.Path != a.Path), "bounded candidate sampling respects active exclusions");
            selector.Remember(good, settings);
            Check(selector.Sample(new[] { a, bad, good }, settings, new HashSet<string>(), 12).All(p => p.Path != good.Path), "candidate sampling respects recent selections");
            settings.RandomOrder = false;
            Check(selector.Sample(new[] { a, bad, good }, settings, new HashSet<string>(), 12).Count == 0, "sequential playback is never rerolled");
        }));
        await Test("small motion photos mirror only when all local viewports fit", () => Sync(() =>
        {
            var s = new WallSettings { GalleryEnabled = false, GalleryScrollEnabled = false, HorizontalPanEnabled = false, ZoomEnabled = false };
            var engine = new CompositionEngine(new PhotoSelector(new Random(4)), new Random(4));
            var wall = new Viewport(4800, 1080); Viewport[] displays = [new(1920, 1080), new(2880, 1440)];
            var small = Photo("small", 800, 2400);
            CompositionPlan? Plan(PhotoInfo p, IReadOnlyList<Viewport>? local = null) => engine.Next(new[] { p }, wall, s, displayViewports: local);
            Check(Plan(small, displays)?.MirrorPerDisplay == true, "a photo rejected at wall width is eligible as one shared mirror");
            Check(Plan(Photo("large", 4000, 12000), displays)?.MirrorPerDisplay == false, "large photos keep spanning");
            Check(Plan(Photo("limit", 2400, 7200), displays)?.MirrorPerDisplay == false, "exactly half the group's long side still spans");
            Check(Plan(Photo("tiny", 400, 1200), displays) == null, "the same photo must meet the limit on every display");
            Check(Plan(small) == null && Plan(small, new[] { wall }) == null, "no fallback without a narrower connected output");
            Check(Plan(small, displays.Take(1).ToArray())?.MirrorPerDisplay == true, "a saved wall with one surviving output can mirror locally");
            Check(Plan(small with { RawWidth = 2400, RawHeight = 800, Orientation = 6 }, displays)?.MirrorPerDisplay == true, "use oriented source width");
            Check(Plan(Photo("landscape", 2400, 800), displays) == null, "fallback does not turn landscapes into vertical Pan");
            Check(engine.Next(new[] { small }, wall, s, new HashSet<string> { small.Path }, displays) == null, "mirror candidates respect exclusions");
            s.VerticalPanPerDisplay = true;
            Check(Plan(small, displays)?.MirrorPerDisplay == false, "explicit per-display mode keeps separate photo selection");
            s.VerticalPanPerDisplay = false; s.PanWidthFraction = .6;
            Check(Plan(small, displays)?.MirrorPerDisplay == true, "long-side resolution rule is independent of the configured Pan width");
        }));
        await Test("spanning face-safe Gallery and vertical Pan avoid display seams", () => Sync(FaceBoundaryGeometry));
        await Test("mode-specific physical viewports, selection and settings compatibility", () => Sync(() =>
        {
            var settings = JsonSerializer.Deserialize<WallSettings>("{}")!;
            Check(Enum.GetValues<CompositionMode>().All(m => !settings.IsPerDisplay(m)) && settings.AvoidFaceDisplayBoundaries, "legacy settings keep spanning and enable face protection");
            settings.GalleryPerDisplay = true; settings.VerticalPanPerDisplay = true;
            var clone = SettingsManager.Clone(settings);
            Check(clone.IsPerDisplay(CompositionMode.Gallery) && clone.IsPerDisplay(CompositionMode.VerticalPan)
                && !clone.IsPerDisplay(CompositionMode.GalleryScroll), "mode switches persist independently");
            settings.GalleryEnabled = settings.GalleryScrollEnabled = settings.VerticalPanEnabled = settings.ZoomEnabled = false;
            settings.HorizontalPanEnabled = true; settings.HorizontalPanPerDisplay = true;
            var wall = new Viewport(2400, 800); Viewport[] displays = [new(800, 800), new(1600, 800)];
            PhotoInfo[] photos = [Photo("medium", 1400, 800), Photo("wide", 2800, 800)];
            var planner = new CompositionEngine(new PhotoSelector(new Random(1)), new Random(1));
            var plan = planner.Next(photos, wall, settings, displayViewports: displays);
            Check(plan?.Mode == CompositionMode.HorizontalPan, "a per-screen Pan eligible locally remains available even if the whole wall is too wide");
            var second = planner.ForMode(photos, displays[1], settings, CompositionMode.HorizontalPan);
            Check(second?.Photos.Single().Path == "wide", "each screen filters candidates using its own dimensions");
            Check(planner.Next(photos.Take(1).ToArray(), wall, settings, displayViewports: displays) == null, "one unsuitable display excludes that mode for the group");
            settings.HorizontalPanPerDisplay = false;
            Check(planner.Next(photos.Take(1).ToArray(), wall, settings, displayViewports: displays) == null, "spanning mode keeps the group viewport eligibility");
        }));
        await Test("face-aware pan approaches from opposite side on both axes", () => Sync(() =>
        {
            var settings = new WallSettings { PanWidthFraction = 1 }; var viewport = new Viewport(1000, 600);
            foreach (var stop in new[] { false, true })
            foreach (var reverse in new[] { false, true })
            foreach (var center in new[] { .1, .3, .7, .9 })
            {
                settings.StopAtFace = stop;
                var face = new FaceRegion(.4, center - .05, .1, .1);
                var photo = Photo("portrait", 1000, 2000) with { Faces = [face] };
                var plan = MotionEngine.Plan(CompositionMode.VerticalPan, photo, viewport, settings, reverse);
                Check(center < .5 ? plan.FromY == viewport.Height - plan.Height && plan.ToY > plan.FromY : plan.FromY == 0 && plan.ToY < plan.FromY, "vertical direction must approach target face");
                Check(Math.Abs(Math.Abs(plan.ToY - plan.FromY) / plan.Seconds - settings.PanPixelsPerSecond) < .001, "speed remains constant in either direction");
                if (stop)
                {
                    var top = face.Y * plan.Height + plan.ToY;
                    Check(top >= -.001 && top + face.Height * plan.Height <= viewport.Height + .001, "target face fully visible at stop");
                }
                var landscape = Photo("panorama", 3000, 600) with { Faces = [new FaceRegion(center - .05, .4, .1, .1)] };
                var horizontal = MotionEngine.Plan(CompositionMode.HorizontalPan, landscape, viewport, settings, reverse);
                Check(center < .5 ? horizontal.FromX == -2000 && horizontal.ToX == 0 : horizontal.FromX == 0 && horizontal.ToX == -2000, "horizontal direction overrides randomness using face position");
            }
            var groupPhoto = Photo("group", 1000, 2000) with { Faces = [new(.1, .1, .05, .05), new(.3, .7, .3, .2)] };
            settings.StopAtFace = true;
            var groupPlan = MotionEngine.Plan(CompositionMode.VerticalPan, groupPhoto, viewport, settings);
            Check(groupPlan.FromY == 0 && groupPlan.ToY < 0, "largest face determines direction and stop");
            settings.FaceAwarePanDirection = false;
            Check(MotionEngine.Plan(CompositionMode.VerticalPan, groupPhoto, viewport, settings).FromY < 0, "direction toggle retains legacy vertical behavior");
            var wide = Photo("wide", 3000, 600) with { Faces = [new(.1, .4, .1, .1)] };
            Check(MotionEngine.Plan(CompositionMode.HorizontalPan, wide, viewport, settings).FromX == 0 && MotionEngine.Plan(CompositionMode.HorizontalPan, wide, viewport, settings, true).FromX == -2000, "direction toggle retains random horizontal behavior");
            settings.FaceAwarePanDirection = true;
            Check(MotionEngine.Plan(CompositionMode.VerticalPan, Photo("no-face", 1000, 2000), viewport, settings).ToY == 0, "missing face fallback");
            Check(JsonSerializer.Deserialize<WallSettings>("{}")!.FaceAwarePanDirection && !SettingsManager.Clone(new WallSettings { FaceAwarePanDirection = false }).FaceAwarePanDirection, "enabled by default and saved choice retained");
        }));
        await Test("display grouping, per-display taskbars and legacy migration", () => Sync(() =>
        {
            var legacy = JsonSerializer.Deserialize<WallSettings>("{\"HideTaskbar\":false,\"Displays\":[{\"Id\":\"one\",\"Width\":1920,\"Height\":1080},{\"Id\":\"two\",\"X\":1920,\"Width\":1920,\"Height\":1080}]}")!;
            legacy.Normalize();
            Check(DisplayGroups.Create(legacy.Displays).Count == 1 && legacy.Displays.All(d => d.HideTaskbar == null && !(d.HideTaskbar ?? legacy.HideTaskbar)), "old wall and taskbar choices retained");
            legacy.Displays.Add(new() { Id = "independent", X = int.MaxValue, Width = 1920, Height = 1080, GroupId = null, HideTaskbar = true });
            legacy.Displays[0].HideTaskbar = false; legacy.Displays[1].HideTaskbar = true;
            var clone = SettingsManager.Clone(legacy); var groups = DisplayGroups.Create(clone.Displays);
            Check(groups.Count == 2 && groups[0].Displays.Count == 2 && groups[1].Independent, "two joined screens and a separate screen");
            Check(new WallLayout(groups[0].Displays).Viewport == new Viewport(3840, 1080) && new WallLayout(groups[1].Displays).Viewport == new Viewport(1920, 1080), "independent screen position cannot enlarge joined canvas");
            Check(clone.Displays[0].HideTaskbar == false && clone.Displays[1].HideTaskbar == true && clone.Displays[2].GroupId == null, "per-display persistence");
            clone.Displays[0].GroupId = null; clone.Displays[1].GroupId = " "; clone.Normalize();
            Check(DisplayGroups.Create(clone.Displays).Count == 3, "blank groups remain individually independent");
        }));
        await Test("wall layout preserves physical offsets, gaps and legacy settings", () => Sync(() =>
        {
            var placements = new List<DisplayPlacement> {
                new() { Id = "left", X = -1920, Y = -120, Width = 1920, Height = 1080 },
                new() { Id = "right", X = 40, Y = 0, Width = 2560, Height = 1440 } };
            var layout = new WallLayout(placements);
            Check(layout.Viewport == new Viewport(4520, 1560), "bounding canvas including gap and vertical offset");
            Check(layout.Regions["right"] == new FrameRect(1960, 120, 2560, 1440), "normalized physical pixel crop");
            var settings = new WallSettings { MonitorId = "legacy" }; settings.Normalize();
            Check(settings.HasDisplaySelection && settings.Displays.Count == 0, "legacy single display remains valid");
            settings.Displays = placements; settings.DisplayTestPattern = true;
            var clone = SettingsManager.Clone(settings);
            Check(clone.Displays[0].X == -1920 && clone.Displays[1].Width == 2560 && clone.DisplayTestPattern, "layout persistence");
            placements[1].X = int.MaxValue;
            try { _ = new WallLayout(placements); throw new Exception("oversized canvas accepted"); }
            catch (InvalidOperationException) { }
        }));
        await Test("display crops exactly match common canvas including animation and background", DisplayCropsAsync);
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
        await Test("gallery versus pan-and-zoom categories preserve an eighty-twenty draw", () => Sync(() =>
        {
            var engine = new CompositionEngine(new PhotoSelector(new Random(9)), new Random(3));
            var photos = new[] { Photo("portrait", 3000, 5000), Photo("wide", 8000, 1200), Photo("landscape", 4000, 2400) };
            var totals = new int[5]; var s = new WallSettings();
            for (var i = 0; i < 20000; i++) totals[(int)engine.Next(photos, new(3840, 1100), s)!.Mode]++;
            var gallery = (totals[0] + totals[4]) / 20000d; var pan = (totals[1] + totals[2]) / 20000d; var zoom = totals[3] / 20000d;
            Console.WriteLine($"Observed weights: gallery={gallery:P1}, pan={pan:P1}, zoom={zoom:P1}");
            Check(gallery > .78 && gallery < .82 && pan + zoom > .18 && pan + zoom < .22, "category distribution");
            s.GalleryWeight = 0; s.MotionWeight = 20; s.VerticalPanEnabled = s.HorizontalPanEnabled = false;
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
    private static void FaceBoundaryGeometry()
    {
        static bool Inside(FrameRect face, FrameRect display) => face.X >= display.X - .00001 && face.Y >= display.Y - .00001
            && face.X + face.Width <= display.X + display.Width + .00001 && face.Y + face.Height <= display.Y + display.Height + .00001;
        var viewport = new Viewport(2000, 1000);
        FrameRect[][] layouts = [
            [new(0, 0, 1000, 1000), new(1000, 0, 1000, 1000)],
            [new(0, 0, 990, 900), new(1010, 100, 990, 900)],
            [new(0, 0, 2000, 480), new(0, 520, 2000, 480)],
            [new(0, 0, 800, 1000), new(840, 0, 1160, 700)],
            [new(1000, 0, 1000, 1000)] ]; // One connected member of a saved two-display wall.
        FaceRegion[][] faces = [[new(.4, .1, .2, .15)], [new(.4, .75, .2, .15)], [new(.1, .1, .8, .8)], [new(.1, .05, .15, .15), new(.6, .7, .3, .2)]];
        foreach (var layout in layouts)
        foreach (var bounds in faces)
        foreach (var stop in new[] { false, true })
        foreach (var direction in new[] { false, true })
        {
            var photo = Photo("portrait", 1000, 2400) with { Faces = bounds };
            var settings = new WallSettings { StopAtFace = stop, FaceAwarePanDirection = direction, PanWidthFraction = 1 };
            var plan = MotionEngine.Plan(CompositionMode.VerticalPan, photo, viewport, settings, displayRegions: layout);
            Check(double.IsFinite(plan.Seconds) && plan.Width > 0 && plan.Height > 0 && plan.Seconds > 0, "valid protected motion");
            for (var step = 0; step <= 20; step++)
            foreach (var face in bounds)
            {
                var y = (plan.FrameTop ?? 0) + plan.FromY + (plan.ToY - plan.FromY) * step / 20 + face.Y * plan.Height;
                var top = Math.Max(0, y); var bottom = Math.Min(viewport.Height, y + face.Height * plan.Height);
                if (bottom <= top) continue; // Entry/exit at an outer wall edge is allowed.
                var visible = new FrameRect(plan.FromX + face.X * plan.Width, top, face.Width * plan.Width, bottom - top);
                Check(layout.Any(d => Inside(visible, d)), "a visible face must never cross an internal seam or gap during vertical motion");
            }
            if (stop) foreach (var face in bounds)
                Check(layout.Any(d => Inside(new(plan.ToX + face.X * plan.Width, (plan.FrameTop ?? 0) + plan.ToY + face.Y * plan.Height,
                    face.Width * plan.Width, face.Height * plan.Height), d)), "every face is completely visible at protected stop");
            var photos = new[] { photo, Photo("landscape", 2000, 1200) with { Faces = bounds }, Photo("portrait2", 800, 1600) with { Faces = bounds } };
            foreach (var gap in new[] { 0d, 8d, 200d })
            {
                var frames = FaceSafeLayout.Gallery(photos, viewport, gap, layout);
                for (var i = 0; i < frames.Count; i++)
                {
                    var frame = frames[i];
                    Check(frame.X >= 0 && frame.Y >= 0 && frame.X + frame.Width <= viewport.Width + .00001 && frame.Y + frame.Height <= viewport.Height + .00001, "gallery remains within the wall");
                    if (i > 0) Check(frames[i - 1].X + frames[i - 1].Width <= frame.X + .00001, "protected gallery photos do not overlap");
                    foreach (var face in bounds) Check(layout.Any(d => Inside(new(frame.X + face.X * frame.Width, frame.Y + face.Y * frame.Height,
                        face.Width * frame.Width, face.Height * frame.Height), d)), "every Gallery face stays inside one display");
                }
            }
        }
        var centered = Photo("center", 1000, 2400) with { Faces = [new(.4, .2, .2, .15)] };
        var legacy = MotionEngine.Plan(CompositionMode.VerticalPan, centered, viewport, new WallSettings());
        var protectedPlan = MotionEngine.Plan(CompositionMode.VerticalPan, centered, viewport, new WallSettings(), displayRegions: layouts[0]);
        Check(protectedPlan.Width == legacy.Width && protectedPlan.FromX != legacy.FromX, "translation alone retains the original photo size where possible");
        var disabled = MotionEngine.Plan(CompositionMode.VerticalPan, centered, viewport, new WallSettings { AvoidFaceDisplayBoundaries = false }, displayRegions: layouts[0]);
        Check(disabled == legacy, "boundary protection can be disabled");
        var noFace = new[] { Photo("no-face", 1000, 2000) };
        Check(FaceSafeLayout.Gallery(noFace, viewport, 8, layouts[0]).SequenceEqual(CompositionEngine.GalleryLayout(noFace, viewport, 8)), "no-face Gallery keeps its original layout");
        foreach (var mode in new[] { CompositionMode.HorizontalPan, CompositionMode.Zoom })
            Check(MotionEngine.Plan(mode, centered, viewport, new WallSettings(), displayRegions: layouts[0]) == MotionEngine.Plan(mode, centered, viewport, new WallSettings()), "horizontal motion and Zoom are unchanged");
        var tiny = FaceSafeLayout.Gallery(new[] { centered }, new(400, 200), 200, new[] { new FrameRect(0, 0, 200, 200), new FrameRect(200, 0, 200, 200) });
        Check(tiny.Single().Width > 0, "large configured gaps still leave room for a protected photo");
    }
    private static BitmapSource Snapshot(FrameworkElement element, int width, int height)
    {
        element.Measure(new Size(width, height)); element.Arrange(new Rect(0, 0, width, height)); element.UpdateLayout();
        var bitmap = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32); bitmap.Render(element); return bitmap;
    }
    private static async Task SettingsPagesAsync()
    {
        var monitors = MonitorManager.Enumerate();
        var settings = new WallSettings { StartOnLaunch = false, DisplayGroupNames = ["グループ1", "グループ2"], Displays = monitors.Select((m, i) => new DisplayPlacement
            { Id = m.Id, X = m.X, Y = m.Y, Width = m.Width, Height = m.Height, GroupId = i < 2 ? "グループ1" : null, HideTaskbar = i == 2 }).ToList() };
        await using var controller = new WallController(settings);
        var window = new DynamicPhotoWall.UI.SettingsWindow(controller, new SettingsManager());
        try
        {
            window.Show();
            var pages = (System.Windows.Controls.TabControl)window.FindName("SettingsPages");
            foreach (var width in new[] { 1040d, 920d })
            {
                window.Width = width; window.Height = width == 920 ? 700 : 820;
                for (var i = 0; i < pages.Items.Count; i++)
                {
                    pages.SelectedIndex = i; await Task.Delay(100); window.UpdateLayout();
                    SaveRender(window, $"settings-page-{i + 1}-{width:0}.png");
                }
            }
        }
        finally { window.Close(); }
    }
    private static IEnumerable<T> VisualDescendants<T>(DependencyObject parent) where T : DependencyObject
    {
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(parent); i++)
        {
            var child = VisualTreeHelper.GetChild(parent, i);
            if (child is T match) yield return match;
            foreach (var descendant in VisualDescendants<T>(child)) yield return descendant;
        }
    }
    private static async Task GalleryFillAsync()
    {
        var previousData = Log.DataDirectory; Log.DataDirectory = Path.Combine(root, "gallery-fill-profile");
        Directory.CreateDirectory(Log.DataDirectory);
        try
        {
            var folder = Path.Combine(root, "gallery-fill-photos"); Directory.CreateDirectory(folder);
            foreach (var entry in new[] { ("a-portrait.png", 400, 800), ("b-center.png", 1600, 800), ("c-right.png", 1600, 800) })
                File.Copy(Fixture(entry.Item1, entry.Item2, entry.Item3), Path.Combine(folder, entry.Item1), true);
            var photos = Directory.GetFiles(folder).OrderBy(p => p).Select(MetadataExtractor.Read).ToArray();
            var cached = photos.ToDictionary(p => $"{p.Path}|{p.Length}|{p.ModifiedTicks}",
                p => p.Path.EndsWith("c-right.png") ? new[] { new FaceRegion(.6, .1, .2, .3) } : new[] { new FaceRegion(.25, .1, .5, .3) });
            var cachePath = Path.Combine(Log.DataDirectory, "faces.json"); File.WriteAllText(cachePath, JsonSerializer.Serialize(cached));
            var analyzer = new FaceAnalyzer();
            Check(analyzer.WithCachedFaces(photos[0]).Faces?.Count == 1, "existing face rectangles can be read without decoding");
            Check(analyzer.WithCachedFaces(photos[0] with { Length = photos[0].Length + 1 }).Faces == null
                && analyzer.WithCachedFaces(photos[0] with { ModifiedTicks = photos[0].ModifiedTicks + 1 }).Faces == null,
                "size and modification changes invalidate cached candidates");
            var monitors = MonitorManager.Enumerate().Take(2).ToArray(); Check(monitors.Length == 2, "two displays required");
            var settings = new WallSettings { StartOnLaunch = false, Folders = [folder], RandomOrder = false, GalleryMax = 2,
                GalleryScrollEnabled = false, VerticalPanEnabled = false, HorizontalPanEnabled = false, ZoomEnabled = false,
                GlassBackground = false, FadeSeconds = .2, GalleryMinSeconds = 5, GalleryMaxSeconds = 5,
                Displays = monitors.Select((m, i) => new DisplayPlacement { Id = m.Id, X = i == 0 ? 0 : monitors[0].Width,
                    Width = m.Width, Height = m.Height, GroupId = "gallery-fill", HideTaskbar = false }).ToList() };
            var wall = new WallLayout(settings.Displays);
            await using var controller = new WallController(settings); await controller.InitializeAsync(); await controller.StartAsync();
            await Until(() => controller.CurrentMode == CompositionMode.Gallery, 15000);
            SceneVisual Scene() => Application.Current.Windows.OfType<PhotoRenderer>().Single(w => w.Current?.Mode == CompositionMode.Gallery).Current!;
            var ordered = Scene(); await Until(() => ordered.Canvas.Opacity > .999, 5000);
            Check(ordered.Photos.Select(p => Path.GetFileName(p.Path)).SequenceEqual(new[] { "a-portrait.png", "b-center.png" }),
                "ordered playback retains its original selection instead of rerolling");
            var orderedLoss = GalleryComposition.Loss(ordered.Photos, wall.Viewport, settings.Gap, wall.Regions.Values.ToArray());
            Check(orderedLoss > .02, "fixture creates a measurable face-protection layout cost");
            void Save(SceneVisual scene, string name)
            {
                var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(Snapshot(scene.Canvas, (int)wall.Viewport.Width, (int)wall.Viewport.Height)));
                using var stream = File.Create(Path.Combine(root, name)); encoder.Save(stream);
            }
            Save(ordered, "gallery-fill-before.png");
            var randomSettings = SettingsManager.Clone(settings); randomSettings.RandomOrder = true;
            await controller.ApplyAsync(randomSettings); await controller.StartAsync();
            await Until(() => controller.CurrentMode == CompositionMode.Gallery, 15000);
            var improved = Scene(); await Until(() => improved.Canvas.Opacity > .999, 5000);
            var improvedLoss = GalleryComposition.Loss(improved.Photos, wall.Viewport, settings.Gap, wall.Regions.Values.ToArray());
            Check(improved.Photos.Any(p => p.Path.EndsWith("c-right.png")) && improvedLoss < orderedLoss - .02,
                "actual random session chooses a cached face position with better filling and balanced margins");
            var original = CompositionEngine.GalleryLayout(improved.Photos, wall.Viewport, settings.Gap);
            Check(improved.Slots.Select((s, i) => Math.Abs(s.Height - original[i].Height) < .001).All(b => b),
                "better photo geometry preserves full photograph size");
            for (var i = 1; i < improved.Slots.Count; i++)
                Check(Math.Abs(Canvas.GetLeft(improved.Slots[i]) - Canvas.GetLeft(improved.Slots[i - 1]) - improved.Slots[i - 1].Width - settings.Gap) < .001,
                    "actual scene retains the normal inter-photo gap");
            Save(improved, "gallery-fill-after.png");
            var firstPath = improved.Photos[0].Path;
            await Until(() => improved.Photos[0].Path != firstPath, 12000);
            Check(improved.Photos[0].Path != firstPath && improved.Photos.Select(p => p.Path).Distinct(StringComparer.OrdinalIgnoreCase).Count() == improved.Photos.Count,
                "timed Gallery replacements still advance and exclude all active photos");
            await Task.Delay(350);
            for (var i = 0; i < improved.Photos.Count; i++) foreach (var face in improved.Photos[i].Faces ?? [])
            {
                var slot = improved.Slots[i]; var x = Canvas.GetLeft(slot) + face.X * slot.Width; var y = Canvas.GetTop(slot) + face.Y * slot.Height;
                Check(wall.Regions.Values.Any(r => x >= r.X && y >= r.Y && x + face.Width * slot.Width <= r.X + r.Width
                    && y + face.Height * slot.Height <= r.Y + r.Height), "replacement finishes with every face inside a connected display");
            }
            controller.TogglePause(); Check(controller.GroupStates.Single().IsPaused, "improved Gallery retains group pause"); controller.TogglePause();
            controller.Next(); await Until(() => Scene() != improved, 10000); Check(Scene() != improved, "Next replaces an optimized Gallery");
            await controller.StopAsync(); Check(!controller.IsRunning, "optimized Gallery stops cleanly");
            Check(JsonSerializer.Deserialize<Dictionary<string, FaceRegion[]>>(File.ReadAllText(cachePath))!.Count == cached.Count,
                "cache-backed trials do not add face analyses for unrelated images");
            File.WriteAllText(Path.Combine(root, "gallery-fill-metrics.json"), JsonSerializer.Serialize(new { OrderedLoss = orderedLoss, ImprovedLoss = improvedLoss }));
        }
        finally { Log.DataDirectory = previousData; }
    }
    private static async Task MirrorGalleryAsync()
    {
        static void Save(FrameworkElement element, string name, int width, int height)
        {
            var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(Snapshot(element, width, height)));
            using var stream = File.Create(Path.Combine(root, name)); encoder.Save(stream);
        }
        var settings = new WallSettings { FadeSeconds = 1.2, GlassBackground = false };
        FrameRect[] regions = [new(0, 0, 400, 300), new(400, 0, 400, 300)];
        var scheduler = new AnimationScheduler(); var transitions = new TransitionController();
        var renderer = new PhotoRenderer(new(800, 300), settings, transitions, scheduler, regions);
        var a = Photo("a", 400, 800) with { Faces = [new(.25, .1, .5, .3)] };
        var b = a with { Path = "b" };
        var image = BitmapFrame.Create(new Uri(Fixture("reflow.png", 80, 160)));
        try
        {
            var scene = renderer.Build(new(CompositionMode.Gallery, new[] { a, b }), new[] { image, image }, new Random(1));
            Save((FrameworkElement)renderer.Content, "gallery-before.png", 800, 300);
            await renderer.ShowAsync(scene, CancellationToken.None);
            await Until(() => scene.Canvas.Opacity > .999, 3000);
            Save((FrameworkElement)renderer.Content, "gallery-before.png", 800, 300);
            var slots = scene.Slots.ToArray();
            FrameRect Rect(System.Windows.Controls.Border slot) => new(Canvas.GetLeft(slot), Canvas.GetTop(slot), slot.Width, slot.Height);
            var before = slots.Select(Rect).ToArray();
            var replacement = a with { Path = "wide", RawWidth = 1600, RawHeight = 800 };
            var expected = FaceSafeLayout.Gallery(new[] { replacement, b }, scene.Viewport, settings.Gap, regions);
            var changed = Enumerable.Range(0, slots.Length).First(i => Math.Abs(before[i].X - expected[i].X) > 1 || Math.Abs(before[i].Width - expected[i].Width) > 1);
            bool Intermediate()
            {
                Snapshot((FrameworkElement)renderer.Content, 800, 300);
                var rect = Rect(slots[changed]); var from = before[changed]; var to = expected[changed];
                var fraction = Math.Abs(to.X - from.X) > 1 ? (rect.X - from.X) / (to.X - from.X) : (rect.Width - from.Width) / (to.Width - from.Width);
                return fraction > .05 && fraction < .9;
            }
            var replacementImage = BitmapFrame.Create(new Uri(Fixture("reflow-wide.png", 160, 80)));
            var moving = renderer.ReplaceSlotAsync(scene, 0, replacement, replacementImage, CancellationToken.None);
            await Until(Intermediate, 2000);
            Check(Intermediate() && slots.SequenceEqual(scene.Slots) && scene.Foreground.Children.Count == slots.Length,
                "existing slots actually move through intermediate geometry rather than fading a rebuilt layout");
            scheduler.SetPaused(true); transitions.SetPaused(true); await Task.Delay(100);
            var frozen = slots.Select(Rect).ToArray(); await Task.Delay(180);
            Check(!moving.IsCompleted && frozen.SequenceEqual(slots.Select(Rect)), "Gallery reflow and fade pause together");
            Save((FrameworkElement)renderer.Content, "gallery-moving.png", 800, 300);
            scheduler.SetPaused(false); transitions.SetPaused(false); await moving;
            await Until(() => slots.All(s => !DependencyPropertyHelper.GetValueSource(s, Canvas.LeftProperty).IsAnimated), 2000);
            for (var i = 0; i < slots.Length; i++)
                Check(Rect(slots[i]) == expected[i] && !DependencyPropertyHelper.GetValueSource(slots[i], Canvas.LeftProperty).IsAnimated,
                    "reflow commits face-safe final geometry and removes clocks without jumping back");
            Save((FrameworkElement)renderer.Content, "gallery-after.png", 800, 300);
            using var cancel = new CancellationTokenSource();
            var interrupted = renderer.ReplaceSlotAsync(scene, 0, a, image, cancel.Token);
            await Task.Delay(120); cancel.Cancel();
            try { await interrupted; Check(false, "replacement must observe cancellation"); } catch (OperationCanceledException) { }
            var cancelledFrames = FaceSafeLayout.Gallery(new[] { a, b }, scene.Viewport, settings.Gap, regions);
            await Until(() => slots.All(s => !DependencyPropertyHelper.GetValueSource(s, FrameworkElement.WidthProperty).IsAnimated), 2000);
            Check(slots.Select(Rect).SequenceEqual(cancelledFrames) && slots.All(s => !DependencyPropertyHelper.GetValueSource(s, FrameworkElement.WidthProperty).IsAnimated),
                "Next/stop cancellation leaves a settled layout without animation clocks");
        }
        finally { renderer.Clear(); renderer.Close(); }

        var monitors = MonitorManager.Enumerate().Take(2).ToArray(); Check(monitors.Length == 2, "two displays required");
        var folder = Path.Combine(root, "mirror-photos"); Directory.CreateDirectory(folder);
        var sourceWidth = (int)Math.Ceiling(monitors.Max(m => m.Width) * .96 / 4) + 1;
        for (var i = 0; i < 2; i++) File.Copy(Fixture($"mirror-{i}.png", sourceWidth, sourceWidth * 6), Path.Combine(folder, $"mirror-{i}.png"), true);
        var config = new WallSettings { StartOnLaunch = false, Folders = [folder], FadeSeconds = .2, GlassBackground = false,
            GalleryEnabled = false, GalleryScrollEnabled = false, HorizontalPanEnabled = false, ZoomEnabled = false,
            FaceAwarePanDirection = false, StopAtFace = false, AvoidFaceDisplayBoundaries = false, CacheMegabytes = 64,
            Displays = monitors.Select((m, i) => new DisplayPlacement { Id = m.Id, X = i == 0 ? 0 : monitors[0].Width, Y = 0,
                Width = m.Width, Height = m.Height, GroupId = "mirror-group", HideTaskbar = false }).ToList() };
        await using var controller = new WallController(config); await controller.InitializeAsync();
        await controller.StartAsync();
        await Until(() => controller.CurrentMode == CompositionMode.VerticalPan, 15000);
        var state = controller.GroupStates.Single();
        Check(state.Mode == CompositionMode.VerticalPan && state.PerDisplay && state.Surfaces.Count == 2
            && state.PhotoPaths.Distinct().Count() == 1 && !controller.Settings.VerticalPanPerDisplay,
            "a real spanning session automatically mirrors the same small photo without changing the user's per-mode setting");
        var live = Application.Current.Windows.OfType<PhotoRenderer>().Single(w => w.Current?.Mode == CompositionMode.VerticalPan);
        var mirror = live.Current!;
        Check(mirror.Displays.All(d => d.Viewport == new Viewport(monitors.Single(m => m.Id == d.DisplayId).Width, monitors.Single(m => m.Id == d.DisplayId).Height))
            && ReferenceEquals(mirror.Displays[0].Bitmaps[0], mirror.Displays[1].Bitmaps[0]), "local physical viewports share one decoded bitmap");
        await Until(() => mirror.Canvas.Opacity > .999, 5000);
        for (var i = 0; i < 2; i++) Save(mirror.Displays[i].Canvas, $"mirror-display-{i}.png", (int)mirror.Displays[i].Viewport.Width, (int)mirror.Displays[i].Viewport.Height);
        controller.TogglePause(); Check(controller.GroupStates.Single().IsPaused, "automatic mirrors share group pause");
        controller.TogglePause(); controller.Next();
        await Until(() => live.Current != mirror, 10000);
        Check(live.Current != mirror && controller.GroupStates.Single().PhotoPaths.Distinct().Count() == 1, "Next replaces the whole mirror group together");
        var relaxedUpscale = SettingsManager.Clone(config); relaxedUpscale.MaxPanUpscale = 12;
        await controller.ApplyAsync(relaxedUpscale); await controller.StartAsync();
        await Until(() => controller.CurrentMode == CompositionMode.VerticalPan, 15000);
        Check(controller.CurrentMode == CompositionMode.VerticalPan && controller.GroupStates.Single().PerDisplay,
            "increasing the pan upscale limit does not force a small photo to span");
        var individual = SettingsManager.Clone(config); individual.VerticalPanPerDisplay = true;
        await controller.ApplyAsync(individual); await controller.StartAsync();
        await Until(() => controller.CurrentMode == CompositionMode.VerticalPan, 15000);
        Check(controller.CurrentMode == CompositionMode.VerticalPan && controller.GroupStates.Single().PhotoPaths.Distinct().Count() == 2,
            "explicit per-display mode still chooses separate photos");
        var missing = SettingsManager.Clone(config); missing.Displays[0].Id = "absent-mirror-display";
        await controller.ApplyAsync(missing); await controller.StartAsync();
        await Until(() => controller.CurrentMode == CompositionMode.VerticalPan, 15000);
        state = controller.GroupStates.Single();
        Check(state.Mode == CompositionMode.VerticalPan && state.Surfaces.Count == 1 && state.Surfaces[0].DisplayId == monitors[1].Id
            && state.Viewport == new WallLayout(missing.Displays).Viewport, "mirrors use only connected outputs and retain saved wall dimensions");
        File.WriteAllText(Path.Combine(root, "mirror-state.json"), JsonSerializer.Serialize(state, new JsonSerializerOptions { WriteIndented = true }));
        await controller.StopAsync(); Check(!controller.IsRunning && controller.GroupStates.Count == 0, "automatic mirror group stops cleanly");
    }
    private static async Task PerDisplayModesAsync()
    {
        static BitmapSource Solid(Color color, int width = 16, int height = 16)
        {
            var pixels = Enumerable.Range(0, width * height).SelectMany(_ => new[] { color.B, color.G, color.R, (byte)255 }).ToArray();
            var bitmap = BitmapSource.Create(width, height, 96, 96, PixelFormats.Bgra32, null, pixels, width * 4); bitmap.Freeze(); return bitmap;
        }
        static Color Center(FrameworkElement element, int width, int height)
        {
            var bitmap = Snapshot(element, width, height); var pixel = new byte[4];
            bitmap.CopyPixels(new Int32Rect(width / 2, height / 2, 1, 1), pixel, 4, 0); return Color.FromRgb(pixel[2], pixel[1], pixel[0]);
        }
        var red = Solid(Colors.Red); var blue = Solid(Colors.Blue);
        var settings = new WallSettings { FadeSeconds = .05, GalleryScrollPixelsPerSecond = 200 };
        var scheduler = new AnimationScheduler(); var transitions = new TransitionController();
        var renderer = new PhotoRenderer(new(800, 300), settings, transitions, scheduler);
        var leftRegion = new FrameRect(0, 0, 400, 300); var rightRegion = new FrameRect(400, 0, 400, 300);
        renderer.SetDisplayRegion(leftRegion, "left");
        var rightView = renderer.CreateDisplayRegion(rightRegion, "right");
        Snapshot((FrameworkElement)renderer.Content, 400, 300);
        try
        {
            foreach (var mode in Enum.GetValues<CompositionMode>())
            {
                var dimensions = mode == CompositionMode.VerticalPan ? (800, 2400) : mode == CompositionMode.GalleryScroll ? (200, 400) : (2400, 800);
                var a = Photo("red", dimensions.Item1, dimensions.Item2); var b = a with { Path = "blue" };
                var redImage = Solid(Colors.Red, dimensions.Item1 / 50, dimensions.Item2 / 50); var blueImage = Solid(Colors.Blue, dimensions.Item1 / 50, dimensions.Item2 / 50);
                var photosA = mode == CompositionMode.GalleryScroll ? new[] { a, a with { Path = "red2" } } : new[] { a };
                var photosB = mode == CompositionMode.GalleryScroll ? new[] { b, b with { Path = "blue2" } } : new[] { b };
                var scene = renderer.BuildPerDisplay(new[] {
                    new DisplayScene("left", leftRegion, new(mode, photosA), photosA.Select(_ => redImage).ToArray()),
                    new DisplayScene("right", rightRegion, new(mode, photosB), photosB.Select(_ => blueImage).ToArray()) }, new Random(7));
                await renderer.ShowAsync(scene, CancellationToken.None);
                Snapshot((FrameworkElement)renderer.Content, 400, 300); Snapshot(rightView, 400, 300);
                await Until(() => scene.Canvas.Opacity > .999, 2000);
                Check(scene.Displays.Count == 2 && scene.Displays.All(s => s.Viewport == new Viewport(400, 300)), "all modes build local physical viewports");
                var leftColor = Center((FrameworkElement)renderer.Content, 400, 300); var rightColor = Center(rightView, 400, 300);
                Check(leftColor.R > 200 && rightColor.B > 200, $"each display presents its own photo and background: {mode}, left={leftColor}, right={rightColor}, opacity={scene.Canvas.Opacity}, child={scene.Displays[0].Canvas.RenderSize}");
                if (mode == CompositionMode.Gallery)
                {
                    await renderer.ReplaceSlotAsync(scene.Displays[0], 0, b, blueImage, CancellationToken.None);
                    Check(scene.Displays[0].Photos[0].Path == "blue" && scene.Displays[1].Photos[0].Path == "blue", "Gallery child replacement is accepted by the active parent scene");
                    await Until(() => Center((FrameworkElement)renderer.Content, 400, 300).B > 200, 2000);
                    Check(Center((FrameworkElement)renderer.Content, 400, 300).B > 200, "replacement actually appears on its display");
                }
                if (mode == CompositionMode.GalleryScroll)
                {
                    await renderer.AdvanceGalleryAsync(scene.Displays[0], a with { Path = "incoming" }, redImage, CancellationToken.None);
                    Check(scene.Displays[0].Photos[^1].Path == "incoming" && scene.Displays[1].Photos[0].Path == "blue", "each scrolling strip advances locally");
                }
                var ambient = scene.Displays.Select(s => s.Ambient!).ToArray();
                scheduler.SetPaused(true); transitions.SetPaused(true); await Task.Delay(180);
                var counts = ambient.Select(a => a.UpdateCount).ToArray(); await Task.Delay(180);
                Check(counts.SequenceEqual(ambient.Select(a => a.UpdateCount)), "all per-display backgrounds pause with the group");
                scheduler.SetPaused(false); transitions.SetPaused(false);
            }
            // Overlapping logical placement must not blend independent outputs.
            renderer.SetDisplayRegion(leftRegion, "left"); var overlappingRight = renderer.CreateDisplayRegion(leftRegion, "right");
            var overlap = renderer.BuildPerDisplay(new[] {
                new DisplayScene("left", leftRegion, new(CompositionMode.Gallery, new[] { Photo("r", 800, 400) }), new[] { red }),
                new DisplayScene("right", leftRegion, new(CompositionMode.Gallery, new[] { Photo("b", 800, 400) }), new[] { blue }) }, new Random(9));
            await renderer.ShowAsync(overlap, CancellationToken.None);
            Snapshot(overlappingRight, 400, 300); await Until(() => overlap.Canvas.Opacity > .999, 2000);
            Check(Center((FrameworkElement)renderer.Content, 400, 300).R > 200 && Center(overlappingRight, 400, 300).B > 200, "display IDs route independent scenes even at identical coordinates");
            var span = renderer.Build(new(CompositionMode.Gallery, new[] { Photo("span", 1600, 600) }), new[] { Solid(Colors.Red, 80, 30) }, new Random(9));
            await renderer.ShowAsync(span, CancellationToken.None);
            await Until(() => span.Canvas.Opacity > .999, 2000);
            await Until(() => Center(overlappingRight, 400, 300).R > 200, 2000);
            Check(Center(overlappingRight, 400, 300).R > 200 && renderer.Current!.Displays.Count == 0, "switching back to span changes every output to the shared wall");
            renderer.Clear(); var oldCount = overlap.Displays.Select(s => s.Ambient!.UpdateCount).ToArray(); await Task.Delay(180);
            Check(oldCount.SequenceEqual(overlap.Displays.Select(s => s.Ambient!.UpdateCount)), "retired per-screen backgrounds stop updating");
        }
        finally { renderer.Clear(); renderer.Close(); }

        // Faces in a spanning Gallery finish replacement at a safe layout.
        var regions = new[] { new FrameRect(0, 0, 400, 300), new FrameRect(400, 0, 400, 300) };
        var safeRenderer = new PhotoRenderer(new(800, 300), settings, new TransitionController(), new AnimationScheduler(), regions);
        var facePhoto = Photo("face", 800, 1600) with { Faces = [new(.25, .1, .5, .5)] };
        try
        {
            Snapshot((FrameworkElement)safeRenderer.Content, 800, 300);
            var scene = safeRenderer.Build(new(CompositionMode.Gallery, new[] { facePhoto }), new[] { Solid(Colors.Red, 16, 32) }, new Random(1));
            await safeRenderer.ShowAsync(scene, CancellationToken.None);
            var replacement = facePhoto with { Path = "replacement", RawWidth = 1600, RawHeight = 800 };
            await safeRenderer.ReplaceSlotAsync(scene, 0, replacement, Solid(Colors.Blue, 32, 16), CancellationToken.None);
            var expected = FaceSafeLayout.Gallery(new[] { replacement }, new(800, 300), settings.Gap, regions).Single();
            Check(scene.Displays.Count == 0 && Math.Abs(Canvas.GetLeft(scene.Slots[0]) - expected.X) < .001
                && Math.Abs(scene.Slots[0].Width - expected.Width) < .001, "face-safe replacement stays a spanning Gallery with the calculated safe frame");
            var image = Snapshot((FrameworkElement)safeRenderer.Content, 800, 300);
            var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(image));
            using var stream = File.Create(Path.Combine(root, "face-safe-gallery.png")); encoder.Save(stream);
        }
        finally { safeRenderer.Clear(); safeRenderer.Close(); }

        FrameRect[] stacked = [new(0, 0, 800, 140), new(0, 160, 800, 140)];
        var stackedRenderer = new PhotoRenderer(new(800, 300), new WallSettings { GlassBackground = false }, new TransitionController(), new AnimationScheduler(), stacked);
        try
        {
            var scene = stackedRenderer.Build(new(CompositionMode.VerticalPan, new[] { facePhoto }), new[] { Solid(Colors.Red, 16, 32) }, new Random(1));
            var image = scene.MotionImage!; var frame = (Canvas)image.Parent;
            var translation = (TranslateTransform)((TransformGroup)image.RenderTransform).Children[1];
            Check(image.Height < 300 && Math.Abs(Canvas.GetTop(frame) - (300 - image.Height) / 2) > 1, "shortened vertical Pan uses the face-safe frame placement rather than wall centering");
            foreach (var face in facePhoto.Faces!)
            {
                var x = Canvas.GetLeft(frame) + translation.X + face.X * image.Width;
                var y = Canvas.GetTop(frame) + translation.Y + face.Y * image.Height;
                Check(stacked.Any(r => x >= r.X - .001 && y >= r.Y - .001 && x + face.Width * image.Width <= r.X + r.Width + .001
                    && y + face.Height * image.Height <= r.Y + r.Height + .001), "rendered vertical Pan face clears the horizontal display seam");
            }
        }
        finally { stackedRenderer.Clear(); stackedRenderer.Close(); }

        var monitors = MonitorManager.Enumerate().Take(2).ToArray(); Check(monitors.Length == 2, "two displays required");
        var folder = Path.Combine(root, "mode-photos"); Directory.CreateDirectory(folder);
        for (var i = 0; i < 4; i++)
        {
            File.Copy(Fixture($"mode-portrait-{i}.png", 800, 2000), Path.Combine(folder, $"portrait-{i}.png"), true);
            File.Copy(Fixture($"mode-wide-{i}.png", 4000, 800), Path.Combine(folder, $"wide-{i}.png"), true);
        }
        var config = new WallSettings { StartOnLaunch = false, Folders = [folder], FadeSeconds = .2, GalleryMinSeconds = 5, GalleryMaxSeconds = 5,
            GalleryPerDisplay = true, VerticalPanPerDisplay = true, HorizontalPanPerDisplay = true, ZoomPerDisplay = true,
            FaceAwarePanDirection = false, FaceAwareFraming = false, StopAtFace = false, CacheMegabytes = 64,
            Displays = monitors.Select(m => new DisplayPlacement { Id = m.Id, X = m.X, Y = m.Y, Width = m.Width, Height = m.Height, GroupId = "mode-group", HideTaskbar = false }).ToList() };
        var manager = new SettingsManager(); manager.Save(config);
        await using var controller = new WallController(config); await controller.InitializeAsync();
        var window = new DynamicPhotoWall.UI.SettingsWindow(controller, manager);
        try
        {
            window.Show(); ((System.Windows.Controls.TabControl)window.FindName("SettingsPages")).SelectedIndex = 4; window.UpdateLayout();
            foreach (var name in new[] { "Gallery", "GalleryScroll", "VerticalPan", "HorizontalPan", "Zoom" })
            {
                var check = (System.Windows.Controls.CheckBox)window.FindName(name + "PerDisplayCheck");
                Check(check.Content!.ToString() == "ディスプレイごとに表示", "every mode exposes the same checkbox");
                check.IsChecked = true;
            }
            var boundaryCheck = (System.Windows.Controls.CheckBox)window.FindName("AvoidFaceDisplayBoundariesCheck"); boundaryCheck.IsChecked = false;
            var save = (System.Windows.Controls.Button)window.FindName("SaveButton"); save.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Button.ClickEvent));
            await Until(() => save.IsEnabled && controller.Settings.GalleryScrollPerDisplay, 10000);
            var saved = manager.Load(); Check(Enum.GetValues<CompositionMode>().All(saved.IsPerDisplay) && !saved.AvoidFaceDisplayBoundaries, "checkboxes save independently through the settings window");
            foreach (var width in new[] { 1040d, 920d })
            { window.Width = width; window.Height = width == 920 ? 700 : 820; window.UpdateLayout(); SaveRender(window, $"mode-checkboxes-{width:0}.png"); }
        }
        finally { window.Close(); }
        var states = new List<object>();
        static void Only(WallSettings s, CompositionMode mode)
        {
            s.GalleryEnabled = mode == CompositionMode.Gallery; s.GalleryScrollEnabled = mode == CompositionMode.GalleryScroll;
            s.VerticalPanEnabled = mode == CompositionMode.VerticalPan; s.HorizontalPanEnabled = mode == CompositionMode.HorizontalPan; s.ZoomEnabled = mode == CompositionMode.Zoom;
        }
        foreach (var mode in Enum.GetValues<CompositionMode>())
        {
            var candidate = SettingsManager.Clone(config); Only(candidate, mode);
            await controller.ApplyAsync(candidate); await controller.StartAsync();
            await Until(() => controller.CurrentMode == mode, 15000);
            await Until(() => Application.Current.Windows.OfType<PhotoRenderer>().Any(r => r.Current?.Mode == mode && r.Current.Canvas.Opacity > .999), 10000);
            var state = controller.GroupStates.Single(); var perDisplay = candidate.IsPerDisplay(mode);
            Check(state.Mode == mode && state.PerDisplay == perDisplay && state.Surfaces.Count == (perDisplay ? monitors.Length : 1)
                && Application.Current.Windows.OfType<PhotoRenderer>().Any(r => r.Current?.Mode == mode && r.Current.Canvas.Opacity > .999), "actual session presents local scenes or the shared wall by mode");
            if (perDisplay) foreach (var monitor in monitors)
                Check(state.Surfaces.Single(s => s.DisplayId == monitor.Id).Viewport == new Viewport(monitor.Width, monitor.Height), "session renders each display at its physical resolution");
            states.Add(state);
            controller.TogglePause(); Check(controller.GroupStates.All(g => g.IsPaused), "group pause reaches all child surfaces"); controller.TogglePause();
            controller.Next();
        }
        var scrolling = SettingsManager.Clone(config); Only(scrolling, CompositionMode.GalleryScroll); scrolling.GalleryScrollPerDisplay = true; scrolling.GalleryScrollPixelsPerSecond = 200;
        await controller.ApplyAsync(scrolling); await controller.StartAsync();
        await Until(() => controller.CurrentMode == CompositionMode.GalleryScroll, 15000);
        Check(controller.GroupStates.Single().Surfaces.Count == 2, "Scrolling Gallery also supports per-screen rendering when enabled");
        var missing = SettingsManager.Clone(scrolling); missing.Displays[0].Id = "absent-mode-screen";
        await controller.ApplyAsync(missing); await controller.StartAsync(); await Until(() => controller.CurrentMode == CompositionMode.GalleryScroll, 15000);
        var reduced = controller.GroupStates.Single();
        Check(reduced.Surfaces.Count == 1 && reduced.Surfaces[0].DisplayId == monitors[1].Id && reduced.Viewport == new WallLayout(missing.Displays).Viewport, "disconnection preserves wall bounds while preparing only connected display scenes");
        var faceFolder = Path.Combine(root, "detected-face"); Directory.CreateDirectory(faceFolder);
        File.Copy("macos/DynamicPhotoWallTests/Fixtures/astronaut.png", Path.Combine(faceFolder, "astronaut.png"), true);
        var faceSettings = SettingsManager.Clone(config); Only(faceSettings, CompositionMode.Gallery);
        faceSettings.GalleryPerDisplay = false; faceSettings.Folders = [faceFolder]; faceSettings.AvoidFaceDisplayBoundaries = true;
        await controller.ApplyAsync(faceSettings); await controller.StartAsync();
        await Until(() => controller.CurrentMode == CompositionMode.Gallery, 15000);
        var live = Application.Current.Windows.OfType<PhotoRenderer>().Single(w => w.Current?.Mode == CompositionMode.Gallery);
        var detectedScene = live.Current!; Check(detectedScene.Displays.Count == 0 && detectedScene.Photos.Single().Faces?.Count > 0,
            "spanning Gallery prepares actual detected faces even with all motion face settings off");
        var faceFrame = detectedScene.Slots.Single(); var faceLayout = new WallLayout(faceSettings.Displays);
        foreach (var face in detectedScene.Photos.Single().Faces!)
        {
            var x = Canvas.GetLeft(faceFrame) + face.X * faceFrame.Width; var y = Canvas.GetTop(faceFrame) + face.Y * faceFrame.Height;
            Check(faceLayout.Regions.Values.Any(r => x >= r.X && y >= r.Y && x + face.Width * faceFrame.Width <= r.X + r.Width
                && y + face.Height * faceFrame.Height <= r.Y + r.Height), "actual detected Gallery face is rendered inside a connected display");
        }
        await Until(() => detectedScene.Canvas.Opacity > .999, 10000);
        Check(detectedScene.Canvas.Opacity > .999, "detected-face scene completes its presentation fade");
        var faceImage = Snapshot(detectedScene.Canvas, (int)faceLayout.Viewport.Width, (int)faceLayout.Viewport.Height);
        var faceEncoder = new PngBitmapEncoder(); faceEncoder.Frames.Add(BitmapFrame.Create(faceImage));
        using (var stream = File.Create(Path.Combine(root, "detected-face-spanning.png"))) faceEncoder.Save(stream);
        var faceMissing = SettingsManager.Clone(faceSettings); faceMissing.Displays[0].Id = "absent-face-screen";
        await controller.ApplyAsync(faceMissing); await controller.StartAsync(); await Until(() => controller.CurrentMode == CompositionMode.Gallery, 15000);
        var oneDisplayScene = Application.Current.Windows.OfType<PhotoRenderer>().Single(w => w.Current?.Mode == CompositionMode.Gallery).Current!;
        var connectedRegion = new WallLayout(faceMissing.Displays).Regions[monitors[1].Id]; var survivingSlot = oneDisplayScene.Slots.Single();
        Check(oneDisplayScene.DisplayRegions.Count == 1 && oneDisplayScene.Photos.Single().Faces?.Count > 0, "a disconnected wall still prepares face protection on its one surviving screen");
        foreach (var face in oneDisplayScene.Photos.Single().Faces!)
        {
            var x = Canvas.GetLeft(survivingSlot) + face.X * survivingSlot.Width; var y = Canvas.GetTop(survivingSlot) + face.Y * survivingSlot.Height;
            Check(x >= connectedRegion.X && y >= connectedRegion.Y && x + face.Width * survivingSlot.Width <= connectedRegion.X + connectedRegion.Width
                && y + face.Height * survivingSlot.Height <= connectedRegion.Y + connectedRegion.Height, "faces never get assigned to the disconnected wall area");
        }
        await controller.ShowTestPatternAsync(config); Check(controller.TestPatternVisible && controller.GroupStates.Single().Mode == null, "alignment preview ignores mode-specific rendering");
        await controller.StopAsync(); Check(!controller.IsRunning && controller.GroupStates.Count == 0, "stop clears every local surface");
        File.WriteAllText(Path.Combine(root, "mode-routing-states.json"), JsonSerializer.Serialize(states, new JsonSerializerOptions { WriteIndented = true }));
    }
    private static async Task GroupDeletionAsync()
    {
        var monitors = MonitorManager.Enumerate(); Check(monitors.Count > 0, "display required");
        var settings = new WallSettings { StartOnLaunch = false, DisplayGroupNames = ["連結", "予備", "残す"],
            Displays = monitors.Select(m => new DisplayPlacement { Id = m.Id, X = m.X, Y = m.Y, Width = m.Width, Height = m.Height, GroupId = "連結", HideTaskbar = false }).ToList() };
        var manager = new SettingsManager(); manager.Save(settings); var originalFile = File.ReadAllText(manager.FilePath);
        await using var controller = new WallController(settings);
        var window = new DynamicPhotoWall.UI.SettingsWindow(controller, manager);
        try
        {
            window.Show(); ((System.Windows.Controls.TabControl)window.FindName("SettingsPages")).SelectedIndex = 2; window.UpdateLayout();
            var editor = (DynamicPhotoWall.UI.DisplayLayoutEditor)((System.Windows.Controls.ContentControl)window.FindName("DisplayEditorHost")).Content;
            void Delete(string name) => VisualDescendants<System.Windows.Controls.Button>(editor)
                .Single(b => b.Name == "RemoveGroupButton" && (string)b.Tag == name).RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Button.ClickEvent));
            var add = VisualDescendants<System.Windows.Controls.Button>(editor).Single(b => b.Name == "AddGroupButton");
            add.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Button.ClickEvent));
            Delete("グループ1"); Check(editor.GroupNames.Count == 3 && !editor.GroupNames.Contains("グループ1"), "new unassigned group deleted by its button");
            Delete("予備"); editor.Load(settings); window.UpdateLayout();
            Check(!editor.GroupNames.Contains("予備") && editor.GroupNames.Count == 2, "refresh must not resurrect deleted saved group");
            var hiddenChoice = editor.Choices.Count > 1 ? editor.Choices.Last() : null;
            if (hiddenChoice != null) hiddenChoice.Selected = false;
            var before = editor.Choices.Select(c => (c.Id, c.Selected, c.X, c.Y, c.HideTaskbar)).ToArray();
            Delete("連結"); window.UpdateLayout();
            Check(editor.Choices.All(c => c.GroupId == null) && before.SequenceEqual(editor.Choices.Select(c => (c.Id, c.Selected, c.X, c.Y, c.HideTaskbar))), "assigned deletion only clears membership, including deselected screens");
            if (hiddenChoice != null) hiddenChoice.Selected = true;
            Check(VisualDescendants<System.Windows.Controls.ComboBox>(editor).All(p => p.Text == "独立して表示"), "assignment pickers immediately show independent display");
            Check(controller.Settings.Displays.All(d => d.GroupId == "連結") && File.ReadAllText(manager.FilePath) == originalFile, "deletion stays in draft until saved");
            // A separate editor represents closing without saving: old groups survive.
            var cancelled = new DynamicPhotoWall.UI.DisplayLayoutEditor(); cancelled.Load(manager.Load());
            Check(cancelled.GroupNames.Contains("連結") && cancelled.GroupNames.Contains("予備"), "unsaved deletion does not modify persisted catalog");
            Delete("残す"); editor.Load(settings); window.UpdateLayout();
            Check(editor.GroupNames.Count == 0 && VisualDescendants<System.Windows.Controls.TextBlock>(editor).Any(t => t.Text == "グループ一覧（0）"), "last group stays deleted after refresh");
            Check(!editor.RemoveGroup("不存在"), "unknown group deletion is harmless");
            var saveButton = (System.Windows.Controls.Button)window.FindName("SaveButton");
            saveButton.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Button.ClickEvent));
            await Until(() => saveButton.IsEnabled && controller.Settings.DisplayGroupNames.Count == 0, 10000);
            var reloaded = manager.Load();
            Check(saveButton.IsEnabled && controller.Settings.DisplayGroupNames.Count == 0 && reloaded.DisplayGroupNames.Count == 0 && reloaded.Displays.Count == monitors.Count
                && reloaded.Displays.All(d => d.GroupId == null), "save removes catalog and assignments without losing selected screens");
            var reopened = new DynamicPhotoWall.UI.DisplayLayoutEditor(); reopened.Load(reloaded);
            Check(reopened.GroupNames.Count == 0 && reopened.SelectedPlacements().All(d => d.GroupId == null), "reopening does not create a phantom default group");
            reopened.AddGroup(); Check(reopened.GroupNames.SequenceEqual(new[] { "グループ1" }), "adding after deleting all reuses first available number");
            SaveRender(window, "groups-deleted.png");
        }
        finally { window.Close(); }
    }
    private static async Task TestPatternToggleAsync()
    {
        var monitors = MonitorManager.Enumerate().Take(2).ToArray(); Check(monitors.Length > 0, "display required");
        var settings = new WallSettings { StartOnLaunch = false, DisplayGroupNames = ["グループ1", "予備"],
            Displays = monitors.Select(m => new DisplayPlacement { Id = m.Id, X = m.X, Y = m.Y, Width = m.Width, Height = m.Height, HideTaskbar = false }).ToList() };
        var manager = new SettingsManager(); manager.Save(settings); var originalFile = File.ReadAllText(manager.FilePath); var originalX = settings.Displays[0].X;
        await using var controller = new WallController(settings); await controller.InitializeAsync();
        var window = new DynamicPhotoWall.UI.SettingsWindow(controller, manager);
        try
        {
            window.Show(); ((System.Windows.Controls.TabControl)window.FindName("SettingsPages")).SelectedIndex = 2; window.UpdateLayout();
            var editor = (DynamicPhotoWall.UI.DisplayLayoutEditor)((System.Windows.Controls.ContentControl)window.FindName("DisplayEditorHost")).Content;
            var add = VisualDescendants<System.Windows.Controls.Button>(editor).First(b => b.Name == "AddGroupButton");
            add.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Button.ClickEvent));
            Check(editor.GroupNames.Count == 3 && VisualDescendants<System.Windows.Controls.TextBlock>(editor).Any(t => t.Text == "グループ一覧（3）"), "unassigned added group is immediately listed and counted");
            editor.Choices.First(c => c.Selected).X += 96;
            var expected = new WallLayout(editor.SelectedPlacements()).Viewport;
            var button = (System.Windows.Controls.Button)window.FindName("TestPatternButton");
            Check((string)button.Content == "表示", "initial button caption");
            button.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Button.ClickEvent));
            await Until(() => controller.TestPatternVisible && button.IsEnabled, 10000);
            Check(controller.IsRunning && controller.TestPatternVisible && (string)button.Content == "表示停止", "click starts pattern immediately without photos");
            Check(controller.GroupStates.Single().Viewport == expected && controller.Settings.Displays[0].X == originalX, "pattern uses draft geometry while keeping saved configuration");
            Check(File.ReadAllText(manager.FilePath) == originalFile, "preview must never save settings");
            SaveRender(window, "test-pattern-button-visible.png");
            button.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Button.ClickEvent));
            await Until(() => !controller.TestPatternVisible && button.IsEnabled, 10000);
            Check(!controller.IsRunning && (string)button.Content == "表示" && File.ReadAllText(manager.FilePath) == originalFile, "second click stops preview and remains stopped without saving");
            var independent = SettingsManager.Clone(settings); independent.Displays.ForEach(d => d.GroupId = null);
            await controller.ShowTestPatternAsync(independent);
            Check(controller.GroupStates.Count == monitors.Length && controller.GroupStates.All(g => g.IsRunning && g.DisplayIds.Count == 1), "pattern supports separate display groups");
            await controller.HideTestPatternAsync();
            ((System.Windows.Controls.Button)window.FindName("SaveButton")).RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Button.ClickEvent));
            await Until(() => controller.Settings.DisplayGroupNames.Contains("グループ2"), 10000);
            var loaded = manager.Load();
            Check(loaded.DisplayGroupNames.Contains("予備") && loaded.DisplayGroupNames.Contains("グループ2") && !loaded.DisplayTestPattern, "empty groups persist while test pattern is transient");
            var folder = Path.Combine(root, "preview-photos"); Directory.CreateDirectory(folder);
            File.Copy(Fixture("preview-landscape.png", 1200, 800), Path.Combine(folder, "photo.png"), true);
            var photos = SettingsManager.Clone(controller.Settings); photos.Folders = [folder]; photos.GalleryWeight = 0; photos.PanWeight = 0; photos.ZoomWeight = 100; photos.FaceAwareFraming = false; photos.FadeSeconds = .2;
            await controller.ApplyAsync(photos); await controller.StartAsync(); await Until(() => controller.CurrentMode == CompositionMode.Zoom, 10000);
            Check(controller.CurrentMode == CompositionMode.Zoom, "normal playback before preview"); controller.TogglePause();
            button.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Button.ClickEvent)); await Until(() => controller.TestPatternVisible && button.IsEnabled, 10000);
            Check(controller.TestPatternVisible, "preview replaces running photos");
            button.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Button.ClickEvent)); await Until(() => !controller.TestPatternVisible && button.IsEnabled && controller.CurrentMode == CompositionMode.Zoom, 10000);
            Check(controller.IsRunning && controller.IsPaused && controller.GroupStates.All(g => g.IsPaused), "preview stop restores previous running and paused state");
            var disconnected = SettingsManager.Clone(photos); disconnected.Displays.ForEach(d => d.Id = Guid.NewGuid().ToString());
            try { await controller.ShowTestPatternAsync(disconnected); throw new Exception("unconnected preview accepted"); } catch (InvalidOperationException) { }
            Check(controller.IsRunning && !controller.TestPatternVisible && controller.CurrentMode == CompositionMode.Zoom, "invalid preview leaves normal playback intact");
            await controller.ShowTestPatternAsync(photos); await controller.StopAsync();
            Check(!controller.TestPatternVisible && !controller.IsRunning && (string)button.Content == "表示", "global stop clears preview and caption");
            await controller.ShowTestPatternAsync(photos); await controller.StartAsync(); await Until(() => controller.CurrentMode == CompositionMode.Zoom, 10000);
            Check(!controller.TestPatternVisible && controller.IsRunning && !controller.IsPaused && controller.CurrentMode == CompositionMode.Zoom, "normal start exits preview and resumes photos");
            var old = SettingsManager.Clone(photos); old.DisplayTestPattern = true; manager.Save(old);
            Check(!manager.Load().DisplayTestPattern, "legacy persisted pattern cannot restart on launch");
        }
        finally { window.Close(); await controller.StopAsync(); }
    }
    private static async Task DisplayCropsAsync()
    {
        var settings = new WallSettings { GlassBackground = true, Gap = 8, FadeSeconds = .2 };
        var transitions = new TransitionController(); var scheduler = new AnimationScheduler();
        var renderer = new PhotoRenderer(new(960, 240), settings, transitions, scheduler);
        var placements = new List<DisplayPlacement> { new() { Id = "left", Width = 480, Height = 240 }, new() { Id = "right", X = 480, Width = 480, Height = 240 } };
        var layout = new WallLayout(placements);
        renderer.ShowTestPattern(layout);
        var full = Snapshot((FrameworkElement)renderer.Content, 960, 240);
        renderer.SetDisplayRegion(layout.Regions["right"]);
        var primary = (FrameworkElement)renderer.Content;
        var secondary = renderer.CreateDisplayRegion(layout.Regions["left"]);
        void Compare(BitmapSource expected)
        {
            var expectedPixels = new byte[960 * 240 * 4]; expected.CopyPixels(expectedPixels, 960 * 4, 0);
            foreach (var (element, offset) in new[] { (primary, 480), (secondary, 0) })
            {
                var crop = Snapshot(element, 480, 240); var actual = new byte[480 * 240 * 4]; crop.CopyPixels(actual, 480 * 4, 0);
                var diagnostics = new PngBitmapEncoder(); diagnostics.Frames.Add(BitmapFrame.Create(crop));
                using (var file = File.Create(Path.Combine(root, $"crop-{offset}.png"))) diagnostics.Save(file);
                for (var y = 0; y < 240; y++) for (var x = 0; x < 480; x++) for (var c = 0; c < 4; c++)
                    Check(Math.Abs(actual[(y * 480 + x) * 4 + c] - expectedPixels[(y * 960 + offset + x) * 4 + c]) <= 1, $"crop pixel differs at {offset + x},{y} channel {c}: actual {actual[(y * 480 + x) * 4 + c]}, expected {expectedPixels[(y * 960 + offset + x) * 4 + c]}");
            }
        }
        Compare(full);
        renderer.Clear();
        var photo = MetadataExtractor.Read(Fixture("crop-motion.png", 1600, 240));
        var cache = new ImageCache();
        var image = (await cache.LoadAsync(photo, 1600, CancellationToken.None))!;
        // A full-canvas VisualBrush gives a reference without reparenting the animated tree.
        var reference = renderer.CreateDisplayRegion(new(0, 0, 960, 240));
        Snapshot(primary, 480, 240);
        var scene = renderer.Build(new(CompositionMode.HorizontalPan, [photo]), [image], new Random(1));
        try
        {
            await renderer.ShowAsync(scene, CancellationToken.None);
            await Task.Delay(150); transitions.SetPaused(true); scheduler.SetPaused(true);
            Compare(Snapshot(reference, 960, 240));
            var output = Snapshot(secondary, 480, 240); var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(output));
            using var stream = File.Create(Path.Combine(root, "display-crop.png")); encoder.Save(stream);
        }
        finally { renderer.Clear(); renderer.Close(); await cache.ClearAsync(); }
    }
    private static async Task MultiDisplayDesktopAsync()
    {
        var monitors = MonitorManager.Enumerate();
        Check(monitors.Count >= 2, "two connected displays required for desktop acceptance");
        var settings = new WallSettings { DisplayTestPattern = true, HideTaskbar = false,
            Displays = monitors.Select(m => new DisplayPlacement { Id = m.Id, X = m.X, Y = m.Y, Width = m.Width, Height = m.Height }).ToList() };
        await MultiDisplayCompositorAsync(monitors, new WallLayout(settings.Displays));
        await using var controller = new WallController(settings);
        await controller.InitializeAsync();
        Check(controller.IsRunning && controller.Status.Contains($"{monitors.Count}画面"), "all selected outputs running without photos");
        await Task.Delay(700);
        var ui = new DynamicPhotoWall.UI.SettingsWindow(controller, new SettingsManager());
        try
        {
            ui.Show(); await Task.Delay(200);
            var bitmap = Snapshot(ui, (int)ui.ActualWidth, (int)ui.ActualHeight);
            var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap));
            using var stream = File.Create(Path.Combine(root, "multi-display-settings.png")); encoder.Save(stream);
        }
        finally { ui.Close(); }
        var missing = SettingsManager.Clone(settings);
        missing.Displays[0].Id = "disconnected-test-display";
        await controller.ApplyAsync(missing);
        Check(controller.IsRunning && controller.Status.Contains("未接続画面の領域を保持中"), "remaining outputs preserve absent region");
        await controller.ApplyAsync(settings);
        Check(controller.IsRunning && controller.Status.Contains($"{monitors.Count}画面"), "outputs recreate on reconnect");
        await controller.StopAsync(); Check(!controller.IsRunning, "all outputs stop");
        var taskbarsBefore = monitors.SelectMany(TaskbarVisibility.Query).ToArray();
        var fullscreen = SettingsManager.Clone(settings); fullscreen.HideTaskbar = true;
        await controller.ApplyAsync(fullscreen); await controller.StartAsync();
        try
        {
            foreach (var monitor in monitors.Where(m => !ExplorerRecovery.IsCovered(m)))
                Check(TaskbarVisibility.Query(monitor).All(b => !b.Visible), $"taskbar remains visible on {monitor.Device}");
        }
        finally { await controller.StopAsync(); }
        var taskbarsAfter = monitors.SelectMany(TaskbarVisibility.Query).ToArray();
        File.WriteAllText(Path.Combine(root, "multi-taskbar-restore.json"), JsonSerializer.Serialize(new { Before = taskbarsBefore, After = taskbarsAfter }, new JsonSerializerOptions { WriteIndented = true }));
        Check(taskbarsAfter.All(b => taskbarsBefore.Any(before => before.Handle == b.Handle && before.Visible == b.Visible)), "all selected taskbars restored");
        // Exercise all display consumers with one shared photo scene and clocks.
        settings.DisplayTestPattern = false; settings.Folders = [root]; settings.GalleryWeight = 0; settings.PanWeight = 0; settings.ZoomWeight = 100; settings.FadeSeconds = .2;
        await controller.ApplyAsync(settings); await controller.StartAsync();
        await Until(() => controller.CurrentMode == CompositionMode.Zoom, 10000);
        Check(controller.CurrentMode == CompositionMode.Zoom && controller.DisplayedPhotoPaths.Count == 1, "common scene ready");
        controller.TogglePause(); Check(controller.IsPaused, "shared pause"); controller.TogglePause(); controller.Next();
        await controller.StopAsync();
    }
    private static async Task DisplayGroupsDesktopAsync()
    {
        IReadOnlyList<MonitorDescriptor> monitors = MonitorManager.Enumerate().Take(3).ToArray(); Check(monitors.Count >= 3, "three displays required for grouping acceptance");
        var before = monitors.SelectMany(TaskbarVisibility.Query).ToArray();
        var placements = monitors.Select((m, i) => new DisplayPlacement { Id = m.Id, X = m.X, Y = m.Y, Width = m.Width, Height = m.Height, GroupId = i < 2 ? "連結" : null, HideTaskbar = i == 2 }).ToList();
        var settings = new WallSettings { Displays = placements, DisplayTestPattern = true, HideTaskbar = true, FadeSeconds = .2 };
        var editor = new DynamicPhotoWall.UI.DisplayLayoutEditor(); editor.Load(settings);
        Check(editor.Choices.Count(c => c.Selected && c.GroupId == "連結") == 2 && editor.Choices.Any(c => c.Selected && c.GroupId == null && c.HideTaskbar), "editor loads group membership separately from taskbar visibility");
        editor.Load(settings);
        Check(editor.SelectedPlacements().All(p => p.GroupId == settings.Displays.First(d => d.Id == p.Id).GroupId && p.HideTaskbar == settings.Displays.First(d => d.Id == p.Id).HideTaskbar), "refresh preserves independent and taskbar choices");
        await using var controller = new WallController(settings);
        try
        {
            await controller.InitializeAsync();
            var states = controller.GroupStates;
            Check(states.Count == 2 && states.All(g => g.IsRunning), "linked and independent playback sessions running");
            Check(states[0].DisplayIds.Count == 2 && states[1].DisplayIds.Count == monitors.Count - 2, "membership matches selected grouping");
            Check(states[0].Viewport == new WallLayout(placements.Take(2).ToArray()).Viewport && states[1].Viewport == new Viewport(monitors[2].Width, monitors[2].Height), "separate viewport sizes");
            foreach (var monitor in monitors)
            {
                var hide = placements.First(p => p.Id == monitor.Id).HideTaskbar == true && !ExplorerRecovery.IsCovered(monitor);
                Check(TaskbarVisibility.Query(monitor).All(b => hide ? !b.Visible : before.Any(old => old.Handle == b.Handle && old.Visible == b.Visible)), "taskbar setting must apply only on its own display");
            }
            var ui = new DynamicPhotoWall.UI.SettingsWindow(controller, new SettingsManager());
            try
            {
                ui.Show(); await Task.Delay(200); SaveRender(ui, "display-groups-settings.png");
                // Capture the editor separately so every per-display option can be reviewed.
                var image = Snapshot(editor, 730, 1050); var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(image));
                using var stream = File.Create(Path.Combine(root, "display-groups-editor.png")); encoder.Save(stream);
            }
            finally { ui.Close(); }
            var missing = SettingsManager.Clone(settings); missing.Displays[0].Id = "absent-group-member";
            await controller.ApplyAsync(missing);
            Check(controller.GroupStates.Count == 2 && controller.GroupStates.All(g => g.IsRunning)
                && controller.GroupStates[0].Viewport == states[0].Viewport && controller.GroupStates[1].Viewport == states[1].Viewport
                && controller.GroupStates[0].DisplayIds.Contains("absent-group-member"), "one group loses a member without merging independent playback");
            await controller.ApplyAsync(settings);
            controller.TogglePause(); Check(controller.GroupStates.All(g => g.IsPaused), "user pause reaches every group");
            controller.TogglePause(); controller.Next();
            var folder = Path.Combine(root, "group-photos"); Directory.CreateDirectory(folder);
            File.Copy(Fixture("groups-photo.png", 1600, 1000), Path.Combine(folder, "photo.png"), true);
            var photos = SettingsManager.Clone(settings); photos.Folders = [folder]; photos.DisplayTestPattern = false;
            photos.GalleryWeight = 0; photos.PanWeight = 0; photos.ZoomWeight = 100; photos.FaceAwareFraming = false;
            await controller.ApplyAsync(photos);
            await Until(() => controller.GroupStates.All(g => g.Mode == CompositionMode.Zoom), 10000);
            Check(controller.GroupStates.All(g => g.Mode == CompositionMode.Zoom && g.PhotoPaths.Count == 1), "every group builds its own scene from shared library");
            var separate = SettingsManager.Clone(settings); foreach (var p in separate.Displays) p.GroupId = null;
            await controller.ApplyAsync(separate);
            Check(controller.GroupStates.Count == monitors.Count && controller.GroupStates.All(g => g.IsRunning && g.DisplayIds.Count == 1), "every ungrouped display has its own session");
            var saved = new SettingsManager(); saved.Save(separate); var reloaded = saved.Load();
            Check(reloaded.Displays.All(p => p.GroupId == null) && reloaded.Displays.Last().HideTaskbar == true, "group and taskbar settings survive reload");
        }
        finally { await controller.StopAsync(); }
        Check(monitors.SelectMany(TaskbarVisibility.Query).All(b => before.Any(old => old.Handle == b.Handle && old.Visible == b.Visible)), "stop restores every owned taskbar");
    }
    private static async Task MultiDisplayCompositorAsync(IReadOnlyList<MonitorDescriptor> monitors, WallLayout layout)
    {
        var renderer = new PhotoRenderer(layout.Viewport, new WallSettings { Background = "#FF00FF" }, new TransitionController(), new AnimationScheduler());
        renderer.SetDisplayRegion(layout.Regions[monitors[0].Id]);
        var hosts = new List<DesktopWindowHost>();
        var windows = new List<Window>();
        var samples = new List<object>();
        var missing = new List<string>();
        try
        {
            foreach (var monitor in monitors)
            {
                var host = new DesktopWindowHost(); hosts.Add(host);
                var window = hosts.Count == 1 ? renderer : new Window { Content = renderer.CreateDisplayRegion(layout.Regions[monitor.Id]), Background = Brushes.Black };
                windows.Add(window); host.Attach(window, monitor);
            }
            await Task.Delay(500);
            foreach (var monitor in monitors)
            {
                var previous = SetThreadDpiAwarenessContext(new nint(-4)); var dc = GetDC(0); var matching = 0; var exposed = 0; var colors = new List<string>(); var covering = new List<string>();
                try
                {
                    foreach (var x in new[] { .2, .5, .8 }) foreach (var y in new[] { .2, .5, .8 })
                    {
                        var point = new System.Drawing.Point(monitor.X + (int)(monitor.Width * x), monitor.Y + (int)(monitor.Height * y));
                        var color = GetPixel(dc, point.X, point.Y);
                        var top = GetAncestor(WindowFromPoint(point), 2); var className = new System.Text.StringBuilder(128); GetClassName(top, className, className.Capacity);
                        covering.Add(className.ToString());
                        if (className.ToString() is "Progman" or "WorkerW") exposed++;
                        colors.Add($"{color:X6}"); if (color == 0xFF00FF) matching++;
                    }
                }
                finally { ReleaseDC(0, dc); SetThreadDpiAwarenessContext(previous); }
                var covered = ExplorerRecovery.IsCovered(monitor);
                var window = windows[monitors.ToList().IndexOf(monitor)];
                SaveRender(window, $"multi-view-{monitor.Device[^1]}.png");
                samples.Add(new { Monitor = monitor.Device, monitor.Width, monitor.Height, Covered = covered, MagentaPixels = matching, ExposedSamples = exposed, Samples = 9, Colors = colors, CoveringClasses = covering, window.ActualWidth, window.ActualHeight });
                Console.WriteLine($"Multi-display compositor {monitor.Device}: {matching}/9 visible, exposed samples={exposed}, covered={covered}");
                if (exposed > 0 && matching == 0) missing.Add(monitor.Device);
            }
            Check(missing.Count == 0, $"common source not presented on uncovered displays {string.Join(", ", missing)}");
        }
        finally
        {
            File.WriteAllText(Path.Combine(root, "multi-display-compositor.json"), JsonSerializer.Serialize(new { Viewport = layout.Viewport, Samples = samples, Hosts = hosts.Select(h => h.Inspect()).ToArray() }, new JsonSerializerOptions { WriteIndented = true }));
            renderer.Clear(); foreach (var host in hosts.AsEnumerable().Reverse()) host.Dispose();
        }
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
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern nint WindowFromPoint(System.Drawing.Point point);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern nint GetAncestor(nint window, uint flags);
    [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] private static extern int GetClassName(nint window, System.Text.StringBuilder text, int capacity);
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
        var visibleFace = MotionEngine.PrimaryFace(person!)!;
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
            DetectedFaceCount = person!.Faces!.Count, FaceTop = faceTop, FaceBottom = faceBottom, ViewportHeight = viewport.Height,
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

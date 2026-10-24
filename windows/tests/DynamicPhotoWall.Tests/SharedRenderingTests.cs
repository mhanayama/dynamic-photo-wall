using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Threading;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using DynamicPhotoWall.Core;
using DynamicPhotoWall.Motion;
using DynamicPhotoWall.Networking.Windows;
using DynamicPhotoWall.Rendering;
using Net = DynamicPhotoWall.Networking;

namespace DynamicPhotoWall.Tests;

internal static class SharedRenderingTests
{
    private static readonly Guid peer = Guid.NewGuid(), group = Guid.NewGuid();
    private static readonly Net.SharedAssetKey key = new(peer, Guid.NewGuid(), Guid.NewGuid(), new string('a', 64));
    private static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }
    private static BitmapSource Texture(bool alpha = false, bool blue = false, int width = 8, int height = 4)
    {
        var pixels = new byte[width * height * 4];
        for (var i = 0; i < pixels.Length; i += 4)
        {
            var a = alpha ? (byte)(80 + i / 4 % 160) : (byte)255;
            pixels[i] = (byte)(((blue ? 130 : 20) + i / 4 % 8 * 10) * a / 255);
            pixels[i + 1] = (byte)((40 + i / (4 * width) % 4 * 20) * a / 255);
            pixels[i + 2] = (byte)(((blue ? 20 : 130) + i / 4 % 4 * 20) * a / 255); pixels[i + 3] = a;
        }
        var bitmap = BitmapSource.Create(width, height, 96, 96, PixelFormats.Pbgra32, null, pixels, width * 4); bitmap.Freeze(); return bitmap;
    }
    private static byte[] Png(BitmapSource texture)
    {
        var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(texture));
        using var stream = new MemoryStream(); encoder.Save(stream); return stream.ToArray();
    }
    private static Net.SharedScenePlan Plan(bool perDisplay, bool alpha, Net.SceneMode mode)
    {
        Net.PeerDisplay[] displays = [new(new(peer, "a"), true, group, 0, 0, 32, 24), new(new(peer, "b"), true, group, 32, 0, 32, 24)];
        var ids = perDisplay ? displays.Select(d => (string?)d.Key.LayoutId).ToArray() : [null];
        var placements = ids.SelectMany((id, n) => new[] {
            new Net.ScenePlacement(n * 2, key, id, new(perDisplay ? n * 32 : 0, 0, perDisplay ? 32 : 64, 24), 48, 30,
                perDisplay ? n * 32 - 8 : -8, -3, perDisplay ? n * 32 - 16 : -16, -5, 1, 1.25, .3, .7, 1, 5, 0, 6, .6, 3, true),
            new Net.ScenePlacement(n * 2 + 1, key, id, new(perDisplay ? n * 32 : 0, 0, perDisplay ? 32 : 64, 24), 40, 26,
                perDisplay ? n * 32 : 3, 0, perDisplay ? n * 32 : 3, 0, 1, 1, .5, .5, 5, 5, 5, 10, .7, 2, false) });
        var ambient = ids.SelectMany(id => new[] { new Net.AmbientFrame(0, Png(Texture(alpha))) { DisplayId = id },
            new Net.AmbientFrame(10, Png(Texture(alpha, blue: true))) { DisplayId = id } }).ToArray();
        return new(Guid.NewGuid(), group, Guid.NewGuid(), 0, mode, new(64, 24), displays, 10, .8, "#223344", placements.ToArray(), ambient);
    }
    private static SharedVisual Build(Net.SharedScenePlan plan, bool optimized, bool photoAlpha = false)
        => SharedSceneBuilder.Build(plan, new Dictionary<string, BitmapSource> { [key.OpaqueId] = Texture(photoAlpha) }, plan.Displays.Select(d => d.Key.LayoutId).ToArray(), optimized);
    private static byte[] Pixels(SharedVisual visual, int output, bool optimized)
    {
        var surface = visual.Scene.Displays.Count == 0 ? visual.Scene : visual.Scene.Displays[output];
        surface.Canvas.Measure(new Size(surface.Viewport.Width, surface.Viewport.Height));
        surface.Canvas.Arrange(new Rect(0, 0, surface.Viewport.Width, surface.Viewport.Height)); surface.Canvas.UpdateLayout();
        var region = new Rect(visual.Scene.Displays.Count == 0 ? output * 32 : 0, 0, 32, 24);
        TileBrush brush = new VisualBrush(surface.Canvas) { AutoLayoutContent = false };
        brush.ViewboxUnits = BrushMappingMode.Absolute; brush.Viewbox = region; brush.Stretch = Stretch.Fill;
        var drawing = new DrawingVisual(); using (var dc = drawing.RenderOpen())
        {
            dc.DrawRectangle(Brushes.Black, null, new Rect(0, 0, 32, 24));
            if (!optimized)
            {
                dc.PushOpacity(visual.Scene.Displays.Count > 0 ? visual.Scene.Canvas.Opacity : 1);
                dc.DrawRectangle(brush, null, new Rect(0, 0, 32, 24)); dc.Pop();
            }
        }
        var bitmap = new RenderTargetBitmap(32, 24, 96, 96, PixelFormats.Pbgra32); bitmap.Render(drawing);
        if (optimized)
        {
            var presenter = new SharedDrawingPresenter(surface.Drawing!, region, 32, 24)
                { Opacity = visual.Scene.Displays.Count > 0 ? visual.Scene.Canvas.Opacity : 1 };
            presenter.Measure(new Size(32, 24)); presenter.Arrange(new Rect(0, 0, 32, 24)); presenter.UpdateLayout(); bitmap.Render(presenter);
        }
        var pixels = new byte[32 * 24 * 4]; bitmap.CopyPixels(pixels, 32 * 4, 0); return pixels;
    }
    public static async Task PreparedBackgrounds()
    {
        var uiThread = Environment.CurrentManagedThreadId;
        var renderer = new PhotoRenderer(new(64, 24), new WallSettings(), new TransitionController(), new AnimationScheduler());
        try
        {
            foreach (var alpha in new[] { false, true })
            {
                var plan = Plan(true, alpha, Net.SceneMode.Gallery);
                var reference = Build(plan, false, alpha);
                var prepared = await Task.Run(() =>
                {
                    Check(Environment.CurrentManagedThreadId != uiThread, "background decoding runs away from the presentation dispatcher");
                    return PreparedAmbientTextures.Create(plan, plan.Displays.Select(d => d.Key.LayoutId).ToArray());
                });
                Check(plan.Ambient.All(f => prepared[f].Texture.IsFrozen), "all prepared textures are safe to share across dispatchers");
                Check(ReferenceEquals(prepared[plan.Ambient[0]].Texture, prepared[plan.Ambient[2]].Texture),
                    "identical PNG samples across displays still share one frozen texture");
                Check(plan.Ambient.All(f => prepared[f].Opaque != alpha), "preparation preserves alpha classification");
                foreach (var frame in plan.Ambient) Array.Clear(frame.Png);
                var images = new Dictionary<string, BitmapSource> { [key.OpaqueId] = Texture(alpha) };
                var ids = plan.Displays.Select(d => d.Key.LayoutId).ToArray();
                var candidate = SharedSceneBuilder.Build(plan, images, ids, prepared);
                // Also exercise rebuilding a retained scene without reading its PNG inputs.
                var rebuilt = SharedSceneBuilder.Build(plan, images, ids, candidate.AmbientTextures);
                foreach (var at in new[] { 0, .4, 2, 5, 9.6, 10, 20d })
                {
                    renderer.PresentShared(reference, at); renderer.PresentShared(candidate, at); renderer.PresentShared(rebuilt, at);
                    for (var output = 0; output < 2; output++)
                    {
                        var expected = Pixels(reference, output, false);
                        Check(expected.Zip(Pixels(candidate, output, true)).Max(p => Math.Abs(p.First - p.Second)) <= 2,
                            "worker-prepared background preserves both outputs, color, fades and transparency");
                        Check(Pixels(candidate, output, true).SequenceEqual(Pixels(rebuilt, output, true)),
                            "recovery reuses decoded background textures without changing pixels");
                    }
                }
            }
            var localPlan = Plan(true, false, Net.SceneMode.Gallery);
            var local = localPlan.Displays[0].Key.LayoutId;
            localPlan = localPlan with { Ambient = localPlan.Ambient.Select(f => f.DisplayId == local ? f : f with { Png = [0] }).ToArray() };
            PreparedAmbientTextures.Create(localPlan, [local]); // Remote PNGs are deliberately not decodable.
            using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
            try { PreparedAmbientTextures.Create(localPlan, [local], cancelled.Token); throw new Exception("Cancelled background preparation completed"); }
            catch (OperationCanceledException) { }
        }
        finally { renderer.Clear(); renderer.Close(); }
    }
    public static Task Parity()
    {
        var renderer = new PhotoRenderer(new(64, 24), new WallSettings(), new TransitionController(), new AnimationScheduler());
        var count = 0; var maximum = 0;
        try
        {
            foreach (var perDisplay in new[] { false, true }) foreach (var alpha in new[] { false, true })
            foreach (var mode in Enum.GetValues<Net.SceneMode>())
            {
                var plan = Plan(perDisplay, alpha, mode); plan.Validate();
                var before = Build(plan, false, alpha); var after = Build(plan, true, alpha);
                foreach (var at in new[] { 0, .4, .8, .9999, 1, 2.2, 4.9999, 5, 5.3, 5.9999, 6, 8, 9.6, 10, 30, 3, 0d })
                {
                    renderer.PresentShared(before, at); renderer.PresentShared(after, at);
                    for (var output = 0; output < 2; output++)
                    {
                        var a = Pixels(before, output, false); var b = Pixels(after, output, true);
                        var difference = a.Zip(b).Max(p => Math.Abs(p.First - p.Second)); maximum = Math.Max(maximum, difference);
                        Check(difference <= 2, $"direct drawing differs at {at}, perDisplay={perDisplay}, alpha={alpha}, mode={mode}, output={output}, delta={difference}"); count++;
                    }
                    for (var i = 0; i < before.Photos.Count; i++)
                    {
                        Check(before.Photos[i].Image.Opacity == after.Photos[i].Image.Opacity, "active set preserves every photo's opacity across seeks and endpoints");
                        if (after.Photos[i].Image.Opacity > 0)
                            Check(before.Photos[i].Translation.X == after.Photos[i].Translation.X && before.Photos[i].Scale.ScaleX == after.Photos[i].Scale.ScaleX, "active geometry matches the shared evaluator");
                    }
                }
                Check(after.Backgrounds.All(b => b.CombinedDrawing!.IsCombined != alpha), "translucent backgrounds retain source-over fallback");
            }
            var displayPlan = Plan(false, false, Net.SceneMode.Gallery); var direct = Build(displayPlan, true);
            renderer.SetDisplayRegion(new(0, 0, 32, 24), displayPlan.Displays[0].Key.LayoutId);
            var second = renderer.CreateDisplayRegion(new(32, 0, 32, 24), displayPlan.Displays[1].Key.LayoutId);
            renderer.PresentShared(direct, 2); renderer.ShowShared(direct);
            var outputCanvas = (Canvas)((Viewbox)second).Child;
            Check(outputCanvas.Children.Count == 1 && outputCanvas.Children[0] is SharedDrawingPresenter, "physical output uses retained drawings without a TileBrush");
            var presentation = (Grid)((Viewbox)renderer.Content).Child;
            Check(presentation.Children[0].Visibility == Visibility.Collapsed, "source UI tree is not rendered underneath the primary output");
            byte[] RetainedPixels()
            {
                outputCanvas.Measure(new Size(32, 24)); outputCanvas.Arrange(new Rect(0, 0, 32, 24)); outputCanvas.UpdateLayout();
                var bitmap = new RenderTargetBitmap(32, 24, 96, 96, PixelFormats.Pbgra32); bitmap.Render(outputCanvas);
                var bytes = new byte[32 * 24 * 4]; bitmap.CopyPixels(bytes, 32 * 4, 0); return bytes;
            }
            var retainedPresenter = outputCanvas.Children[0]; var initial = RetainedPixels();
            renderer.PresentShared(direct, 4);
            Check(!initial.SequenceEqual(RetainedPixels()), "drawing mutations update an already rendered presenter without replacing the output");
            renderer.PresentShared(direct, 10);
            var next = Build(displayPlan with { Id = Guid.NewGuid(), ContinuationOf = displayPlan.Id }, true);
            Check(renderer.ContinueShared(next, direct), "continued drawings keep the existing scene and presenter");
            renderer.PresentShared(next, 2); renderer.ShowShared(next);
            Check(ReferenceEquals(retainedPresenter, outputCanvas.Children[0]), "continuation retains output rendering commands");
            Check(RetainedPixels().Zip(Pixels(next, 1, true)).Max(p => Math.Abs(p.First - p.Second)) <= 1,
                "a retained presenter observes the replacement drawing contents across continuation");
            var late = displayPlan with { Placements = [displayPlan.Placements[1] with { VisibleFrom = 9.8, FadeSeconds = 1 }] };
            var lateReference = Build(late, false); var lateCandidate = Build(late, true);
            foreach (var at in new[] { 9.8, 9.9, 10, 10.1, 10.6, 10.8, 11, 20, 10.2 })
            {
                renderer.PresentShared(lateReference, at); renderer.PresentShared(lateCandidate, at);
                Check(lateReference.Photos[0].Image.Opacity == lateCandidate.Photos[0].Image.Opacity,
                    "a late final-slot fade keeps progressing after the geometry reaches the plan endpoint");
            }
        }
        finally { renderer.Clear(); renderer.Close(); }
        VerifyOffscreenTextures();
        Console.WriteLine($"Shared drawing: {count} output comparisons; maximum channel delta {maximum}.");
        return Task.CompletedTask;
    }
    private static void VerifyOffscreenTextures()
    {
        var source = Plan(false, false, Net.SceneMode.GalleryScroll);
        var placements = Enumerable.Range(0, 64).Select(i => source.Placements[0] with
        {
            Id = i, Clip = new(0, 0, 64, 24), Width = 28, Height = 20,
            FromX = 80 + i * 40, ToX = 80 + i * 40 - 240, FromY = 2, ToY = 2,
            FromScale = 1, ToScale = 1, StartSeconds = 0, MotionSeconds = 10,
            VisibleFrom = 0, VisibleUntil = 10, FadeSeconds = 0, Ease = false
        }).ToArray();
        var plan = source with { Placements = placements };
        var reference = Build(plan, false); var candidate = Build(plan, true);
        var renderer = new PhotoRenderer(new(64, 24), new WallSettings(), new TransitionController(), new AnimationScheduler());
        var maximumAttached = 0;
        try
        {
            foreach (var at in new[] { 0, .5, .625, .666666, .7, 1, 2, 5, 7.9999, 9.9999, 10, 30, 3, 0d })
            {
                renderer.PresentShared(reference, at); renderer.PresentShared(candidate, at);
                var attached = candidate.PhotoDrawings.Count(d => d.Root.Children.Count != 0);
                maximumAttached = Math.Max(maximumAttached, attached);
                Check(attached <= 3, "the future scroll strip must not attach dozens of offscreen textures to an output");
                if (at == 0) Check(attached == 0, "seeking before entry detaches every future photo without dropping the prepared textures");
                for (var output = 0; output < 2; output++)
                    Check(Pixels(reference, output, false).Zip(Pixels(candidate, output, true)).Max(p => Math.Abs(p.First - p.Second)) <= 2,
                        $"scroll entry, exit and backward seeks preserve both physical crops (at={at})");
            }
            Check(maximumAttached > 0, "visible photos must reattach when scrolling into the clip");
            Check(candidate.Images.Count == reference.Images.Count, "ready and seek retain all decoded assets");
        }
        finally { renderer.Clear(); renderer.Close(); }
        Console.WriteLine($"Future scroll drawing attachments: 64 -> at most {maximumAttached}; prepared assets preserved; entry/exit/seek pixels verified.");
    }
    public static Task DecodeSizes()
    {
        var plan = Plan(false, false, Net.SceneMode.Zoom);
        var photo = new Net.SharedPhoto(key, 6000, 4000, 1, new(1, 6000, 4000, "fixture", "1", Net.FaceAnalysisState.Complete, []));
        var outputs = plan.Displays.ToDictionary(d => d.Key.LayoutId, _ => new Net.Viewport(32, 24));
        var width = SharedDecodeSizing.Width(plan, photo, outputs, 256, 1);
        Check(width == 64, "small placements do not decode a 4096-pixel texture");
        var p = plan.Placements[0] with { Width = 800, Height = 600, FromScale = 1, ToScale = 1.5 };
        var large = plan with { Placements = [p] };
        Check(SharedDecodeSizing.Width(large, photo, outputs, 256, 1) == 1350, "maximum zoom and both image dimensions determine decode demand");
        var doubled = outputs.ToDictionary(e => e.Key, _ => new Net.Viewport(64, 48));
        Check(SharedDecodeSizing.Width(large, photo, doubled, 256, 1) == 2700, "physical output scaling preserves high-DPI detail");
        Check(SharedDecodeSizing.Width(large, photo, outputs, 1, 100) <= 314, "cache budget still caps decoded pixels");
        Check(SharedDecodeSizing.Width(large, photo with { PixelWidth = 200, PixelHeight = 300, Orientation = 6 }, outputs, 256, 1) == 200, "oriented source dimensions cap the decode without upscaling");
        var source = Texture(width: 128, height: 256); var png = Png(source);
        var bytes = new byte[128 * 256 * 4]; source.CopyPixels(bytes, 128 * 4, 0);
        using var bitmap = new SkiaSharp.SKBitmap(new SkiaSharp.SKImageInfo(128, 256, SkiaSharp.SKColorType.Bgra8888, SkiaSharp.SKAlphaType.Premul));
        System.Runtime.InteropServices.Marshal.Copy(bytes, 0, bitmap.GetPixels(), bytes.Length);
        using var skImage = SkiaSharp.SKImage.FromBitmap(bitmap); using var encoded = skImage.Encode(SkiaSharp.SKEncodedImageFormat.Webp, 100);
        foreach (var orientation in Enumerable.Range(1, 8)) foreach (var data in new[] { png, encoded.ToArray() })
        {
            var decoded = NetworkBitmap.Decode(data, 64, orientation);
            Check(decoded.PixelWidth == 64, $"oriented PNG and WebP decode at requested display width (orientation={orientation}, actual={decoded.PixelWidth})");
        }
        var retained = new List<(BitmapSource Image, WeakReference<byte[]> Input, byte[] Pixels)>();
        foreach (var orientation in Enumerable.Range(1, 8)) foreach (var format in new[] { "png", "jpg", "webp" })
            retained.Add(DecodedWithoutInput(format, orientation));
        GC.Collect(); GC.WaitForPendingFinalizers(); GC.Collect();
        var retainedInputs = retained.Count(item => item.Input.TryGetTarget(out _));
        Console.WriteLine($"Decoded input buffers retained: {retainedInputs}/{retained.Count}");
        Check(retainedInputs == 0, "displaying a decoded image must not pin its disposed compressed input buffer");
        foreach (var item in retained)
        {
            var actual = new byte[item.Pixels.Length]; item.Image.CopyPixels(actual, item.Image.PixelWidth * 4, 0);
            Check(actual.SequenceEqual(item.Pixels), "decoded pixels stay readable after stream disposal, zeroing and input collection");
        }
        return Task.CompletedTask;
    }
    [System.Runtime.CompilerServices.MethodImpl(System.Runtime.CompilerServices.MethodImplOptions.NoInlining)]
    private static (BitmapSource Image, WeakReference<byte[]> Input, byte[] Pixels) DecodedWithoutInput(string format, int orientation)
    {
        var source = Texture(width: 128, height: 256);
        byte[] data;
        if (format == "webp")
        {
            var pixels = new byte[128 * 256 * 4]; source.CopyPixels(pixels, 128 * 4, 0);
            using var bitmap = new SkiaSharp.SKBitmap(new SkiaSharp.SKImageInfo(128, 256, SkiaSharp.SKColorType.Bgra8888, SkiaSharp.SKAlphaType.Premul));
            System.Runtime.InteropServices.Marshal.Copy(pixels, 0, bitmap.GetPixels(), pixels.Length);
            using var image = SkiaSharp.SKImage.FromBitmap(bitmap); using var encoded = image.Encode(SkiaSharp.SKEncodedImageFormat.Webp, 100);
            data = encoded.ToArray();
        }
        else
        {
            BitmapEncoder encoder = format == "jpg" ? new JpegBitmapEncoder() : new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(source));
            using var output = new MemoryStream(); encoder.Save(output); data = output.ToArray();
        }
        var weak = new WeakReference<byte[]>(data);
        var decoded = NetworkBitmap.Decode(data, 64, orientation);
        var expected = new byte[decoded.PixelWidth * decoded.PixelHeight * 4];
        var converted = new FormatConvertedBitmap(decoded, PixelFormats.Pbgra32, null, 0);
        converted.CopyPixels(expected, decoded.PixelWidth * 4, 0);
        System.Security.Cryptography.CryptographicOperations.ZeroMemory(data);
        // Compare premultiplied pixels for all codec output formats.
        converted.Freeze(); return (converted, weak, expected);
    }
    public static Task Benchmark(string root)
    {
        var records = new List<object>();
        for (var repetition = 0; repetition < 3; repetition++)
        foreach (var moving in new[] { false, true }) foreach (var changingBackground in new[] { false, true })
        foreach (var optimized in repetition % 2 == 0 ? new[] { false, true } : new[] { true, false })
        {
            var plan = Plan(false, false, Net.SceneMode.Gallery) with { Duration = 60, FadeSeconds = 0 };
            var template = plan.Placements[0] with { Width = 64, Height = 24, FromX = 0, FromY = 0, ToX = moving ? -10 : 0,
                ToY = 0, FromScale = 1, ToScale = 1, StartSeconds = 0, MotionSeconds = 60, VisibleUntil = 60, FadeSeconds = 0 };
            var texture = Texture(width: 256, height: 96); var nextTexture = changingBackground ? Texture(blue: true, width: 256, height: 96) : texture;
            plan = plan with { Placements = Enumerable.Range(0, 100).Select(i => template with { Id = i, VisibleFrom = i == 0 ? 0 : 40 }).ToArray(),
                Ambient = [new(0, Png(texture)), new(60, Png(nextTexture))] };
            var visual = Build(plan, optimized);
            var renderer = new PhotoRenderer(new(64, 24), new WallSettings(), new TransitionController(), new AnimationScheduler());
            try
            {
                for (var frame = 0; frame < 60; frame++) renderer.PresentShared(visual, 1 + frame / 60d);
                visual.EvaluationCount = 0;
                var beforeUpdates = visual.Backgrounds.Sum(b => b.CombinedDrawing?.UpdateCount ?? 0);
                var beforeUpload = visual.Backgrounds.Sum(b => b.CombinedDrawing?.WrittenBytes ?? 0);
                var allocated = GC.GetAllocatedBytesForCurrentThread(); var watch = Stopwatch.StartNew();
                for (var frame = 0; frame < 600; frame++) renderer.PresentShared(visual, 2 + frame / 60d);
                watch.Stop(); allocated = GC.GetAllocatedBytesForCurrentThread() - allocated;
                records.Add(new { Repetition=repetition, Moving=moving, ChangingBackground=changingBackground, Optimized=optimized, Updates=600,
                    Evaluations=visual.EvaluationCount, Milliseconds=watch.Elapsed.TotalMilliseconds, AllocatedBytes=allocated,
                    BackgroundWrites=visual.Backgrounds.Sum(b => b.CombinedDrawing?.UpdateCount ?? 0)-beforeUpdates,
                    BackgroundBytes=visual.Backgrounds.Sum(b => b.CombinedDrawing?.WrittenBytes ?? 0)-beforeUpload });
                if (optimized) Check(visual.EvaluationCount == (moving ? 600 : 0), "inactive and static placements must skip evaluation");
            }
            finally { renderer.Clear(); renderer.Close(); }
        }
        File.WriteAllText(Path.Combine(root, "shared-rendering-benchmark.json"), JsonSerializer.Serialize(records, new JsonSerializerOptions { WriteIndented = true }));
        Console.WriteLine($"Shared rendering benchmark: {records.Count} trials; raw counters and timings saved separately."); return Task.CompletedTask;
    }
}

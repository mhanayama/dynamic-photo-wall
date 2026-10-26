using System.Text.Json;

namespace DpwSpatial;
internal static class SelfTest
{
    public static int Run(string output, string? model, string? photo, bool warp)
    {
        Directory.CreateDirectory(output);
        var results = new List<object>(); var failures = 0;
        void Assert(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
        void Test(string name, Action action) {
            try { action(); results.Add(new { name, success = true }); Console.WriteLine($"PASS {name}"); }
            catch (Exception e) { failures++; results.Add(new { name, success = false, error = e.ToString() }); Console.Error.WriteLine($"FAIL {name}: {e.Message}"); }
        }
        Test("one-way endpoint and ping-pong single-pass duration", () => {
            Assert(SpatialMotion.At(0, 20, false, 1).Position == -1, "start");
            foreach (var t in new[] { 20.0, 30, 40, 600 }) Assert(SpatialMotion.At(t, 20, false, 1) == (1, true), "must hold endpoint");
            Assert(SpatialMotion.At(20, 20, false, -1).Position == -1, "reverse");
            Assert(SpatialMotion.At(20, 20, true, 1) == (1, false), "forward pass");
            Assert(SpatialMotion.At(40, 20, true, 1) == (-1, false), "return pass");
            Assert(SpatialMotion.Amplitude(300) == .24f && SpatialMotion.Amplitude(-1) == 0, "strength bounds");
            Assert(SpatialMotion.Amplitude(SpatialMotion.DefaultStrength) == .12f, "visible default strength");
        });
        Test("all eight EXIF orientations preserve exact pixel identity", () => {
            var source = new Pixels(2, 3, new byte[24]);
            for (var i = 0; i < 6; i++) source.Rgba[i * 4] = (byte)(i + 1);
            int[][] expected = [[1, 2, 3, 4, 5, 6], [2, 1, 4, 3, 6, 5], [6, 5, 4, 3, 2, 1], [5, 6, 3, 4, 1, 2],
                [1, 3, 5, 2, 4, 6], [5, 3, 1, 6, 4, 2], [6, 4, 2, 5, 3, 1], [2, 4, 6, 1, 3, 5]];
            for (var orientation = 1; orientation <= 8; orientation++) {
                var actual = Pixels.Orient(source, orientation);
                Assert(actual.Width == (orientation >= 5 ? 3 : 2), "oriented width");
                Assert(Enumerable.Range(0, 6).Select(i => (int)actual.Rgba[i * 4]).SequenceEqual(expected[orientation - 1]), $"orientation {orientation}");
            }
        });
        Test("preprocessing shape, robust normalization and cache identity", () => {
            Assert(DepthPipeline.InputSize(640, 400) == (518, 322), "518 target, multiples of 14");
            Assert(DepthPipeline.Normalize([1, 1, 1]).All(v => v == 128), "constant depth");
            Assert(DepthPipeline.Normalize([0, 1, 2, 3, 4]).Last() == 255, "near is white");
            try { DepthPipeline.Normalize([float.NaN]); throw new Exception("accepted NaN"); } catch (InvalidDataException) { }
            Assert(DepthPipeline.CacheKey("photoA", "modelA") != DepthPipeline.CacheKey("photoB", "modelA"), "source invalidation");
            Assert(DepthPipeline.CacheKey("photoA", "modelA") != DepthPipeline.CacheKey("photoA", "modelB"), "model invalidation");
        });
        var fixture = new Pixels(256, 160, new byte[256 * 160 * 4]);
        for (var y = 0; y < fixture.Height; y++) for (var x = 0; x < fixture.Width; x++) {
            var i = (y * fixture.Width + x) * 4;
            fixture.Rgba[i] = (byte)x; fixture.Rgba[i + 1] = (byte)y; fixture.Rgba[i + 2] = (byte)(x / 8 % 2 * 255); fixture.Rgba[i + 3] = 255;
        }
        var fixturePath = Path.Combine(output, "fixture.png"); fixture.Save(fixturePath);
        Test("drop accepts one existing photo; rejects folders, missing files and multiple photos", () => {
            Assert(PhotoDrop.TrySelect([fixturePath], out var selected, out _) && selected == Path.GetFullPath(fixturePath), "photo rejected");
            Assert(!PhotoDrop.TrySelect([output], out _, out _), "folder accepted");
            Assert(!PhotoDrop.TrySelect([fixturePath, fixturePath], out _, out _), "multiple files accepted");
            Assert(!PhotoDrop.TrySelect([Path.Combine(output, "missing.png")], out _, out _), "missing file accepted");
            Assert(!PhotoDrop.TrySelect([Path.Combine(output, "results.json")], out _, out _), "non-image accepted");
            Assert(!PhotoDrop.TrySelect(null, out _, out _), "non-file drag accepted");
        });
        Test("native drop reads Explorer-compatible CF_HDROP without creating windows", () => {
            var data = new System.Windows.DataObject(System.Windows.DataFormats.FileDrop, new[] { Path.GetFullPath(fixturePath) });
            var files = PhotoDrop.ReadFiles((System.Runtime.InteropServices.ComTypes.IDataObject)(object)data);
            Assert(files.SequenceEqual(new[] { Path.GetFullPath(fixturePath) }), "CF_HDROP Unicode path roundtrip failed");
        });
        Test("portable model path is relative to EXE, independent of current directory", () => {
            var portable = Path.Combine(Path.GetFullPath(output), "portable-layout");
            Directory.CreateDirectory(Path.Combine(portable, "models"));
            var adjacent = Path.Combine(portable, "models", "model.onnx"); File.WriteAllBytes(adjacent, [1]);
            Assert(TrialPaths.Model(portable) == adjacent, "adjacent model not selected");
            var workspace = TrialPaths.FindWorkspace(TrialPaths.ExecutableDirectory);
            var expectedCache = workspace is null
                ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "DynamicPhotoWall.SpatialPhotoTest", "cache")
                : Path.Combine(workspace, "artifacts/windows/spatial-photo/cache");
            Assert(TrialPaths.Cache(TrialPaths.ExecutableDirectory) == expectedCache, "independent cache path");
        });
        Test("EXIF-free PNG decode roundtrip", () => {
            var decoded = Pixels.Load(fixturePath); Assert(decoded.Width == fixture.Width && decoded.Rgba.SequenceEqual(fixture.Rgba), "pixels changed");
        });
        Test("real Direct3D12 shader compile, upload, render, readback, resize and disposal (no HWND)", () => {
            using var renderer = new NativeRenderer(0, fixture.Width, fixture.Height, warp);
            Console.WriteLine($"D3D12 adapter: {renderer.Adapter}");
            renderer.SetImages(fixture, Enumerable.Repeat((byte)220, fixture.Width * fixture.Height).ToArray(), fixture.Width, fixture.Height);
            renderer.Render(0, 0); var still = renderer.Readback(fixture.Width, fixture.Height);
            Assert(still.Zip(fixture.Rgba).All(p => Math.Abs(p.First - p.Second) <= 1), "identity draw is blank, flipped or incorrectly colored");
            renderer.Render(-1, .018f); var left = renderer.Readback(fixture.Width, fixture.Height);
            renderer.Render(1, .018f); var right = renderer.Readback(fixture.Width, fixture.Height);
            Assert(!left.SequenceEqual(right), "parallax is static");
            new Pixels(fixture.Width, fixture.Height, left).Save(Path.Combine(output, "native-left.png"));
            new Pixels(fixture.Width, fixture.Height, right).Save(Path.Combine(output, "native-right.png"));
            renderer.Resize(128, 80); renderer.Render(0, 0); Assert(renderer.Readback(128, 80).Any(v => v != 0), "resize draw failed");
        });
        Test("default strength visibly separates near/far layers and native maximum is not silently clamped", () => {
            const int width = 256, height = 160;
            var scene = new Pixels(width, height, new byte[width * height * 4]);
            var depths = new byte[width * height];
            for (var y = 0; y < height; y++) for (var x = 0; x < width; x++) {
                var index = y * width + x; scene.Rgba[index * 4 + 3] = 255; depths[index] = x < width / 2 ? (byte)255 : (byte)0;
                if (x >= 68 && x <= 76 && y >= 44 && y <= 56) scene.Rgba[index * 4] = 255;
                if (x >= 180 && x <= 188 && y >= 104 && y <= 116) scene.Rgba[index * 4 + 2] = 255;
            }
            using var renderer = new NativeRenderer(0, width, height, warp); renderer.SetImages(scene, depths, width, height);
            (double Near, double Far) Centers(byte[] image) {
                var near = new List<int>(); var far = new List<int>();
                for (var y = 0; y < height; y++) for (var x = 0; x < width; x++) {
                    var index = (y * width + x) * 4;
                    if (image[index] > 200 && image[index + 2] < 20) near.Add(x);
                    if (image[index + 2] > 200 && image[index] < 20) far.Add(x);
                }
                Assert(near.Count > 0 && far.Count > 0, "layer markers disappeared");
                return (near.Average(), far.Average());
            }
            foreach (var strength in new[] { SpatialMotion.DefaultStrength, 100.0 }) {
                var a = SpatialMotion.Amplitude(strength);
                renderer.Render(-1, a); var left = renderer.Readback(width, height); var lc = Centers(left);
                renderer.Render(1, a); var right = renderer.Readback(width, height); var rc = Centers(right);
                var requiredTravel = strength == 100 ? 60 : 25;
                Assert(lc.Near - rc.Near > requiredTravel && rc.Far - lc.Far > requiredTravel, "near/far must visibly move in opposite directions");
                Console.WriteLine($"Strength {strength:0}%: near travel {lc.Near - rc.Near:0.0}px, far travel {rc.Far - lc.Far:0.0}px / {width}px image");
                new Pixels(width, height, left).Save(Path.Combine(output, $"layers-{strength:0}-left.png"));
                new Pixels(width, height, right).Save(Path.Combine(output, $"layers-{strength:0}-right.png"));
                // The half-amplitude crop must reserve all possible border travel.
                foreach (var u in new[] { 0.0, .5, 1.0 }) foreach (var p in new[] { -1.0, 1.0 }) foreach (var d in new[] { 0.0, 1.0 }) {
                    var source = (u - .5) * (1 - a) + .5 + p * a * (d - .5);
                    Assert(source >= -1e-7 && source <= 1 + 1e-7, "warp exceeded reserved image border");
                }
            }
        });
        if (model is not null) Test("depth generation -> persistent cache -> native D3D12 playback readback", () => {
            var source = photo ?? fixturePath;
            var pair = DepthPipeline.Generate(source, model, Path.Combine(output, "cache"), "auto", true, Console.WriteLine);
            Assert(pair.Depth.Length == pair.Photo.Width * pair.Photo.Height, "depth shape");
            Assert(pair.Depth.Min() < pair.Depth.Max(), "model returned constant depth");
            var cached = DepthPipeline.Generate(source, model, Path.Combine(output, "cache"));
            Assert(cached.CacheHit && cached.Depth.SequenceEqual(pair.Depth), "cached result mismatch");
            using var renderer = new NativeRenderer(0, 640, 400, warp); renderer.SetPair(cached);
            renderer.Render(-1, SpatialMotion.Amplitude(SpatialMotion.DefaultStrength)); var left = renderer.Readback(640, 400);
            renderer.Render(1, SpatialMotion.Amplitude(SpatialMotion.DefaultStrength)); var right = renderer.Readback(640, 400);
            Assert(!left.SequenceEqual(right), "inferred depth did not change rendering");
            new Pixels(640, 400, left).Save(Path.Combine(output, "inferred-left.png"));
            new Pixels(640, 400, right).Save(Path.Combine(output, "inferred-right.png"));
            Console.WriteLine($"Inference: {pair.Backend}; cached={cached.CacheHit}; {pair.Photo.Width}x{pair.Photo.Height}");
        });
        File.WriteAllText(Path.Combine(output, "results.json"), JsonSerializer.Serialize(new { failures, modelTested = model is not null, warp, results }, new JsonSerializerOptions { WriteIndented = true }));
        Console.WriteLine($"{results.Count - failures}/{results.Count} passed; no windows created."); return failures == 0 ? 0 : 1;
    }
}

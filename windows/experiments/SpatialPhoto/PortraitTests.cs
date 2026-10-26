using System.Text;
using System.Text.Json;

namespace DpwSpatial;
internal static class PortraitTests
{
    internal static PortraitScene Fixture(bool fullBody)
    {
        var bg = new Pixels(2, 2, Enumerable.Repeat((byte)255, 16).ToArray());
        var vertices = new List<float>();
        void Vertex(float x, float y, float z, float r, float g, float b, float u = 0, float v = 0) => vertices.AddRange([x, y, z, r, g, b, u, v]);
        Vertex(-40, 40, 6, 1, 1, 1); Vertex(40, 40, 6, 1, 1, 1, 1); Vertex(-40, -40, 6, 1, 1, 1, 0, 1); Vertex(40, -40, 6, 1, 1, 1, 1, 1);
        var top = fullBody ? .85f : .45f; var bottom = fullBody ? -.85f : -.45f;
        foreach (var z in new[] { 2.7f, 3.3f }) foreach (var y in new[] { bottom, top }) foreach (var x in new[] { -.22f, .22f })
            Vertex(x, y, z, z < 3 ? 1 : .05f, x < 0 ? .05f : .2f, z < 3 ? .05f : 1);
        uint[] box = [0, 1, 2, 2, 1, 3, 4, 6, 5, 6, 7, 5, 0, 4, 1, 1, 4, 5, 2, 3, 6, 6, 3, 7, 0, 2, 4, 4, 2, 6, 1, 5, 3, 3, 5, 7];
        return new(bg, vertices.ToArray(), new uint[] { 0, 1, 2, 2, 1, 3 }.Concat(box.Select(i => i + 4)).ToArray(), 400, 600, 40, 3, 60, "", "synthetic renderer fixture, not generated human", 0);
    }
    public static int Run(string output, string? manifest, bool warp)
    {
        Directory.CreateDirectory(output); var results = new List<object>(); var failures = 0;
        void Check(bool condition, string error) { if (!condition) throw new InvalidOperationException(error); }
        void Test(string name, Action action) {
            try { action(); Console.WriteLine($"PASS {name}"); results.Add(new { name, success = true }); }
            catch (Exception e) { failures++; Console.Error.WriteLine($"FAIL {name}: {e.Message}"); results.Add(new { name, success = false, error = e.ToString() }); }
        }
        foreach (var fullBody in new[] { false, true }) Test(fullBody ? "full-body scene fixture: perspective, depth occlusion, +/-60 degree camera and resize" : "upper-body scene fixture: perspective, depth occlusion, +/-60 degree camera and resize", () => {
            var scene = Fixture(fullBody); using var renderer = new NativeRenderer(0, 400, 600, warp); renderer.SetPortrait(scene);
            Console.WriteLine("D3D12 adapter: " + renderer.Adapter);
            renderer.RenderPortrait(0); var front = renderer.Readback(400, 600);
            var center = (300 * 400 + 200) * 4;
            Check(front[center] > 200 && front[center + 2] < 30, "back face incorrectly covers front face: depth buffer required");
            var views = new List<byte[]>();
            foreach (var angle in new[] { -60, -30, 0, 30, 60 }) {
                renderer.RenderPortrait(angle); var image = renderer.Readback(400, 600); views.Add(image);
                Check(image[0] > 245 && image[1] > 245 && image[2] > 245, "background does not cover camera sweep");
                Check(!image.SequenceEqual(Enumerable.Repeat((byte)255, image.Length)), "person vanished");
                new Pixels(400, 600, image).Save(Path.Combine(output, $"fixture-{(fullBody ? "full" : "upper")}-{angle}.png"));
            }
            Check(!views.First().SequenceEqual(views.Last()), "camera sweep is static");
            renderer.Resize(200, 300); renderer.RenderPortrait(30); Check(renderer.Readback(200, 300).Length == 200 * 300 * 4, "portrait resize failed");
        });
        Test("native mesh rejects non-finite vertices and out-of-range indices", () => {
            using var renderer = new NativeRenderer(0, 64, 64, warp); var scene = Fixture(false);
            var broken = (float[])scene.Vertices.Clone(); broken[40] = float.NaN;
            try { renderer.SetPortrait(scene with { Vertices = broken }); throw new Exception("accepted NaN"); } catch (InvalidOperationException) { }
            var indices = (uint[])scene.Indices.Clone(); indices[^1] = uint.MaxValue;
            try { renderer.SetPortrait(scene with { Indices = indices }); throw new Exception("accepted invalid index"); } catch (InvalidOperationException) { }
        });
        Test("photo projection preserves pixel detail, rejects occluded surfaces and survives resize/toggle", () => {
            var scene = Fixture(false); var rgba = new byte[400 * 600 * 4];
            for (var y = 0; y < 600; ++y) for (var x = 0; x < 400; ++x) {
                var p = (y * 400 + x) * 4; rgba[p] = 60; rgba[p + 1] = (byte)(((x / 3 + y / 3) % 2) == 0 ? 200 : 250); rgba[p + 2] = 20; rgba[p + 3] = 255;
            }
            // Two separated planes: the blue rear plane is hidden from the source camera,
            // but becomes visible beside the red front plane when the viewing camera moves.
            scene = scene with { SourcePhoto = new Pixels(400, 600, rgba), Indices = scene.Indices.Take(18).ToArray() };
            using var renderer = new NativeRenderer(0, 400, 600, warp); renderer.SetPortrait(scene); renderer.RenderPortrait(0);
            var front = renderer.Readback(400, 600); long error = 0; var samples = 0;
            for (var y = 250; y < 350; ++y) for (var x = 170; x < 230; ++x) for (var c = 0; c < 3; ++c) {
                var p = (y * 400 + x) * 4 + c; error += Math.Abs(front[p] - rgba[p]); samples++;
            }
            Check((double)error / samples < 1, "source photo detail lost or projection coordinates are incorrect");
            Console.WriteLine($"Source texture RGB mean error: {(double)error / samples:F3}/255 over {samples / 3} pixels");
            new Pixels(400, 600, front).Save(Path.Combine(output, "projection-detail.png"));
            renderer.RenderPortrait(60); var side = renderer.Readback(400, 600); var blue = 0; var green = 0;
            for (var p = 0; p < side.Length; p += 4) { if (side[p + 2] > 220 && side[p] < 40 && side[p + 1] < 80) blue++; if (side[p + 1] > 180 && side[p] < 80 && side[p + 2] < 40) green++; }
            Check(blue > 100 && green > 100, "source photo leaked onto an occluded rear surface or was not projected on front");
            Console.WriteLine($"Occlusion fixture: {blue} unprojected rear pixels, {green} projected front pixels");
            new Pixels(400, 600, side).Save(Path.Combine(output, "projection-occlusion.png"));
            renderer.RenderPortrait(0, false); var original = renderer.Readback(400, 600); var center = (300 * 400 + 200) * 4;
            Check(original[center] > 200 && original[center + 1] < 80, "generated-color comparison mode still projects the photo");
            renderer.Resize(200, 300); renderer.RenderPortrait(0); var resized = renderer.Readback(200, 300);
            Check(resized[(150 * 200 + 100) * 4 + 1] > 180, "source camera map broke after viewport resize");
            renderer.SetPortrait(scene with { SourcePhoto = null }); renderer.RenderPortrait(0); resized = renderer.Readback(200, 300);
            Check(resized[(150 * 200 + 100) * 4] > 200, "previous photo survives a scene without source photo");
        });
        Test("scene file roundtrip, hashes and malformed mesh validation", () => {
            var directory = Path.Combine(output, "scene-fixture"); Directory.CreateDirectory(directory); var scene = Fixture(false);
            scene.Background.Save(Path.Combine(directory, "background.png"));
            var meshPath = Path.Combine(directory, "person.mesh");
            using (var writer = new BinaryWriter(File.Create(meshPath))) {
                writer.Write(Encoding.ASCII.GetBytes("DPWMESH1")); writer.Write((uint)(scene.Vertices.Length / 8 - 4)); writer.Write((uint)(scene.Indices.Length - 6));
                foreach (var value in scene.Vertices.Skip(32)) writer.Write(value);
                foreach (var index in scene.Indices.Skip(6)) writer.Write(index - 4);
            }
            var manifestPath = Path.Combine(directory, "manifest.json");
            File.WriteAllText(manifestPath, JsonSerializer.Serialize(new { width = 400, height = 600, fovY = 40, pivot = 3, maximumAngle = 60, backgroundDepth = 6,
                backgroundBounds = new[] { -40, 40, -40, 40 }, generator = "fixture", seconds = 0,
                hashes = new Dictionary<string, string> { ["background.png"] = DepthPipeline.HashFile(Path.Combine(directory, "background.png")), ["person.mesh"] = DepthPipeline.HashFile(meshPath) } }));
            var decoded = PortraitScene.Load(manifestPath); Check(decoded.Vertices.SequenceEqual(scene.Vertices) && decoded.Indices.SequenceEqual(scene.Indices), "scene roundtrip changed mesh");
            File.AppendAllText(meshPath, "corrupt");
            try { PortraitScene.Load(manifestPath); throw new Exception("accepted corrupt cache"); } catch (InvalidDataException) { }
        });
        if (manifest is not null) Test("generated portrait scene loads and renders front, +/-30, +/-60 without windows", () => {
            var scene = PortraitScene.Load(manifest); using var renderer = new NativeRenderer(0, 640, 640, warp); renderer.SetPortrait(scene);
            foreach (var angle in new[] { -60, -30, 0, 30, 60 }) {
                renderer.RenderPortrait(angle, false); new Pixels(640, 640, renderer.Readback(640, 640)).Save(Path.Combine(output, $"generated-colors-{angle}.png"));
                renderer.RenderPortrait(angle); var image = renderer.Readback(640, 640);
                new Pixels(640, 640, image).Save(Path.Combine(output, $"generated-{angle}.png"));
            }
            Console.WriteLine($"Generated scene: {scene.Vertices.Length / 8 - 4} vertices; {(scene.Indices.Length - 6) / 3} triangles; {scene.GenerationSeconds:F1}s generation");
        });
        File.WriteAllText(Path.Combine(output, "portrait-results.json"), JsonSerializer.Serialize(new { failures, generatedSceneTested = manifest is not null, warp, results }, new JsonSerializerOptions { WriteIndented = true }));
        Console.WriteLine($"Portrait alpha: {results.Count - failures}/{results.Count} passed; no windows created."); return failures == 0 ? 0 : 1;
    }
}

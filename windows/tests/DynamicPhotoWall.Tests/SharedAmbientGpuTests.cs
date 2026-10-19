using System.ComponentModel;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using DynamicPhotoWall.Rendering;
using Net = DynamicPhotoWall.Networking;

namespace DynamicPhotoWall.Tests;

// Offscreen pixels and dependency-property notifications. This verifies work
// elimination and composition, not an actual GPU utilization improvement.
internal static class SharedAmbientGpuTests
{
    private static void Check(bool value, string message) { if (!value) throw new Exception(message); }
    private static BitmapSource Texture(byte b, byte g, byte r, byte alpha = 255, bool freeze = true)
    {
        var texture = BitmapSource.Create(1, 1, 96, 96, PixelFormats.Pbgra32, null, new byte[] { b, g, r, alpha }, 4);
        if (freeze) texture.Freeze(); return texture;
    }
    private static (Canvas Root, System.Windows.Controls.Image[] Images) Surface(BitmapSource[] textures)
    {
        var canvas = new Canvas { Width = 16, Height = 9, Background = Brushes.DarkSlateGray };
        var images = textures.Select(texture => new System.Windows.Controls.Image { Source = texture, Width = 16, Height = 9, Opacity = 0, Stretch = Stretch.Fill }).ToArray();
        foreach (var image in images) canvas.Children.Add(image);
        return (canvas, images);
    }
    private static void OldPresent(Net.AmbientFrame[] frames, System.Windows.Controls.Image[] images, double elapsed)
    {
        var index = 0;
        while (index + 1 < frames.Length && frames[index + 1].At <= elapsed) index++;
        var next = Math.Min(index + 1, frames.Length - 1);
        var amount = next == index ? 0 : Math.Clamp((elapsed - frames[index].At) / Math.Max(.001, frames[next].At - frames[index].At), 0, 1);
        for (var i = 0; i < images.Length; i++) images[i].Opacity = i == index ? 1 : i == next ? amount : 0;
    }
    private static byte[] Render(Canvas canvas)
    {
        canvas.Measure(new Size(16, 9)); canvas.Arrange(new Rect(0, 0, 16, 9)); canvas.UpdateLayout();
        var bitmap = new RenderTargetBitmap(16, 9, 96, 96, PixelFormats.Pbgra32); bitmap.Render(canvas);
        var pixels = new byte[16 * 9 * 4]; bitmap.CopyPixels(pixels, 16 * 4, 0); return pixels;
    }
    public static Task Run()
    {
        var red = Texture(20, 40, 200); var blue = Texture(200, 40, 20); var alpha = Texture(50, 20, 80, 128);
        var mutable = Texture(20, 40, 200, freeze: false);
        BitmapSource[][] scenarios = [ [red, red, red, blue, blue, red, red], [red, blue, red],
            [alpha, alpha, alpha], [red, alpha, alpha, blue, blue], [mutable, mutable],
            [red, Texture(20, 40, 200), red] ];
        var maximumDifference = 0; var comparisons = 0;
        foreach (var textures in scenarios)
        {
            var frames = textures.Select((_, i) => new Net.AmbientFrame(i, [])).ToArray();
            var reference = Surface(textures); var current = new AmbientFrameVisual(frames, textures, 16, 9);
            var candidate = new Canvas { Width = 16, Height = 9, Background = Brushes.DarkSlateGray };
            foreach (var image in current.Images) candidate.Children.Add(image);
            var times = Enumerable.Range(0, (textures.Length - 1) * 12 + 1).Select(i => i / 12d)
                .Concat(Enumerable.Range(1, textures.Length - 1).SelectMany(i => new[] { i - .0001, i + .0001 }))
                .Concat([100, .5, 0]);
            foreach (var at in times)
            {
                OldPresent(frames, reference.Images, at); current.Present(at);
                var before = Render(reference.Root); var after = Render(candidate);
                var difference = before.Zip(after).Max(pair => Math.Abs(pair.First - pair.Second));
                maximumDifference = Math.Max(maximumDifference, difference);
                Check(difference <= 1, $"opaque deduplication must preserve source-over pixels within one 8-bit rounding step (at={at:R}, delta={difference})");
                if (textures.All(t => ReferenceEquals(t, alpha))) Check(difference == 0, "translucent repeated samples must preserve the exact wire blend");
                Check(current.Images.Select((image, i) => ReferenceEquals(image.Source, textures[i])).All(same => same), "attached image sources must never be swapped");
                comparisons++;
            }
        }
        var repeated = Enumerable.Repeat(red, 24).ToArray();
        var constantFrames = repeated.Select((_, i) => new Net.AmbientFrame(i, [])).ToArray();
        var old = Surface(repeated); OldPresent(constantFrames, old.Images, 0);
        var optimized = new AmbientFrameVisual(constantFrames, repeated, 16, 9);
        var descriptor = DependencyPropertyDescriptor.FromProperty(UIElement.OpacityProperty, typeof(System.Windows.Controls.Image));
        var oldChanges = 0; var newChanges = 0;
        EventHandler oldChanged = (_, _) => oldChanges++; EventHandler newChanged = (_, _) => newChanges++;
        foreach (var image in old.Images) descriptor.AddValueChanged(image, oldChanged);
        foreach (var image in optimized.Images) descriptor.AddValueChanged(image, newChanged);
        try
        {
            for (var frame = 1; frame <= 600; frame++) { OldPresent(constantFrames, old.Images, frame / 60d); optimized.Present(frame / 60d); }
            Check(oldChanges >= 590 && newChanges == 0, "identical opaque samples must remove continuous opacity invalidations across sample boundaries");
        }
        finally
        {
            foreach (var image in old.Images) descriptor.RemoveValueChanged(image, oldChanged);
            foreach (var image in optimized.Images) descriptor.RemoveValueChanged(image, newChanged);
        }
        VerifyBuilderInterning();
        Console.WriteLine($"Shared ambient: {comparisons} offscreen comparisons, maximum channel delta {maximumDifference}; opacity notifications {oldChanges} -> {newChanges} / 600 updates.");
        return Task.CompletedTask;
    }
    private static void VerifyBuilderInterning()
    {
        var bitmap = Texture(40, 60, 100); var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var stream = new MemoryStream(); encoder.Save(stream); var png = stream.ToArray();
        var peer = Guid.NewGuid(); var group = Guid.NewGuid();
        var key = new Net.SharedAssetKey(peer, Guid.NewGuid(), Guid.NewGuid(), new string('a', 64));
        var displays = Enumerable.Range(0, 2).Select(i => new Net.PeerDisplay(new(peer, i.ToString()), true, group, i * 16, 0, 16, 9)).ToArray();
        var placements = displays.Select((display, i) => new Net.ScenePlacement(i, key, display.Key.LayoutId, new(i * 16, 0, 16, 9),
            16, 9, i * 16, 0, i * 16, 0, 1, 1, .5, .5, 0, 3, 0, 3, 0, 0, false)).ToArray();
        var frames = displays.SelectMany(display => Enumerable.Range(0, 4).Select(i => new Net.AmbientFrame(i, png.ToArray()) { DisplayId = display.Key.LayoutId })).ToArray();
        var plan = new Net.SharedScenePlan(Guid.NewGuid(), group, Guid.NewGuid(), 0, Net.SceneMode.Gallery, new(32, 9), displays, 3, 0, "#000000", placements, frames);
        plan.Validate();
        var visual = SharedSceneBuilder.Build(plan, new Dictionary<string, BitmapSource> { [key.OpaqueId] = bitmap }, displays.Select(d => d.Key.LayoutId).ToArray());
        var images = visual.Backgrounds.SelectMany(b => b.Images).ToArray();
        Check(images.Length == 8 && images.All(image => ReferenceEquals(image.Source, images[0].Source)), "identical PNG bytes share a single frozen texture across both surfaces");
        var pixel = new byte[4]; ((BitmapSource)images[0].Source).CopyPixels(pixel, 4, 0);
        byte[] expected = [40, 60, 100, 255]; AmbientPixels.EnhanceColors(expected);
        Check(pixel.SequenceEqual(expected), "interned PNG samples receive color enhancement exactly once");
        foreach (var background in visual.Backgrounds) { background.Present(1.5); Check(background.Images[0].Opacity == 1 && background.Images.Skip(1).All(image => image.Opacity == 0), "each surface keeps a stable opaque representative"); }
    }
}

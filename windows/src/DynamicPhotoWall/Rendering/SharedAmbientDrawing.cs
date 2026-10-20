using System.Windows.Media.Imaging;

namespace DynamicPhotoWall.Rendering;

// Combine opaque low-resolution samples before scaling to the output. Alpha
// samples keep their original source-over order; interpolation of alpha products
// at low resolution is not equivalent to composition after image scaling.
internal sealed class SharedAmbientDrawing
{
    private readonly DrawingGroup[] layers;
    private readonly byte[][]? pixels;
    private readonly WriteableBitmap? composite;
    private readonly byte[]? result;
    private int lastIndex = -1, lastNext = -1, lastBlend = -1;
    public DrawingGroup Root { get; } = new();
    public int UpdateCount { get; private set; }
    public long WrittenBytes { get; private set; }
    public bool IsCombined => composite != null;

    public SharedAmbientDrawing(BitmapSource[] textures, bool[] opaque, double width, double height)
    {
        layers = textures.Select(texture =>
        {
            var group = new DrawingGroup();
            group.Children.Add(new ImageDrawing(texture, new Rect(0, 0, width, height)));
            return group;
        }).ToArray();
        if (opaque.All(value => value) && textures.All(t => t.IsFrozen && t.PixelWidth == textures[0].PixelWidth && t.PixelHeight == textures[0].PixelHeight))
        {
            var first = textures[0]; var cache = new Dictionary<BitmapSource, byte[]>();
            pixels = textures.Select(texture =>
            {
                if (cache.TryGetValue(texture, out var bytes)) return bytes;
                var converted = texture.Format == PixelFormats.Pbgra32 ? texture : new FormatConvertedBitmap(texture, PixelFormats.Pbgra32, null, 0);
                bytes = new byte[first.PixelWidth * first.PixelHeight * 4]; converted.CopyPixels(bytes, first.PixelWidth * 4, 0);
                cache.Add(texture, bytes); return bytes;
            }).ToArray();
            result = new byte[pixels[0].Length];
            composite = new WriteableBitmap(first.PixelWidth, first.PixelHeight, 96, 96, PixelFormats.Pbgra32, null);
            Root.Children.Add(new ImageDrawing(composite, new Rect(0, 0, width, height)));
        }
        else
        {
            foreach (var layer in layers) Root.Children.Add(layer);
            Root.Children.Add(new GeometryDrawing(new SolidColorBrush(Color.FromArgb(46, 12, 17, 28)), null,
                new RectangleGeometry(new Rect(0, 0, width, height))));
        }
    }
    public void Present(int index, int next, double blend)
    {
        if (composite == null)
        {
            for (var i = 0; i < layers.Length; i++)
            {
                var opacity = i == index ? 1 : i == next ? blend : 0;
                if (layers[i].Opacity != opacity) layers[i].Opacity = opacity;
            }
            return;
        }
        var fraction = index == next || ReferenceEquals(pixels![index], pixels[next]) ? 0 : (int)Math.Round(blend * 1024);
        if (index == lastIndex && next == lastNext && fraction == lastBlend) return;
        // Same texture at a sample boundary is already on the GPU.
        if (fraction == 0 && lastBlend == 0 && lastIndex >= 0 && ReferenceEquals(pixels![index], pixels[lastIndex]))
        { lastIndex = index; lastNext = next; return; }
        var a = pixels![index]; var b = pixels[next];
        for (var i = 0; i < result!.Length; i += 4)
        {
            result[i] = Channel(a[i], b[i], fraction, 28);
            result[i + 1] = Channel(a[i + 1], b[i + 1], fraction, 17);
            result[i + 2] = Channel(a[i + 2], b[i + 2], fraction, 12);
            result[i + 3] = 255;
        }
        composite.WritePixels(new Int32Rect(0, 0, composite.PixelWidth, composite.PixelHeight), result, composite.PixelWidth * 4, 0);
        lastIndex = index; lastNext = next; lastBlend = fraction; UpdateCount++; WrittenBytes += result.Length;
    }
    private static byte Channel(int a, int b, int fraction, int tint)
        => (byte)(((a * (1024 - fraction) + b * fraction) * 209 + tint * 46 * 1024 + 255 * 512) / (255 * 1024));
}

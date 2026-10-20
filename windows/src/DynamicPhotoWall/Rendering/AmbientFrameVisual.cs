using System.Windows.Media.Imaging;
using Net = DynamicPhotoWall.Networking;

namespace DynamicPhotoWall.Rendering;

// Sources stay attached for the whole scene. At a timeline boundary the next
// layer becomes the opaque base; no visible Image.Source is swapped in place.
public sealed class AmbientFrameVisual
{
    private readonly Net.AmbientFrame[] frames;
    private readonly int[] representatives;
    internal SharedAmbientDrawing? CombinedDrawing { get; }
    public IReadOnlyList<System.Windows.Controls.Image> Images { get; }
    public AmbientFrameVisual(Net.AmbientFrame[] frames, BitmapSource[] textures, double width, double height, bool[]? opaqueTextures = null, bool directDrawing = false)
    {
        this.frames = frames;
        representatives = Enumerable.Range(0, textures.Length).ToArray();
        for (var i = 1; i < textures.Length; i++)
            if (textures[i].IsFrozen && ReferenceEquals(textures[i], textures[i - 1]) && (opaqueTextures?[i] ?? IsOpaque(textures[i])))
                representatives[i] = representatives[i - 1];
        Images = textures.Select(texture => new System.Windows.Controls.Image
            { Width = width, Height = height, Stretch = Stretch.Fill, Source = texture, Opacity = 0 }).ToArray();
        if (directDrawing) CombinedDrawing = new(textures, opaqueTextures ?? textures.Select(IsOpaque).ToArray(), width, height);
        Present(0);
    }
    public void Present(double elapsed)
    {
        var index = 0;
        while (index + 1 < frames.Length && frames[index + 1].At <= elapsed) index++;
        var next = Math.Min(index + 1, frames.Length - 1);
        var blend = next == index ? 0 : Math.Clamp((elapsed - frames[index].At) / Math.Max(.001, frames[next].At - frames[index].At), 0, 1);
        index = representatives[index]; next = representatives[next];
        CombinedDrawing?.Present(index, next, blend);
        // Keep a stable representative throughout a run of identical opaque
        // images. Translucent images still require their original source-over.
        for (var i = 0; i < Images.Count; i++)
        {
            var opacity = i == index ? 1 : i == next ? blend : 0;
            if (Images[i].Opacity != opacity) Images[i].Opacity = opacity;
        }
    }
    private static bool IsOpaque(BitmapSource texture)
    {
        var converted = texture.Format == PixelFormats.Pbgra32 ? texture : new FormatConvertedBitmap(texture, PixelFormats.Pbgra32, null, 0);
        var pixels = new byte[converted.PixelWidth * converted.PixelHeight * 4];
        converted.CopyPixels(pixels, converted.PixelWidth * 4, 0);
        for (var i = 3; i < pixels.Length; i += 4) if (pixels[i] != 255) return false;
        return true;
    }
}

using System.Security.Cryptography;
using System.Windows.Media.Imaging;
using DynamicPhotoWall.PhotoLibrary;
using Net = DynamicPhotoWall.Networking;

namespace DynamicPhotoWall.Rendering;

// Only frozen textures cross from preparation to the presentation dispatcher.
internal sealed class PreparedAmbientTextures
{
    private readonly Dictionary<Net.AmbientFrame, (BitmapSource Texture, bool Opaque)> textures = [];

    public (BitmapSource Texture, bool Opaque) this[Net.AmbientFrame frame] => textures[frame];

    public static PreparedAmbientTextures Create(Net.SharedScenePlan plan, IReadOnlyCollection<string> localDisplayIds,
        CancellationToken cancellation = default)
    {
        var prepared = new PreparedAmbientTextures();
        var surfaces = plan.Placements.Select(p => p.DisplayId)
            .Where(id => id == null || localDisplayIds.Contains(id)).ToHashSet();
        var unique = new Dictionary<string, (byte[] Png, BitmapSource Texture, bool Opaque)>();
        foreach (var frame in plan.Ambient.Where(f => surfaces.Contains(f.DisplayId)))
        {
            cancellation.ThrowIfCancellationRequested();
            var hash = Convert.ToHexString(SHA256.HashData(frame.Png));
            if (unique.TryGetValue(hash, out var cached) && cached.Png.AsSpan().SequenceEqual(frame.Png))
            { prepared.textures[frame] = (cached.Texture, cached.Opaque); continue; }
            using var stream = new ImageDecodeStream(frame.Png);
            var bitmap = new BitmapImage(); bitmap.BeginInit(); bitmap.CacheOption = BitmapCacheOption.OnLoad;
            bitmap.StreamSource = stream; bitmap.EndInit();
            var converted = new FormatConvertedBitmap(bitmap, PixelFormats.Pbgra32, null, 0);
            var pixels = new byte[converted.PixelWidth * converted.PixelHeight * 4];
            converted.CopyPixels(pixels, converted.PixelWidth * 4, 0); AmbientPixels.EnhanceColors(pixels);
            var opaque = true;
            for (var i = 3; i < pixels.Length; i += 4) if (pixels[i] != 255) { opaque = false; break; }
            var texture = BitmapSource.Create(converted.PixelWidth, converted.PixelHeight, 96, 96,
                PixelFormats.Pbgra32, null, pixels, converted.PixelWidth * 4);
            texture.Freeze(); unique[hash] = (frame.Png, texture, opaque);
            prepared.textures[frame] = (texture, opaque);
        }
        cancellation.ThrowIfCancellationRequested();
        return prepared;
    }
}

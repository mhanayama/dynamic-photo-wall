using System.Globalization;
using System.Windows.Media.Imaging;
using SkiaSharp;

namespace DynamicPhotoWall.PhotoLibrary;

public static class MetadataExtractor
{
    public static PhotoInfo Read(string path)
    {
        var file = new FileInfo(path);
        int width, height, orientation = 1;
        DateTime? taken = null;
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        if (Path.GetExtension(path).Equals(".webp", StringComparison.OrdinalIgnoreCase))
        {
            using var codec = SKCodec.Create(stream) ?? throw new InvalidDataException("WebPヘッダーが不正です。");
            width = codec.Info.Width; height = codec.Info.Height; orientation = (int)codec.EncodedOrigin;
        }
        else
        {
            var decoder = BitmapDecoder.Create(stream, BitmapCreateOptions.DelayCreation | BitmapCreateOptions.IgnoreColorProfile, BitmapCacheOption.None);
            var frame = decoder.Frames[0]; width = frame.PixelWidth; height = frame.PixelHeight;
            if (frame.Metadata is BitmapMetadata metadata)
            {
                orientation = ReadOrientation(metadata);
                taken = ParseDate(ReadQuery(metadata, "/app1/ifd/exif/{ushort=36867}")?.ToString()) ?? ParseDate(metadata.DateTaken);
            }
        }
        if (width < 1 || height < 1 || (long)width * height > 500_000_000) throw new InvalidDataException("画像サイズが許容範囲外です。");
        return new(path, width, height, orientation is >= 1 and <= 8 ? orientation : 1, taken, file.Length, file.LastWriteTimeUtc.Ticks);
    }
    private static object? ReadQuery(BitmapMetadata m, string query) { try { return m.GetQuery(query); } catch (Exception e) when (e is NotSupportedException or ArgumentException) { return null; } }
    private static int ReadOrientation(BitmapMetadata m)
    {
        var value = ReadQuery(m, "/app1/ifd/{ushort=274}") ?? ReadQuery(m, "/ifd/{ushort=274}");
        return value == null ? 1 : Convert.ToInt32(value, CultureInfo.InvariantCulture);
    }
    private static DateTime? ParseDate(string? text)
    {
        if (DateTime.TryParseExact(text, "yyyy:MM:dd HH:mm:ss", CultureInfo.InvariantCulture, DateTimeStyles.None, out var value)) return value;
        return DateTime.TryParse(text, CultureInfo.InvariantCulture, DateTimeStyles.None, out value) ? value : null;
    }
}

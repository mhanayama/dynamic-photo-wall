using System.Windows.Media.Imaging;
using DynamicPhotoWall.Configuration;
using SkiaSharp;

namespace DynamicPhotoWall.PhotoLibrary;

public sealed class ImageCache
{
    private sealed record Entry(string Key, BitmapSource Source, long Bytes);
    private readonly LinkedList<Entry> lru = new();
    private readonly Dictionary<string, LinkedListNode<Entry>> entries = new();
    private readonly SemaphoreSlim gate = new(1, 1);
    private long bytes;
    public long BudgetBytes { get; set; } = 256L * 1024 * 1024;
    public long CachedBytes => Interlocked.Read(ref bytes);
    public async Task<BitmapSource?> LoadAsync(PhotoInfo photo, int desiredWidth, CancellationToken token)
    {
        desiredWidth = Math.Min(photo.Width, Math.Clamp(desiredWidth, 64, 8192));
        // Limit a single decoded bitmap to ~64 MiB, including tall portrait panoramas.
        desiredWidth = Math.Min(desiredWidth, Math.Max(64, (int)Math.Sqrt(16_000_000 * photo.Aspect)));
        var key = $"{photo.Path}|{photo.Length}|{photo.ModifiedTicks}|{desiredWidth}";
        await gate.WaitAsync(token);
        try
        {
            if (entries.TryGetValue(key, out var node)) { lru.Remove(node); lru.AddFirst(node); return node.Value.Source; }
            var width = desiredWidth;
            var result = await Task.Run(() => Decode(photo, width), token);
            token.ThrowIfCancellationRequested();
            if (result == null) return null;
            var size = (long)result.PixelWidth * result.PixelHeight * 4;
            while (bytes + size > BudgetBytes && lru.Last != null) { var last = lru.Last; lru.RemoveLast(); entries.Remove(last.Value.Key); bytes -= last.Value.Bytes; }
            if (size <= BudgetBytes) { var item = lru.AddFirst(new Entry(key, result, size)); entries[key] = item; bytes += size; }
            return result;
        }
        finally { gate.Release(); }
    }
    private static BitmapSource? Decode(PhotoInfo photo, int width)
    {
        try
        {
            using var stream = new FileStream(photo.Path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            BitmapSource source;
            if (Path.GetExtension(photo.Path).Equals(".webp", StringComparison.OrdinalIgnoreCase))
            {
                using var codec = SKCodec.Create(stream) ?? throw new InvalidDataException("WebPヘッダーが不正です。");
                var scale = Math.Min(1f, (float)width / photo.Width);
                var dimensions = codec.GetScaledDimensions(scale);
                if ((long)dimensions.Width * dimensions.Height > 16_000_000) throw new InvalidDataException("WebPのデコード領域が大きすぎます。");
                using var bitmap = new SKBitmap(new SKImageInfo(dimensions.Width, dimensions.Height, SKColorType.Bgra8888, SKAlphaType.Premul));
                if (codec.GetPixels(bitmap.Info, bitmap.GetPixels()) != SKCodecResult.Success) throw new InvalidDataException("WebPをデコードできません。");
                source = BitmapSource.Create(bitmap.Width, bitmap.Height, 96, 96, PixelFormats.Pbgra32, null, bitmap.GetPixels(), bitmap.ByteCount, bitmap.RowBytes);
                source.Freeze();
            }
            else
            {
                var image = new BitmapImage(); image.BeginInit(); image.CacheOption = BitmapCacheOption.OnLoad;
                image.StreamSource = stream;
                if (photo.Orientation is >= 5 and <= 8) image.DecodePixelHeight = width; else image.DecodePixelWidth = width;
                image.EndInit(); image.Freeze(); source = image;
            }
            if (photo.Orientation == 1) return source;
            var matrix = photo.Orientation switch
            {
                2 => new Matrix(-1, 0, 0, 1, 0, 0), 3 => new Matrix(-1, 0, 0, -1, 0, 0),
                4 => new Matrix(1, 0, 0, -1, 0, 0), 5 => new Matrix(0, 1, 1, 0, 0, 0),
                6 => new Matrix(0, 1, -1, 0, 0, 0), 7 => new Matrix(0, -1, -1, 0, 0, 0),
                8 => new Matrix(0, -1, 1, 0, 0, 0), _ => Matrix.Identity
            };
            var oriented = new TransformedBitmap(source, new MatrixTransform(matrix)); oriented.Freeze(); return oriented;
        }
        catch (Exception e) when (e is not OutOfMemoryException) { Log.Write($"デコード失敗: {photo.Path}", e); return null; }
    }
    public async Task ClearAsync()
    {
        await gate.WaitAsync();
        try { entries.Clear(); lru.Clear(); bytes = 0; } finally { gate.Release(); }
    }
}

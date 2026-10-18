using System.Collections.Concurrent;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Text.Json;
using System.Windows.Media.Imaging;
using Windows.Graphics.Imaging;
using Windows.Media.FaceAnalysis;
using DynamicPhotoWall.Configuration;

namespace DynamicPhotoWall.PhotoLibrary;

public sealed class FaceAnalyzer
{
    private readonly ConcurrentDictionary<string, FaceRegion[]> cache = new();
    private readonly SemaphoreSlim gate = new(1, 1);
    private FaceDetector? detector;
    private bool unavailable;
    private int dirty;
    private readonly bool persistCache;
    private string CachePath => Path.Combine(Log.DataDirectory, "faces.json");
    public FaceAnalyzer(bool persistCache = true)
    {
        this.persistCache = persistCache;
        if (!persistCache) return;
        try
        {
            if (File.Exists(CachePath)) foreach (var pair in JsonSerializer.Deserialize<Dictionary<string, FaceRegion[]>>(File.ReadAllText(CachePath)) ?? [])
                if (pair.Value != null && pair.Value.All(f => f != null && double.IsFinite(f.X + f.Y + f.Width + f.Height)
                    && f.X >= 0 && f.Y >= 0 && f.Width > 0 && f.Height > 0 && f.X + f.Width <= 1.000001 && f.Y + f.Height <= 1.000001)) cache[pair.Key] = pair.Value;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException) { Log.Write("顔位置キャッシュを再生成します。", e); }
    }
    private static string Key(PhotoInfo photo) => $"{photo.Path}|{photo.Length}|{photo.ModifiedTicks}";
    public PhotoInfo WithCachedFaces(PhotoInfo photo) => cache.TryGetValue(Key(photo), out var found) ? photo with { Faces = found } : photo;
    public async Task<PhotoInfo> AnalyzeAsync(PhotoInfo photo, BitmapSource source, CancellationToken token)
    {
        var key = Key(photo);
        if (cache.TryGetValue(key, out var found)) return photo with { Faces = found };
        await gate.WaitAsync(token);
        try
        {
            if (cache.TryGetValue(key, out found)) return photo with { Faces = found };
            if (unavailable || !FaceDetector.IsSupported) { unavailable = true; return photo; }
            detector ??= await FaceDetector.CreateAsync().AsTask(token);
            var pixels = await Task.Run(() =>
            {
                var scale = Math.Min(1, 640d / Math.Max(source.PixelWidth, source.PixelHeight));
                var small = new TransformedBitmap(source, new ScaleTransform(scale, scale)); small.Freeze();
                var gray = new FormatConvertedBitmap(small, PixelFormats.Gray8, null, 0); gray.Freeze();
                var bytes = new byte[gray.PixelWidth * gray.PixelHeight]; gray.CopyPixels(bytes, gray.PixelWidth, 0);
                return (Bytes: bytes, Width: gray.PixelWidth, Height: gray.PixelHeight);
            }, token);
            using var software = SoftwareBitmap.CreateCopyFromBuffer(pixels.Bytes.AsBuffer(), BitmapPixelFormat.Gray8, pixels.Width, pixels.Height, BitmapAlphaMode.Ignore);
            var faces = await detector.DetectFacesAsync(software).AsTask(token);
            found = faces.Select(f => new FaceRegion((double)f.FaceBox.X / pixels.Width, (double)f.FaceBox.Y / pixels.Height,
                (double)f.FaceBox.Width / pixels.Width, (double)f.FaceBox.Height / pixels.Height)).ToArray();
            cache[key] = found; dirty++;
            if (dirty >= 16) await SaveAsync();
            return photo with { Faces = found };
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception e) { Log.Write("顔位置を取得できないため通常のパンを使用します。", e); return photo; }
        finally { gate.Release(); }
    }
    public async Task SaveAsync()
    {
        if (!persistCache) return;
        if (dirty == 0) return;
        try
        {
            var snapshot = cache.TakeLast(10000).ToDictionary(p => p.Key, p => p.Value);
            await Task.Run(() =>
            {
                Directory.CreateDirectory(Log.DataDirectory);
                File.WriteAllText(CachePath + ".tmp", JsonSerializer.Serialize(snapshot)); File.Move(CachePath + ".tmp", CachePath, true);
            });
            dirty = 0;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { Log.Write("顔位置キャッシュを保存できません。", e); }
    }
}

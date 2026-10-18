using System.Security.Cryptography;
using System.Runtime.CompilerServices;
using System.Windows.Media.Imaging;
using DynamicPhotoWall.PhotoLibrary;
using Net = DynamicPhotoWall.Networking;

namespace DynamicPhotoWall.Networking.Windows;

public sealed class WindowsPhotoProvider(Guid peerId, Func<WallSettings> settings,
    Func<IReadOnlyList<PhotoInfo>> photos, Func<Net.SharedAssetKey, bool>? cached = null) : Net.IPhotoProvider
{
    private readonly FaceAnalyzer analyzer = new(persistCache: false);
    private readonly Dictionary<string, Net.SharedAssetKey> known = [];
    public static Guid StableId(string text)
        => Guid.ParseExact(Convert.ToHexStringLower(SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(text)).AsSpan(0, 16)), "N");
    public IReadOnlyList<Net.SharedSource> Sources => settings().Folders.Select(folder =>
        new Net.SharedSource(peerId, StableId(Path.GetFullPath(folder).ToUpperInvariant()),
            Path.GetFileName(folder.TrimEnd(Path.DirectorySeparatorChar)) is { Length: > 0 } name ? name : "写真フォルダー")).ToArray();
    public async IAsyncEnumerable<(Net.SharedPhoto Photo, byte[] Original)> ReadAsync(Net.SourceSelection selection,
        [EnumeratorCancellation] CancellationToken cancellation)
    {
        var folders = settings().Folders.Where(folder => StableId(Path.GetFullPath(folder).ToUpperInvariant()) == selection.SourceId)
            .Select(Path.GetFullPath).ToArray();
        var snapshot = photos().Where(photo => folders.Any(folder => photo.Path.StartsWith(
            folder.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))).ToArray();
        foreach (var photo in snapshot)
        {
            cancellation.ThrowIfCancellationRequested();
            if (photo.Length <= 0 || photo.Length > Net.PhotoTransferService.MaximumAssetBytes) continue;
            var fingerprint = $"{selection.SourceId:N}:{selection.GenerationId:N}:{photo.Path}:{photo.Length}:{photo.ModifiedTicks}";
            if (known.TryGetValue(fingerprint, out var previous) && cached?.Invoke(previous) == true) continue;
            byte[] bytes;
            try { bytes = await File.ReadAllBytesAsync(photo.Path, cancellation); }
            catch (IOException) { continue; }
            BitmapSource image;
            try { image = NetworkBitmap.Decode(bytes, 1024, photo.Orientation); }
            catch (Exception error) when (error is NotSupportedException or FileFormatException or InvalidDataException)
                { CryptographicOperations.ZeroMemory(bytes); continue; }
            var current = new FileInfo(photo.Path);
            if (current.Length != photo.Length || current.LastWriteTimeUtc.Ticks != photo.ModifiedTicks)
                { CryptographicOperations.ZeroMemory(bytes); continue; }
            var withFaces = await analyzer.AnalyzeAsync(photo, image, cancellation);
            var faces = withFaces.Faces?.Select(f => new Net.FaceRegion(Math.Clamp(f.X, 0, 1), Math.Clamp(f.Y, 0, 1),
                Math.Min(f.Width, 1 - Math.Clamp(f.X, 0, 1)), Math.Min(f.Height, 1 - Math.Clamp(f.Y, 0, 1))))
                .Where(f => f.Width > 0 && f.Height > 0).ToArray() ?? [];
            var metadata = new Net.SharedFaceMetadata(1, photo.Width, photo.Height, "windows-face-detector", "1",
                withFaces.Faces == null ? Net.FaceAnalysisState.Failed : Net.FaceAnalysisState.Complete, faces);
            var key = new Net.SharedAssetKey(peerId, selection.SourceId, selection.GenerationId, Convert.ToHexStringLower(SHA256.HashData(bytes)));
            known[fingerprint] = key;
            yield return (new(key, photo.Width, photo.Height, bytes.Length, metadata) { Orientation = photo.Orientation }, bytes);
        }
    }
}

public static class NetworkBitmap
{
    public static BitmapSource Decode(byte[] bytes, int width, int orientation = 1)
    {
        using var stream = new MemoryStream(bytes, false);
        BitmapSource source;
        using var codec = SkiaSharp.SKCodec.Create(stream);
        if (codec != null && codec.EncodedFormat == SkiaSharp.SKEncodedImageFormat.Webp)
        {
            var dimensions = codec.GetScaledDimensions(Math.Min(1f, (float)width / Math.Max(1, codec.Info.Width)));
            using var bitmap = new SkiaSharp.SKBitmap(new SkiaSharp.SKImageInfo(dimensions.Width, dimensions.Height,
                SkiaSharp.SKColorType.Bgra8888, SkiaSharp.SKAlphaType.Premul));
            if (codec.GetPixels(bitmap.Info, bitmap.GetPixels()) != SkiaSharp.SKCodecResult.Success) throw new InvalidDataException("画像をデコードできません。");
            source = BitmapSource.Create(bitmap.Width, bitmap.Height, 96, 96, PixelFormats.Pbgra32, null, bitmap.GetPixels(), bitmap.ByteCount, bitmap.RowBytes);
            source.Freeze();
        }
        else
        {
            stream.Position = 0;
            var bitmap = new BitmapImage(); bitmap.BeginInit(); bitmap.CacheOption = BitmapCacheOption.OnLoad;
            bitmap.StreamSource = stream;
            if (orientation is >= 5 and <= 8) bitmap.DecodePixelHeight = width; else bitmap.DecodePixelWidth = width;
            bitmap.EndInit(); bitmap.Freeze(); source = bitmap;
        }
        if (orientation == 1) return source;
        var matrix = orientation switch
        {
            2 => new Matrix(-1, 0, 0, 1, 0, 0), 3 => new Matrix(-1, 0, 0, -1, 0, 0), 4 => new Matrix(1, 0, 0, -1, 0, 0),
            5 => new Matrix(0, 1, 1, 0, 0, 0), 6 => new Matrix(0, 1, -1, 0, 0, 0), 7 => new Matrix(0, -1, -1, 0, 0, 0),
            8 => new Matrix(0, -1, 1, 0, 0, 0), _ => Matrix.Identity
        };
        var oriented = new TransformedBitmap(source, new MatrixTransform(matrix)); oriented.Freeze(); return oriented;
    }
}

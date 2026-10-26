using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.ML.OnnxRuntime;
using Microsoft.ML.OnnxRuntime.Tensors;
using SkiaSharp;

namespace DpwSpatial;

internal sealed record Pixels(int Width, int Height, byte[] Rgba)
{
    public static Pixels Load(string path)
    {
        using var stream = File.OpenRead(path);
        using var codec = SKCodec.Create(stream) ?? throw new InvalidDataException("JPEG・PNG・WebPを読み込めません。");
        if ((long)codec.Info.Width * codec.Info.Height > 64_000_000) throw new InvalidDataException("6400万画素以下の画像を使用してください。");
        var scale = Math.Min(1f, 2048f / Math.Max(codec.Info.Width, codec.Info.Height));
        var size = codec.GetScaledDimensions(scale);
        using var decoded = new SKBitmap(new SKImageInfo(size.Width, size.Height, SKColorType.Rgba8888, SKAlphaType.Unpremul));
        if (codec.GetPixels(decoded.Info, decoded.GetPixels()) != SKCodecResult.Success) throw new InvalidDataException("画像デコードに失敗しました。");
        var factor = Math.Min(1.0, 2048.0 / Math.Max(decoded.Width, decoded.Height));
        using var small = Resize(decoded, Math.Max(1, (int)Math.Round(decoded.Width * factor)), Math.Max(1, (int)Math.Round(decoded.Height * factor)));
        var raw = new byte[small.Width * small.Height * 4];
        Marshal.Copy(small.GetPixels(), raw, 0, raw.Length);
        return Orient(new(small.Width, small.Height, raw), (int)codec.EncodedOrigin);
    }

    internal static Pixels Orient(Pixels source, int orientation)
    {
        int w = source.Width, h = source.Height;
        var result = new Pixels(orientation is >= 5 and <= 8 ? h : w, orientation is >= 5 and <= 8 ? w : h, new byte[w * h * 4]);
        for (var y = 0; y < h; y++) for (var x = 0; x < w; x++)
        {
            var (dx, dy) = orientation switch {
                2 => (w - 1 - x, y), 3 => (w - 1 - x, h - 1 - y), 4 => (x, h - 1 - y),
                5 => (y, x), 6 => (h - 1 - y, x), 7 => (h - 1 - y, w - 1 - x), 8 => (y, w - 1 - x), _ => (x, y) };
            Array.Copy(source.Rgba, (y * w + x) * 4, result.Rgba, (dy * result.Width + dx) * 4, 4);
        }
        return result;
    }

    public SKBitmap Bitmap()
    {
        var bitmap = new SKBitmap(new SKImageInfo(Width, Height, SKColorType.Rgba8888, SKAlphaType.Unpremul));
        Marshal.Copy(Rgba, 0, bitmap.GetPixels(), Rgba.Length); return bitmap;
    }
    internal static SKBitmap Resize(SKBitmap source, int width, int height)
    {
        if (source.Width == width && source.Height == height) return source.Copy();
        var resized = new SKBitmap(new SKImageInfo(width, height, SKColorType.Rgba8888, SKAlphaType.Unpremul));
        using var canvas = new SKCanvas(resized);
        canvas.Clear(SKColors.Black);
        using var image = SKImage.FromBitmap(source);
        canvas.DrawImage(image, new SKRect(0, 0, width, height), new SKSamplingOptions(SKCubicResampler.Mitchell));
        return resized;
    }
    public void Save(string path)
    {
        using var bitmap = Bitmap(); using var image = SKImage.FromBitmap(bitmap); using var data = image.Encode(SKEncodedImageFormat.Png, 100);
        using var file = File.Create(path); data.SaveTo(file);
    }
}

internal sealed record DepthPair(Pixels Photo, byte[] Depth, int DepthWidth, int DepthHeight, string Directory, string Backend, bool CacheHit);
internal sealed record Manifest(string Version, string Key, string ModelHash, string PhotoHash, string DepthHash, string Backend, int Width, int Height, double InferenceSeconds);

internal static class DepthPipeline
{
    public const string ModelSha = "afb6a5c28f3b6bf1618c6e43f02073ef9dfdc70e937502d51603e57b0a1df10c";
    public const string Version = "dav2-small-64fe43e-imagenet-rgb-518-m14-mitchell-p01-p99-v1";
    public static string HashFile(string file) { using var stream = File.OpenRead(file); return Convert.ToHexStringLower(SHA256.HashData(stream)); }
    internal static string CacheKey(string photoHash, string modelHash) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes($"{photoHash}|{modelHash}|{Version}")));
    internal static (int Width, int Height) InputSize(int width, int height)
    {
        var sw = 518.0 / width; var sh = 518.0 / height;
        var scale = Math.Abs(1 - sw) < Math.Abs(1 - sh) ? sw : sh;
        int Multiple(double n) => Math.Max(14, (int)Math.Round(n / 14) * 14);
        return (Multiple(width * scale), Multiple(height * scale));
    }
    internal static byte[] Normalize(float[] values)
    {
        if (values.Length == 0 || values.Any(v => !float.IsFinite(v))) throw new InvalidDataException("深度出力が不正です。");
        var sorted = values.Order().ToArray();
        var low = sorted[(int)((sorted.Length - 1) * .01)]; var high = sorted[(int)((sorted.Length - 1) * .99)];
        if (high - low < 1e-6) return Enumerable.Repeat((byte)128, values.Length).ToArray();
        return values.Select(v => (byte)Math.Round(Math.Clamp((v - low) / (high - low), 0, 1) * 255)).ToArray();
    }
    public static DepthPair Generate(string source, string model, string output, string backend = "auto", bool force = false, Action<string>? progress = null)
    {
        if (!new[] { "auto", "directml", "cpu" }.Contains(backend)) throw new ArgumentException("backend: auto / directml / cpu");
        var sourceHash = HashFile(source);
        var photo = Pixels.Load(source); // Same oriented, bounded source is used by inference and playback.
        if (HashFile(source) != sourceHash) throw new IOException("読み込み中に写真が変更されました。再試行してください。");
        progress?.Invoke("モデルと画像を確認中…");
        var modelHash = HashFile(model);
        if (modelHash != ModelSha) throw new InvalidDataException("固定版のDepth Anything V2 Small ONNXモデルとSHA256が一致しません。Get-Model.ps1を実行してください。");
        var key = CacheKey(sourceHash, modelHash);
        var directory = Path.Combine(Path.GetFullPath(output), key);
        var manifestPath = Path.Combine(directory, "manifest.json");
        if (!force && File.Exists(manifestPath))
        {
            try {
                var m = JsonSerializer.Deserialize<Manifest>(File.ReadAllText(manifestPath));
                if (m is not null && m.Version == Version && m.Key == key && m.ModelHash == modelHash
                    && m.PhotoHash == HashFile(Path.Combine(directory, "photo.png")) && m.DepthHash == HashFile(Path.Combine(directory, "depth.png")))
                {
                    var cached = Pixels.Load(Path.Combine(directory, "depth.png"));
                    if (cached.Width != photo.Width || cached.Height != photo.Height) throw new InvalidDataException("キャッシュの寸法不一致");
                    return new(photo, Enumerable.Range(0, cached.Width * cached.Height).Select(i => cached.Rgba[i * 4]).ToArray(), cached.Width, cached.Height, directory, m.Backend, true);
                }
            } catch (Exception e) when (e is IOException or JsonException or InvalidDataException) { progress?.Invoke("無効なキャッシュを再生成します。"); }
        }
        var (iw, ih) = InputSize(photo.Width, photo.Height);
        using var original = photo.Bitmap(); using var input = Pixels.Resize(original, iw, ih);
        var rgb = new byte[iw * ih * 4]; Marshal.Copy(input.GetPixels(), rgb, 0, rgb.Length);
        var tensor = new DenseTensor<float>(new[] { 1, 3, ih, iw });
        float[] mean = [.485f, .456f, .406f], std = [.229f, .224f, .225f];
        for (var c = 0; c < 3; c++) for (var y = 0; y < ih; y++) for (var x = 0; x < iw; x++)
            tensor[0, c, y, x] = (rgb[(y * iw + x) * 4 + c] / 255f - mean[c]) / std[c];
        (float[] Values, int Width, int Height) Infer(bool gpu)
        {
            using var options = new SessionOptions { EnableMemoryPattern = false, ExecutionMode = ExecutionMode.ORT_SEQUENTIAL, GraphOptimizationLevel = GraphOptimizationLevel.ORT_ENABLE_ALL };
            options.AddFreeDimensionOverrideByName("batch_size", 1);
            options.AddFreeDimensionOverrideByName("height", ih); options.AddFreeDimensionOverrideByName("width", iw);
            if (gpu) options.AppendExecutionProvider_DML(0);
            using var session = new InferenceSession(model, options);
            var name = session.InputMetadata.Keys.Single();
            using var results = session.Run([NamedOnnxValue.CreateFromTensor(name, tensor)]);
            var result = results.First().AsTensor<float>(); var dimensions = result.Dimensions.ToArray();
            var ow = dimensions[^1]; var oh = dimensions[^2];
            if (result.Length != ow * oh) throw new InvalidDataException("深度出力の形状が不正です。");
            return (result.ToArray(), ow, oh);
        }
        progress?.Invoke("深度を生成中… 初回はモデルの準備に時間がかかります。");
        var timer = Stopwatch.StartNew(); var actualBackend = backend == "cpu" ? "CPU" : "DirectML preferred (adapter 0)";
        (float[] Values, int Width, int Height) prediction;
        try { prediction = Infer(backend != "cpu"); }
        catch (OnnxRuntimeException e) when (backend == "auto") { progress?.Invoke($"DirectMLを使用できないためCPUへ切り替えます: {e.Message}"); actualBackend = "CPU (DirectML fallback)"; prediction = Infer(false); }
        timer.Stop();
        var normalized = Normalize(prediction.Values);
        var rgba = new byte[normalized.Length * 4];
        for (var i = 0; i < normalized.Length; i++) { rgba[i * 4] = rgba[i * 4 + 1] = rgba[i * 4 + 2] = normalized[i]; rgba[i * 4 + 3] = 255; }
        using var smallDepth = new Pixels(prediction.Width, prediction.Height, rgba).Bitmap();
        using var resizedDepth = Pixels.Resize(smallDepth, photo.Width, photo.Height);
        var depthRgba = new byte[photo.Width * photo.Height * 4]; Marshal.Copy(resizedDepth.GetPixels(), depthRgba, 0, depthRgba.Length);
        var depths = Enumerable.Range(0, photo.Width * photo.Height).Select(i => depthRgba[i * 4]).ToArray();
        if (HashFile(source) != sourceHash) throw new IOException("深度生成中に写真が変更されました。再試行してください。");
        Directory.CreateDirectory(directory);
        var suffix = "." + Guid.NewGuid().ToString("N") + ".tmp";
        var photoPath = Path.Combine(directory, "photo.png"); var depthPath = Path.Combine(directory, "depth.png");
        photo.Save(photoPath + suffix); new Pixels(photo.Width, photo.Height, depthRgba).Save(depthPath + suffix);
        File.Move(photoPath + suffix, photoPath, true); File.Move(depthPath + suffix, depthPath, true);
        var manifest = new Manifest(Version, key, modelHash, HashFile(photoPath), HashFile(depthPath), actualBackend, photo.Width, photo.Height, timer.Elapsed.TotalSeconds);
        File.WriteAllText(manifestPath + suffix, JsonSerializer.Serialize(manifest, new JsonSerializerOptions { WriteIndented = true })); File.Move(manifestPath + suffix, manifestPath, true);
        return new(photo, depths, photo.Width, photo.Height, directory, actualBackend, false);
    }
}

internal static class SpatialMotion
{
    public const double DefaultStrength = 50;
    public static (double Position, bool Done) At(double seconds, double duration, bool pingPong, int direction, bool smooth = true)
    {
        var passes = Math.Max(0, double.IsFinite(seconds) ? seconds : 0) / Math.Clamp(double.IsFinite(duration) ? duration : 20, 1, 300);
        var phase = Math.Min(1, passes);
        if (pingPong) { var cycle = passes % 2; phase = cycle <= 1 ? cycle : 2 - cycle; }
        if (smooth) phase = phase * phase * (3 - 2 * phase);
        return ((direction < 0 ? -1 : 1) * (phase * 2 - 1), !pingPong && passes >= 1);
    }
    public static float Amplitude(double strength) => (float)(Math.Clamp(double.IsFinite(strength) ? strength : DefaultStrength, 0, 100) / 100 * .24);
}

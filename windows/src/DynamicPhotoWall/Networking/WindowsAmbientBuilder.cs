using System.Security.Cryptography;
using System.Runtime.InteropServices;
using System.Windows.Media.Imaging;
using DynamicPhotoWall.Rendering;
using SkiaSharp;
using Net = DynamicPhotoWall.Networking;

namespace DynamicPhotoWall.Networking.Windows;

internal static class WindowsAmbientBuilder
{
    public static Net.AmbientFrame[] Build(Net.SharedScenePlan plan, IReadOnlyDictionary<string, Net.SharedPhoto> catalog,
        Func<Net.SharedAssetKey, byte[]> read, CancellationToken token)
    {
        var images = new Dictionary<string, SKBitmap>();
        var frames = new List<Net.AmbientFrame>();
        try
        {
            foreach (var key in plan.Placements.Select(p => p.Asset).Distinct())
            {
                var bytes = read(key);
                try
                {
                    var source = NetworkBitmap.Decode(bytes, 128, catalog[key.OpaqueId].Orientation);
                    var converted = new FormatConvertedBitmap(source, PixelFormats.Pbgra32, null, 0);
                    var bitmap = new SKBitmap(new SKImageInfo(converted.PixelWidth, converted.PixelHeight, SKColorType.Bgra8888, SKAlphaType.Premul));
                    converted.CopyPixels(new Int32Rect(0, 0, converted.PixelWidth, converted.PixelHeight), bitmap.GetPixels(), bitmap.ByteCount, bitmap.RowBytes);
                    images[key.OpaqueId] = bitmap;
                }
                finally { CryptographicOperations.ZeroMemory(bytes); }
            }
            var surfaces = plan.Placements.Select(p => p.DisplayId).Distinct().ToArray();
            var count = Math.Max(2, Math.Min(24, 64 / surfaces.Length));
            foreach (var surface in surfaces)
            {
                var display = surface == null ? null : plan.Displays.First(d => d.Key.LayoutId == surface);
                var originX = display == null ? 0 : display.X - plan.Displays.Min(d => d.X);
                var originY = display == null ? 0 : display.Y - plan.Displays.Min(d => d.Y);
                var width = display?.Width ?? plan.Viewport.Width; var height = display?.Height ?? plan.Viewport.Height;
                var h = Math.Max(1, (int)Math.Round(256 * height / width));
                for (var index = 0; index < count; index++)
                {
                    token.ThrowIfCancellationRequested(); var at = plan.Duration * index / (count - 1);
                    using var bitmap = new SKBitmap(256, Math.Min(256, h)); using var canvas = new SKCanvas(bitmap);
                    canvas.Clear(SKColors.Transparent); canvas.Scale((float)(256 / width), (float)(bitmap.Height / height));
                    foreach (var p in plan.Placements.Where(p => p.DisplayId == surface))
                    {
                        var evaluated = Net.SceneEvaluation.Evaluate(p, Math.Min(at, plan.Duration - .001));
                        if (evaluated.Opacity <= 0) continue;
                        canvas.Save(); canvas.ClipRect(new((float)(p.Clip.X - originX), (float)(p.Clip.Y - originY),
                            (float)(p.Clip.X - originX + p.Clip.Width), (float)(p.Clip.Y - originY + p.Clip.Height)));
                        var x = evaluated.X - originX + (1 - evaluated.Scale) * p.CenterX * p.Width;
                        var y = evaluated.Y - originY + (1 - evaluated.Scale) * p.CenterY * p.Height;
                        using var paint = new SKPaint { Color = SKColors.White.WithAlpha((byte)(255 * evaluated.Opacity)), IsAntialias = true };
                        canvas.DrawBitmap(images[p.Asset.OpaqueId], new SKRect((float)x, (float)y,
                            (float)(x + p.Width * evaluated.Scale), (float)(y + p.Height * evaluated.Scale)), paint);
                        canvas.Restore();
                    }
                    canvas.ResetMatrix();
                    var pixels = new byte[bitmap.ByteCount]; Marshal.Copy(bitmap.GetPixels(), pixels, 0, pixels.Length);
                    if (!AmbientPixels.ExtendPadding(pixels, bitmap.Width, bitmap.Height)) continue;
                    Marshal.Copy(pixels, 0, bitmap.GetPixels(), pixels.Length);
                    using var blurred = new SKBitmap(bitmap.Width, bitmap.Height); using var blurredCanvas = new SKCanvas(blurred);
                    using var blur = new SKPaint { ImageFilter = SKImageFilter.CreateBlur(7, 7, SKShaderTileMode.Clamp) };
                    blurredCanvas.DrawBitmap(bitmap, 0, 0, blur);
                    using var image = SKImage.FromBitmap(blurred); using var png = image.Encode(SKEncodedImageFormat.Png, 100);
                    frames.Add(new(at, png.ToArray()) { DisplayId = surface });
                }
            }
            return frames.ToArray();
        }
        finally { foreach (var bitmap in images.Values) bitmap.Dispose(); }
    }
}

using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using DynamicPhotoWall.Configuration;
using DynamicPhotoWall.Motion;
using SkiaSharp;

namespace DynamicPhotoWall.Rendering;

// Sample only the visible photo layer, never the ambient layer itself. Like
// YouTube's published storyboard approach, blur a small preview rather than
// performing a full-resolution blur on every presentation frame.
public sealed class GlassBackground : IDisposable
{
    private readonly Canvas foreground;
    private readonly Viewport viewport;
    private readonly AnimationScheduler scheduler;
    private readonly AmbientTexturePresenter presenter;
    private readonly AmbientTransition colors = new();
    private readonly DispatcherTimer timer;
    private readonly int width, height;
    private readonly CancellationTokenSource lifetime = new();
    private bool busy, disposed, failed;
    public int UpdateCount { get; private set; }
    public double MaximumCaptureMilliseconds { get; private set; }
    public BitmapSource? Texture => presenter.Texture;

    public GlassBackground(Canvas foreground, Viewport viewport, AnimationScheduler scheduler, ImageBrush target, TransitionController transitions)
    {
        this.foreground = foreground; this.viewport = viewport; this.scheduler = scheduler;
        presenter = new(target, foreground, transitions);
        var scale = 160 / Math.Max(viewport.Width, viewport.Height);
        width = Math.Max(1, (int)Math.Ceiling(viewport.Width * scale));
        height = Math.Max(1, (int)Math.Ceiling(viewport.Height * scale));
        timer = new DispatcherTimer(DispatcherPriority.Background, foreground.Dispatcher) { Interval = TimeSpan.FromMilliseconds(125) };
        timer.Tick += Tick;
    }

    public async Task StartAsync(CancellationToken token)
    {
        await UpdateAsync(); token.ThrowIfCancellationRequested();
        if (!disposed && !failed) timer.Start();
    }

    private async void Tick(object? sender, EventArgs e)
    {
        if (!busy && !disposed && !failed && !scheduler.IsPaused) await UpdateAsync();
    }

    private async Task UpdateAsync()
    {
        if (busy || disposed) return;
        busy = true;
        try
        {
            var clock = Stopwatch.StartNew();
            var drawing = new DrawingVisual();
            using (var context = drawing.RenderOpen())
            {
                var brush = new VisualBrush(foreground) { AutoLayoutContent = false, Stretch = Stretch.Fill,
                    ViewboxUnits = BrushMappingMode.Absolute, Viewbox = new Rect(0, 0, viewport.Width, viewport.Height) };
                context.DrawRectangle(brush, null, new Rect(0, 0, width, height));
            }
            var sample = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32);
            sample.Render(drawing);
            var pixels = new byte[width * height * 4]; sample.CopyPixels(pixels, width * 4, 0);
            MaximumCaptureMilliseconds = Math.Max(MaximumCaptureMilliseconds, clock.Elapsed.TotalMilliseconds);
            var at = scheduler.ElapsedSeconds;
            var result = await Task.Run(() => Process(pixels, at, lifetime.Token), lifetime.Token);
            if (disposed || result == null) return;
            presenter.SetFrame(result, width, height, scheduler.ElapsedSeconds); UpdateCount++;
        }
        catch (OperationCanceledException) when (disposed) { }
        catch (Exception e)
        {
            // Keep the last valid background and stop retrying a broken visual.
            failed = true; timer.Stop(); Log.Write("背景の更新を停止しました。", e);
        }
        finally { busy = false; if (disposed) lifetime.Dispose(); }
    }

    private byte[]? Process(byte[] pixels, double at, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        // Extend the nearest visible color into transparent padding. Treating
        // empty margins as black would darken narrow portraits and gallery gaps.
        if (!AmbientPixels.ExtendPadding(pixels, width, height)) return null;
        using var source = new SKBitmap(new SKImageInfo(width, height, SKColorType.Bgra8888, SKAlphaType.Premul));
        Marshal.Copy(pixels, 0, source.GetPixels(), pixels.Length);
        using var blurred = new SKBitmap(source.Info);
        using (var canvas = new SKCanvas(blurred))
        using (var filter = SKImageFilter.CreateBlur(7, 7, SKShaderTileMode.Clamp))
        using (var paint = new SKPaint { ImageFilter = filter }) canvas.DrawBitmap(source, 0, 0, paint);
        Marshal.Copy(blurred.GetPixels(), pixels, 0, pixels.Length);
        AmbientPixels.EnhanceColors(pixels);
        token.ThrowIfCancellationRequested();
        return colors.Push(pixels, at);
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true; timer.Stop(); timer.Tick -= Tick; lifetime.Cancel();
        if (!busy) lifetime.Dispose();
        presenter.Dispose();
    }
}

using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using System.Windows.Media.Animation;
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
    private readonly TransitionController transitions;
    private readonly AmbientTexturePresenter presenter;
    private readonly AmbientTransition colors = new();
    private readonly DispatcherTimer timer;
    private readonly int width, height;
    private readonly CancellationTokenSource lifetime = new();
    private readonly bool continuousReference;
    private readonly Dictionary<Storyboard, double> motions = [];
    private readonly HashSet<Storyboard> tracked = [];
    private CancellationTokenSource? processing;
    private AmbientCompositionKey? lastComposition;
    private bool busy, disposed, failed, started, queued, dirty = true;
    private int revision;
    private long processTicks;
    public int UpdateCount { get; private set; }
    public int CaptureCount { get; private set; }
    public int GeometryCheckCount { get; private set; }
    public int DiscardedCount { get; private set; }
    public bool IsSampling => timer.IsEnabled;
    public bool IsRefreshing => busy || queued;
    public double TotalCaptureMilliseconds { get; private set; }
    public double TotalProcessMilliseconds => Interlocked.Read(ref processTicks) * 1000d / Stopwatch.Frequency;
    public double MaximumCaptureMilliseconds { get; private set; }
    public BitmapSource? Texture => presenter.Texture;

    // continuousReference retains the original capture/filter/presentation path
    // for isolated A/B diagnostics. It is never enabled by application settings.
    public GlassBackground(Canvas foreground, Viewport viewport, AnimationScheduler scheduler, ImageBrush target, TransitionController transitions,
        bool continuousReference = false)
    {
        this.foreground = foreground; this.viewport = viewport; this.scheduler = scheduler;
        this.transitions = transitions; this.continuousReference = continuousReference;
        presenter = new(target, foreground, transitions, continuousReference);
        var scale = 160 / Math.Max(viewport.Width, viewport.Height);
        width = Math.Max(1, (int)Math.Ceiling(viewport.Width * scale));
        height = Math.Max(1, (int)Math.Ceiling(viewport.Height * scale));
        timer = new DispatcherTimer(DispatcherPriority.Background, foreground.Dispatcher) { Interval = TimeSpan.FromMilliseconds(125) };
        timer.Tick += Tick;
        scheduler.PauseChanged += PauseChanged;
        if (!continuousReference) transitions.ActivityChanged += ActivityChanged;
    }

    public async Task StartAsync(CancellationToken token)
    {
        started = true;
        await UpdateAsync(token, initial: true); token.ThrowIfCancellationRequested();
        UpdateTimer();
    }

    public void Invalidate()
    {
        if (disposed || failed) return;
        dirty = true; revision++; processing?.Cancel(); QueueUpdate(); UpdateTimer();
    }

    private void PauseChanged()
    {
        // A completed worker from before pause must never replace the held image.
        Invalidate();
    }

    private bool TargetsForeground(Storyboard board) => board.Children.Any(animation =>
    {
        DependencyObject? target = Storyboard.GetTarget(animation);
        while (target is Visual)
        {
            if (target == foreground) return true;
            target = VisualTreeHelper.GetParent(target);
        }
        return false;
    });

    private void ActivityChanged(Storyboard board, FrameworkElement root, bool active)
    {
        if (active)
        {
            if (!TargetsForeground(board)) return;
            tracked.Add(board);
            var seconds = board.Children.Max(animation => (animation.BeginTime?.TotalSeconds ?? 0)
                + (animation.Duration.HasTimeSpan ? animation.Duration.TimeSpan.TotalSeconds : 0));
            motions[board] = scheduler.ElapsedSeconds + seconds;
        }
        else
        {
            if (!tracked.Remove(board)) return;
            motions.Remove(board);
        }
        // Queue after the caller has committed final geometry or replaced children.
        Invalidate();
    }

    private void Tick(object? sender, EventArgs e)
    {
        var ended = motions.Where(pair => pair.Value <= scheduler.ElapsedSeconds).Select(pair => pair.Key).ToArray();
        foreach (var board in ended) motions.Remove(board);
        if (ended.Length > 0) Invalidate(); // Exact endpoint, even below a quantization boundary.
        else QueueUpdate();
        UpdateTimer();
    }

    private void UpdateTimer()
    {
        if (!started || disposed || failed || scheduler.IsPaused || (!continuousReference && motions.Count == 0)) timer.Stop();
        else timer.Start();
    }

    private void QueueUpdate()
    {
        if (!started || queued || busy || disposed || failed || scheduler.IsPaused) return;
        queued = true;
        foreground.Dispatcher.BeginInvoke(DispatcherPriority.Background, new Action(async () =>
        {
            queued = false;
            if (!scheduler.IsPaused) await UpdateAsync();
        }));
    }

    private async Task UpdateAsync(CancellationToken token = default, bool initial = false)
    {
        if (busy || disposed || failed || (scheduler.IsPaused && !initial)) return;
        busy = true;
        using var request = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token, token);
        processing = request;
        var capturedRevision = revision;
        var force = dirty; dirty = false;
        try
        {
            token.ThrowIfCancellationRequested();
            foreground.UpdateLayout();
            AmbientCompositionKey? composition = null;
            if (!continuousReference)
            {
                composition = AmbientCompositionKey.Capture(foreground, viewport); GeometryCheckCount++;
                if (!force && composition.Matches(lastComposition)) return;
            }
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
            CaptureCount++;
            var captureMilliseconds = clock.Elapsed.TotalMilliseconds;
            TotalCaptureMilliseconds += captureMilliseconds;
            MaximumCaptureMilliseconds = Math.Max(MaximumCaptureMilliseconds, captureMilliseconds);
            var at = scheduler.ElapsedSeconds;
            var result = await Task.Run(() =>
            {
                var begin = Stopwatch.GetTimestamp();
                try { return Process(pixels, at, request.Token); }
                finally { Interlocked.Add(ref processTicks, Stopwatch.GetTimestamp() - begin); }
            }, request.Token);
            if (disposed || request.IsCancellationRequested || capturedRevision != revision || (scheduler.IsPaused && !initial))
            { DiscardedCount++; return; }
            lastComposition = composition;
            if (result == null) return;
            presenter.SetFrame(result, width, height, scheduler.ElapsedSeconds); UpdateCount++;
        }
        catch (OperationCanceledException) when (request.IsCancellationRequested)
        {
            DiscardedCount++;
            if (token.IsCancellationRequested) throw;
        }
        catch (Exception e)
        {
            // Keep the last valid background and stop retrying a broken visual.
            failed = true; timer.Stop(); Log.Write("背景の更新を停止しました。", e);
        }
        finally
        {
            processing = null; busy = false;
            if (disposed) lifetime.Dispose();
            else { if (dirty) QueueUpdate(); UpdateTimer(); }
        }
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
        // The event-driven path sends a full target once. Its color response is
        // a compositor animation, independent of texture generation frequency.
        return continuousReference ? colors.Push(pixels, at) : pixels;
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true; timer.Stop(); timer.Tick -= Tick; lifetime.Cancel();
        scheduler.PauseChanged -= PauseChanged; transitions.ActivityChanged -= ActivityChanged;
        motions.Clear(); tracked.Clear();
        if (!busy) lifetime.Dispose();
        presenter.Dispose();
    }
}

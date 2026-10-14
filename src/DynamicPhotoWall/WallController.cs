using System.Windows.Media.Imaging;
using System.Windows.Threading;
using DynamicPhotoWall.Configuration;
using DynamicPhotoWall.DesktopIntegration;
using DynamicPhotoWall.Motion;
using DynamicPhotoWall.PhotoLibrary;
using DynamicPhotoWall.Rendering;

namespace DynamicPhotoWall;

public sealed class WallController : IAsyncDisposable
{
    private sealed record Prepared(CompositionPlan Plan, IReadOnlyList<BitmapSource> Images);
    private readonly PhotoScanner library = new();
    private readonly ImageCache cache = new();
    private readonly FaceAnalyzer faces = new();
    private readonly PhotoSelector selector = new();
    private readonly CompositionEngine composition;
    private readonly Random random = new();
    private readonly SemaphoreSlim operations = new(1, 1);
    private readonly CancellationTokenSource lifetime = new();
    private readonly AnimationScheduler scheduler = new();
    private readonly TransitionController transitions = new();
    private readonly DesktopWindowHost host = new();
    private readonly TaskbarVisibility taskbar = new();
    private readonly ExplorerRecovery recovery = new();
    private readonly Dispatcher dispatcher = Dispatcher.CurrentDispatcher;
    private readonly DispatcherTimer occlusionDebounce;
    private readonly HashSet<string> failed = new(StringComparer.OrdinalIgnoreCase);
    private CancellationTokenSource? playback;
    private Task? playTask;
    private CancellationTokenSource? sceneLifetime;
    private PhotoRenderer? renderer;
    private MonitorDescriptor? monitor;
    private bool desiredRunning, userPaused, covered, sleeping;
    private bool disposed;
    public WallSettings Settings { get; private set; }
    public string Status { get; private set; } = "停止中";
    public int PhotoCount => library.Photos.Count;
    public bool IsPaused => userPaused;
    public bool IsRunning => renderer != null && desiredRunning;
    public CompositionMode? CurrentMode => renderer?.Current?.Mode;
    public IReadOnlyList<string> DisplayedPhotoPaths => renderer?.Current?.Photos.Select(p => p.Path).ToArray() ?? [];
    public event Action? Changed;
    public WallController(WallSettings settings)
    {
        Settings = settings; composition = new(selector);
        library.Changed += LibraryChanged;
        recovery.EnvironmentChanged += () => _ = GuardAsync(RecoverAsync);
        recovery.PowerSuspended += value => { sleeping = value; UpdatePause(); };
        occlusionDebounce = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(250) };
        occlusionDebounce.Tick += (_, _) => { occlusionDebounce.Stop(); CheckOcclusion(); };
        recovery.OcclusionChanged += () => { if (!occlusionDebounce.IsEnabled) occlusionDebounce.Start(); };
    }
    public async Task InitializeAsync()
    {
        SetStatus("写真を検索中…");
        await library.ConfigureAsync(Settings, lifetime.Token);
        if (Settings.StartOnLaunch && Settings.MonitorId != null && Settings.Folders.Count > 0) await StartAsync();
        else SetStatus($"停止中 · {PhotoCount}枚");
    }
    public async Task ApplyAsync(WallSettings settings)
    {
        await operations.WaitAsync();
        try
        {
            var restart = desiredRunning;
            await StopPlaybackAsync();
            Settings = settings; failed.Clear();
            cache.BudgetBytes = settings.CacheMegabytes * 1024L * 1024;
            await cache.ClearAsync();
            await library.ConfigureAsync(Settings, lifetime.Token);
            if (restart) StartPlayback(); else SetStatus($"停止中 · {PhotoCount}枚");
        }
        finally { operations.Release(); }
    }
    public async Task StartAsync()
    {
        await operations.WaitAsync();
        try { desiredRunning = true; if (renderer == null) StartPlayback(); else { userPaused = false; UpdatePause(); } }
        finally { operations.Release(); }
    }
    private void StartPlayback()
    {
        if (Settings.MonitorId == null) { desiredRunning = false; SetStatus("表示対象ディスプレイを選択してください。"); return; }
        monitor = MonitorManager.Enumerate().FirstOrDefault(m => m.Id == Settings.MonitorId);
        if (monitor == null) { SetStatus("対象ディスプレイ未接続 · 再接続を待機中"); return; }
        if (library.Photos.Count == 0) { SetStatus("画像がありません · フォルダーを確認してください。"); return; }
        try
        {
            renderer = new(new(monitor.Width, monitor.Height), Settings, transitions, scheduler);
            host.Attach(renderer, monitor);
            cache.BudgetBytes = Settings.CacheMegabytes * 1024L * 1024;
            playback = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
            userPaused = false; CheckOcclusion();
            playTask = PlayAsync(playback.Token);
            SetStatus($"再生中 · {PhotoCount}枚 · {monitor.Name}");
        }
        catch (Exception e)
        {
            renderer?.Clear(); host.Dispose(); renderer = null; desiredRunning = false;
            Log.Write("背面表示を安全に停止しました。", e); SetStatus($"表示停止: {e.Message}");
        }
    }
    public async Task StopAsync()
    {
        await operations.WaitAsync();
        try { desiredRunning = false; await StopPlaybackAsync(); SetStatus("停止中"); }
        finally { operations.Release(); }
    }
    private async Task StopPlaybackAsync()
    {
        taskbar.Restore();
        playback?.Cancel(); sceneLifetime?.Cancel();
        if (playTask != null) { try { await playTask; } catch (OperationCanceledException) { } }
        sceneLifetime?.Dispose(); sceneLifetime = null; playback?.Dispose(); playback = null; playTask = null;
        renderer?.Clear(); host.Dispose(); renderer = null;
        transitions.Clear(); scheduler.SetPaused(false);
    }
    public void TogglePause() { userPaused = !userPaused; UpdatePause(); }
    public void Next() { sceneLifetime?.Cancel(); }
    private void CheckOcclusion() { covered = monitor != null && ExplorerRecovery.IsCovered(monitor); UpdatePause(); }
    private void UpdatePause()
    {
        var pause = userPaused || covered || sleeping;
        scheduler.SetPaused(pause); transitions.SetPaused(pause);
        UpdateTaskbar();
        if (renderer != null) SetStatus(userPaused ? "一時停止中" : sleeping ? "スリープ中" : covered ? "画面遮蔽のため一時停止中" : $"再生中 · {PhotoCount}枚");
        else Changed?.Invoke();
    }
    private void UpdateTaskbar() => taskbar.Update(monitor, Settings.HideTaskbar && renderer?.Current != null && desiredRunning && !covered && !sleeping);
    private async Task PlayAsync(CancellationToken token)
    {
        Prepared? prepared = null;
        try
        {
            while (!token.IsCancellationRequested)
            {
                try
                {
                    prepared ??= await PrepareAsync(token);
                    if (prepared == null) { SetStatus("適した写真・有効なモードがありません。"); await scheduler.DelayAsync(5, token); continue; }
                    var activeRenderer = renderer!;
                    // Consume before Build: a failed layout must not pin the
                    // retry loop to the same invalid prepared composition.
                    var ready = prepared; prepared = null;
                    var scene = activeRenderer.Build(ready.Plan, ready.Images, random);
                    using var local = CancellationTokenSource.CreateLinkedTokenSource(token);
                    sceneLifetime = local;
                    try
                    {
                        await activeRenderer.ShowAsync(scene, local.Token);
                        UpdatePause();
                        var updates = scene.Mode == CompositionMode.Gallery ? Enumerable.Range(0, scene.Slots.Count).Select(i => UpdateGalleryAsync(activeRenderer, scene, i, local.Token)).ToArray()
                            : scene.Mode == CompositionMode.GalleryScroll ? new[] { ScrollGalleryAsync(activeRenderer, scene, local.Token) } : [];
                        var preload = PrepareAsync(local.Token); // Only one future composition held.
                        try
                        {
                            await scheduler.DelayAsync(scene.Seconds, local.Token);
                            prepared = await preload;
                        }
                        finally
                        {
                            local.Cancel();
                            try { await preload; } catch (OperationCanceledException) { }
                            try { await Task.WhenAll(updates); } catch (OperationCanceledException) { }
                        }
                    }
                    catch (OperationCanceledException) when (!token.IsCancellationRequested) { }
                    finally { if (sceneLifetime == local) sceneLifetime = null; }
                }
                catch (OperationCanceledException) when (token.IsCancellationRequested) { break; }
                catch (Exception e)
                {
                    prepared = null;
                    Log.Write("構成をスキップしました。", e); SetStatus($"画像表示を再試行中: {e.Message}"); await Task.Delay(2000, token);
                }
            }
        }
        finally { sceneLifetime = null; }
    }
    private async Task<Prepared?> PrepareAsync(CancellationToken token)
    {
        if (monitor == null) return null;
        var photos = library.Photos.Where(p => !failed.Contains(p.Path)).ToArray();
        var excluded = renderer?.Current?.Photos.Select(p => p.Path).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var plan = composition.Next(photos, new(monitor.Width, monitor.Height), Settings, excluded) ?? composition.Next(photos, new(monitor.Width, monitor.Height), Settings);
        if (plan == null) return null;
        var kept = new List<PhotoInfo>(); var images = new List<BitmapSource>();
        foreach (var photo in plan.Photos)
        {
            var targetWidth = plan.Mode is CompositionMode.Gallery or CompositionMode.GalleryScroll or CompositionMode.HorizontalPan ? (int)(monitor.Height * photo.Aspect)
                : plan.Mode == CompositionMode.VerticalPan ? (int)(monitor.Width * Settings.PanWidthFraction) : monitor.Width;
            var image = await cache.LoadAsync(photo, targetWidth, token);
            if (image == null) { failed.Add(photo.Path); continue; }
            var analyzeFace = plan.Mode == CompositionMode.VerticalPan && Settings.StopAtFace || plan.Mode == CompositionMode.Zoom && Settings.FaceAwareFraming;
            kept.Add(analyzeFace ? await faces.AnalyzeAsync(photo, image, token) : photo); images.Add(image);
        }
        return kept.Count > 0 ? new(new(plan.Mode, kept), images) : null;
    }
    private async Task<(PhotoInfo Photo, BitmapSource Image)?> PrepareScrollPhotoAsync(SceneVisual scene, string? reserved, CancellationToken token)
    {
        var candidates = library.Photos.Where(p => !failed.Contains(p.Path)).ToArray();
        var excluded = scene.Photos.Select(p => p.Path).ToHashSet(StringComparer.OrdinalIgnoreCase);
        if (reserved != null) excluded.Add(reserved);
        var portraits = candidates.Where(p => p.Aspect < .95).ToArray();
        var photo = selector.Pick(portraits.Length > 0 ? portraits : candidates, Settings, excluded);
        photo ??= scene.Photos.FirstOrDefault(p => p.Path != reserved);
        if (photo == null) return null;
        var image = await cache.LoadAsync(photo, (int)(monitor!.Height * photo.Aspect), token);
        if (image == null) { failed.Add(photo.Path); return null; }
        return (photo, image);
    }
    private async Task ScrollGalleryAsync(PhotoRenderer activeRenderer, SceneVisual scene, CancellationToken token)
    {
        var preload = PrepareScrollPhotoAsync(scene, null, token);
        try
        {
            while (!token.IsCancellationRequested)
            {
                var prepared = await preload;
                if (prepared == null) { await scheduler.DelayAsync(1, token); preload = PrepareScrollPhotoAsync(scene, null, token); continue; }
                var moving = activeRenderer.AdvanceGalleryAsync(scene, prepared.Value.Photo, prepared.Value.Image, token);
                preload = PrepareScrollPhotoAsync(scene, prepared.Value.Photo.Path, token);
                await moving;
            }
        }
        finally { try { await preload; } catch (OperationCanceledException) { } }
    }
    private readonly SemaphoreSlim galleryUpdates = new(1, 1);
    private async Task UpdateGalleryAsync(PhotoRenderer activeRenderer, SceneVisual scene, int slot, CancellationToken token)
    {
        try
        {
            await scheduler.DelayAsync(Settings.GalleryMinSeconds + slot * 3, token);
            while (!token.IsCancellationRequested)
            {
                await galleryUpdates.WaitAsync(token);
                try
                {
                    var candidates = library.Photos.Where(p => !failed.Contains(p.Path)).ToArray();
                    var excluded = scene.Photos.Select(p => p.Path).ToHashSet(StringComparer.OrdinalIgnoreCase);
                    var photo = selector.Pick(candidates, Settings, excluded);
                    if (photo != null)
                    {
                        var bitmap = await cache.LoadAsync(photo, (int)(monitor!.Height * photo.Aspect), token);
                        if (bitmap != null) await activeRenderer.ReplaceSlotAsync(scene, slot, photo, bitmap, token); else failed.Add(photo.Path);
                    }
                }
                finally { galleryUpdates.Release(); }
                await scheduler.DelayAsync(Settings.GalleryMinSeconds + random.NextDouble() * (Settings.GalleryMaxSeconds - Settings.GalleryMinSeconds), token);
            }
        }
        catch (OperationCanceledException) { }
    }
    private void LibraryChanged() => dispatcher.BeginInvoke(() =>
    {
        if (disposed) return;
        failed.Clear();
        var paths = library.Photos.Select(p => p.Path).ToHashSet(StringComparer.OrdinalIgnoreCase);
        if (renderer?.Current?.Photos.Any(p => !paths.Contains(p.Path)) == true) Next();
        if (desiredRunning && renderer == null && PhotoCount > 0) _ = GuardAsync(RecoverAsync);
        Changed?.Invoke();
    });
    private async Task RecoverAsync()
    {
        if (disposed || !desiredRunning || !await operations.WaitAsync(0)) return;
        try
        {
            var current = MonitorManager.Enumerate().FirstOrDefault(m => m.Id == Settings.MonitorId);
            if (current != monitor || renderer == null || !host.IsAlive)
            {
                await StopPlaybackAsync();
                if (current == null) { monitor = null; SetStatus("対象ディスプレイ未接続 · 再接続を待機中"); }
                else StartPlayback();
            }
            host.EnsureZOrder();
            CheckOcclusion();
        }
        finally { operations.Release(); }
    }
    private void SetStatus(string text) { Status = text; Changed?.Invoke(); }
    public static async Task GuardAsync(Func<Task> action)
    {
        try { await action(); } catch (OperationCanceledException) { } catch (Exception e) { Log.Write("操作に失敗しました。", e); }
    }
    public async ValueTask DisposeAsync()
    {
        disposed = true; desiredRunning = false; lifetime.Cancel(); recovery.Dispose(); occlusionDebounce.Stop();
        await StopPlaybackAsync(); library.Changed -= LibraryChanged; library.Dispose(); await cache.ClearAsync(); await faces.SaveAsync(); lifetime.Dispose();
    }
}

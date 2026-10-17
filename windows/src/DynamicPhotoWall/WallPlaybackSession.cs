using System.Windows.Media.Imaging;
using DynamicPhotoWall.Configuration;
using DynamicPhotoWall.DesktopIntegration;
using DynamicPhotoWall.Motion;
using DynamicPhotoWall.PhotoLibrary;
using DynamicPhotoWall.Rendering;

namespace DynamicPhotoWall;

internal sealed class WallPlaybackSession : IAsyncDisposable
{
    private sealed record Prepared(CompositionPlan Plan, IReadOnlyList<BitmapSource> Images);
    private readonly PhotoScanner library;
    private readonly ImageCache cache;
    private readonly FaceAnalyzer faces;
    private readonly PhotoSelector selector = new();
    private readonly CompositionEngine composition;
    private readonly Random random = new();
    private readonly CancellationToken lifetime;
    private readonly DisplayGroup group;
    private readonly AnimationScheduler scheduler = new();
    private readonly TransitionController transitions = new();
    private sealed record Output(MonitorDescriptor Monitor, DesktopWindowHost Host, TaskbarVisibility Taskbar);
    private readonly List<Output> outputs = [];
    private readonly HashSet<string> failed = new(StringComparer.OrdinalIgnoreCase);
    private CancellationTokenSource? playback;
    private Task? playTask;
    private CancellationTokenSource? sceneLifetime;
    private PhotoRenderer? renderer;
    private IReadOnlyList<MonitorDescriptor> monitors = [];
    private WallLayout? layout;
    private bool desiredRunning, userPaused, covered, sleeping;
    public WallSettings Settings { get; }
    public string Status { get; private set; } = "停止中";
    public int PhotoCount => library.Photos.Count;
    public bool IsPaused => userPaused;
    public bool IsRunning => renderer != null && desiredRunning;
    public CompositionMode? CurrentMode => renderer?.Current?.Mode;
    public IReadOnlyList<string> DisplayedPhotoPaths => renderer?.Current?.Photos.Select(p => p.Path).ToArray() ?? [];
    public event Action? Changed;
    public WallGroupState State => new(group.Name, group.Displays.Select(d => d.Id).ToArray(), layout?.Viewport,
        CurrentMode, DisplayedPhotoPaths, IsRunning, userPaused || covered || sleeping, Status);
    public WallPlaybackSession(WallSettings settings, DisplayGroup group, PhotoScanner library, ImageCache cache, FaceAnalyzer faces, CancellationToken lifetime)
    {
        Settings = settings; this.group = group; this.library = library; this.cache = cache; this.faces = faces; this.lifetime = lifetime;
        composition = new(selector);
    }
    public void Start()
    {
        desiredRunning = true;
        if (renderer == null) StartPlayback(); else UpdatePause();
    }
    private void StartPlayback()
    {
        if (!Settings.HasDisplaySelection) { desiredRunning = false; SetStatus("表示対象ディスプレイを選択してください。"); return; }
        monitors = SelectedMonitors();
        if (monitors.Count == 0) { SetStatus("対象ディスプレイ未接続 · 再接続を待機中"); return; }
        if (!Settings.DisplayTestPattern && library.Photos.Count == 0) { SetStatus("画像がありません · フォルダーを確認してください。"); return; }
        try
        {
            layout = BuildLayout();
            renderer = new(layout.Viewport, Settings, transitions, scheduler);
            renderer.SetDisplayRegion(layout.Regions[monitors[0].Id]);
            foreach (var monitor in monitors)
            {
                var output = new Output(monitor, new DesktopWindowHost(), new TaskbarVisibility());
                outputs.Add(output);
                var window = outputs.Count == 1 ? renderer : new Window { Background = renderer.Background, Content = renderer.CreateDisplayRegion(layout.Regions[monitor.Id]), Focusable = false, IsHitTestVisible = false };
                output.Host.Attach(window, monitor);
            }
            cache.BudgetBytes = Settings.CacheMegabytes * 1024L * 1024;
            playback = CancellationTokenSource.CreateLinkedTokenSource(lifetime);
            CheckOcclusion();
            if (Settings.DisplayTestPattern) renderer.ShowTestPattern(layout, group.Name, Settings.Displays.Select(d => d.Id).ToArray());
            else playTask = PlayAsync(playback.Token);
            UpdatePause();
        }
        catch (Exception e)
        {
            renderer?.Clear(); DisposeOutputs(); renderer = null; desiredRunning = false;
            Log.Write("背面表示を安全に停止しました。", e); SetStatus($"表示停止: {e.Message}");
        }
    }
    public async Task StopAsync()
    {
        desiredRunning = false; await StopPlaybackAsync(); SetStatus("停止中");
    }
    private async Task StopPlaybackAsync()
    {
        foreach (var output in outputs) output.Taskbar.Restore();
        playback?.Cancel(); sceneLifetime?.Cancel();
        if (playTask != null) { try { await playTask; } catch (OperationCanceledException) { } }
        sceneLifetime?.Dispose(); sceneLifetime = null; playback?.Dispose(); playback = null; playTask = null;
        renderer?.Clear(); DisposeOutputs(); renderer = null;
        transitions.Clear(); scheduler.SetPaused(false);
    }
    public void SetPauseState(bool paused, bool suspended) { userPaused = paused; sleeping = suspended; UpdatePause(); }
    public void Next() { sceneLifetime?.Cancel(); }
    private IReadOnlyList<MonitorDescriptor> SelectedMonitors()
    {
        var connected = MonitorManager.Enumerate();
        var ids = group.Displays.Select(d => d.Id);
        return ids.Select(id => connected.FirstOrDefault(m => m.Id == id)).OfType<MonitorDescriptor>().ToArray();
    }
    private WallLayout BuildLayout()
    {
        var placements = group.Displays;
        // Remember the last connected resolution so unplugging never compacts
        // the wall, including after a resolution change in this session.
        foreach (var placement in placements)
        {
            var connected = monitors.FirstOrDefault(m => m.Id == placement.Id);
            if (connected != null) { placement.Width = connected.Width; placement.Height = connected.Height; }
        }
        return new WallLayout(placements);
    }
    private void DisposeOutputs() { foreach (var output in outputs.AsEnumerable().Reverse()) { output.Taskbar.Dispose(); output.Host.Dispose(); } outputs.Clear(); }
    private string PlaybackStatus() => $"{(Settings.DisplayTestPattern ? "テストパターン" : $"再生中 · {PhotoCount}枚")} · {monitors.Count}画面" + (group.Displays.Count > monitors.Count ? " · 未接続画面の領域を保持中" : "");
    public void CheckOcclusion() { covered = monitors.Count > 0 && monitors.All(ExplorerRecovery.IsCovered); UpdatePause(); }
    private void UpdatePause()
    {
        var pause = userPaused || covered || sleeping;
        scheduler.SetPaused(pause); transitions.SetPaused(pause);
        UpdateTaskbar();
        if (renderer != null) SetStatus(userPaused ? "一時停止中" : sleeping ? "スリープ中" : covered ? "画面遮蔽のため一時停止中" : PlaybackStatus());
        else Changed?.Invoke();
    }
    private void UpdateTaskbar()
    {
        foreach (var output in outputs)
        {
            var hide = group.Displays.First(d => d.Id == output.Monitor.Id).HideTaskbar ?? Settings.HideTaskbar;
            output.Taskbar.Update(output.Monitor, hide && renderer != null && (Settings.DisplayTestPattern || renderer.Current != null) && desiredRunning && !sleeping && !ExplorerRecovery.IsCovered(output.Monitor));
        }
    }
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
        if (layout == null) return null;
        var photos = library.Photos.Where(p => !failed.Contains(p.Path)).ToArray();
        var excluded = renderer?.Current?.Photos.Select(p => p.Path).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var plan = composition.Next(photos, layout.Viewport, Settings, excluded) ?? composition.Next(photos, layout.Viewport, Settings);
        if (plan == null) return null;
        var kept = new List<PhotoInfo>(); var images = new List<BitmapSource>();
        foreach (var photo in plan.Photos)
        {
            var targetWidth = plan.Mode is CompositionMode.Gallery or CompositionMode.GalleryScroll or CompositionMode.HorizontalPan ? (int)(layout.Viewport.Height * photo.Aspect)
                : plan.Mode == CompositionMode.VerticalPan ? (int)(layout.Viewport.Width * Settings.PanWidthFraction) : (int)layout.Viewport.Width;
            var image = await cache.LoadAsync(photo, targetWidth, token);
            if (image == null) { failed.Add(photo.Path); continue; }
            var analyzeFace = (plan.Mode is CompositionMode.VerticalPan or CompositionMode.HorizontalPan) && Settings.FaceAwarePanDirection
                || plan.Mode == CompositionMode.VerticalPan && Settings.StopAtFace || plan.Mode == CompositionMode.Zoom && Settings.FaceAwareFraming;
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
        var image = await cache.LoadAsync(photo, (int)(layout!.Viewport.Height * photo.Aspect), token);
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
                        var bitmap = await cache.LoadAsync(photo, (int)(layout!.Viewport.Height * photo.Aspect), token);
                        if (bitmap != null) await activeRenderer.ReplaceSlotAsync(scene, slot, photo, bitmap, token); else failed.Add(photo.Path);
                    }
                }
                finally { galleryUpdates.Release(); }
                await scheduler.DelayAsync(Settings.GalleryMinSeconds + random.NextDouble() * (Settings.GalleryMaxSeconds - Settings.GalleryMinSeconds), token);
            }
        }
        catch (OperationCanceledException) { }
    }
    public void LibraryChanged()
    {
        failed.Clear();
        var paths = library.Photos.Select(p => p.Path).ToHashSet(StringComparer.OrdinalIgnoreCase);
        if (renderer?.Current?.Photos.Any(p => !paths.Contains(p.Path)) == true) Next();
    }
    public async Task RecoverAsync()
    {
        if (!desiredRunning) return;
        var current = SelectedMonitors();
        if (!current.SequenceEqual(monitors) || renderer == null || outputs.Any(o => !o.Host.IsAlive))
        {
            await StopPlaybackAsync();
            StartPlayback();
        }
        foreach (var output in outputs) output.Host.EnsureZOrder();
        CheckOcclusion();
    }
    private void SetStatus(string text) { Status = text; Changed?.Invoke(); }
    public async ValueTask DisposeAsync()
    {
        desiredRunning = false; await StopPlaybackAsync();
    }
}

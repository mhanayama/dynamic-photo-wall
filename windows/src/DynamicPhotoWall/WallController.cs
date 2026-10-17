using System.Windows.Threading;
using DynamicPhotoWall.Configuration;
using DynamicPhotoWall.DesktopIntegration;
using DynamicPhotoWall.PhotoLibrary;

namespace DynamicPhotoWall;

public sealed record WallGroupState(string Name, IReadOnlyList<string> DisplayIds, Viewport? Viewport,
    CompositionMode? Mode, IReadOnlyList<string> PhotoPaths, bool IsRunning, bool IsPaused, string Status);

public sealed class WallController : IAsyncDisposable
{
    private readonly PhotoScanner library = new();
    private readonly ImageCache cache = new();
    private readonly FaceAnalyzer faces = new();
    private readonly List<WallPlaybackSession> sessions = [];
    private readonly SemaphoreSlim operations = new(1, 1);
    private readonly CancellationTokenSource lifetime = new();
    private readonly ExplorerRecovery recovery = new();
    private readonly Dispatcher dispatcher = Dispatcher.CurrentDispatcher;
    private readonly DispatcherTimer occlusionDebounce;
    private bool desiredRunning, userPaused, sleeping, disposed;
    private WallSettings? testPatternSettings;
    public WallSettings Settings { get; private set; }
    public string Status { get; private set; } = "停止中";
    public int PhotoCount => library.Photos.Count;
    public bool IsPaused => userPaused;
    public bool IsRunning => (desiredRunning || TestPatternVisible) && sessions.Any(s => s.IsRunning);
    public bool TestPatternVisible => testPatternSettings != null;
    public CompositionMode? CurrentMode => sessions.FirstOrDefault(s => s.IsRunning)?.CurrentMode;
    public IReadOnlyList<string> DisplayedPhotoPaths => sessions.SelectMany(s => s.DisplayedPhotoPaths).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
    public IReadOnlyList<WallGroupState> GroupStates => sessions.Select(s => s.State).ToArray();
    public event Action? Changed;

    public WallController(WallSettings settings)
    {
        Settings = settings;
        library.Changed += LibraryChanged;
        recovery.EnvironmentChanged += () => _ = GuardAsync(RecoverAsync);
        recovery.PowerSuspended += value => { sleeping = value; UpdatePause(); };
        occlusionDebounce = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(250) };
        occlusionDebounce.Tick += (_, _) => { occlusionDebounce.Stop(); foreach (var session in sessions.ToArray()) session.CheckOcclusion(); };
        recovery.OcclusionChanged += () => { if (!occlusionDebounce.IsEnabled) occlusionDebounce.Start(); };
    }
    public async Task InitializeAsync()
    {
        SetStatus("写真を検索中…");
        cache.BudgetBytes = Settings.CacheMegabytes * 1024L * 1024;
        await library.ConfigureAsync(Settings, lifetime.Token);
        if (Settings.StartOnLaunch && Settings.HasDisplaySelection && (Settings.DisplayTestPattern || Settings.Folders.Count > 0)) await StartAsync();
        else SetStatus($"停止中 · {PhotoCount}枚");
    }
    public async Task ApplyAsync(WallSettings settings)
    {
        await operations.WaitAsync();
        try
        {
            await StopSessionsAsync();
            Settings = settings;
            cache.BudgetBytes = settings.CacheMegabytes * 1024L * 1024;
            await cache.ClearAsync();
            await library.ConfigureAsync(Settings, lifetime.Token);
            if (desiredRunning || TestPatternVisible) StartSessions(); else SetStatus($"停止中 · {PhotoCount}枚");
        }
        finally { operations.Release(); }
    }
    public async Task StartAsync()
    {
        await operations.WaitAsync();
        try
        {
            if (TestPatternVisible) { await StopSessionsAsync(); testPatternSettings = null; }
            desiredRunning = true; userPaused = false;
            if (sessions.Count == 0) StartSessions();
            else { foreach (var session in sessions.ToArray()) session.Start(); UpdatePause(); }
        }
        finally { operations.Release(); }
    }
    private void StartSessions()
    {
        var activeSettings = testPatternSettings ?? Settings;
        if (!activeSettings.HasDisplaySelection) { desiredRunning = false; SetStatus("表示対象ディスプレイを選択してください。"); return; }
        var displays = activeSettings.Displays.Count > 0 ? activeSettings.Displays : new List<DisplayPlacement> { new() { Id = activeSettings.MonitorId!, GroupId = null } };
        foreach (var group in DisplayGroups.Create(displays))
        {
            var session = new WallPlaybackSession(activeSettings, group, library, cache, faces, lifetime.Token);
            session.Changed += UpdateStatus; sessions.Add(session);
        }
        foreach (var session in sessions.ToArray()) { session.SetPauseState(userPaused, sleeping); session.Start(); }
        UpdateStatus();
    }
    public async Task StopAsync()
    {
        await operations.WaitAsync();
        try { desiredRunning = false; testPatternSettings = null; await StopSessionsAsync(); SetStatus("停止中"); }
        finally { operations.Release(); }
    }
    public async Task ShowTestPatternAsync(WallSettings draft)
    {
        var candidate = SettingsManager.Clone(draft); candidate.Normalize(); candidate.DisplayTestPattern = true;
        if (candidate.Displays.Count == 0) throw new InvalidOperationException("使用するディスプレイを選択してください。");
        foreach (var group in DisplayGroups.Create(candidate.Displays)) _ = new WallLayout(group.Displays);
        var connected = MonitorManager.Enumerate();
        if (!candidate.Displays.Any(d => connected.Any(m => m.Id == d.Id))) throw new InvalidOperationException("選択したディスプレイが接続されていません。");
        await operations.WaitAsync();
        try
        {
            var previous = testPatternSettings;
            await StopSessionsAsync(); testPatternSettings = candidate;
            try
            {
                StartSessions();
                if (!sessions.Any(s => s.IsRunning)) throw new InvalidOperationException("テストパターンを表示できませんでした。");
            }
            catch
            {
                await StopSessionsAsync(); testPatternSettings = previous;
                if (desiredRunning || TestPatternVisible) StartSessions(); else SetStatus("停止中");
                throw;
            }
        }
        finally { operations.Release(); }
    }
    public async Task HideTestPatternAsync()
    {
        await operations.WaitAsync();
        try
        {
            if (!TestPatternVisible) return;
            await StopSessionsAsync(); testPatternSettings = null;
            if (desiredRunning) StartSessions(); else SetStatus($"停止中 · {PhotoCount}枚");
        }
        finally { operations.Release(); }
    }
    private async Task StopSessionsAsync()
    {
        foreach (var session in sessions.ToArray()) session.Changed -= UpdateStatus;
        foreach (var session in sessions.ToArray()) await session.DisposeAsync();
        sessions.Clear();
    }
    public void TogglePause() { userPaused = !userPaused; UpdatePause(); }
    public void Next() { foreach (var session in sessions.ToArray()) session.Next(); }
    private void UpdatePause()
    {
        foreach (var session in sessions.ToArray()) session.SetPauseState(userPaused, sleeping);
        UpdateStatus();
    }
    private void UpdateStatus()
    {
        if (sessions.Count == 0) { Changed?.Invoke(); return; }
        SetStatus(sessions.Count == 1 ? sessions[0].Status : string.Join(" / ", sessions.Select((s, i) => $"{s.State.Name}{(s.State.Name == "独立画面" ? $" {i + 1}" : "")}: {s.Status}")));
    }
    private void LibraryChanged() => dispatcher.BeginInvoke(() =>
    {
        if (disposed) return;
        foreach (var session in sessions.ToArray()) session.LibraryChanged();
        if (desiredRunning || TestPatternVisible) _ = GuardAsync(RecoverAsync);
        Changed?.Invoke();
    });
    private async Task RecoverAsync()
    {
        if (disposed || (!desiredRunning && !TestPatternVisible) || !await operations.WaitAsync(0)) return;
        try { foreach (var session in sessions.ToArray()) await session.RecoverAsync(); }
        finally { operations.Release(); }
    }
    private void SetStatus(string text) { Status = text; Changed?.Invoke(); }
    public static async Task GuardAsync(Func<Task> action)
    {
        try { await action(); } catch (OperationCanceledException) { } catch (Exception e) { Log.Write("操作に失敗しました。", e); }
    }
    public async ValueTask DisposeAsync()
    {
        if (disposed) return;
        disposed = true; desiredRunning = false; testPatternSettings = null; lifetime.Cancel(); recovery.Dispose(); occlusionDebounce.Stop();
        await StopSessionsAsync(); library.Changed -= LibraryChanged; library.Dispose(); await cache.ClearAsync(); await faces.SaveAsync(); lifetime.Dispose();
    }
}

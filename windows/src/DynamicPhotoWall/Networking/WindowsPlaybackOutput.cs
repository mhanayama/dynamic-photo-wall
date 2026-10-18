using System.Security.Cryptography;
using System.Windows.Threading;
using DynamicPhotoWall.DesktopIntegration;
using DynamicPhotoWall.Motion;
using DynamicPhotoWall.Rendering;
using Net = DynamicPhotoWall.Networking;
using FrameRect = DynamicPhotoWall.Core.FrameRect;

namespace DynamicPhotoWall.Networking.Windows;

public sealed class WindowsPlaybackOutput(Guid localPeer, Net.ISharedClock clock, Func<WallSettings> settings,
    Func<Task> enterNetwork) : Net.IPlaybackOutput
{
    private sealed class Group(PhotoRenderer renderer, SharedVisual visual)
    {
        public PhotoRenderer Renderer { get; } = renderer;
        public SharedVisual Visual { get; set; } = visual;
        public List<(MonitorDescriptor Monitor, DesktopWindowHost Host, TaskbarVisibility Taskbar)> Outputs { get; } = [];
        public double Started, PausedSeconds;
        public SharedVisual? Previous;
        public double PreviousStarted, PreviousPaused;
        public void Replace(SharedVisual next, double started)
        {
            Previous = Visual; PreviousStarted = Started; PreviousPaused = PausedSeconds;
            Visual = next; Started = started; PausedSeconds = 0;
        }
    }
    private readonly Dispatcher dispatcher = Dispatcher.CurrentDispatcher;
    private readonly WindowsLayoutPreview preview = new(localPeer);
    private readonly Dictionary<Guid, SharedVisual> prepared = [];
    private readonly Dictionary<Guid, Group> current = [];
    private readonly Dictionary<Guid, Net.SceneCommit> commits = [];
    private readonly List<Net.PlaybackControl> controls = [];
    private Net.PeerPlaybackState recovery = Net.PeerPlaybackState.Offline;
    private Net.WallSnapshot? snapshot;
    private double? pausedAt;
    private bool stopped, entering, attached, rebuilding;
    private bool rendering;
    private readonly CancellationTokenSource outputLifetime = new();
    private Task? localPreparation;
    private double? repeatAt;
    private Net.IScenePlanner? planner;
    private Net.PhotoTransferService? photos;
    public bool IsDisplaying => attached;
    public bool IsPaused => pausedAt != null;
    public bool IsRunning => attached && !stopped && current.Count > 0;
    public bool Stopped => stopped;
    public bool PreviewVisible => preview.Visible;
    public event Action? Changed;
    public void Bind(Net.IScenePlanner planner, Net.PhotoTransferService photos) { this.planner = planner; this.photos = photos; preview.Changed += () => Changed?.Invoke(); }
    public void Preview(Net.LayoutPreviewPlan plan) => dispatcher.BeginInvoke(() =>
    { preview.Schedule(plan); CompositionTarget.Rendering -= Render; CompositionTarget.Rendering += Render; });
    public async Task PrepareAsync(Net.SharedScenePlan plan, CancellationToken cancellation)
    {
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellation, outputLifetime.Token);
        cancellation = linked.Token;
        plan.Validate();
        if (photos == null) throw new InvalidOperationException("写真キャッシュが接続されていません。");
        var own = plan.Displays.Where(d => d.Key.PeerId == localPeer).Select(d => d.Key.LayoutId).ToArray();
        var required = plan.Placements.Where(p => p.DisplayId == null || own.Contains(p.DisplayId)).Select(p => p.Asset).Distinct().ToArray();
        var bitmaps = await Task.Run(() =>
        {
            var result = new Dictionary<string, System.Windows.Media.Imaging.BitmapSource>();
            foreach (var key in required)
            {
                cancellation.ThrowIfCancellationRequested(); var data = photos.ReadImage(key);
                try
                {
                    var metadata = photos.Available.First(p => p.Key == key);
                    var maxPixels = Math.Min(16_000_000d, Math.Max(65536, settings().CacheMegabytes * 1024d * 1024 / 8 / Math.Max(1, required.Length)));
                    var width = (int)Math.Min(4096, Math.Sqrt(maxPixels * metadata.PixelWidth / metadata.PixelHeight));
                    result[key.OpaqueId] = NetworkBitmap.Decode(data, Math.Max(64, width), metadata.Orientation);
                }
                finally { CryptographicOperations.ZeroMemory(data); }
            }
            return result;
        }, cancellation);
        await dispatcher.InvokeAsync(() =>
        {
            cancellation.ThrowIfCancellationRequested();
            prepared[plan.Id] = SharedSceneBuilder.Build(plan, bitmaps, own);
            foreach (var old in prepared.Where(p => p.Value.Plan.GroupId == plan.GroupId && p.Key != plan.Id).Select(p => p.Key).ToArray())
                prepared.Remove(old);
        });
    }
    public void Commit(Net.SceneCommit commit) => dispatcher.BeginInvoke(() =>
    {
        if (!prepared.ContainsKey(commit.PlanId)) return;
        commits[commit.GroupId] = commit;
        CompositionTarget.Rendering -= Render; CompositionTarget.Rendering += Render;
    });
    private async void Render(object? sender, EventArgs e)
    {
        if (rendering) return;
        rendering = true;
        try { await RenderFrame(); }
        catch (Exception error) { Configuration.Log.Write("同期表示を準備し直します。", error); CloseGroups(); }
        finally { rendering = false; }
    }
    private async Task RenderFrame()
    {
        var now = clock.Now;
        try { preview.Update(now); }
        catch (Exception error) { Configuration.Log.Write("配置テストを表示できません。", error); preview.Dispose(); }
        foreach (var control in controls.Where(c => c.EffectiveAt <= now).ToArray())
        {
            controls.Remove(control);
            switch (control.Operation)
            {
                case "pause": pausedAt ??= control.EffectiveAt; break;
                case "resume":
                    if (pausedAt != null)
                    {
                        var delay = Math.Max(0, control.EffectiveAt - pausedAt.Value);
                        foreach (var group in current.Values) group.PausedSeconds += delay;
                        foreach (var group in current.Values) group.PreviousPaused += delay;
                        foreach (var key in commits.Keys.ToArray()) commits[key] = commits[key] with { StartAt = commits[key].StartAt + delay };
                    }
                    pausedAt = null; break;
                case "stop": stopped = true; CloseGroups(); break;
                case "start": stopped = false; pausedAt = null; break;
            }
            Changed?.Invoke();
        }
        if (stopped || entering) return;
        foreach (var commit in commits.Values.Where(c => pausedAt == null && c.StartAt <= now).ToArray())
        {
            if (!prepared.Remove(commit.PlanId, out var visual)) { commits.Remove(commit.GroupId); continue; }
            if (!attached)
            {
                entering = true;
                try { await enterNetwork(); attached = true; }
                catch (Exception error) { Configuration.Log.Write("同期表示へ切り替えられません。", error); }
                finally { entering = false; }
                if (!attached || stopped) continue;
            }
            current.TryGetValue(commit.GroupId, out var old);
            var plan = visual.Plan;
            var selected = plan.Displays.Where(d => d.Key.PeerId == localPeer && d.Selected).ToArray();
            var monitors = MonitorManager.Enumerate();
            var reuse = old != null && PlaybackSurfaceLayout.CanReuse(old.Visual.Plan, plan, localPeer)
                && old.Outputs.All(o => o.Host.IsAlive && monitors.Any(m => m.Id == o.Monitor.Id && m.X == o.Monitor.X
                    && m.Y == o.Monitor.Y && m.Width == o.Monitor.Width && m.Height == o.Monitor.Height))
                && old.Outputs.Count == selected.Count(d => monitors.Any(m => m.Id == d.Key.DisplayId));
            var group = reuse ? old! : new Group(new PhotoRenderer(new(plan.Viewport.Width, plan.Viewport.Height), settings(),
                new TransitionController(), new AnimationScheduler()), visual);
            if (reuse) group.Replace(visual, commit.StartAt);
            else
            {
                group.Started = commit.StartAt;
                if (old != null)
                {
                    group.Previous = SharedSceneBuilder.Build(old.Visual.Plan, old.Visual.Images, selected.Select(d => d.Key.LayoutId).ToArray());
                    group.PreviousStarted = old.Started; group.PreviousPaused = old.PausedSeconds;
                }
            }
            current[commit.GroupId] = group; commits.Remove(commit.GroupId);
            // Initialize images, ambient frames and opacity before exposing a tree.
            if (group.Previous != null) group.Renderer.PresentShared(group.Previous, Math.Max(0, now - group.PreviousStarted - group.PreviousPaused));
            group.Renderer.PresentShared(visual, Math.Max(0, now - group.Started));
            group.Renderer.ShowShared(group.Visual, group.Previous);
            var left = plan.Displays.Min(d => d.X); var top = plan.Displays.Min(d => d.Y);
            foreach (var display in selected.Where(_ => !reuse))
            {
                var monitor = monitors.FirstOrDefault(m => m.Id == display.Key.DisplayId);
                if (monitor == null) continue;
                var region = new DynamicPhotoWall.Core.FrameRect(display.X - left, display.Y - top, display.Width, display.Height);
                var host = new DesktopWindowHost(); var taskbar = new TaskbarVisibility();
                Window window;
                if (group.Outputs.Count == 0) { group.Renderer.SetDisplayRegion(region, display.Key.LayoutId); window = group.Renderer; }
                else window = new Window { Content = group.Renderer.CreateDisplayRegion(region, display.Key.LayoutId), Background = group.Renderer.Background, Focusable = false, IsHitTestVisible = false };
                host.Attach(window, monitor);
                taskbar.Update(monitor, settings().Displays.FirstOrDefault(d => d.Id == monitor.Id)?.HideTaskbar ?? settings().HideTaskbar);
                group.Outputs.Add((monitor, host, taskbar));
            }
            if (old != null && !reuse) Close(old);
            foreach (var output in group.Outputs)
                output.Taskbar.Update(output.Monitor, settings().Displays.FirstOrDefault(d => d.Id == output.Monitor.Id)?.HideTaskbar ?? settings().HideTaskbar);
            Changed?.Invoke();
        }
        foreach (var group in current.Values.ToArray())
        {
            var elapsed = (pausedAt ?? now) - group.Started - group.PausedSeconds;
            if (repeatAt != null && pausedAt == null && elapsed >= group.Visual.Plan.Duration)
            {
                // Repeating after isolation is another scene transition, not a
                // modulo jump to a transparent first frame on an empty backing.
                var repeated = SharedSceneBuilder.Build(group.Visual.Plan, group.Visual.Images,
                    group.Visual.Plan.Displays.Where(d => d.Key.PeerId == localPeer && d.Selected).Select(d => d.Key.LayoutId).ToArray());
                group.Replace(repeated, now); elapsed = 0;
                group.Renderer.PresentShared(group.Previous!, Math.Max(0, now - group.PreviousStarted - group.PreviousPaused));
                group.Renderer.PresentShared(repeated, 0);
                group.Renderer.ShowShared(repeated, group.Previous);
            }
            if (group.Previous != null)
            {
                group.Renderer.PresentShared(group.Previous, Math.Max(0, (pausedAt ?? now) - group.PreviousStarted - group.PreviousPaused));
                if (elapsed >= group.Visual.Plan.FadeSeconds) { group.Renderer.RemoveShared(group.Previous); group.Previous = null; }
            }
            group.Renderer.PresentShared(group.Visual, Math.Max(0, elapsed));
            if (!preview.Visible) foreach (var item in group.Outputs) item.Host.EnsureZOrder();
            if (recovery == Net.PeerPlaybackState.Standalone && elapsed >= group.Visual.Plan.Duration - 2) RebuildLocal();
        }
    }
    public void Control(string operation, double effectiveAt) => dispatcher.BeginInvoke(() => controls.Add(new(operation, effectiveAt)));
    public void SetRecovery(Net.PeerPlaybackState state, Net.WallSnapshot wall) => dispatcher.BeginInvoke(() =>
    {
        snapshot = wall;
        foreach (var id in current.Keys.Where(id => !wall.Displays.Any(d => d.Selected && d.Key.PeerId == localPeer && (d.GroupId ?? Net.SceneCoordinator.StandaloneId(d.Key)) == id)).ToArray())
        { Close(current[id]); current.Remove(id); }
        if (state == recovery) return;
        recovery = state;
        if (state == Net.PeerPlaybackState.IsolatedRepeating) repeatAt ??= clock.Now;
        if (state == Net.PeerPlaybackState.Standalone && attached) { repeatAt ??= clock.Now; RebuildLocal(); }
        if (state == Net.PeerPlaybackState.Synchronized) repeatAt = null;
        Changed?.Invoke();
    });
    private void RebuildLocal()
    {
        if (rebuilding || planner == null || photos == null || snapshot == null || !attached) return;
        localPreparation = RebuildLocalAsync();
    }
    private async Task RebuildLocalAsync()
    {
        rebuilding = true;
        try
        {
            var wall = snapshot! with { Displays = snapshot!.Displays.Where(d => d.Key.PeerId == localPeer).ToArray() };
            foreach (var group in wall.Displays.Where(d => d.Selected).GroupBy(d => d.GroupId ?? Net.SceneCoordinator.StandaloneId(d.Key)))
            {
                var plan = await planner!.PrepareAsync(wall, group.Key, photos!.Available, outputLifetime.Token);
                if (plan == null || recovery != Net.PeerPlaybackState.Standalone) continue;
                await PrepareAsync(plan, outputLifetime.Token); Commit(new(plan.Id, plan.GroupId, clock.Now + .25));
            }
        }
        catch (OperationCanceledException) when (outputLifetime.IsCancellationRequested) { }
        catch (Exception error) { Configuration.Log.Write("単体表示の写真を準備できません。", error); }
        finally { rebuilding = false; }
    }
    private static void Close(Group group)
    {
        foreach (var (_, host, taskbar) in group.Outputs) { taskbar.Dispose(); host.Dispose(); }
        group.Renderer.Clear(); group.Renderer.Close();
    }
    private void CloseGroups() { foreach (var group in current.Values) Close(group); current.Clear(); }
    public async Task StopAsync()
    {
        await outputLifetime.CancelAsync();
        if (localPreparation != null) await localPreparation;
        await dispatcher.InvokeAsync(() =>
        {
        CompositionTarget.Rendering -= Render; preview.Dispose(); CloseGroups();
        prepared.Clear(); commits.Clear(); controls.Clear(); attached = false;
        });
    }
}

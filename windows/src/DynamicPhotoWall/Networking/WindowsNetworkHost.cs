using System.Windows.Threading;
using DynamicPhotoWall.Configuration;
using Net = DynamicPhotoWall.Networking;

namespace DynamicPhotoWall.Networking.Windows;

public sealed class WindowsNetworkHost(Func<WallSettings> settings, Func<IReadOnlyList<PhotoInfo>> photos,
    Func<Task> enterNetwork) : IAsyncDisposable, Net.IConnectionNotifications
{
    private readonly Dispatcher dispatcher = Dispatcher.CurrentDispatcher;
    private Net.PeerIdentity? identity;
    private Net.EncryptedPhotoCache? cache;
    private WindowsPlaybackOutput? output;
    private Net.SharedClock? clock;
    private readonly SemaphoreSlim operations = new(1, 1);
    public Net.PeerSession? Session { get; private set; }
    public bool Online => Session != null;
    public bool IsDisplaying => output?.IsDisplaying == true;
    public bool IsPaused => Session?.ConnectedPeers.Count > 0 ? Session.PlaybackPaused : output?.IsPaused == true;
    public bool IsRunning => output?.IsRunning == true;
    public bool PreviewVisible => output?.PreviewVisible == true;
    public bool Stopped => Session?.ConnectedPeers.Count > 0 ? Session.PlaybackStopped : output?.Stopped == true;
    public string Status { get; private set; } = "オフライン";
    public event Action? Changed;
    public event Action<string, string>? Notification;
    public async Task SetOnlineAsync(bool enabled)
    {
        await operations.WaitAsync();
        try
        {
            if (enabled == Online) return;
            if (!enabled)
            {
                if (Session != null) await Session.DisposeAsync();
                Session = null; output = null; clock = null; cache?.Dispose(); cache = null; identity?.Dispose(); identity = null;
                Status = "オフライン"; Raise(); return;
            }
            var root = Path.Combine(Log.DataDirectory, "network");
            identity = new(new WindowsSecretStore(Path.Combine(root, "secrets"))); clock = new();
            var local = new Net.PeerHello(1, identity.PeerId, Environment.MachineName, "windows");
            var s = settings();
            var groups = s.DisplayGroupNames.Concat(s.Displays.Select(d => d.GroupId).OfType<string>())
                .Where(name => !string.IsNullOrWhiteSpace(name)).Distinct().Select(name =>
                    new Net.SharedGroup(WindowsPhotoProvider.StableId($"{identity.PeerId:N}:{name}"), name)).ToArray();
            var saved = s.Displays;
            var allDisplays = saved.Concat(DesktopIntegration.MonitorManager.Enumerate().Where(m => !saved.Any(d => d.Id == m.Id))
                .Select(m => new DisplayPlacement { Id = m.Id, Width = m.Width, Height = m.Height, GroupId = null })).ToArray();
            var displays = allDisplays.Select(d => new Net.PeerDisplay(new(identity.PeerId, d.Id), saved.Any(a => a.Id == d.Id),
                string.IsNullOrWhiteSpace(d.GroupId) ? null : groups.First(g => g.Name == d.GroupId).Id,
                d.X, d.Y, d.Width, d.Height)).ToArray();
            Net.PeerSession? running = null;
            var provider = new WindowsPhotoProvider(identity.PeerId, settings, photos, key => running?.Photos.IsAvailable(key) == true);
            cache = new(Path.Combine(root, "cache"), identity.CacheKey);
            var initial = new Net.WallSnapshot(Guid.NewGuid(), Guid.NewGuid(), identity.PeerId, 0, groups, displays, [], WindowsPlaybackOptions.Export(s));
            var planner = new WindowsScenePlanner(key => running!.Photos.ReadImage(key));
            output = new(identity.PeerId, clock, settings, enterNetwork);
            running = new(local, displays, new Net.TlsPeerTransport(local, identity.Certificate, identity), new Net.LanPeerDiscovery(),
                new Net.EncryptedStateStore(Path.Combine(root, "wall.encrypted"), identity.CacheKey), provider, cache,
                planner, output, clock, this, initial);
            output.Bind(planner, running.Photos); output.Changed += Raise;
            running.Changed += () =>
            {
                Status = running.ConnectedPeers.Count == 0 ? "接続待機中" :
                    $"{running.ConnectedPeers.Count + 1}ピア接続 · {running.Photos.Available.Count}枚準備済み · {running.PlaybackState}";
                if (running.Photos.DeferredCount > 0) Status += $" · 容量上限で{running.Photos.DeferredCount}枚待機";
                Raise();
            };
            running.Error += error => { Log.Write("ネットワーク処理を継続して再試行します。", error); Status = error.Message; Raise(); };
            try { await running.StartAsync(); Session = running; Status = "接続候補を検索中"; Raise(); }
            catch
            {
                await running.DisposeAsync(); cache.Dispose(); identity.Dispose(); cache = null; identity = null; output = null;
                throw;
            }
        }
        finally { operations.Release(); }
    }
    public async Task ControlAsync(string operation)
    {
        if (Session == null) return;
        if (Session.ConnectedPeers.Count > 0) await Session.ControlAsync(operation);
        else output?.Control(operation, clock!.Now);
    }
    public void RefreshPhotos() => Session?.RefreshLocalPhotos();
    private void Raise() => dispatcher.BeginInvoke(() => Changed?.Invoke());
    public void Disconnected(string name) => dispatcher.BeginInvoke(() => Notification?.Invoke("Photo Wall の接続が切れました", $"{name} へ再接続しています。"));
    public void Reconnected(string name) => dispatcher.BeginInvoke(() => Notification?.Invoke("Photo Wall に再接続しました", $"{name} との表示同期を準備しています。"));
    public async ValueTask DisposeAsync() { await SetOnlineAsync(false); operations.Dispose(); }
}

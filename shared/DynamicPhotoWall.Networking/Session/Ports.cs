using System.Security.Cryptography.X509Certificates;

namespace DynamicPhotoWall.Networking;

public interface IPeerLink : IAsyncDisposable
{
    PeerHello Remote { get; }
    bool Outbound { get; }
    string RemoteHost { get; }
    ValueTask SendAsync(PeerPacket packet, CancellationToken cancellation);
    IAsyncEnumerable<PeerPacket> ReceiveAsync(CancellationToken cancellation);
}
public interface IPeerTransport : IAsyncDisposable
{
    int Port { get; }
    Task StartAsync(Func<IPeerLink, Task> accept, CancellationToken cancellation);
    Task<IPeerLink> ConnectAsync(PeerCandidate candidate, CancellationToken cancellation);
}
public interface IPeerDiscovery : IAsyncDisposable
{
    event Action<PeerCandidate>? Found;
    Task StartAsync(PeerHello hello, int port, CancellationToken cancellation);
}
public interface IPeerTrust
{
    bool Accept(Guid peerId, string certificateDigest);
}
public interface INetworkPersistence
{
    WallSnapshot? Load();
    void Save(WallSnapshot state);
}
public interface IPhotoProvider
{
    IReadOnlyList<SharedSource> Sources { get; }
    IAsyncEnumerable<(SharedPhoto Photo, byte[] Original)> ReadAsync(SourceSelection selection, CancellationToken cancellation);
}
public interface IScenePlanner
{
    Task<SharedScenePlan?> PrepareAsync(WallSnapshot wall, Guid groupId, IReadOnlyList<SharedPhoto> photos,
        CancellationToken cancellation);
    Task<SharedScenePlan?> PrepareAsync(WallSnapshot wall, Guid groupId, IReadOnlyList<SharedPhoto> photos,
        CancellationToken cancellation, SharedScenePlan? previous)
        => PrepareAsync(wall, groupId, photos, cancellation);
}
public interface IPlaybackOutput
{
    Task PrepareAsync(SharedScenePlan plan, CancellationToken cancellation);
    void Commit(SceneCommit commit);
    void Control(string operation, double effectiveAt);
    void SetRecovery(PeerPlaybackState state, WallSnapshot snapshot);
    void Preview(LayoutPreviewPlan plan) { }
    Task StopAsync();
}
public interface IConnectionNotifications
{
    void Disconnected(string peerName);
    void Reconnected(string peerName);
}
public interface ISharedClock
{
    double Now { get; }
    double Elapsed { get; }
    void Observe(double sentAt, double remoteReceived, double remoteReplied, double receivedAt);
}

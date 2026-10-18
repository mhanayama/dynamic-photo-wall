namespace DynamicPhotoWall.Networking;

public enum PeerPlaybackState { Offline, Synchronized, IsolatedRepeating, Standalone }
public enum PeerConnectionNotice { Disconnected, Reconnected }

// Transport liveness and synchronized playback are deliberately separate.
// The caller passes elapsed real seconds including sleep, not a playback clock.
public sealed class PeerPlaybackRecovery
{
    public const double GraceSeconds = 60;
    private double lastElapsed = double.NegativeInfinity;
    private double? isolatedAt;
    private double? resumeAt;
    private bool resumePrepared;
    private bool connected;
    private bool wantsConnection;
    public bool Online { get; private set; }
    public PeerPlaybackState State { get; private set; } = PeerPlaybackState.Offline;
    public bool ShouldRetry => Online && wantsConnection && !connected;
    public bool IsPreparingSynchronization => connected && State != PeerPlaybackState.Synchronized;

    private void CheckTime(double elapsed)
    {
        PeerProtocol.Require(double.IsFinite(elapsed) && elapsed >= 0 && elapsed >= lastElapsed,
            "Recovery elapsed time must not move backwards.");
        lastElapsed = elapsed;
    }

    public void SetOnline(bool online, double elapsed)
    {
        CheckTime(elapsed);
        if (Online == online) return;
        Online = online; connected = false; wantsConnection = false;
        isolatedAt = null; resumeAt = null; resumePrepared = false;
        State = online ? PeerPlaybackState.Standalone : PeerPlaybackState.Offline;
    }

    // Called for a clicked candidate, accepted inbound session, or saved peer retry.
    // Merely discovering a candidate must not start a connection retry loop.
    public void BeginConnection(double elapsed)
    {
        CheckTime(elapsed);
        PeerProtocol.Require(Online, "Online mode is disabled.");
        wantsConnection = true;
    }

    public void SynchronizationEstablished(double elapsed)
    {
        CheckTime(elapsed);
        PeerProtocol.Require(Online, "Online mode is disabled.");
        connected = true; wantsConnection = true; isolatedAt = null; resumeAt = null; resumePrepared = false;
        State = PeerPlaybackState.Synchronized;
    }

    public PeerConnectionNotice? ConnectionLost(double elapsed, bool canContinueWithOtherPeers)
    {
        CheckTime(elapsed);
        if (!Online) return null;
        var notice = connected ? PeerConnectionNotice.Disconnected : (PeerConnectionNotice?)null;
        connected = false; resumeAt = null; resumePrepared = false;
        if (!canContinueWithOtherPeers && State == PeerPlaybackState.Synchronized)
        {
            isolatedAt = elapsed;
            State = PeerPlaybackState.IsolatedRepeating;
        }
        AdvanceState(elapsed);
        return notice;
    }

    public PeerConnectionNotice? ConnectionRestored(double elapsed)
    {
        CheckTime(elapsed);
        if (!Online || !wantsConnection || connected) return null;
        connected = true;
        AdvanceState(elapsed); // A brief transport recovery does not restart the grace period.
        return PeerConnectionNotice.Reconnected;
    }

    public void PrepareSynchronization(double elapsed, double sharedNow, double effectiveAt)
    {
        CheckTime(elapsed);
        PeerProtocol.Require(Online && connected && double.IsFinite(sharedNow) && double.IsFinite(effectiveAt)
            && effectiveAt > sharedNow, "A connected peer and future synchronization time are required.");
        resumeAt = effectiveAt; resumePrepared = true;
        AdvanceState(elapsed);
    }

    public void Tick(double elapsed, double sharedNow)
    {
        CheckTime(elapsed);
        PeerProtocol.Require(double.IsFinite(sharedNow), "Invalid shared time.");
        AdvanceState(elapsed);
        if (Online && connected && resumePrepared && sharedNow >= resumeAt)
            SynchronizationEstablished(elapsed);
    }

    private void AdvanceState(double elapsed)
    {
        if (isolatedAt != null && elapsed - isolatedAt >= GraceSeconds) State = PeerPlaybackState.Standalone;
    }
}

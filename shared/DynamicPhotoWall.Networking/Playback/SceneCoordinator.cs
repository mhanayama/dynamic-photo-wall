namespace DynamicPhotoWall.Networking;

// Owns only the prepare/ready/commit barrier, not transport, planning or rendering.
public sealed class SceneCoordinator(IScenePlanner planner, IPlaybackOutput output, ISharedClock clock)
{
    private sealed class Pending(SharedScenePlan plan, Guid[] participants, double created)
    {
        public SharedScenePlan Plan { get; } = plan;
        public HashSet<Guid> Waiting { get; } = participants.ToHashSet();
        public double Created { get; } = created;
    }
    private readonly Dictionary<Guid, Pending> pending = [];
    private readonly Dictionary<Guid, double> retryAt = [];
    private readonly Dictionary<Guid, (SharedScenePlan Plan, double Started, double PausedBaseline)> current = [];
    private double? pauseAt;
    private double totalPaused;
    public event Func<PeerPacket, Task>? Broadcast;
    public event Action<SceneCommit>? Committed;
    public bool Paused { get; private set; }
    public bool Stopped { get; private set; }
    public PlaybackStatus Status => new(Paused, Stopped, clock.Now + 1);
    public void ApplyStatus(PlaybackStatus status)
    {
        if (Stopped != status.Stopped) ApplyControl(new(status.Stopped ? "stop" : "start", status.EffectiveAt));
        if (Paused != status.Paused) ApplyControl(new(status.Paused ? "pause" : "resume", status.EffectiveAt));
    }
    public async Task PumpAsync(Guid local, WallSnapshot state, IReadOnlyList<Guid> live,
        IReadOnlyList<SharedPhoto> photos, CancellationToken token)
    {
        if (Stopped || Paused || state.LeaderId != local || live.Count < 2 || photos.Count == 0) return;
        foreach (var id in pending.Where(p => clock.Elapsed - p.Value.Created > 35).Select(p => p.Key).ToArray()) pending.Remove(id);
        var units = state.Displays.Where(d => d.Selected).GroupBy(d => d.GroupId ?? StandaloneId(d.Key));
        foreach (var group in units)
        {
            var participants = group.Select(d => d.Key.PeerId).Where(live.Contains).Distinct().ToArray();
            if (participants.Length == 0 || pending.ContainsKey(group.Key)) continue;
            if (current.TryGetValue(group.Key, out var active) && active.Plan.SettingsRevision == state.Revision
                && clock.Now - active.Started - (totalPaused - active.PausedBaseline) < active.Plan.Duration - 4) continue;
            if (retryAt.TryGetValue(group.Key, out var retry) && clock.Elapsed < retry) continue;
            var plan = await planner.PrepareAsync(state, group.Key, photos, token, active.Plan);
            if (plan == null) { retryAt[group.Key] = clock.Elapsed + 5; continue; }
            retryAt.Remove(group.Key);
            plan.Validate();
            pending[group.Key] = new(plan, participants, clock.Elapsed);
            if (Broadcast != null) await Broadcast(PeerPacket.Create("scenePrepare", plan));
            if (participants.Contains(local))
            {
                await output.PrepareAsync(plan, token);
                pending[group.Key].Waiting.Remove(local);
            }
            await TryCommit(group.Key);
        }
    }
    public static Guid StandaloneId(PeerDisplayKey key)
    {
        var hash = System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(key.LayoutId));
        return Guid.ParseExact(Convert.ToHexStringLower(hash.AsSpan(0, 16)), "N");
    }
    public async Task Ready(Guid peer, SceneReady ready)
    {
        if (!pending.TryGetValue(ready.GroupId, out var item) || item.Plan.Id != ready.PlanId) return;
        item.Waiting.Remove(peer); await TryCommit(ready.GroupId);
    }
    public async Task PeerLost(Guid peer)
    {
        foreach (var group in pending.Keys.ToArray()) { pending[group].Waiting.Remove(peer); await TryCommit(group); }
    }
    private async Task TryCommit(Guid group)
    {
        if (!pending.TryGetValue(group, out var item) || item.Waiting.Count != 0) return;
        var start = clock.Now + 2;
        if (current.TryGetValue(group, out var active) && item.Plan.Continues(active.Plan))
            start = Math.Max(start, active.Started + active.Plan.Duration + totalPaused - active.PausedBaseline);
        var commit = new SceneCommit(item.Plan.Id, group, start);
        current[group] = (item.Plan, commit.StartAt, totalPaused); pending.Remove(group);
        if (Broadcast != null) await Broadcast(PeerPacket.Create("sceneCommit", commit));
        output.Commit(commit);
        Committed?.Invoke(commit);
    }
    public async Task Control(string operation)
    {
        PeerProtocol.Require(operation is "start" or "stop" or "pause" or "resume" or "next", "Unknown playback operation.");
        var at = clock.Now + 1;
        ApplyControl(new(operation, at));
        if (Broadcast != null) await Broadcast(PeerPacket.Create("playbackControl", new PlaybackControl(operation, at)));
    }
    public void ApplyControl(PlaybackControl control)
    {
        switch (control.Operation)
        {
            case "pause": if (!Paused) { Paused = true; pauseAt = control.EffectiveAt; } break;
            case "resume": if (pauseAt != null) totalPaused += Math.Max(0, control.EffectiveAt - pauseAt.Value);
                Paused = false; pauseAt = null; break;
            case "stop": Stopped = true; break;
            case "start": Stopped = false; Paused = false; pauseAt = null; Invalidate(); break;
            case "next": Invalidate(); break;
            default: throw new InvalidDataException("Unknown playback operation.");
        }
        output.Control(control.Operation, control.EffectiveAt);
    }
    public void Invalidate() { pending.Clear(); current.Clear(); retryAt.Clear(); totalPaused = 0; }
    public void LeadershipChanged() { pending.Clear(); retryAt.Clear(); }
    public void Observe(SharedScenePlan plan, SceneCommit commit)
        => current[plan.GroupId] = (plan, commit.StartAt, totalPaused);
}

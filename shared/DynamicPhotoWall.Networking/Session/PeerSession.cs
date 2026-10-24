using System.Collections.Concurrent;

namespace DynamicPhotoWall.Networking;

// Application coordinator: routes events to independent state/photo/playback services.
// All state-changing handlers are serialized; socket reads and photo import stay off this gate.
public sealed partial class PeerSession : IAsyncDisposable
{
    private sealed class LinkState(IPeerLink link, double seen)
    {
        public IPeerLink Link { get; } = link;
        public double Seen { get; set; } = seen;
    }
    private readonly PeerHello local;
    private readonly IPeerTransport transport;
    private readonly IPeerDiscovery discovery;
    private readonly ISharedClock clock;
    private readonly IConnectionNotifications notifications;
    private readonly IPlaybackOutput output;
    private readonly SharedStateCoordinator state;
    private readonly PhotoTransferService photos;
    private readonly SceneCoordinator scenes;
    private readonly PeerDisplay[] localDisplays;
    private readonly IPhotoProvider provider;
    private readonly ConcurrentDictionary<Guid, LinkState> links = new();
    private readonly ConcurrentDictionary<Guid, PeerDisplayKey[]> displayInventories = new();
    private readonly ConcurrentDictionary<Guid, PeerCandidate> candidates = new(), targets = new();
    private readonly ConcurrentDictionary<Guid, double> discoveredAt = new();
    private readonly ConcurrentDictionary<Guid, Task> connecting = new();
    private readonly ConcurrentDictionary<Guid, byte> disconnectedPeers = new();
    private readonly ConcurrentDictionary<Guid, Task> backgroundJobs = new();
    private readonly Dictionary<Guid, TaskCompletionSource<StateResult>> proposals = [];
    private readonly SemaphoreSlim operations = new(1, 1);
    private readonly CancellationTokenSource lifetime = new();
    private readonly PeerPlaybackRecovery recovery = new();
    private readonly HashSet<Guid> notices = [];
    private readonly Dictionary<Guid, SharedScenePlan> knownPlans = [];
    private SharedSource[] remoteSources = [];
    private Task? pumping;
    private Task? importing;
    private CancellationTokenSource? importCancellation;
    private readonly List<Task> importJobs = [];
    private bool started;
    private double lastRetry = -100;
    private double lastMaintenance = -100;
    private SourceSelection[] importSources = [];
    private PeerCandidate Self => new(local, "127.0.0.1", transport.Port);
    public WallSnapshot Snapshot => state.Current;
    public IReadOnlyList<PeerCandidate> Candidates => candidates.Values.OrderBy(c => c.Hello.Name).ToArray();
    public IReadOnlyList<SharedSource> Sources => provider.Sources.Concat(remoteSources).DistinctBy(s => (s.ProviderId, s.SourceId)).ToArray();
    public bool IsSourceConnected(SharedSource source)
        => started && !lifetime.IsCancellationRequested && (source.ProviderId == local.PeerId
            ? provider.Sources.Any(s => s.SourceId == source.SourceId)
            : links.ContainsKey(source.ProviderId) && displayInventories.ContainsKey(source.ProviderId)
                && remoteSources.Any(s => s.ProviderId == source.ProviderId && s.SourceId == source.SourceId));
    public IReadOnlyList<Guid> ConnectedPeers => links.Keys.ToArray();
    public bool IsDisplayConnected(PeerDisplayKey key)
        => started && !lifetime.IsCancellationRequested && (key.PeerId == local.PeerId
            ? localDisplays.Any(d => d.Key == key)
            : links.ContainsKey(key.PeerId) && displayInventories.TryGetValue(key.PeerId, out var confirmed) && confirmed.Contains(key));
    public string PeerName(Guid peerId)
    {
        if (peerId == local.PeerId) return local.Name;
        if (links.TryGetValue(peerId, out var connected)) return connected.Link.Remote.Name;
        if (targets.TryGetValue(peerId, out var known)) return known.Hello.Name;
        return candidates.TryGetValue(peerId, out var candidate) ? candidate.Hello.Name : "未接続の端末";
    }
    public PhotoTransferService Photos => photos;
    public PeerPlaybackState PlaybackState => recovery.State;
    public bool PlaybackPaused => scenes.Paused;
    public bool PlaybackStopped => scenes.Stopped;
    public event Action? Changed;
    public event Action<Exception>? Error;

    public PeerSession(PeerHello local, PeerDisplay[] displays, IPeerTransport transport, IPeerDiscovery discovery,
        INetworkPersistence persistence, IPhotoProvider provider, IPhotoCache cache,
        IScenePlanner planner, IPlaybackOutput output, ISharedClock clock, IConnectionNotifications notifications,
        WallSnapshot initial)
    {
        this.local = local; localDisplays = displays; this.transport = transport; this.discovery = discovery;
        this.provider = provider; this.output = output; this.clock = clock; this.notifications = notifications;
        state = new(local.PeerId, persistence, persistence.Load() ?? initial);
        photos = new(local.PeerId, provider, cache); scenes = new(planner, output, clock);
        scenes.Broadcast += Broadcast;
        scenes.Committed += commit => recovery.PrepareSynchronization(clock.Elapsed, clock.Now, commit.StartAt);
        photos.CatalogProduced += batch => Background(() => Broadcast(PeerPacket.Create("catalog", batch)));
        photos.Changed += () => Changed?.Invoke();
        discovery.Found += candidate =>
        {
            candidates[candidate.Hello.PeerId] = candidate; discoveredAt[candidate.Hello.PeerId] = clock.Elapsed;
            Changed?.Invoke();
        };
    }
    public Task StartAsync(bool automaticPump = true) => Task.Run(() => StartCoreAsync(automaticPump), lifetime.Token);
    private async Task StartCoreAsync(bool automaticPump)
    {
        if (started) return;
        started = true; recovery.SetOnline(true, clock.Elapsed);
        if (Snapshot.LeaderId == local.PeerId)
        {
            RefreshDisplayNames(localDisplays);
            var added = localDisplays.Where(d => !Snapshot.Displays.Any(saved => saved.Key == d.Key)).Select(d => d with { GroupId = null }).ToArray();
            if (added.Length > 0) state.Adopt(Snapshot with { Displays = Snapshot.Displays.Concat(added).ToArray(), Revision = checked(Snapshot.Revision + 1) });
        }
        photos.Configure(Snapshot.Sources); importSources = Snapshot.Sources; StartImport();
        await transport.StartAsync(Attach, lifetime.Token);
        await discovery.StartAsync(local, transport.Port, lifetime.Token);
        if (automaticPump) pumping = PumpLoop();
        Changed?.Invoke();
    }
    public Task ConnectAsync(PeerCandidate candidate)
    {
        PeerProtocol.Require(started && candidate.Hello.PeerId != local.PeerId, "Online mode is disabled or candidate is self.");
        disconnectedPeers.TryRemove(candidate.Hello.PeerId, out _);
        targets[candidate.Hello.PeerId] = candidate;
        explicitJoins[candidate.Hello.PeerId] = Snapshot;
        return ConnectTarget(candidate);
    }
    // Keep saved layout, selections and cached photos. Only an explicit Connect
    // in this session may undo the user's disconnect, including inbound retries.
    public async Task DisconnectAsync(Guid peer)
    {
        PeerProtocol.Require(peer != local.PeerId, "Cannot disconnect self.");
        disconnectedPeers[peer] = 0;
        explicitJoins.TryRemove(peer, out _);
        // Close before taking the handler gate: a stalled send may own it.
        if (links.TryGetValue(peer, out var current)) await current.Link.DisposeAsync();
        await operations.WaitAsync(lifetime.Token);
        try
        {
            if (disconnectedPeers.ContainsKey(peer)) await RemovePeer(peer);
            Changed?.Invoke();
        }
        finally { operations.Release(); }
    }
    private Task ConnectTarget(PeerCandidate candidate)
    {
        if (disconnectedPeers.ContainsKey(candidate.Hello.PeerId) || links.ContainsKey(candidate.Hello.PeerId)) return Task.CompletedTask;
        return connecting.GetOrAdd(candidate.Hello.PeerId, peerKey => Task.Run(async () =>
        {
            try { var link = await transport.ConnectAsync(candidate, lifetime.Token); Background(() => Attach(link)); }
            finally { connecting.TryRemove(candidate.Hello.PeerId, out _); }
        }, lifetime.Token));
    }
    private async Task Attach(IPeerLink link)
    {
        var peer = link.Remote.PeerId;
        try
        {
            await operations.WaitAsync(lifetime.Token);
            try
            {
                if (disconnectedPeers.ContainsKey(peer)) return;
                if (links.TryGetValue(peer, out var old))
                {
                    var preferOutbound = string.CompareOrdinal(local.PeerId.ToString("N"), peer.ToString("N")) < 0;
                    if (old.Link.Outbound == preferOutbound || link.Outbound != preferOutbound) return;
                    links.TryRemove(peer, out _); await old.Link.DisposeAsync();
                }
                displayInventories.TryRemove(peer, out _);
                links[peer] = new(link, clock.Elapsed);
                if (notices.Remove(peer)) notifications.Reconnected(link.Remote.Name);
                recovery.BeginConnection(clock.Elapsed); recovery.ConnectionRestored(clock.Elapsed);
                await link.SendAsync(PeerPacket.Create("inventory", new PeerInventory(Self, localDisplays, provider.Sources.ToArray())), lifetime.Token);
                if (!link.Outbound) await link.SendAsync(PeerPacket.Create("welcome", new SnapshotNotice(Snapshot, LivePeers())), lifetime.Token);
                if (Snapshot.LeaderId == local.PeerId) await link.SendAsync(PeerPacket.Create("playbackStatus", scenes.Status), lifetime.Token);
                foreach (var batch in photos.Catalog.Where(p => p.Key.ProviderId == local.PeerId).Chunk(64))
                    await link.SendAsync(PeerPacket.Create("catalog", new CatalogBatch(batch)), lifetime.Token);
            }
            finally { operations.Release(); }
            await foreach (var packet in link.ReceiveAsync(lifetime.Token))
            {
                await operations.WaitAsync(lifetime.Token);
                try
                {
                    if (!links.TryGetValue(peer, out var current) || current.Link != link) break;
                    current.Seen = clock.Elapsed; await Handle(link, packet);
                }
                finally { operations.Release(); }
            }
        }
        catch (Exception e)
            { if (!lifetime.IsCancellationRequested && !disconnectedPeers.ContainsKey(peer)) Error?.Invoke(e); }
        finally
        {
            await link.DisposeAsync();
            if (!lifetime.IsCancellationRequested)
            {
                await operations.WaitAsync();
                try { if (links.TryGetValue(peer, out var current) && current.Link == link) await RemovePeer(peer); }
                finally { operations.Release(); }
            }
        }
    }
    private async Task Handle(IPeerLink link, PeerPacket packet)
    {
        var peer = link.Remote.PeerId;
        switch (packet.Type)
        {
            case "inventory":
                var inventory = packet.Decode<PeerInventory>();
                foreach (var display in inventory.Displays) display.Validate();
                PeerProtocol.Require(inventory.Candidate.Hello.PeerId == peer && inventory.Displays.All(d => d.Key.PeerId == peer)
                    && inventory.Sources.All(s => s.ProviderId == peer), "Inventory identity differs.");
                var endpoint = inventory.Candidate with { Host = link.RemoteHost };
                displayInventories[peer] = inventory.Displays.Select(d => d.Key).ToArray();
                targets[peer] = endpoint; candidates[peer] = endpoint;
                discoveredAt.TryAdd(peer, clock.Elapsed);
                remoteSources = remoteSources.Where(s => s.ProviderId != peer).Concat(inventory.Sources).ToArray();
                if (Snapshot.LeaderId == local.PeerId)
                {
                    RefreshDisplayNames(inventory.Displays);
                    var added = inventory.Displays.Where(d => !Snapshot.Displays.Any(old => old.Key == d.Key))
                        .Select(d => d with { GroupId = null });
                    var next = Snapshot with { Displays = Snapshot.Displays.Concat(added).ToArray(), Revision = Snapshot.Revision + 1 };
                    state.Adopt(next); await PublishState();
                }
                break;
            case "welcome":
                var welcome = packet.Decode<SnapshotNotice>(); welcome.Snapshot.Validate();
                if (link.Outbound) await JoinWall(link, welcome);
                break;
            case "wallMergeRequest": await MergeWall(packet.Decode<WallMergeRequest>()); break;
            case "wallMigration": await MigrateWall(link, packet.Decode<WallMigration>()); break;
            case "snapshot":
                var notice = packet.Decode<SnapshotNotice>(); notice.Snapshot.Validate();
                if (notice.Snapshot.LeaderId == peer && Leadership.PreferIncoming(Snapshot, notice.Snapshot))
                {
                    var changedSettings = notice.Snapshot.Revision != Snapshot.Revision;
                    state.Adopt(notice.Snapshot); ApplyState(changedSettings);
                }
                break;
            case "propose":
                var result = state.Apply(packet.Decode<StateProposal>());
                await link.SendAsync(PeerPacket.Create("stateResult", result), lifetime.Token);
                if (result.Accepted) { ApplyState(); await PublishState(); }
                break;
            case "stateResult":
                var response = packet.Decode<StateResult>();
                if (peer == Snapshot.LeaderId && proposals.Remove(response.RequestId, out var pending))
                { if (response.Accepted) { state.Adopt(response.Snapshot); ApplyState(); } pending.TrySetResult(response); }
                break;
            case "heartbeat":
                var beat = packet.Decode<Heartbeat>();
                foreach (var member in beat.Members.Where(m => m.Hello.PeerId != local.PeerId))
                {
                    member.Hello.Validate();
                    if (member.Port is <= 0 or > 65535 || !System.Net.IPAddress.TryParse(member.Host, out _)) continue;
                    targets.TryAdd(member.Hello.PeerId, member);
                }
                if (Snapshot.LeaderId == local.PeerId && (beat.SessionId != Snapshot.SessionId || beat.Revision < Snapshot.Revision))
                    await link.SendAsync(PeerPacket.Create("snapshot", new SnapshotNotice(Snapshot, LivePeers())), lifetime.Token);
                break;
            case "clockPing":
                var ping = packet.Decode<ClockPing>(); var received = clock.Now;
                await link.SendAsync(PeerPacket.Create("clockPong", new ClockPong(ping.RequestId, ping.SentAt, received, clock.Now)), lifetime.Token);
                break;
            case "clockPong":
                if (peer == Snapshot.LeaderId)
                {
                    var pong = packet.Decode<ClockPong>(); clock.Observe(pong.SentAt, pong.ReceivedAt, pong.RepliedAt, clock.Now);
                }
                break;
            case "catalog":
                foreach (var request in photos.AcceptCatalog(peer, packet.Decode<CatalogBatch>()))
                    await link.SendAsync(PeerPacket.Create("assetRequest", request), lifetime.Token);
                break;
            case "assetRequest":
                var requestData = packet.Decode<AssetRequest>();
                Background(async () =>
                {
                    await foreach (var chunk in photos.SendAsync(requestData, lifetime.Token))
                        await link.SendAsync(PeerPacket.Create("assetChunk", chunk), lifetime.Token);
                });
                break;
            case "assetChunk":
                var receivedChunk = packet.Decode<AssetChunk>();
                photos.Receive(peer, receivedChunk);
                if (receivedChunk.Last)
                    foreach (var request in photos.MissingRequests(peer))
                        await link.SendAsync(PeerPacket.Create("assetRequest", request), lifetime.Token);
                break;
            case "scenePrepare":
                if (peer != Snapshot.LeaderId) break;
                var plan = packet.Decode<SharedScenePlan>(); plan.Validate();
                if (plan.SessionId != Snapshot.SessionId || plan.SettingsRevision != Snapshot.Revision) break;
                knownPlans[plan.Id] = plan;
                while (knownPlans.Count > 256) knownPlans.Remove(knownPlans.Keys.First());
                if (plan.Displays.Any(d => d.Key.PeerId == local.PeerId))
                {
                    Background(async () =>
                    {
                        using var preparation = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
                        preparation.CancelAfter(TimeSpan.FromSeconds(30));
                        var keys = plan.Placements.Where(p => p.DisplayId == null || plan.Displays.Any(d =>
                            d.Key.PeerId == local.PeerId && d.Key.LayoutId == p.DisplayId)).Select(p => p.Asset).Distinct().ToArray();
                        while (!keys.All(key => photos.Available.Any(p => p.Key == key)))
                            await Task.Delay(100, preparation.Token);
                        if (plan.SessionId != Snapshot.SessionId || plan.SettingsRevision != Snapshot.Revision) return;
                        await output.PrepareAsync(plan, preparation.Token);
                        await link.SendAsync(PeerPacket.Create("sceneReady", new SceneReady(plan.Id, plan.GroupId)), lifetime.Token);
                    });
                }
                break;
            case "sceneReady": if (Snapshot.LeaderId == local.PeerId) await scenes.Ready(peer, packet.Decode<SceneReady>()); break;
            case "sceneCommit":
                if (peer == Snapshot.LeaderId)
                {
                    var commit = packet.Decode<SceneCommit>(); output.Commit(commit);
                    // Only uncommitted plans belong here. The coordinator and
                    // output own the active plan; retaining committed history
                    // also pins every retired plan's ambient PNG payloads.
                    if (knownPlans.Remove(commit.PlanId, out var committedPlan)) scenes.Observe(committedPlan, commit);
                    recovery.PrepareSynchronization(clock.Elapsed, clock.Now, Math.Max(clock.Now + .01, commit.StartAt));
                }
                break;
            case "playbackRequest":
                if (Snapshot.LeaderId == local.PeerId) await scenes.Control(packet.Decode<PlaybackOperation>().Operation);
                break;
            case "playbackControl": if (peer == Snapshot.LeaderId) scenes.ApplyControl(packet.Decode<PlaybackControl>()); break;
            case "playbackStatus": if (peer == Snapshot.LeaderId) scenes.ApplyStatus(packet.Decode<PlaybackStatus>()); break;
            case "layoutPreviewRequest": if (Snapshot.LeaderId == local.PeerId) await SchedulePreview(packet.Decode<LayoutPreviewRequest>()); break;
            case "layoutPreview": if (peer == Snapshot.LeaderId) output.Preview(packet.Decode<LayoutPreviewPlan>()); break;
            default: throw new InvalidDataException("Unknown peer message type.");
        }
        if (packet.Type is not ("assetChunk" or "catalog" or "clockPing" or "clockPong" or "heartbeat")) Changed?.Invoke();
    }
    private Guid[] LivePeers() => links.Keys.Append(local.PeerId).Distinct().ToArray();
    private void ApplyState(bool invalidate = true)
    {
        var changed = !importSources.SequenceEqual(Snapshot.Sources);
        photos.Configure(Snapshot.Sources); importSources = Snapshot.Sources; StartImport(changed);
        if (invalidate) { scenes.Invalidate(); knownPlans.Clear(); }
        Changed?.Invoke();
    }
    private void StartImport(bool replace = false)
    {
        if (!replace && importing is { IsCompleted: false }) return;
        var cancellation = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        var previous = Interlocked.Exchange(ref importCancellation, cancellation);
        try { previous?.Cancel(); } catch (ObjectDisposedException) { }
        importing = Task.Run(async () =>
        {
            try { await photos.ImportAsync(cancellation.Token); }
            catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { }
            catch (Exception e) { if (!lifetime.IsCancellationRequested) Error?.Invoke(e); }
            finally { Interlocked.CompareExchange(ref importCancellation, null, cancellation); cancellation.Dispose(); }
        });
        importJobs.Add(importing);
        importJobs.RemoveAll(task => task.IsCompleted);
    }
    public void RefreshLocalPhotos()
    {
        Background(async () =>
        {
            await operations.WaitAsync(lifetime.Token);
            try
            {
                StartImport();
                await Broadcast(PeerPacket.Create("inventory", new PeerInventory(Self, localDisplays, provider.Sources.ToArray())));
            }
            finally { operations.Release(); }
        });
    }
    public Task<StateResult> ProposeAsync(StateProposal proposal, CancellationToken token = default)
        => Task.Run(() => ProposeCoreAsync(proposal, token), token);
    private async Task<StateResult> ProposeCoreAsync(StateProposal proposal, CancellationToken token)
    {
        Task<StateResult>? waiting = null;
        await operations.WaitAsync(token);
        try
        {
            if (Snapshot.LeaderId == local.PeerId)
            {
                var result = state.Apply(proposal);
                if (result.Accepted) { ApplyState(); await PublishState(); }
                return result;
            }
            PeerProtocol.Require(links.TryGetValue(Snapshot.LeaderId, out var leader), "進行役へ再接続中です。");
            var completion = new TaskCompletionSource<StateResult>(TaskCreationOptions.RunContinuationsAsynchronously);
            proposals.Add(proposal.RequestId, completion); waiting = completion.Task;
            await leader!.Link.SendAsync(PeerPacket.Create("propose", proposal), lifetime.Token);
        }
        finally { operations.Release(); }
        try { return await waiting!.WaitAsync(TimeSpan.FromSeconds(15), token); }
        finally { await operations.WaitAsync(); try { proposals.Remove(proposal.RequestId); } finally { operations.Release(); } }
    }
    public async Task ControlAsync(string operation)
    {
        await operations.WaitAsync(lifetime.Token);
        try
        {
            if (Snapshot.LeaderId == local.PeerId) await scenes.Control(operation);
            else if (links.TryGetValue(Snapshot.LeaderId, out var leader))
                await leader.Link.SendAsync(PeerPacket.Create("playbackRequest", new PlaybackOperation(Guid.NewGuid(), operation)), lifetime.Token);
        }
        finally { operations.Release(); }
    }
    public async Task PreviewAsync(LayoutPreviewRequest request)
    {
        await operations.WaitAsync(lifetime.Token);
        try
        {
            if (Snapshot.LeaderId == local.PeerId) await SchedulePreview(request);
            else if (links.TryGetValue(Snapshot.LeaderId, out var leader))
                await leader.Link.SendAsync(PeerPacket.Create("layoutPreviewRequest", request), lifetime.Token);
        }
        finally { operations.Release(); }
    }
    private async Task SchedulePreview(LayoutPreviewRequest request)
    {
        (Snapshot with { Displays = request.Displays, Groups = request.Groups }).Validate();
        var plan = new LayoutPreviewPlan(request.Enabled, clock.Now + 1, request.Displays, request.Groups);
        await Broadcast(PeerPacket.Create("layoutPreview", plan)); output.Preview(plan);
    }
    private Task PublishState() => Broadcast(PeerPacket.Create("snapshot", new SnapshotNotice(Snapshot, LivePeers())));
    private void RefreshDisplayNames(PeerDisplay[] inventory)
    {
        var names = inventory.ToDictionary(d => d.Key, d => d.Name);
        var displays = Snapshot.Displays.Select(d => names.TryGetValue(d.Key, out var name) && !string.IsNullOrWhiteSpace(name)
            ? d with { Name = name } : d).ToArray();
        if (!displays.SequenceEqual(Snapshot.Displays))
            state.Adopt(Snapshot with { Displays = displays, Revision = checked(Snapshot.Revision + 1) });
    }
    private async Task Broadcast(PeerPacket packet)
    {
        foreach (var item in links.Values)
        {
            try { await item.Link.SendAsync(packet, lifetime.Token); }
            catch (Exception e) when (e is IOException or OperationCanceledException or System.Net.Sockets.SocketException)
                { if (!lifetime.IsCancellationRequested && !disconnectedPeers.ContainsKey(item.Link.Remote.PeerId)) Error?.Invoke(e); }
        }
    }
    private async Task RemovePeer(Guid peer)
    {
        if (!links.TryRemove(peer, out var item)) return;
        displayInventories.TryRemove(peer, out _);
        await item.Link.DisposeAsync(); photos.PeerLost(peer); await scenes.PeerLost(peer);
        if (!disconnectedPeers.ContainsKey(peer) && notices.Add(peer)) notifications.Disconnected(item.Link.Remote.Name);
        recovery.ConnectionLost(clock.Elapsed, links.Count > 0);
        if (Snapshot.LeaderId == peer && Leadership.Select(peer, LivePeers()) == local.PeerId)
        { state.TakeLeadership(); scenes.LeadershipChanged(); await PublishState(); }
        output.SetRecovery(recovery.State, Snapshot); Changed?.Invoke();
    }
    private async Task PumpLoop()
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(1));
        try
        {
            while (await timer.WaitForNextTickAsync(lifetime.Token))
            {
                try { await PumpAsync(); }
                catch (Exception e) when (!lifetime.IsCancellationRequested) { Error?.Invoke(e); }
            }
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
    }
    public async Task PumpAsync()
    {
        await operations.WaitAsync(lifetime.Token);
        try
        {
            if (clock.Elapsed - lastMaintenance >= 60)
            {
                lastMaintenance = clock.Elapsed; photos.Maintain(DateTimeOffset.UtcNow);
                StartImport();
            }
            foreach (var peer in links.Where(p => clock.Elapsed - p.Value.Seen > 6).Select(p => p.Key).ToArray()) await RemovePeer(peer);
            foreach (var peer in discoveredAt.Where(p => clock.Elapsed - p.Value > 8 && !links.ContainsKey(p.Key)).Select(p => p.Key).ToArray())
            { candidates.TryRemove(peer, out _); discoveredAt.TryRemove(peer, out _); }
            // Saved wall membership survives a restart; endpoints do not. Use
            // fresh advertisements for known peers, including changed TCP ports.
            // Discovery of a new wall still requires an explicit Connect.
            foreach (var candidate in candidates.Values.Where(c => c.Hello.PeerId != local.PeerId))
            {
                var peer = candidate.Hello.PeerId;
                if (targets.ContainsKey(peer) || Snapshot.LeaderId == peer
                    || Snapshot.Displays.Any(d => d.Key.PeerId == peer)
                    || Snapshot.Sources.Any(s => s.ProviderId == peer))
                    targets[peer] = candidate;
            }
            recovery.Tick(clock.Elapsed, clock.Now); output.SetRecovery(recovery.State, Snapshot);
            var members = links.Keys.Where(targets.ContainsKey).Select(id => targets[id]).Append(Self).ToArray();
            await Broadcast(PeerPacket.Create("heartbeat", new Heartbeat(members, Snapshot.LeaderId, Snapshot.SessionId, Snapshot.Revision)));
            if (Snapshot.LeaderId != local.PeerId && links.TryGetValue(Snapshot.LeaderId, out var leader))
                await leader.Link.SendAsync(PeerPacket.Create("clockPing", new ClockPing(Guid.NewGuid(), clock.Now)), lifetime.Token);
            await scenes.PumpAsync(local.PeerId, Snapshot, LivePeers(), photos.Available, lifetime.Token);
            foreach (var peer in links.Values)
                foreach (var request in photos.MissingRequests(peer.Link.Remote.PeerId))
                    await peer.Link.SendAsync(PeerPacket.Create("assetRequest", request), lifetime.Token);
            if (clock.Elapsed - lastRetry > 5)
            {
                lastRetry = clock.Elapsed;
                foreach (var candidate in targets.Values.Where(c => !links.ContainsKey(c.Hello.PeerId)))
                    Background(() => ConnectTarget(candidate));
            }
            Changed?.Invoke();
        }
        finally { operations.Release(); }
    }
    private void Background(Func<Task> work)
    {
        if (lifetime.IsCancellationRequested) return;
        var id = Guid.NewGuid();
        var task = Task.Run(async () =>
        { try { await work(); } catch (Exception e) { if (!lifetime.IsCancellationRequested) Error?.Invoke(e); } });
        backgroundJobs[id] = task;
        _ = task.ContinueWith(_ => backgroundJobs.TryRemove(id, out var ignored), TaskScheduler.Default);
    }
    public async ValueTask DisposeAsync()
    {
        await lifetime.CancelAsync();
        foreach (var link in links.Values) await link.Link.DisposeAsync();
        await discovery.DisposeAsync(); await transport.DisposeAsync();
        if (pumping != null) await pumping;
        await Task.WhenAll(backgroundJobs.Values);
        await Task.WhenAll(importJobs);
        photos.Dispose(); await output.StopAsync(); lifetime.Dispose();
    }
}

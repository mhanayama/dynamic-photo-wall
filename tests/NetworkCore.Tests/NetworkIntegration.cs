using System.Net;
using System.Security.Cryptography;
using DynamicPhotoWall.Networking;

internal static class NetworkIntegration
{
    public static int Assertions;
    private static void Check(bool ok, string message) { Assertions++; if (!ok) throw new Exception(message); }
    public static WallSnapshot Initial(Guid peer, PeerDisplay[]? displays = null, SourceSelection[]? sources = null)
        => new(Guid.NewGuid(), Guid.NewGuid(), peer, 0, [], displays ?? [], sources ?? [], new());

    public static void StateAndLeadership()
    {
        var a = Guid.Parse("10000000-0000-0000-0000-000000000001");
        var b = Guid.Parse("10000000-0000-0000-0000-000000000002");
        var c = Guid.Parse("10000000-0000-0000-0000-000000000003");
        Check(Leadership.Select(c, [a, b, c]) == c, "joining peers do not take a healthy coordinator away");
        Check(Leadership.Select(c, [a, b]) == a, "remaining peers independently choose the same successor");
        var disk = new MemoryPersistence(); var coordinator = new SharedStateCoordinator(a, disk, Initial(a));
        var command = new StateProposal(Guid.NewGuid(), 0, [], [], [], new() { PanPixelsPerSecond = 100 });
        var first = coordinator.Apply(command);
        Check(first.Accepted && first.Snapshot.Revision == 1, "leader commits a valid state revision");
        Check(coordinator.Apply(command) == first && coordinator.Current.Revision == 1, "retry cannot apply twice");
        var restarted = new SharedStateCoordinator(a, disk, disk.Load()!);
        Check(restarted.Apply(command).Accepted && restarted.Current.Revision == 1, "request identity survives restart and authority replication");
        Check(!coordinator.Apply(command with { RequestId = Guid.NewGuid() }).Accepted, "concurrent stale editor is rejected");
        coordinator.TakeLeadership();
        Check(coordinator.Current.Term == 1 && coordinator.Current.Revision == 1, "automatic successor preserves settings and advances term");
        var returning = first.Snapshot with { LeaderId = c, Revision = 100 };
        Check(!Leadership.PreferIncoming(coordinator.Current, returning), "returning old coordinator cannot reclaim authority with an old term");
        var nextTerm = coordinator.Current with { SessionId = Guid.NewGuid(), Term = 2, LeaderId = b };
        Check(Leadership.PreferIncoming(coordinator.Current, nextTerm), "newer connected-component authority can merge");
    }

    public static async Task TlsLoopback()
    {
        using var identityA = new PeerIdentity(new MemorySecrets()); using var identityB = new PeerIdentity(new MemorySecrets());
        var helloA = new PeerHello(1, identityA.PeerId, "A", "windows");
        var helloB = new PeerHello(1, identityB.PeerId, "B", "macos");
        var accepted = new TaskCompletionSource<IPeerLink>(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        await using var server = new TlsPeerTransport(helloB, identityB.Certificate, identityB, IPAddress.Loopback);
        await server.StartAsync(async link => { accepted.TrySetResult(link); await release.Task; }, CancellationToken.None);
        await using var client = new TlsPeerTransport(helloA, identityA.Certificate, identityA, IPAddress.Loopback);
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        await using var outgoing = await client.ConnectAsync(new(helloB, "127.0.0.1", server.Port), timeout.Token);
        var incoming = await accepted.Task.WaitAsync(timeout.Token);
        Check(incoming.Remote == helloA && outgoing.Remote == helloB, "mutual TLS exchanges native peer contracts without confirmation");
        await outgoing.SendAsync(PeerPacket.Create("clockPing", new ClockPing(Guid.NewGuid(), 100)), timeout.Token);
        await using var reader = incoming.ReceiveAsync(timeout.Token).GetAsyncEnumerator();
        Check(await reader.MoveNextAsync() && reader.Current.Decode<ClockPing>().SentAt == 100, "length-framed packet crosses encrypted socket");
        await incoming.SendAsync(PeerPacket.Create("clockPong", new ClockPong(Guid.NewGuid(), 100, 101, 102)), timeout.Token);
        await using var reply = outgoing.ReceiveAsync(timeout.Token).GetAsyncEnumerator();
        Check(await reply.MoveNextAsync() && reply.Current.Decode<ClockPong>().RepliedAt == 102, "duplex peer messages remain separate");
        using var changed = new PeerIdentity(new MemorySecrets());
        Check(!identityA.Accept(identityB.PeerId, Convert.ToHexStringLower(SHA256.HashData(changed.Certificate.RawData))),
            "TOFU identity rejects changed registered certificates");
        release.TrySetResult();
    }

    public static async Task PhotoTransfer(string root)
    {
        var providerId = Guid.NewGuid(); var sourceId = Guid.NewGuid(); var generation = Guid.NewGuid();
        var original = RandomNumberGenerator.GetBytes(150000);
        var provider = new FixtureProvider(providerId, sourceId, original);
        using var senderCache = new EncryptedPhotoCache(Path.Combine(root, "sender"), RandomNumberGenerator.GetBytes(32));
        using var recipientCache = new EncryptedPhotoCache(Path.Combine(root, "recipient"), RandomNumberGenerator.GetBytes(32));
        using var sender = new PhotoTransferService(providerId, provider, senderCache);
        using var recipient = new PhotoTransferService(Guid.NewGuid(), new FixtureProvider(Guid.NewGuid(), Guid.NewGuid(), []), recipientCache);
        var selected = new SourceSelection(providerId, sourceId, generation);
        sender.Configure([selected]); recipient.Configure([selected]);
        await sender.ImportAsync(CancellationToken.None);
        Check(sender.Available.Count == 1, "applying source generates a cache and shared face metadata");
        var requests = recipient.AcceptCatalog(providerId, new(sender.Catalog.ToArray()));
        Check(requests.Length == 1, "recipient requests selected provider original");
        await foreach (var chunk in sender.SendAsync(requests[0], CancellationToken.None)) recipient.Receive(providerId, chunk);
        var photo = recipient.Available.Single(); var received = recipient.ReadImage(photo.Key);
        Check(received.SequenceEqual(original), "background transfer preserves all original bytes across multiple chunks");
        Check(photo.FaceMetadata.Faces.Single() == new FaceRegion(.1, .2, .3, .4), "face metadata travels with photo");
        Check(recipient.AcceptCatalog(providerId, new(sender.Catalog.ToArray())).Length == 0, "reconnect reuses verified valid cache");
        recipient.Configure([selected with { GenerationId = Guid.NewGuid() }]);
        Check(recipient.Available.Count == 0, "source reapply invalidates old catalog and files");
        Check(recipient.AcceptCatalog(providerId, new(sender.Catalog.ToArray())).Length == 0, "old catalog cannot repopulate new generation");
    }

    public static async Task SceneBarrier()
    {
        var a = Guid.NewGuid(); var b = Guid.NewGuid(); var group = Guid.NewGuid();
        var displays = new[] { new PeerDisplay(new(a, "1"), true, group, 0, 0, 1920, 1080), new PeerDisplay(new(b, "1"), true, group, 1920, 0, 1920, 1080) };
        var wall = Initial(a, displays) with { Groups = [new(group, "wall")] };
        var clock = new FixtureClock(); var output = new FixtureOutput(); var planner = new FixturePlanner();
        var coordinator = new SceneCoordinator(planner, output, clock);
        var packets = new List<PeerPacket>(); coordinator.Broadcast += packet => { packets.Add(packet); return Task.CompletedTask; };
        var key = new SharedAssetKey(a, Guid.NewGuid(), Guid.NewGuid(), new string('a', 64));
        var photo = new SharedPhoto(key, 1920, 1080, 100, new(1, 1920, 1080, "fixture", "1", FaceAnalysisState.Complete, []));
        await coordinator.PumpAsync(a, wall, [a, b], [photo], CancellationToken.None);
        var prepare = packets.Single().Decode<SharedScenePlan>();
        Check(packets.Count == 1 && packets[0].Type == "scenePrepare", "prepare never starts playback before readiness");
        clock.Time = 10;
        await coordinator.Ready(b, new(prepare.Id, group));
        var commit = packets.Last().Decode<SceneCommit>();
        Check(commit.StartAt == 1012 && output.Commits.Single() == commit, "all ready commits in the future using shared clock");
        var placement = prepare.Placements.Single();
        Check(SceneEvaluation.Evaluate(placement, 2).X == 20, "scene geometry is evaluated from elapsed time");
        Check(Math.Abs(SceneEvaluation.Evaluate(placement, 2.1).X - 21) < 1e-9, "late frame catches up without receive-time anchoring");
    }
    public static async Task TransferQuota(string root)
    {
        var peer = Guid.NewGuid(); var source = Guid.NewGuid(); var selected = new SourceSelection(peer, source, Guid.NewGuid());
        var provider = new FixtureProvider(peer, source, new byte[8192]);
        using var firstCache = new EncryptedPhotoCache(Path.Combine(root, "sender"), RandomNumberGenerator.GetBytes(32));
        using var secondCache = new EncryptedPhotoCache(Path.Combine(root, "receiver"), RandomNumberGenerator.GetBytes(32), maxDiskBytes: 4096);
        using var sender = new PhotoTransferService(peer, provider, firstCache);
        using var receiver = new PhotoTransferService(Guid.NewGuid(), new FixtureProvider(Guid.NewGuid(), source, []), secondCache);
        sender.Configure([selected]); receiver.Configure([selected]); await sender.ImportAsync(CancellationToken.None);
        var request = receiver.AcceptCatalog(peer, new(sender.Catalog.ToArray())).Single();
        await foreach (var chunk in sender.SendAsync(request, CancellationToken.None)) receiver.Receive(peer, chunk);
        Check(receiver.DeferredCount == 1 && receiver.Available.Count == 0, "full original is deferred when encrypted disk quota would be exceeded");
        Check(receiver.MissingRequests(peer).Length == 0, "quota does not cause an immediate download and eviction loop");
        Check(!Directory.EnumerateFiles(Path.Combine(root, "receiver"), "*", SearchOption.AllDirectories).Any(), "over-budget transfer never publishes a partial original");
        receiver.Configure([]);
        Check(receiver.DeferredCount == 0, "source removal clears deferred work");
    }

    internal sealed class MemorySecrets : ISecretStore
    {
        private readonly Dictionary<string, byte[]> data = [];
        public byte[]? Read(string name) => data.TryGetValue(name, out var value) ? value.ToArray() : null;
        public void Write(string name, byte[] value) => data[name] = value.ToArray();
    }
    internal sealed class MemoryPersistence : INetworkPersistence
    {
        public WallSnapshot? Value;
        public WallSnapshot? Load() => Value;
        public void Save(WallSnapshot value) => Value = value;
    }
    internal sealed class FixtureClock : ISharedClock
    {
        public double Time;
        public double Now => 1000 + Time;
        public double Elapsed => Time;
        public void Observe(double a, double b, double c, double d) { }
    }
    internal sealed class FixtureProvider(Guid peer, Guid source, byte[] original) : IPhotoProvider
    {
        public IReadOnlyList<SharedSource> Sources => [new(peer, source, "synthetic")];
        public async IAsyncEnumerable<(SharedPhoto Photo, byte[] Original)> ReadAsync(SourceSelection selected,
            [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken cancellation)
        {
            if (original.Length == 0) yield break;
            await Task.Yield(); cancellation.ThrowIfCancellationRequested();
            yield return (new(new(peer, source, selected.GenerationId, Convert.ToHexStringLower(SHA256.HashData(original))),
                6000, 4000, original.Length, new(1, 6000, 4000, "fixture", "1", FaceAnalysisState.Complete, [new(.1, .2, .3, .4)])), original.ToArray());
        }
    }
    internal sealed class FixtureOutput : IPlaybackOutput
    {
        public List<SceneCommit> Commits = [];
        public List<LayoutPreviewPlan> Previews = [];
        public Task PrepareAsync(SharedScenePlan plan, CancellationToken token) => Task.CompletedTask;
        public void Commit(SceneCommit commit) => Commits.Add(commit);
        public void Control(string operation, double at) { }
        public void SetRecovery(PeerPlaybackState state, WallSnapshot snapshot) { }
        public void Preview(LayoutPreviewPlan plan) => Previews.Add(plan);
        public Task StopAsync() => Task.CompletedTask;
    }
    internal sealed class FixturePlanner : IScenePlanner
    {
        public Task<SharedScenePlan?> PrepareAsync(WallSnapshot state, Guid group, IReadOnlyList<SharedPhoto> photos, CancellationToken token)
            => Task.FromResult<SharedScenePlan?>(new(Guid.NewGuid(), group, state.SessionId, state.Revision,
                SceneMode.HorizontalPan, new(3840, 1080), state.Displays, 20, 1, "#101116",
                [new(0, photos[0].Key, null, new(0, 0, 3840, 1080), 5000, 1080, 0, 0, 200, 0, 1, 1, .5, .5,
                    0, 20, 0, 20, 1, 0, false)], []));
    }
}

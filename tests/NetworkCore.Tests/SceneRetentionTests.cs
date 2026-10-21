using System.Runtime.CompilerServices;
using System.Security.Cryptography;
using System.Threading.Channels;
using DynamicPhotoWall.Networking;

internal static class SceneRetentionTests
{
    public static async Task Run(string root)
    {
        var local = Guid.NewGuid(); var leader = Guid.NewGuid(); var source = Guid.NewGuid();
        var selected = new SourceSelection(local, source, Guid.NewGuid());
        var display = new PeerDisplay(new(local, "fixture"), true, null, 0, 0, 1920, 1080);
        var group = SceneCoordinator.StandaloneId(display.Key);
        var initial = NetworkIntegration.Initial(leader, [display], [selected]);
        var transport = new Transport(); var output = new Output();
        using var cache = new EncryptedPhotoCache(root, RandomNumberGenerator.GetBytes(32));
        await using var session = new PeerSession(new(1, local, "receiver", "windows"), [display], transport,
            new Discovery(), new NetworkIntegration.MemoryPersistence { Value = initial },
            new NetworkIntegration.FixtureProvider(local, source, new byte[128]), cache,
            new NetworkIntegration.FixturePlanner(), output, new NetworkIntegration.FixtureClock(), new Notices(), initial);
        var errors = new List<Exception>(); session.Error += e => { lock (errors) errors.Add(e); };
        await session.StartAsync(false);
        var deadline = DateTime.UtcNow.AddSeconds(5);
        while (session.Photos.Available.Count == 0 && DateTime.UtcNow < deadline) await Task.Delay(10);
        var asset = session.Photos.Available.Single().Key;
        var link = new Link(new(1, leader, "leader", "macos"));
        var attached = transport.Accept!(link);
        try
        {
            // Exercise actual serialized prepare/ready/commit handling. The output
            // keeps only weak references, like a renderer after retiring a scene.
            for (var i = 0; i < 300; i++)
            {
                var id = Guid.NewGuid();
                await SendPlan(link, initial, display, group, asset, id, i);
                var ready = await link.Ready.Reader.ReadAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(5));
                if (ready != new SceneReady(id, group)) throw new Exception("Ready lost its plan or group identity");
                var commit = new SceneCommit(id, group, 1002 + i);
                await link.Incoming.Writer.WriteAsync(PeerPacket.Create("sceneCommit", commit));
                if (await output.Committed.Reader.ReadAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(5)) != commit)
                    throw new Exception("Commit lost its shared start time or identity");
            }
            // A subsequent ready is a barrier after the final commit handler.
            await SendPlan(link, initial, display, group, asset, Guid.NewGuid(), 300);
            await link.Ready.Reader.ReadAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(5));
            GC.Collect(); GC.WaitForPendingFinalizers(); GC.Collect();
            var retired = output.Payloads.Take(299).Count(reference => reference.TryGetTarget(out _));
            Console.WriteLine($"Retired scene PNG payloads retained: {retired}/299 (64 KiB each)");
            if (retired != 0) throw new Exception("Committed scene history retains retired ambient PNGs");
            if (output.CommitCount != 300 || output.Payloads.Count != 301 || output.FullPayloadCount != 301)
                throw new Exception("Memory cleanup must preserve every prepare payload and commit");
            lock (errors) if (errors.Count > 0) throw new AggregateException(errors);
        }
        finally { await link.DisposeAsync(); await attached; }
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    private static ValueTask SendPlan(Link link, WallSnapshot wall, PeerDisplay display, Guid group,
        SharedAssetKey asset, Guid id, int sequence)
    {
        var payload = new byte[65536]; payload[0] = (byte)sequence;
        var plan = new SharedScenePlan(id, group, wall.SessionId, wall.Revision, SceneMode.Gallery,
            new(1920, 1080), [display], 20, 1, "#101116",
            [new(0, asset, null, new(0, 0, 1920, 1080), 1920, 1080, 0, 0, 0, 0, 1, 1, .5, .5, 0, 20, 0, 20, 1, 0, false)],
            [new(0, payload)]);
        return link.Incoming.Writer.WriteAsync(PeerPacket.Create("scenePrepare", plan));
    }

    private sealed class Output : IPlaybackOutput
    {
        public List<WeakReference<byte[]>> Payloads { get; } = [];
        public Channel<SceneCommit> Committed { get; } = Channel.CreateUnbounded<SceneCommit>();
        public int CommitCount, FullPayloadCount;
        public Task PrepareAsync(SharedScenePlan plan, CancellationToken token)
        {
            Payloads.Add(new(plan.Ambient.Single().Png));
            if (plan.Ambient[0].Png.Length == 65536) FullPayloadCount++;
            return Task.CompletedTask;
        }
        public void Commit(SceneCommit commit) { CommitCount++; Committed.Writer.TryWrite(commit); }
        public void Control(string operation, double at) { }
        public void SetRecovery(PeerPlaybackState state, WallSnapshot wall) { }
        public Task StopAsync() => Task.CompletedTask;
    }
    private sealed class Link(PeerHello remote) : IPeerLink
    {
        public Channel<PeerPacket> Incoming { get; } = Channel.CreateUnbounded<PeerPacket>();
        public Channel<SceneReady> Ready { get; } = Channel.CreateUnbounded<SceneReady>();
        public PeerHello Remote => remote;
        public bool Outbound => false;
        public string RemoteHost => "127.0.0.1";
        public ValueTask SendAsync(PeerPacket packet, CancellationToken token)
        {
            if (packet.Type == "sceneReady") Ready.Writer.TryWrite(packet.Decode<SceneReady>());
            return ValueTask.CompletedTask;
        }
        public IAsyncEnumerable<PeerPacket> ReceiveAsync(CancellationToken token) => Incoming.Reader.ReadAllAsync(token);
        public ValueTask DisposeAsync() { Incoming.Writer.TryComplete(); return ValueTask.CompletedTask; }
    }
    private sealed class Transport : IPeerTransport
    {
        public Func<IPeerLink, Task>? Accept;
        public int Port => 1;
        public Task StartAsync(Func<IPeerLink, Task> accept, CancellationToken token) { Accept = accept; return Task.CompletedTask; }
        public Task<IPeerLink> ConnectAsync(PeerCandidate candidate, CancellationToken token) => throw new NotSupportedException();
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }
    private sealed class Discovery : IPeerDiscovery
    {
        public event Action<PeerCandidate>? Found { add { } remove { } }
        public Task StartAsync(PeerHello hello, int port, CancellationToken token) => Task.CompletedTask;
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }
    private sealed class Notices : IConnectionNotifications
    {
        public void Disconnected(string name) { }
        public void Reconnected(string name) { }
    }
}

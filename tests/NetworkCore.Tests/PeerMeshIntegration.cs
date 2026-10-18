using System.Collections.Concurrent;
using System.Runtime.CompilerServices;
using System.Security.Cryptography;
using System.Threading.Channels;
using DynamicPhotoWall.Networking;

internal static class PeerMeshIntegration
{
    public static int Assertions;
    private static void Check(bool value, string message) { Assertions++; if (!value) throw new Exception(message); }
    public static async Task Run(string root)
    {
        var mesh = new Mesh();
        var ids = Enumerable.Range(1, 3).Select(i => Guid.Parse($"10000000-0000-0000-0000-{i:000000000000}")).ToArray();
        var source = Guid.NewGuid();
        var sessions = new List<PeerSession>(); var caches = new List<EncryptedPhotoCache>();
        var clocks = ids.Select(_ => new NetworkIntegration.FixtureClock()).ToArray();
        var outputs = ids.Select(_ => new NetworkIntegration.FixtureOutput()).ToArray();
        var notices = ids.Select(_ => new Notices()).ToArray();
        try
        {
            for (var i = 0; i < ids.Length; i++)
            {
                var cache = new EncryptedPhotoCache(Path.Combine(root, i.ToString()), RandomNumberGenerator.GetBytes(32)); caches.Add(cache);
                var hello = new PeerHello(1, ids[i], $"peer{i}", i == 0 ? "macos" : "windows");
                var display = new PeerDisplay(new(ids[i], "screen"), true, null, i * 100, 0, 100, 100) { Name = $"Monitor {i}" };
                var provider = new NetworkIntegration.FixtureProvider(ids[i], source, i == 0 ? new byte[150000] : []);
                var session = new PeerSession(hello, [display], new Transport(mesh, hello), new Discovery(),
                    new NetworkIntegration.MemoryPersistence(), provider, cache, new NetworkIntegration.FixturePlanner(), outputs[i], clocks[i],
                    notices[i], NetworkIntegration.Initial(ids[i], [display with { Name = null }]));
                sessions.Add(session); await session.StartAsync(automaticPump: false);
                Check(session.Snapshot.Displays.Single().Name == display.Name, "startup restores the local display name in an old saved layout");
            }
            await sessions[1].ConnectAsync(new(new(1, ids[0], "peer0", "macos"), "127.0.0.1", 1));
            await Until(() => sessions[0].Snapshot.Displays.Length == 2 && sessions[1].Snapshot.WallId == sessions[0].Snapshot.WallId);
            await sessions[2].ConnectAsync(new(new(1, ids[0], "peer0", "macos"), "127.0.0.1", 1));
            await Rounds(8);
            await Until(() => sessions.All(s => s.ConnectedPeers.Count == 2 && s.Snapshot.Displays.Length == 3));
            Check(sessions.All(s => s.Snapshot.LeaderId == ids[0]), "connecting peers preserve existing coordinator");
            Check(sessions.All(s => s.Snapshot.Displays.All(d => d.Name == $"Monitor {Array.IndexOf(ids, d.Key.PeerId)}")),
                "every peer receives the display names of the integrated wall");
            var group = Guid.NewGuid(); var draft = sessions[1].Snapshot;
            var accepted = await sessions[1].ProposeAsync(new(Guid.NewGuid(), draft.Revision, [new(group, "combined")],
                draft.Displays.Select(d => d with { GroupId = group }).ToArray(), [new(ids[0], source, Guid.NewGuid())], new()));
            Check(accepted.Accepted, "non-coordinator settings UI changes shared configuration");
            await Until(() => sessions.All(s => s.Snapshot.Revision == accepted.Snapshot.Revision && s.Photos.Available.Count == 1));
            await Rounds(4);
            await Until(() => outputs.All(o => o.Commits.Count > 0));
            Check(outputs.Select(o => o.Commits.Last().StartAt).Distinct().Count() == 1, "all native outputs receive identical future start time");
            Check(sessions.SelectMany(s => s.Photos.Available).Select(p => p.Key).Distinct().Count() == 1, "one original and face catalog is shared across all peers");
            var previewRevision = sessions[1].Snapshot.Revision;
            await sessions[1].PreviewAsync(new(true, sessions[1].Snapshot.Displays, sessions[1].Snapshot.Groups));
            await Until(() => outputs.All(o => o.Previews.Count == 1));
            Check(outputs.Select(o => o.Previews[0].EffectiveAt).Distinct().Count() == 1, "draft test pattern is scheduled at the same time on every peer");
            Check(sessions.All(s => s.Snapshot.Revision == previewRevision), "layout preview does not commit the draft settings");
            mesh.Block(ids[0], true);
            await Until(() => sessions[1].ConnectedPeers.Count == 1 && sessions[2].ConnectedPeers.Count == 1);
            await Rounds(4);
            Check(sessions[1].Snapshot.LeaderId == ids[1] && sessions[2].Snapshot.LeaderId == ids[1], "surviving peers automatically agree on a new coordinator");
            Check(sessions[0].PlaybackState == PeerPlaybackState.IsolatedRepeating, "isolated peer repeats its previous mode first");
            clocks[0].Time += 61; await sessions[0].PumpAsync();
            Check(sessions[0].PlaybackState == PeerPlaybackState.Standalone, "isolated peer becomes standalone after one minute");
            Check(sessions[1].Snapshot.Displays.Length == 3, "disconnect retains the integrated display layout");
            mesh.Block(ids[0], false);
            await Rounds(12);
            await Until(() => sessions.All(s => s.ConnectedPeers.Count == 2));
            await Rounds(8);
            Check(sessions.All(s => s.Snapshot.LeaderId == ids[1]), "returning former coordinator adopts the successor authority");
            Check(sessions.All(s => s.Snapshot.Displays.All(d => !string.IsNullOrWhiteSpace(d.Name))), "display names survive failover and reconnection");
            Check(notices[0].DisconnectedCount == 2 && notices[0].ReconnectedCount == 2, "OS notices fire once for each lost and recovered connection");
        }
        finally { foreach (var session in sessions) await session.DisposeAsync(); foreach (var cache in caches) cache.Dispose(); }
        async Task Rounds(int count)
        {
            for (var n = 0; n < count; n++)
            {
                for (var i = 0; i < sessions.Count; i++) { clocks[i].Time += 1; await sessions[i].PumpAsync(); }
                await Task.Delay(30);
            }
        }
    }
    private static async Task Until(Func<bool> condition)
    {
        for (var n = 0; n < 250; n++) { if (condition()) return; await Task.Delay(20); }
        throw new TimeoutException("Peer mesh did not converge.");
    }
    public static async Task MergeExistingWalls(string root)
    {
        var mesh = new Mesh(); var ids = Enumerable.Range(1, 4).Select(i => Guid.Parse($"20000000-0000-0000-0000-{i:000000000000}")).ToArray();
        var sessions = new List<PeerSession>(); var caches = new List<EncryptedPhotoCache>();
        var clocks = ids.Select(_ => new NetworkIntegration.FixtureClock()).ToArray();
        try
        {
            for (var i = 0; i < ids.Length; i++)
            {
                var cache = new EncryptedPhotoCache(Path.Combine(root, i.ToString()), RandomNumberGenerator.GetBytes(32)); caches.Add(cache);
                var hello = new PeerHello(1, ids[i], $"merge{i}", "windows"); var display = new PeerDisplay(new(ids[i], "screen"), true, null, i * 100, 0, 100, 100);
                var session = new PeerSession(hello, [display], new Transport(mesh, hello), new Discovery(), new NetworkIntegration.MemoryPersistence(),
                    new NetworkIntegration.FixtureProvider(ids[i], Guid.NewGuid(), []), cache, new NetworkIntegration.FixturePlanner(), new NetworkIntegration.FixtureOutput(), clocks[i], new Notices(), NetworkIntegration.Initial(ids[i], [display]));
                sessions.Add(session); await session.StartAsync(false);
            }
            await sessions[1].ConnectAsync(Candidate(0)); await sessions[3].ConnectAsync(Candidate(2));
            await Until(() => sessions.All(s => s.Snapshot.Displays.Length == 2)); await Rounds(4);
            var ab = Guid.NewGuid(); var cd = Guid.NewGuid();
            await Configure(0, ab); await Configure(2, cd); await Rounds(3);
            await sessions[2].ControlAsync("pause"); await Rounds(2);
            var targetWall = sessions[2].Snapshot.WallId;
            await sessions[1].ConnectAsync(Candidate(2)); await Rounds(15);
            await Until(() => sessions.All(s => s.Snapshot.WallId == targetWall && s.Snapshot.Displays.Length == 4 && s.ConnectedPeers.Count == 3));
            Check(sessions.All(s => s.Snapshot.Displays.Count(d => d.GroupId == ab) == 2 && s.Snapshot.Displays.Count(d => d.GroupId == cd) == 2),
                "merging existing peer groups retains both cross-peer display layouts");
            Check(sessions.All(s => s.Snapshot.LeaderId == ids[2]), "explicit connection adopts target wall authority throughout the former component");
            Check(sessions.All(s => s.PlaybackPaused), "newly joined peers inherit the destination wall's pause state");
            await sessions[0].ControlAsync("resume"); await Rounds(3);
            Check(sessions.All(s => !s.PlaybackPaused), "a new peer can resume the wall before presenting its first shared scene");
        }
        finally { foreach (var session in sessions) await session.DisposeAsync(); foreach (var cache in caches) cache.Dispose(); }
        PeerCandidate Candidate(int i) => new(new(1, ids[i], $"merge{i}", "windows"), "127.0.0.1", 1);
        async Task Configure(int i, Guid group)
        {
            var wall = sessions[i].Snapshot;
            var result = await sessions[i].ProposeAsync(new(Guid.NewGuid(), wall.Revision, [new(group, "Group")], wall.Displays.Select(d => d with { GroupId = group }).ToArray(), [], new()));
            Check(result.Accepted, "original component settings are committed before the merge");
        }
        async Task Rounds(int n)
        {
            for (var round = 0; round < n; round++) { for (var i = 0; i < sessions.Count; i++) { clocks[i].Time += 1; await sessions[i].PumpAsync(); }; await Task.Delay(30); }
        }
    }
    public static async Task SavedDisplaysAreNotConnections(string root)
    {
        var mesh = new Mesh(); var a = Guid.NewGuid(); var b = Guid.NewGuid(); var stalePeer = Guid.NewGuid();
        var helloA = new PeerHello(1, a, "current", "windows"); var helloB = new PeerHello(1, b, "other", "macos");
        var local = new PeerDisplay(new(a, "present"), true, null, 0, 0, 100, 100) { Name = "Current monitor" };
        var removed = local with { Key = new(a, "old-monitor"), X = -100, Name = "Removed monitor" };
        var remote = local with { Key = new(b, "present"), X = 100, Name = "Other monitor" };
        var stale = local with { Key = new(stalePeer, "old-remote"), X = 200, Name = "Old peer" };
        var saved = NetworkIntegration.Initial(a, [removed, remote, stale]);
        using var cacheA = new EncryptedPhotoCache(Path.Combine(root, "a"), RandomNumberGenerator.GetBytes(32));
        using var cacheB = new EncryptedPhotoCache(Path.Combine(root, "b"), RandomNumberGenerator.GetBytes(32));
        var discovery = new Discovery();
        await using var sessionA = new PeerSession(helloA, [local], new Transport(mesh, helloA), discovery,
            new NetworkIntegration.MemoryPersistence { Value = saved }, new NetworkIntegration.FixtureProvider(a, Guid.NewGuid(), []),
            cacheA, new NetworkIntegration.FixturePlanner(), new NetworkIntegration.FixtureOutput(), new NetworkIntegration.FixtureClock(), new Notices(), NetworkIntegration.Initial(a));
        await using var sessionB = new PeerSession(helloB, [remote], new Transport(mesh, helloB), new Discovery(),
            new NetworkIntegration.MemoryPersistence(), new NetworkIntegration.FixtureProvider(b, Guid.NewGuid(), []),
            cacheB, new NetworkIntegration.FixturePlanner(), new NetworkIntegration.FixtureOutput(), new NetworkIntegration.FixtureClock(), new Notices(), NetworkIntegration.Initial(b, [remote]));
        await sessionA.StartAsync(false); await sessionB.StartAsync(false);
        Check(sessionA.Snapshot.Displays.Length == 4 && sessionA.Snapshot.Displays.Any(d => d.Key == local.Key) && sessionA.IsDisplayConnected(local.Key),
            "restart retains saved layout and adds a newly detected local monitor");
        Check(!sessionA.IsDisplayConnected(remote.Key) && !sessionA.IsDisplayConnected(stale.Key) && !sessionA.IsDisplayConnected(removed.Key),
            "saved peers and removed local monitors are not current connections");
        discovery.Offer(new(helloB, "127.0.0.1", 1));
        Check(sessionA.Candidates.Count == 1 && !sessionA.IsDisplayConnected(remote.Key), "LAN discovery alone cannot confirm a display connection");
        var previousWall = sessionB.Snapshot.WallId;
        await sessionB.ConnectAsync(new(helloA, "127.0.0.1", 1));
        await Until(() => sessionA.IsDisplayConnected(remote.Key) && sessionB.IsDisplayConnected(local.Key)
            && sessionA.Snapshot.MergedWalls.Contains(previousWall) && sessionB.Snapshot.WallId == sessionA.Snapshot.WallId);
        Check(!sessionB.IsDisplayConnected(removed.Key) && !sessionA.IsDisplayConnected(stale.Key), "authenticated inventories exclude saved-only monitors");
        var previous = sessionA.Snapshot.Displays.ToArray();
        mesh.Block(b, true);
        await Until(() => sessionA.ConnectedPeers.Count == 0 && sessionB.ConnectedPeers.Count == 0 && !sessionA.IsDisplayConnected(remote.Key));
        Check(sessionA.Snapshot.Displays.SequenceEqual(previous), "disconnection changes availability without deleting placement or selection");
        mesh.Block(b, false);
        await sessionB.ConnectAsync(new(helloA, "127.0.0.1", 1));
        await Until(() => sessionA.IsDisplayConnected(remote.Key) && sessionB.IsDisplayConnected(local.Key));
        Check(!sessionA.IsDisplayConnected(stale.Key) && sessionA.Snapshot.Displays.Length == 4, "reconnection restores confirmed monitors and retains hidden saved entries");
    }
    private sealed class Notices : IConnectionNotifications
    {
        public int DisconnectedCount, ReconnectedCount;
        public void Disconnected(string name) => DisconnectedCount++;
        public void Reconnected(string name) => ReconnectedCount++;
    }
    private sealed class Discovery : IPeerDiscovery
    {
        public event Action<PeerCandidate>? Found;
        public void Offer(PeerCandidate candidate) => Found?.Invoke(candidate);
        public Task StartAsync(PeerHello local, int port, CancellationToken token) => Task.CompletedTask;
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }
    private sealed class Mesh
    {
        public readonly ConcurrentDictionary<Guid, Transport> Nodes = new();
        public readonly ConcurrentBag<Link> Links = [];
        public readonly ConcurrentDictionary<Guid, bool> Blocked = new();
        public void Block(Guid id, bool value)
        {
            Blocked[id] = value;
            if (value) foreach (var link in Links.Where(l => l.Local == id || l.Remote.PeerId == id)) link.Close();
        }
    }
    private sealed class Transport(Mesh mesh, PeerHello hello) : IPeerTransport
    {
        private Func<IPeerLink, Task>? accept;
        public int Port => 1;
        public Task StartAsync(Func<IPeerLink, Task> handler, CancellationToken token)
        { accept = handler; mesh.Nodes[hello.PeerId] = this; return Task.CompletedTask; }
        public Task<IPeerLink> ConnectAsync(PeerCandidate candidate, CancellationToken token)
        {
            if (mesh.Blocked.GetValueOrDefault(hello.PeerId) || mesh.Blocked.GetValueOrDefault(candidate.Hello.PeerId))
                throw new IOException("Simulated partition");
            var remote = mesh.Nodes[candidate.Hello.PeerId];
            var a = Channel.CreateUnbounded<PeerPacket>(); var b = Channel.CreateUnbounded<PeerPacket>();
            var outgoing = new Link(hello.PeerId, candidate.Hello, true, a, b);
            var incoming = new Link(candidate.Hello.PeerId, hello, false, b, a);
            mesh.Links.Add(outgoing); mesh.Links.Add(incoming);
            _ = Task.Run(() => remote.accept!(incoming));
            return Task.FromResult<IPeerLink>(outgoing);
        }
        public ValueTask DisposeAsync() { mesh.Nodes.TryRemove(hello.PeerId, out _); return ValueTask.CompletedTask; }
    }
    private sealed class Link(Guid local, PeerHello remote, bool outbound, Channel<PeerPacket> read, Channel<PeerPacket> write) : IPeerLink
    {
        public Guid Local => local;
        public PeerHello Remote => remote;
        public bool Outbound => outbound;
        public string RemoteHost => "127.0.0.1";
        public ValueTask SendAsync(PeerPacket packet, CancellationToken token)
        { if (!write.Writer.TryWrite(packet)) throw new IOException("Link closed"); return ValueTask.CompletedTask; }
        public async IAsyncEnumerable<PeerPacket> ReceiveAsync([EnumeratorCancellation] CancellationToken token)
        { await foreach (var packet in read.Reader.ReadAllAsync(token)) yield return packet; }
        public void Close() { read.Writer.TryComplete(); write.Writer.TryComplete(); }
        public ValueTask DisposeAsync() { Close(); return ValueTask.CompletedTask; }
    }
}

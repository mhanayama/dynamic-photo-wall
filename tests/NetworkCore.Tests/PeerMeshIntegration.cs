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
                var display = new PeerDisplay(new(ids[i], "screen"), true, null, i * 100, 0, 100, 100);
                var provider = new NetworkIntegration.FixtureProvider(ids[i], source, i == 0 ? new byte[150000] : []);
                var session = new PeerSession(hello, [display], new Transport(mesh, hello), new Discovery(),
                    new NetworkIntegration.MemoryPersistence(), provider, cache, new NetworkIntegration.FixturePlanner(), outputs[i], clocks[i],
                    notices[i], NetworkIntegration.Initial(ids[i], [display]));
                sessions.Add(session); await session.StartAsync(automaticPump: false);
            }
            await sessions[1].ConnectAsync(new(new(1, ids[0], "peer0", "macos"), "127.0.0.1", 1));
            await Until(() => sessions[0].Snapshot.Displays.Length == 2 && sessions[1].Snapshot.WallId == sessions[0].Snapshot.WallId);
            await sessions[2].ConnectAsync(new(new(1, ids[0], "peer0", "macos"), "127.0.0.1", 1));
            await Rounds(8);
            await Until(() => sessions.All(s => s.ConnectedPeers.Count == 2 && s.Snapshot.Displays.Length == 3));
            Check(sessions.All(s => s.Snapshot.LeaderId == ids[0]), "connecting peers preserve existing coordinator");
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
    private sealed class Notices : IConnectionNotifications
    {
        public int DisconnectedCount, ReconnectedCount;
        public void Disconnected(string name) => DisconnectedCount++;
        public void Reconnected(string name) => ReconnectedCount++;
    }
    private sealed class Discovery : IPeerDiscovery
    {
        public event Action<PeerCandidate>? Found { add { } remove { } }
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

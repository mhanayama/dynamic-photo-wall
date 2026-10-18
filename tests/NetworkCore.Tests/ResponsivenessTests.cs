using System.Security.Cryptography;
using DynamicPhotoWall.Networking;

internal static class ResponsivenessTests
{
    public static int Assertions;
    private static void Check(bool condition, string message) { Assertions++; if (!condition) throw new Exception(message); }

    public static void Notifications()
    {
        var queue = new Queue<Action>(); var observed = 0; var latest = 0;
        CoalescedAction? updates = null;
        using (updates = new(queue.Enqueue, () => { observed = latest; if (latest == 10000) { latest++; updates!.Request(); } }))
        {
            for (var i = 1; i <= 10000; i++) { latest = i; updates.Request(); }
            Check(queue.Count == 1, "ten thousand notifications create one pending UI callback");
            queue.Dequeue()();
            Check(observed == 10000 && queue.Count == 1, "a change during refresh schedules one follow-up");
            queue.Dequeue()();
            Check(observed == 10001 && queue.Count == 0, "consumer catches up to the latest state");
            updates.Request();
        }
        queue.Dequeue()();
        Check(observed == 10001, "disposal suppresses late callbacks");
    }

    public static async Task CacheProgress(string root)
    {
        var bytes = RandomNumberGenerator.GetBytes(150000); var photo = Photo(bytes);
        using var cache = new EncryptedPhotoCache(root, RandomNumberGenerator.GetBytes(32));
        cache.ActivateGeneration(photo.Key.ProviderId, photo.Key.GenerationId);
        cache.Put(photo, new MemoryStream(bytes), DateTimeOffset.UtcNow);
        using var probe = new Probe(cache);
        using var transfers = new PhotoTransferService(Guid.NewGuid(), new NetworkIntegration.FixtureProvider(Guid.NewGuid(), Guid.NewGuid(), []), probe);
        var sources = new[] { new SourceSelection(photo.Key.ProviderId, photo.Key.SourceId, photo.Key.GenerationId) };
        transfers.Configure(sources);
        Check(transfers.Progress.AvailableCount == 1 && transfers.Progress.DeferredCount == 0, "progress snapshot reflects configured cache");
        for (var i = 0; i < 30; i++)
        {
            transfers.Configure(sources);
            Check(transfers.AcceptCatalog(photo.Key.ProviderId, new([photo])).Length == 0, "reconnection reuses the cached photo");
        }
        Check(probe.Reads == 0 && probe.Catalogs == 1, "unchanged selection and repeated catalogs do not decrypt originals or rescan disk");
        probe.BlockRead = true;
        var reading = Task.Run(() => transfers.ReadImage(photo.Key));
        try
        {
            Check(probe.ReadEntered.Wait(TimeSpan.FromSeconds(3)), "cache read owns the transfer lock");
            var ui = Task.Factory.StartNew(() => (transfers.Progress, transfers.DeferredCount), CancellationToken.None,
                TaskCreationOptions.LongRunning, TaskScheduler.Default);
            var status = await ui.WaitAsync(TimeSpan.FromMilliseconds(500));
            Check(status.Progress.AvailableCount == 1 && status.DeferredCount == 0, "UI progress remains readable while disk work is blocked");
        }
        finally { probe.ReleaseRead.Set(); await reading; }
        Check((await reading).SequenceEqual(bytes), "background image read completes normally");
        var path = Path.Combine(root, photo.Key.ProviderId.ToString("N"), photo.Key.GenerationId.ToString("N"), photo.Key.OpaqueId + ".pwc");
        var encrypted = File.ReadAllBytes(path); encrypted[^1] ^= 1; File.WriteAllBytes(path, encrypted);
        var rejected = false;
        try { transfers.ReadImage(photo.Key); } catch (FileNotFoundException) { rejected = true; }
        Check(rejected && transfers.Progress.AvailableCount == 0, "actual use still verifies ciphertext and invalidates corrupted cached data");
        Check(transfers.MissingRequests(photo.Key.ProviderId).Single().Key == photo.Key, "corruption creates a replacement request");
    }

    public static void RequestScheduling(string root)
    {
        using var cache = new EncryptedPhotoCache(root, RandomNumberGenerator.GetBytes(32));
        using var probe = new Probe(cache);
        var provider = Guid.NewGuid(); var source = Guid.NewGuid(); var generation = Guid.NewGuid();
        using var transfers = new PhotoTransferService(Guid.NewGuid(), new NetworkIntegration.FixtureProvider(Guid.NewGuid(), source, []), probe);
        transfers.Configure([new(provider, source, generation)]);
        var photos = Enumerable.Range(0, 128).Select(i => Photo([(byte)i], provider, source, generation)).ToArray();
        Check(transfers.AcceptCatalog(provider, new(photos)).Length == 2, "ingress is still bounded to two requests");
        var reads = probe.Reads; var notices = 0; transfers.Changed += () => notices++;
        Check(Enumerable.Range(0, 1000).All(_ => transfers.MissingRequests(provider).Length == 0), "active requests are not duplicated");
        Check(probe.Reads == reads && notices == 0, "checking pending requests neither scans storage nor notifies the UI");
    }

    public static async Task CallerContext(string root)
    {
        var local = Guid.NewGuid(); var source = Guid.NewGuid(); var generation = Guid.NewGuid();
        using var cache = new EncryptedPhotoCache(root, RandomNumberGenerator.GetBytes(32));
        using var probe = new Probe(cache); var persistence = new Persistence();
        var initial = NetworkIntegration.Initial(local, sources: [new(local, source, generation)]);
        await using var session = new PeerSession(new(1, local, "fixture", "windows"), [], new Transport(), new Discovery(),
            persistence, new NetworkIntegration.FixtureProvider(local, source, []), probe,
            new NetworkIntegration.FixturePlanner(), new NetworkIntegration.FixtureOutput(), new NetworkIntegration.FixtureClock(), new Notices(), initial);
        var original = SynchronizationContext.Current;
        Task starting;
        try { SynchronizationContext.SetSynchronizationContext(new RejectContext()); starting = session.StartAsync(false); }
        finally { SynchronizationContext.SetSynchronizationContext(original); }
        await starting;
        Check(probe.CatalogContext == null, "cache startup runs outside the caller's UI context");
        Task<StateResult> proposing;
        try
        {
            SynchronizationContext.SetSynchronizationContext(new RejectContext());
            proposing = session.ProposeAsync(new(Guid.NewGuid(), session.Snapshot.Revision, [], [], initial.Sources, new()));
        }
        finally { SynchronizationContext.SetSynchronizationContext(original); }
        Check((await proposing).Accepted && persistence.SaveContext == null, "settings persistence also runs outside the UI context");
        Check(probe.Catalogs == 1, "display-only settings do not rescan the photo cache");
    }

    private static SharedPhoto Photo(byte[] bytes, Guid? provider = null, Guid? source = null, Guid? generation = null)
        => new(new(provider ?? Guid.NewGuid(), source ?? Guid.NewGuid(), generation ?? Guid.NewGuid(), Convert.ToHexStringLower(SHA256.HashData(bytes))),
            6000, 4000, bytes.Length, new(1, 6000, 4000, "fixture", "1", FaceAnalysisState.Complete, []));

    private sealed class Probe(IPhotoCache inner) : IPhotoCache, IDisposable
    {
        public int Reads, Catalogs;
        public SynchronizationContext? CatalogContext;
        public bool BlockRead;
        public readonly ManualResetEventSlim ReadEntered = new(), ReleaseRead = new();
        public CachedPhoto? Read(SharedAssetKey key, DateTimeOffset now)
        {
            Interlocked.Increment(ref Reads);
            if (BlockRead) { ReadEntered.Set(); if (!ReleaseRead.Wait(TimeSpan.FromSeconds(5))) throw new TimeoutException("Test cache was not released"); }
            return inner.Read(key, now);
        }
        public IReadOnlyList<PhotoCacheHeader> Catalog(DateTimeOffset now) { Catalogs++; CatalogContext = SynchronizationContext.Current; return inner.Catalog(now); }
        public void ActivateGeneration(Guid provider, Guid generation) => inner.ActivateGeneration(provider, generation);
        public void RetainProviders(IEnumerable<Guid> providers) => inner.RetainProviders(providers);
        public PhotoCacheHeader Put(SharedPhoto photo, Stream data, DateTimeOffset now, CancellationToken token = default) => inner.Put(photo, data, now, token);
        public void Delete(SharedAssetKey key) => inner.Delete(key);
        public void Dispose() { ReadEntered.Dispose(); ReleaseRead.Dispose(); }
    }
    private sealed class RejectContext : SynchronizationContext
    {
        public override void Post(SendOrPostCallback callback, object? state) => throw new Exception("Background network work captured the UI context");
    }
    private sealed class Persistence : INetworkPersistence
    {
        public SynchronizationContext? SaveContext;
        public WallSnapshot? Load() => null;
        public void Save(WallSnapshot value) => SaveContext = SynchronizationContext.Current;
    }
    private sealed class Transport : IPeerTransport
    {
        public int Port => 1;
        public Task StartAsync(Func<IPeerLink, Task> accept, CancellationToken token) => Task.CompletedTask;
        public Task<IPeerLink> ConnectAsync(PeerCandidate candidate, CancellationToken token) => throw new NotSupportedException();
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }
    private sealed class Discovery : IPeerDiscovery
    {
        public event Action<PeerCandidate>? Found { add { } remove { } }
        public Task StartAsync(PeerHello hello, int port, CancellationToken token) => Task.CompletedTask;
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }
    private sealed class Notices : IConnectionNotifications { public void Disconnected(string name) { } public void Reconnected(string name) { } }
}

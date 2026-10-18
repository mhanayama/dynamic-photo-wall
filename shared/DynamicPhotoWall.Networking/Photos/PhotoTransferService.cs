using System.Runtime.CompilerServices;
using System.Security.Cryptography;

namespace DynamicPhotoWall.Networking;

public sealed record PhotoTransferProgress(int AvailableCount, int DeferredCount);

public sealed class PhotoTransferService : IDisposable
{
    private sealed class Incoming(SharedPhoto photo) : IDisposable
    {
        public SharedPhoto Photo { get; } = photo;
        public MemoryStream Data { get; } = new();
        public int Next { get; set; }
        public void Dispose()
        {
            if (Data.TryGetBuffer(out var bytes)) CryptographicOperations.ZeroMemory(bytes.AsSpan());
            Data.Dispose();
        }
    }
    private readonly IPhotoCache cache;
    private readonly Guid localPeer;
    private readonly IPhotoProvider provider;
    private readonly object gate = new();
    private readonly Dictionary<string, SharedPhoto> catalog = [];
    private readonly HashSet<string> available = [];
    private readonly Dictionary<string, DateTimeOffset> expiresAt = [];
    private readonly Dictionary<Guid, Incoming> incoming = [];
    private readonly Dictionary<Guid, Guid> generations = [];
    private readonly Dictionary<Guid, SharedAssetKey> requested = [];
    private readonly Dictionary<Guid, DateTimeOffset> requestedAt = [];
    private readonly HashSet<string> deferred = [];
    private readonly SemaphoreSlim importGate = new(1, 1);
    private SourceSelection[] selection = [];
    private bool configured;
    private PhotoTransferProgress progress = new(0, 0);
    // UI readers never acquire the cache/transfer lock or enumerate the catalog.
    public PhotoTransferProgress Progress => Volatile.Read(ref progress);
    public const long MaximumAssetBytes = 256L * 1024 * 1024;
    public event Action<CatalogBatch>? CatalogProduced;
    public event Action? Changed;
    public int DeferredCount => Progress.DeferredCount;
    public bool HasMissingLocal { get { lock (gate) return catalog.Values.Any(p => p.Key.ProviderId == localPeer && !available.Contains(p.Key.OpaqueId) && !deferred.Contains(p.Key.OpaqueId)); } }
    public bool IsAvailable(SharedAssetKey key) { lock (gate) return available.Contains(key.OpaqueId); }
    public PhotoTransferService(Guid localPeer, IPhotoProvider provider, IPhotoCache cache)
        { this.localPeer = localPeer; this.provider = provider; this.cache = cache; }
    public IReadOnlyList<SharedPhoto> Available
    {
        get { lock (gate) return catalog.Where(p => available.Contains(p.Key)).Select(p => p.Value).ToArray(); }
    }
    public IReadOnlyList<SharedPhoto> Catalog { get { lock (gate) return catalog.Values.ToArray(); } }
    public void Configure(SourceSelection[] sources)
    {
        lock (gate)
        {
            if (configured && selection.SequenceEqual(sources)) return;
            configured = false;
            var removed = selection.Select(s => s.ProviderId).Except(sources.Select(s => s.ProviderId)).ToArray();
            foreach (var id in removed)
            {
                // A revoked provider gets an empty generation; old encrypted objects are deleted.
                cache.ActivateGeneration(id, Guid.NewGuid()); generations.Remove(id);
            }
            selection = sources;
            cache.RetainProviders(sources.Select(s => s.ProviderId));
            deferred.Clear();
            foreach (var group in sources.GroupBy(s => s.ProviderId))
            {
                var generation = group.First().GenerationId;
                if (generations.GetValueOrDefault(group.Key) == generation) continue;
                cache.ActivateGeneration(group.Key, generation); generations[group.Key] = generation;
            }
            foreach (var key in catalog.Where(p => !Selected(p.Value.Key)).Select(p => p.Key).ToArray())
                {
                    var photo = catalog[key];
                    if (generations.GetValueOrDefault(photo.Key.ProviderId) == photo.Key.GenerationId) cache.Delete(photo.Key);
                    catalog.Remove(key); available.Remove(key); expiresAt.Remove(key);
                }
            foreach (var header in cache.Catalog(DateTimeOffset.UtcNow))
            {
                if (!Selected(header.Photo.Key)) { cache.Delete(header.Photo.Key); continue; }
                catalog[header.Photo.Key.OpaqueId] = header.Photo; available.Add(header.Photo.Key.OpaqueId);
                expiresAt[header.Photo.Key.OpaqueId] = header.ExpiresAt;
            }
            foreach (var request in incoming.Where(p => !Selected(p.Value.Photo.Key)).Select(p => p.Key).ToArray())
                { incoming[request].Dispose(); incoming.Remove(request); requested.Remove(request); }
            configured = true;
        }
        NotifyChanged();
    }
    public void Maintain(DateTimeOffset now)
    {
        lock (gate)
        {
            var valid = cache.Catalog(now).Select(h => h.Photo.Key.OpaqueId).ToHashSet();
            var count = available.Count; available.IntersectWith(valid);
            if (count != available.Count) deferred.Clear();
            foreach (var id in requestedAt.Where(p => now - p.Value > TimeSpan.FromSeconds(30)).Select(p => p.Key).ToArray())
            { requestedAt.Remove(id); requested.Remove(id); if (incoming.Remove(id, out var item)) item.Dispose(); }
        }
        NotifyChanged();
    }
    private bool Selected(SharedAssetKey key) => selection.Any(s => s.ProviderId == key.ProviderId
        && s.SourceId == key.SourceId && s.GenerationId == key.GenerationId);
    private CachedPhoto? ReadKnown(SharedAssetKey key)
    {
        try
        {
            var found = cache.Read(key, DateTimeOffset.UtcNow);
            if (found == null) { available.Remove(key.OpaqueId); expiresAt.Remove(key.OpaqueId); PublishProgress(); }
            return found;
        }
        catch (Exception error) when (error is CryptographicException or InvalidDataException or EndOfStreamException)
        { cache.Delete(key); available.Remove(key.OpaqueId); expiresAt.Remove(key.OpaqueId); PublishProgress(); return null; }
    }
    public async Task ImportAsync(CancellationToken token)
    {
        await importGate.WaitAsync(token);
        try
        {
            SourceSelection[] own; lock (gate) own = selection.Where(s => s.ProviderId == localPeer).ToArray();
            foreach (var source in own)
            {
                await foreach (var (photo, original) in provider.ReadAsync(source, token))
                {
                    var published = photo;
                    try
                    {
                        photo.Validate();
                        lock (gate)
                        {
                            if (!Selected(photo.Key)) continue;
                            if (deferred.Contains(photo.Key.OpaqueId)) continue;
                            var existing = ReadKnown(photo.Key);
                            if (existing == null) expiresAt[photo.Key.OpaqueId] = cache.Put(photo, new MemoryStream(original, false), DateTimeOffset.UtcNow, token).ExpiresAt;
                            else CryptographicOperations.ZeroMemory(existing.Image);
                            if (existing != null) expiresAt[photo.Key.OpaqueId] = existing.Header.ExpiresAt;
                            published = existing?.Header.Photo ?? photo;
                            catalog[photo.Key.OpaqueId] = published; available.Add(photo.Key.OpaqueId);
                        }
                        CatalogProduced?.Invoke(new([published])); NotifyChanged();
                    }
                    catch (PhotoCacheBudgetException) { lock (gate) deferred.Add(photo.Key.OpaqueId); NotifyChanged(); }
                    finally { CryptographicOperations.ZeroMemory(original); }
                }
            }
        }
        finally { importGate.Release(); }
    }
    public AssetRequest[] AcceptCatalog(Guid sender, CatalogBatch batch)
    {
        PeerProtocol.Require(batch.Photos.Length <= 128, "Catalog batch is too large.");
        AssetRequest[] requests;
        lock (gate)
        {
            foreach (var photo in batch.Photos)
            {
                photo.Validate();
                PeerProtocol.Require(photo.Key.ProviderId == sender, "Catalog provider differs from sender.");
                if (!Selected(photo.Key) || photo.ByteLength > MaximumAssetBytes) continue;
                catalog[photo.Key.OpaqueId] = photo;
                if (available.Contains(photo.Key.OpaqueId) && expiresAt.GetValueOrDefault(photo.Key.OpaqueId) > DateTimeOffset.UtcNow) continue;
                if (ReadKnown(photo.Key) is { } known)
                {
                    CryptographicOperations.ZeroMemory(known.Image); available.Add(photo.Key.OpaqueId);
                    expiresAt[photo.Key.OpaqueId] = known.Header.ExpiresAt;
                }
            }
            requests = AllocateRequests(sender);
        }
        NotifyChanged(); return requests;
    }
    public AssetRequest[] MissingRequests(Guid providerId)
    {
        lock (gate) return AllocateRequests(providerId);
    }
    private AssetRequest[] AllocateRequests(Guid providerId)
    {
        var result = new List<AssetRequest>();
        foreach (var photo in catalog.Values)
        {
            if (requested.Count >= 2) break;
            if (photo.Key.ProviderId != providerId || !Selected(photo.Key) || available.Contains(photo.Key.OpaqueId)
                || deferred.Contains(photo.Key.OpaqueId) || requested.Values.Contains(photo.Key)) continue;
            var id = Guid.NewGuid(); requested[id] = photo.Key; requestedAt[id] = DateTimeOffset.UtcNow;
            result.Add(new(id, photo.Key));
        }
        return result.ToArray();
    }
    public async IAsyncEnumerable<AssetChunk> SendAsync(AssetRequest request,
        [EnumeratorCancellation] CancellationToken token)
    {
        CachedPhoto? found;
        lock (gate) found = Selected(request.Key) ? ReadKnown(request.Key) : null;
        PeerProtocol.Require(found != null, "Requested photo is not available.");
        try
        {
            var index = 0;
            for (var offset = 0; offset < found!.Image.Length; offset += 65536)
            {
                token.ThrowIfCancellationRequested();
                var count = Math.Min(65536, found.Image.Length - offset);
                yield return new(request.RequestId, found.Header.Photo, index++, found.Image.AsSpan(offset, count).ToArray(),
                    offset + count == found.Image.Length);
                await Task.Yield();
            }
        }
        finally { if (found != null) CryptographicOperations.ZeroMemory(found.Image); }
    }
    public void Receive(Guid sender, AssetChunk chunk)
    {
        chunk.Photo.Validate();
        lock (gate)
        {
            PeerProtocol.Require(requested.TryGetValue(chunk.RequestId, out var expected) && expected == chunk.Photo.Key
                && expected.ProviderId == sender && Selected(expected), "Unexpected asset transfer.");
            PeerProtocol.Require(chunk.Photo.ByteLength <= MaximumAssetBytes && chunk.Data.Length is > 0 and <= 65536,
                "Invalid asset chunk length.");
            if (!incoming.TryGetValue(chunk.RequestId, out var item)) incoming[chunk.RequestId] = item = new(chunk.Photo);
            try
            {
                PeerProtocol.Require(chunk.Index == item.Next && chunk.Photo.Key == item.Photo.Key
                    && item.Data.Length + chunk.Data.Length <= item.Photo.ByteLength, "Asset chunk order differs.");
                item.Data.Write(chunk.Data); item.Next++; requestedAt[chunk.RequestId] = DateTimeOffset.UtcNow;
                if (!chunk.Last) return;
                PeerProtocol.Require(item.Data.Length == item.Photo.ByteLength, "Asset transfer is incomplete.");
                item.Data.Position = 0; expiresAt[item.Photo.Key.OpaqueId] = cache.Put(item.Photo, item.Data, DateTimeOffset.UtcNow).ExpiresAt;
                available.Add(item.Photo.Key.OpaqueId);
                item.Dispose(); incoming.Remove(chunk.RequestId); requested.Remove(chunk.RequestId);
            }
            catch (PhotoCacheBudgetException) { deferred.Add(item.Photo.Key.OpaqueId); item.Dispose(); incoming.Remove(chunk.RequestId); requested.Remove(chunk.RequestId); }
            catch { item.Dispose(); incoming.Remove(chunk.RequestId); requested.Remove(chunk.RequestId); throw; }
            finally { if (!requested.ContainsKey(chunk.RequestId)) requestedAt.Remove(chunk.RequestId); }
        }
        NotifyChanged();
    }
    public byte[] ReadImage(SharedAssetKey key)
    {
        lock (gate)
        {
            PeerProtocol.Require(Selected(key), "Photo is no longer selected.");
            return ReadKnown(key)?.Image ?? throw new FileNotFoundException("Photo cache is unavailable.");
        }
    }
    public void PeerLost(Guid peer)
    {
        lock (gate)
            foreach (var id in requested.Where(p => p.Value.ProviderId == peer).Select(p => p.Key).ToArray())
            { requested.Remove(id); requestedAt.Remove(id); if (incoming.Remove(id, out var item)) item.Dispose(); }
    }
    private void PublishProgress() => Volatile.Write(ref progress, new(available.Count, deferred.Count));
    private void NotifyChanged()
    {
        lock (gate) PublishProgress();
        Changed?.Invoke();
    }
    public void Dispose()
    {
        lock (gate) { foreach (var item in incoming.Values) item.Dispose(); incoming.Clear(); }
    }
}

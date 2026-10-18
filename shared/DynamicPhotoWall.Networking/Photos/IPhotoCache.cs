namespace DynamicPhotoWall.Networking;

// Storage is deliberately separate from transfer state and UI progress.
public interface IPhotoCache
{
    void ActivateGeneration(Guid providerId, Guid generationId);
    void RetainProviders(IEnumerable<Guid> providers);
    PhotoCacheHeader Put(SharedPhoto photo, Stream original, DateTimeOffset cachedAt, CancellationToken token = default);
    IReadOnlyList<PhotoCacheHeader> Catalog(DateTimeOffset now);
    CachedPhoto? Read(SharedAssetKey key, DateTimeOffset now);
    void Delete(SharedAssetKey key);
}

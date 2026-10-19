namespace DynamicPhotoWall.Core;

// Incoming cards wait until the cards already on screen have had their turn.
public sealed class GalleryRotation
{
    private readonly HashSet<string> updated = new(StringComparer.OrdinalIgnoreCase);
    public GalleryRotation(IEnumerable<string>? previous = null) { if (previous != null) updated.UnionWith(previous); }
    public IReadOnlyList<string> Updated => updated.ToArray();
    public int Choose(IReadOnlyList<PhotoInfo> active, Random random)
    {
        updated.IntersectWith(active.Select(p => p.Path));
        var eligible = Enumerable.Range(0, active.Count).Where(i => !updated.Contains(active[i].Path)).ToArray();
        if (eligible.Length == 0) { updated.Clear(); eligible = Enumerable.Range(0, active.Count).ToArray(); }
        return eligible.Length == 0 ? -1 : eligible[random.Next(eligible.Length)];
    }
    public void Inserted(PhotoInfo photo) => updated.Add(photo.Path);
}

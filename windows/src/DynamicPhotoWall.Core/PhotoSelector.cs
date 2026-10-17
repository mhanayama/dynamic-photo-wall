namespace DynamicPhotoWall.Core;

public sealed class PhotoSelector(Random? random = null)
{
    private readonly Random random = random ?? new Random();
    private readonly LinkedList<string> recent = new();
    private string? sequentialAfter;
    public PhotoInfo? Pick(IReadOnlyList<PhotoInfo> photos, WallSettings settings, ISet<string>? excluded = null)
    {
        var available = photos.Where(p => excluded == null || !excluded.Contains(p.Path)).OrderBy(p => p.Path, StringComparer.OrdinalIgnoreCase).ToArray();
        if (available.Length == 0) return null;
        var candidates = available.Where(p => !recent.Contains(p.Path, StringComparer.OrdinalIgnoreCase)).ToArray();
        // Small libraries relax history, never the simultaneous exclusion set.
        if (candidates.Length == 0)
            candidates = available.OrderBy(p => RecentIndex(p.Path)).Take(1).ToArray();
        var result = settings.RandomOrder ? candidates[random.Next(candidates.Length)] :
            candidates.FirstOrDefault(p => string.Compare(p.Path, sequentialAfter, StringComparison.OrdinalIgnoreCase) > 0) ?? candidates[0];
        Remember(result, settings);
        return result;
    }
    public IReadOnlyList<PhotoInfo> Sample(IReadOnlyList<PhotoInfo> photos, WallSettings settings, ISet<string> excluded, int count)
    {
        if (!settings.RandomOrder || count <= 0) return [];
        var available = photos.Where(p => !excluded.Contains(p.Path)).ToArray();
        var fresh = available.Where(p => !recent.Contains(p.Path, StringComparer.OrdinalIgnoreCase)).ToArray();
        // Match Pick's small-library history fallback, but record only a chosen
        // replacement; evaluating twelve candidates must not consume twelve picks.
        if (fresh.Length == 0) fresh = available.OrderBy(p => RecentIndex(p.Path)).Take(1).ToArray();
        return fresh.OrderBy(_ => random.NextDouble()).Take(count).ToArray();
    }
    public void Remember(PhotoInfo result, WallSettings settings)
    {
        sequentialAfter = result.Path;
        recent.Remove(result.Path);
        recent.AddLast(result.Path);
        while (recent.Count > settings.RecentCount) recent.RemoveFirst();
    }
    private int RecentIndex(string path) { var i = 0; foreach (var item in recent) { if (string.Equals(item, path, StringComparison.OrdinalIgnoreCase)) return i; i++; } return -1; }
}

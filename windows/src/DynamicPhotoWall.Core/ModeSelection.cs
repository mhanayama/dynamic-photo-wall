namespace DynamicPhotoWall.Core;

public static class ModeSelection
{
    public static bool IsGallery(CompositionMode mode) => mode is CompositionMode.Gallery or CompositionMode.GalleryScroll;
    // Keep the old wire fields readable. The former default is migrated to the
    // new ratio; other legacy values combine Pan and Zoom into one category.
    public static (int Gallery, int Motion) Weights(int gallery, int pan, int zoom)
        => (gallery, pan, zoom) == (45, 35, 20) ? (80, 20) : (gallery, pan + zoom);

    public static CompositionMode? Pick(IReadOnlyList<CompositionMode> available, int galleryWeight, int motionWeight,
        CompositionMode? previous, int repeats, Random random)
    {
        var gallery = available.Where(IsGallery).Distinct().ToArray();
        var motion = available.Where(m => !IsGallery(m)).Distinct().ToArray();
        var g = gallery.Length > 0 ? Math.Max(0, galleryWeight) : 0;
        var m = motion.Length > 0 ? Math.Max(0, motionWeight) : 0;
        if (g + m == 0) return null;
        var pool = random.NextDouble() * (g + m) < g ? gallery : motion;
        if (!IsGallery(pool[0]) && repeats >= 2 && pool.Length > 1) pool = pool.Where(mode => mode != previous).ToArray();
        var result = pool[random.Next(pool.Length)];
        return IsGallery(result) && result == previous ? null : result;
    }
}

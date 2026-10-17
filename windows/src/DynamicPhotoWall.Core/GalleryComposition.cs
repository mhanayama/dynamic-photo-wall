namespace DynamicPhotoWall.Core;

// Evaluate only known face rectangles. No decoding, inference or selection
// history changes occur during layout trials.
public static class GalleryComposition
{
    public sealed record Replacement(int Index, PhotoInfo Photo);
    public const int CandidateLimit = 12;
    public static double Loss(IReadOnlyList<PhotoInfo> photos, Viewport viewport, double gap, IReadOnlyList<FrameRect> displays)
    {
        if (photos.Count == 0 || !FaceSafeLayout.RequiresProtection(viewport, displays)) return 0;
        var original = CompositionEngine.GalleryLayout(photos, viewport, gap);
        var frames = FaceSafeLayout.Gallery(photos, viewport, gap, displays);
        var normalGap = original.Count > 1 ? original[1].X - original[0].X - original[0].Width : 0;
        var excess = Enumerable.Range(1, frames.Count - 1).Sum(i => Math.Max(0, frames[i].X - frames[i - 1].X - frames[i - 1].Width - normalGap));
        // Prefer full-size photographs; count spacing and lopsided margins
        // added by face protection, not a portrait row's natural outer margins.
        var rowCenter = (frames[0].X + frames[^1].X + frames[^1].Width) / 2;
        return 2 * Math.Max(0, 1 - frames[0].Height / original[0].Height)
            + (excess + Math.Abs(rowCenter - viewport.Width / 2)) / Math.Max(1, viewport.Width);
    }
    public static Replacement? Improve(IReadOnlyList<PhotoInfo> photos, IReadOnlyList<PhotoInfo> candidates,
        Viewport viewport, double gap, IReadOnlyList<FrameRect> displays, int? onlyIndex = null, CancellationToken token = default)
    {
        var best = Loss(photos, viewport, gap, displays);
        if (best < .02) return null;
        var threshold = best - .02;
        Replacement? result = null;
        var trial = photos.ToArray();
        foreach (var photo in candidates.Take(CandidateLimit))
        {
            token.ThrowIfCancellationRequested();
            if (photo.Faces == null || photos.Any(p => string.Equals(p.Path, photo.Path, StringComparison.OrdinalIgnoreCase))) continue;
            for (var i = onlyIndex ?? 0; i < (onlyIndex.HasValue ? onlyIndex.Value + 1 : photos.Count); i++)
            {
                token.ThrowIfCancellationRequested();
                trial[i] = photo;
                var loss = Loss(trial, viewport, gap, displays);
                trial[i] = photos[i];
                if (loss < best && loss <= threshold) { best = loss; result = new(i, photo); }
            }
        }
        return result;
    }
}

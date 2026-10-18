namespace DynamicPhotoWall.Core;

public static class FixedGalleryLayout
{
    public sealed record Item(int Index, FrameRect Frame);
    private sealed record Allowed(double Min, double Max);
    public static IReadOnlyList<Item> Arrange(IReadOnlyList<PhotoInfo> photos, Viewport viewport, double gap,
        IReadOnlyList<FrameRect>? displays = null, int? pinned = null)
    {
        if (photos.Count == 0) return [];
        var horizontal = viewport.Width >= viewport.Height;
        var length = horizontal ? viewport.Width : viewport.Height; var cross = horizontal ? viewport.Height : viewport.Width;
        gap = Math.Min(gap, Math.Min(length, cross) / 4); var size = Math.Max(1, cross - 2 * gap);
        var active = Enumerable.Range(0, photos.Count).ToList();
        List<Item> Pack()
        {
            var items = new List<Item>(); var usedRanges = new List<Allowed>(); var cursor = gap;
            foreach (var index in active)
            {
                var photo = photos[index]; var extent = horizontal ? size * photo.Aspect : size / photo.Aspect;
                if (extent > length - 2 * gap) continue;
                var face = FaceSafeLayout.Bounds(photo); var ranges = new List<Allowed>();
                if (face == null || displays?.Count is not > 0) ranges.Add(new(gap, length - gap - extent));
                else foreach (var d in displays)
                {
                    var margin = Math.Min(24, Math.Min(d.Width, d.Height) * .03);
                    var faceCross = horizontal ? face.Y : face.X; var faceCrossSize = horizontal ? face.Height : face.Width;
                    var dCross = horizontal ? d.Y : d.X; var dCrossSize = horizontal ? d.Height : d.Width;
                    if (gap + faceCross * size < dCross + margin || gap + (faceCross + faceCrossSize) * size > dCross + dCrossSize - margin) continue;
                    var faceAlong = horizontal ? face.X : face.Y; var faceAlongSize = horizontal ? face.Width : face.Height;
                    var dAlong = horizontal ? d.X : d.Y; var dAlongSize = horizontal ? d.Width : d.Height;
                    var min = Math.Max(gap, dAlong + margin - faceAlong * extent);
                    var max = Math.Min(length - gap - extent, dAlong + dAlongSize - margin - (faceAlong + faceAlongSize) * extent);
                    if (min <= max) ranges.Add(new(min, max));
                }
                var allowed = ranges.Where(r => Math.Max(cursor, r.Min) <= r.Max).OrderBy(r => Math.Max(cursor, r.Min)).FirstOrDefault();
                if (allowed == null) continue;
                var at = Math.Max(cursor, allowed.Min);
                items.Add(new(index, horizontal ? new(at, gap, extent, size) : new(gap, at, size, extent)));
                usedRanges.Add(new(allowed.Min - at, allowed.Max - at)); cursor = at + extent + gap;
            }
            if (items.Count > 0)
            {
                var shift = Math.Clamp((length - cursor) / 2, usedRanges.Max(r => r.Min), usedRanges.Min(r => r.Max));
                for (var i = 0; i < items.Count; i++) items[i] = items[i] with { Frame = horizontal
                    ? items[i].Frame with { X = items[i].Frame.X + shift } : items[i].Frame with { Y = items[i].Frame.Y + shift } };
            }
            return items;
        }
        var result = Pack();
        while (pinned is { } pin && result.All(i => i.Index != pin) && active.Count > 1)
        {
            var remove = active.Where(i => i != pin).OrderByDescending(i => Math.Abs(i - pin)).First(); active.Remove(remove); result = Pack();
        }
        // A photograph longer than the whole group still keeps the short-axis
        // size, like scrolling Gallery. Only its outer long-axis edges crop.
        if (result.Count == 0 && (pinned == null || active.Count == 1))
        {
            var i = pinned ?? 0; var p = photos[i];
            var w = horizontal ? size * p.Aspect : size; var h = horizontal ? size : size / p.Aspect;
            var centered = horizontal ? (viewport.Width - w) / 2 : (viewport.Height - h) / 2;
            var face = FaceSafeLayout.Bounds(p);
            if (face == null || displays?.Count is not > 0)
                return [new(i, horizontal ? new(centered, gap, w, h) : new(gap, centered, w, h))];
            foreach (var d in displays)
            {
                var margin = Math.Min(24, Math.Min(d.Width, d.Height) * .03);
                var crossStart = horizontal ? gap + face.Y * h : gap + face.X * w;
                var crossEnd = horizontal ? gap + (face.Y + face.Height) * h : gap + (face.X + face.Width) * w;
                if (crossStart < (horizontal ? d.Y : d.X) + margin || crossEnd > (horizontal ? d.Y + d.Height : d.X + d.Width) - margin) continue;
                var min = horizontal ? d.X + margin - face.X * w : d.Y + margin - face.Y * h;
                var max = horizontal ? d.X + d.Width - margin - (face.X + face.Width) * w : d.Y + d.Height - margin - (face.Y + face.Height) * h;
                if (min <= max) { var at = Math.Clamp(centered, min, max); return [new(i, horizontal ? new(at, gap, w, h) : new(gap, at, w, h))]; }
            }
        }
        return result;
    }
}

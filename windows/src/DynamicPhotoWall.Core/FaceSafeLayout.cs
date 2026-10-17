namespace DynamicPhotoWall.Core;

// Keep the wall spanning. Only the photo geometry changes; display clipping,
// clocks and mode selection remain shared by the group.
public static class FaceSafeLayout
{
    public static bool RequiresProtection(Viewport viewport, IReadOnlyList<FrameRect> displays)
        => displays.Count > 1 || displays.Count == 1 && displays[0] != new FrameRect(0, 0, viewport.Width, viewport.Height);
    public static FaceRegion? Bounds(PhotoInfo photo)
    {
        var faces = photo.Faces?.Where(f => double.IsFinite(f.X + f.Y + f.Width + f.Height)
            && f.Width > 0 && f.Height > 0 && f.X >= 0 && f.Y >= 0 && f.X + f.Width <= 1.000001 && f.Y + f.Height <= 1.000001).ToArray();
        if (faces == null || faces.Length == 0) return null;
        var left = faces.Min(f => f.X); var top = faces.Min(f => f.Y);
        return new(left, top, faces.Max(f => f.X + f.Width) - left, faces.Max(f => f.Y + f.Height) - top);
    }
    private static double Margin(FrameRect r) => Math.Min(24, Math.Min(r.Width, r.Height) * .03);
    private sealed record Range(double Left, double Right, double Top, double Bottom);

    public static IReadOnlyList<FrameRect> Gallery(IReadOnlyList<PhotoInfo> photos, Viewport viewport, double gap, IReadOnlyList<FrameRect> displays)
    {
        var original = CompositionEngine.GalleryLayout(photos, viewport, gap);
        if (!RequiresProtection(viewport, displays) || photos.All(p => Bounds(p) == null)) return original;
        gap = Math.Min(gap, Math.Min(viewport.Width / (photos.Count + 1), viewport.Height / 4));
        gap = Math.Min(gap, viewport.Width / (photos.Count + 1) * .99);
        IReadOnlyList<FrameRect>? Try(double height)
        {
            var widths = photos.Select(p => height * p.Aspect).ToArray();
            var ranges = new List<Range>[photos.Count];
            for (var i = 0; i < photos.Count; i++)
            {
                ranges[i] = [];
                var face = Bounds(photos[i]);
                if (face == null) ranges[i].Add(new(gap, viewport.Width - gap - widths[i], gap, viewport.Height - gap - height));
                else foreach (var display in displays)
                {
                    var margin = Margin(display);
                    var left = Math.Max(gap, display.X + margin - face.X * widths[i]);
                    var right = Math.Min(viewport.Width - gap - widths[i], display.X + display.Width - margin - (face.X + face.Width) * widths[i]);
                    var top = Math.Max(gap, display.Y + margin - face.Y * height);
                    var bottom = Math.Min(viewport.Height - gap - height, display.Y + display.Height - margin - (face.Y + face.Height) * height);
                    if (left <= right && top <= bottom) ranges[i].Add(new(left, right, top, bottom));
                }
            }
            // Move the entire row before separating individual photos. Intersect
            // the allowed wall positions of every face, preserving the normal
            // gap, a common baseline and the current photograph size.
            var rowWidth = widths.Sum() + gap * (photos.Count - 1);
            var centeredX = (viewport.Width - rowWidth) / 2; var centeredY = (viewport.Height - height) / 2;
            var rows = new List<Range> { new(gap, viewport.Width - gap - rowWidth, gap, viewport.Height - gap - height) };
            var offset = 0d;
            for (var i = 0; i < photos.Count && rows.Count > 0; i++)
            {
                rows = rows.SelectMany(row => ranges[i].Select(r => new Range(Math.Max(row.Left, r.Left - offset),
                    Math.Min(row.Right, r.Right - offset), Math.Max(row.Top, r.Top), Math.Min(row.Bottom, r.Bottom))))
                    .Where(r => r.Left <= r.Right && r.Top <= r.Bottom).Distinct()
                    .OrderBy(r => Math.Abs(Math.Clamp(centeredX, r.Left, r.Right) - centeredX)
                        + Math.Abs(Math.Clamp(centeredY, r.Top, r.Bottom) - centeredY)).Take(128).ToList();
                offset += widths[i] + gap;
            }
            if (rows.Count > 0)
            {
                var row = rows[0]; var x = Math.Clamp(centeredX, row.Left, row.Right); var y = Math.Clamp(centeredY, row.Top, row.Bottom);
                return widths.Select(w => { var frame = new FrameRect(x, y, w, height); x += w + gap; return frame; }).ToArray();
            }
            var minimums = new double[photos.Count]; var cursor = gap;
            for (var i = 0; i < photos.Count; i++)
            {
                var possible = ranges[i].Where(r => Math.Max(cursor, r.Left) <= r.Right).ToArray();
                if (possible.Length == 0) return null;
                minimums[i] = possible.Min(r => Math.Max(cursor, r.Left));
                cursor = minimums[i] + widths[i] + gap;
            }
            // Place as close to the original centered row as constraints permit,
            // preserving order and a gap between all photos.
            var result = new FrameRect[photos.Count]; var next = viewport.Width - gap;
            var centered = (viewport.Width - widths.Sum() - gap * (photos.Count - 1)) / 2;
            var desired = new double[photos.Count];
            for (var i = 0; i < photos.Count; i++) { desired[i] = centered; centered += widths[i] + gap; }
            for (var i = photos.Count - 1; i >= 0; i--)
            {
                var options = ranges[i].Select(r => (r, Left: Math.Max(r.Left, minimums[i]), Right: Math.Min(r.Right, next - widths[i])))
                    .Where(r => r.Left <= r.Right).Select(r => new FrameRect(Math.Clamp(desired[i], r.Left, r.Right), Math.Clamp(centeredY, r.r.Top, r.r.Bottom), widths[i], height))
                    .OrderBy(r => Math.Abs(r.X - desired[i]) + Math.Abs(r.Y - (viewport.Height - height) / 2)).ToArray();
                if (options.Length == 0) return null;
                result[i] = options[0]; next = result[i].X - gap;
            }
            return result;
        }
        var high = original[0].Height;
        var full = Try(high); if (full != null) return full;
        // Shrink the row only if translation cannot protect all faces. Refine
        // the first feasible height rather than leaving an arbitrary scale step.
        var low = high;
        IReadOnlyList<FrameRect>? best = null;
        for (var i = 0; i < 100 && best == null; i++) { low *= .85; best = Try(low); }
        if (best == null) throw new InvalidOperationException("顔を収められるディスプレイの領域がありません。");
        for (var i = 0; i < 20; i++)
        {
            var middle = (low + high) / 2; var result = Try(middle);
            if (result == null) high = middle; else { low = middle; best = result; }
        }
        return best;
    }

    public static MotionPlan VerticalPan(PhotoInfo photo, Viewport viewport, WallSettings settings, IReadOnlyList<FrameRect> displays, MotionPlan original)
    {
        var bounds = Bounds(photo); if (bounds == null) return original;
        var primary = settings.FaceAwarePanDirection ? MotionEngine.PrimaryFace(photo) : photo.Faces?.OrderBy(f => f.Y).FirstOrDefault();
        if (primary == null) return original;
        var towardBottom = settings.FaceAwarePanDirection && primary.Y + primary.Height / 2 > .5;
        MotionPlan? Try(FrameRect display, double width)
        {
            var height = width / photo.Aspect; var overflow = Math.Max(0, height - viewport.Height); var margin = Margin(display);
            // Pan already crops the photo. Permit cropping at the outer wall
            // edge instead of shrinking merely to keep non-face pixels inside.
            var left = display.X + margin - bounds.X * width;
            var right = display.X + display.Width - margin - (bounds.X + bounds.Width) * width;
            if (left > right) return null;
            var x = Math.Clamp(original.FromX, left, right);
            var frameTop = (viewport.Height - Math.Min(viewport.Height, height)) / 2;
            if (height < viewport.Height)
            {
                var top = Math.Max(0, display.Y + margin - bounds.Y * height);
                var bottom = Math.Min(viewport.Height - height, display.Y + display.Height - margin - (bounds.Y + bounds.Height) * height);
                if (top > bottom) return null;
                frameTop = Math.Clamp(frameTop, top, bottom);
            }
            var safeTop = Math.Max(-overflow, display.Y + margin - frameTop - bounds.Y * height);
            var safeBottom = Math.Min(0, display.Y + display.Height - margin - frameTop - (bounds.Y + bounds.Height) * height);
            if (safeTop > safeBottom) return null;
            var start = towardBottom ? 0 : -overflow; var end = towardBottom ? -overflow : 0;
            if (settings.StopAtFace)
                end = Math.Clamp(display.Y + display.Height * .3 - frameTop - (primary.Y + primary.Height / 2) * height, safeTop, safeBottom);
            // Side-by-side screens permit the original full-height pan. If a
            // screen has an internal top/bottom boundary, shorten the path so
            // faces do not travel through that horizontal seam either.
            var pathMin = display.Y > 0 ? safeTop : -overflow;
            var pathMax = display.Y + display.Height < viewport.Height ? safeBottom : 0;
            start = Math.Clamp(start, pathMin, pathMax); end = Math.Clamp(end, pathMin, pathMax);
            var distance = Math.Abs(end - start);
            return original with { Width = width, Height = height, FromX = x, ToX = x, FromY = start, ToY = end, FrameTop = frameTop,
                Seconds = distance > 0 ? Math.Max(.1, distance / settings.PanPixelsPerSecond) : 5 };
        }
        var candidates = new List<MotionPlan>();
        foreach (var display in displays)
        {
            var high = original.Width; var candidate = Try(display, high);
            if (candidate == null)
            {
                var low = high;
                for (var i = 0; i < 100 && candidate == null; i++) { low *= .85; candidate = Try(display, low); }
                if (candidate == null) continue;
                for (var i = 0; i < 20; i++)
                {
                    var middle = (low + high) / 2; var next = Try(display, middle);
                    if (next == null) high = middle; else { low = middle; candidate = next; }
                }
            }
            candidates.Add(candidate);
        }
        return candidates.OrderByDescending(p => p.Width).ThenBy(p => Math.Abs(p.FromX - original.FromX)).FirstOrDefault()
            ?? throw new InvalidOperationException("顔を収められるディスプレイの領域がありません。");
    }
}

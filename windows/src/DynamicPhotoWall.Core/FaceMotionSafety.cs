namespace DynamicPhotoWall.Core;

// Current playback guard, separate from the historical motion geometry fixtures.
public static class FaceMotionSafety
{
    public static MotionPlan? TryPlan(CompositionMode mode, PhotoInfo photo, Viewport viewport, WallSettings settings,
        bool reverse = false, double centerX = .5, double centerY = .5, IReadOnlyList<FrameRect>? displays = null)
    {
        MotionPlan original;
        try { original = MotionEngine.Plan(mode, photo, viewport, settings, reverse, centerX, centerY, displays); }
        catch (InvalidOperationException) { return null; }
        var face = FaceSafeLayout.Bounds(photo);
        if (face == null || mode is not (CompositionMode.VerticalPan or CompositionMode.HorizontalPan or CompositionMode.Zoom)) return original;
        var targets = displays?.Count > 0 ? displays : [new FrameRect(0, 0, viewport.Width, viewport.Height)];
        var plans = new List<MotionPlan>();
        foreach (var target in targets)
        {
            var margin = Math.Min(24, Math.Min(target.Width, target.Height) * .03);
            var availableW = target.Width - 2 * margin; var availableH = target.Height - 2 * margin;
            if (availableW <= 0 || availableH <= 0) continue;
            var cx = face.X + face.Width / 2; var cy = face.Y + face.Height / 2;
            if (mode == CompositionMode.Zoom)
            {
                var maximum = Math.Max(original.FromScale, original.ToScale);
                var safe = Math.Min(availableW / (face.Width * original.Width), availableH / (face.Height * original.Height));
                var factor = Math.Min(1, safe / maximum);
                if (!double.IsFinite(factor) || factor <= 0 || Math.Min(original.Width, original.Height) * factor < 32) continue;
                var minimumScale = Math.Min(original.FromScale, original.ToScale) * factor;
                var maximumScale = maximum * factor;
                var x = ZoomOrigin(original.Width, viewport.Width, target.X, target.X + target.Width,
                    cx, face.Width, minimumScale, maximumScale, margin);
                var y = ZoomOrigin(original.Height, viewport.Height, target.Y, target.Y + target.Height,
                    cy, face.Height, minimumScale, maximumScale, margin);
                plans.Add(original with { FromScale = original.FromScale * factor, ToScale = original.ToScale * factor,
                    CenterX = cx, CenterY = cy, FromX = x, ToX = x, FromY = y, ToY = y });
                continue;
            }
            var shrink = Math.Min(1, Math.Min(availableW / (face.Width * original.Width), availableH / (face.Height * original.Height)));
            var width = original.Width * shrink; var height = original.Height * shrink;
            if (mode == CompositionMode.VerticalPan)
            {
                var overflow = height - viewport.Height; if (overflow <= 20) continue;
                var low = Math.Max(-overflow, target.Y + margin - face.Y * height);
                var high = Math.Min(0, target.Y + target.Height - margin - (face.Y + face.Height) * height);
                if (low > high) continue;
                var end = Math.Clamp(target.Y + target.Height / 2 - cy * height, low, high);
                var start = original.FromY <= original.ToY ? -overflow : 0;
                // A face may enter from outside the frame during the pan. Its
                // full rectangle fits a physical output at the resting position.
                double SafeStart(double value)
                {
                    if (target.Y > 0) value = Math.Max(value, low);
                    if (target.Y + target.Height < viewport.Height) value = Math.Min(value, high);
                    return value;
                }
                start = SafeStart(start);
                if (Math.Abs(end - start) <= 20) start = SafeStart(original.FromY <= original.ToY ? 0 : -overflow);
                var distance = Math.Abs(end - start); if (distance <= 20) continue;
                var left = target.X + margin - face.X * width;
                var right = target.X + target.Width - margin - (face.X + face.Width) * width;
                // Center the photograph on each output; move only as far as
                // necessary to keep the face rectangle inside that output.
                var x = Math.Clamp((viewport.Width - width) / 2, left, Math.Max(left, right));
                plans.Add(original with { Width = width, Height = height, FromX = x, ToX = x, FromY = start, ToY = end, FrameTop = 0,
                    Seconds = Math.Max(.1, distance / settings.PanPixelsPerSecond) });
            }
            else
            {
                var overflow = width - viewport.Width; if (overflow <= 20) continue;
                var low = Math.Max(-overflow, target.X + margin - face.X * width);
                var high = Math.Min(0, target.X + target.Width - margin - (face.X + face.Width) * width);
                var top = Math.Max(0, target.Y + margin - face.Y * height);
                var bottom = Math.Min(viewport.Height - height, target.Y + target.Height - margin - (face.Y + face.Height) * height);
                if (low > high || top > bottom) continue;
                var end = Math.Clamp(target.X + target.Width / 2 - cx * width, low, high);
                var start = original.FromX >= original.ToX ? 0 : -overflow;
                if (Math.Abs(end - start) <= 20) start = start == 0 ? -overflow : 0;
                var distance = Math.Abs(end - start); if (distance <= 20) continue;
                var frameTop = Math.Clamp((viewport.Height - height) / 2, top, bottom);
                plans.Add(original with { Width = width, Height = height, FromX = start, ToX = end, FromY = 0, ToY = 0, FrameTop = frameTop,
                    Seconds = Math.Max(.1, distance / settings.PanPixelsPerSecond) });
            }
        }
        double Displacement(MotionPlan p)
        {
            if (mode != CompositionMode.Zoom) return Math.Abs(p.FromX - original.FromX) + Math.Abs(p.FromY - original.FromY);
            var scale = Math.Min(p.FromScale, p.ToScale);
            return Math.Abs(p.FromX + (1 - scale) * p.CenterX * p.Width + p.Width * scale / 2 - viewport.Width / 2)
                + Math.Abs(p.FromY + (1 - scale) * p.CenterY * p.Height + p.Height * scale / 2 - viewport.Height / 2);
        }
        return plans.OrderByDescending(p => mode == CompositionMode.Zoom ? Math.Max(p.FromScale, p.ToScale) : p.Width)
            .ThenBy(Displacement).FirstOrDefault();
    }
    private static double ZoomOrigin(double length, double viewport, double targetMin, double targetMax,
        double faceCenter, double faceLength, double minimumScale, double maximumScale, double margin)
    {
        // Center the photograph at its smallest scale; shift only for face safety.
        // Keeping the face as the zoom anchor does not require centering it on screen.
        var anchor = faceCenter * length;
        var preferred = (viewport - length * minimumScale) / 2 + (minimumScale - 1) * anchor;
        var halfFace = faceLength * length * maximumScale / 2;
        var low = targetMin + margin + halfFace - anchor;
        var high = Math.Max(low, targetMax - margin - halfFace - anchor);
        if (length * minimumScale >= viewport)
        {
            var coveredLow = Math.Max(low, viewport - length * minimumScale + (minimumScale - 1) * anchor);
            var coveredHigh = Math.Min(high, (minimumScale - 1) * anchor);
            if (coveredLow <= coveredHigh) { low = coveredLow; high = coveredHigh; }
        }
        return Math.Clamp(preferred, low, high);
    }
    public static MotionPlan Plan(CompositionMode mode, PhotoInfo photo, Viewport viewport, WallSettings settings,
        bool reverse = false, double centerX = .5, double centerY = .5, IReadOnlyList<FrameRect>? displays = null)
        => TryPlan(mode, photo, viewport, settings, reverse, centerX, centerY, displays)
            ?? throw new InvalidOperationException("顔を収めて動かせる表示領域がありません。この写真のモードをスキップします。");
}

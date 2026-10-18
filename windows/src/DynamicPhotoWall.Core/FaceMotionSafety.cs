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
                plans.Add(original with { FromScale = original.FromScale * factor, ToScale = original.ToScale * factor,
                    CenterX = cx, CenterY = cy, FromX = target.X + target.Width / 2 - cx * original.Width,
                    ToX = target.X + target.Width / 2 - cx * original.Width,
                    FromY = target.Y + target.Height / 2 - cy * original.Height, ToY = target.Y + target.Height / 2 - cy * original.Height });
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
                var x = target.X + target.Width / 2 - cx * width;
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
        return plans.OrderByDescending(p => mode == CompositionMode.Zoom ? Math.Max(p.FromScale, p.ToScale) : p.Width)
            .ThenBy(p => Math.Abs(p.FromX - original.FromX) + Math.Abs(p.FromY - original.FromY)).FirstOrDefault();
    }
    public static MotionPlan Plan(CompositionMode mode, PhotoInfo photo, Viewport viewport, WallSettings settings,
        bool reverse = false, double centerX = .5, double centerY = .5, IReadOnlyList<FrameRect>? displays = null)
        => TryPlan(mode, photo, viewport, settings, reverse, centerX, centerY, displays)
            ?? throw new InvalidOperationException("顔を収めて動かせる表示領域がありません。この写真のモードをスキップします。");
}

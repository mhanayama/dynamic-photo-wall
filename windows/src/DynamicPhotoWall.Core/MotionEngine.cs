namespace DynamicPhotoWall.Core;

// Pure geometry in physical pixels; rendering converts it to device-independent units.
public static class MotionEngine
{
    public static FaceRegion? PrimaryFace(PhotoInfo photo) => photo.Faces?
        .OrderByDescending(f => f.Width * f.Height).ThenBy(f => f.Y).ThenBy(f => f.X).FirstOrDefault();

    public static MotionPlan Plan(CompositionMode mode, PhotoInfo photo, Viewport v, WallSettings s, bool reverse = false, double centerX = .5, double centerY = .5,
        IReadOnlyList<FrameRect>? displayRegions = null)
    {
        var directionFace = s.FaceAwarePanDirection ? PrimaryFace(photo) : null;
        if (mode == CompositionMode.VerticalPan)
        {
            var width = v.Width * s.PanWidthFraction;
            var face = s.StopAtFace ? directionFace ?? photo.Faces?.OrderBy(f => f.Y).FirstOrDefault() : null;
            if (face != null) width = Math.Min(width, v.Height * .92 * photo.Aspect / face.Height);
            var height = width / photo.Aspect;
            var overflow = Math.Max(0, height - v.Height);
            var towardBottom = directionFace != null && directionFace.Y + directionFace.Height / 2 > .5;
            var start = towardBottom ? 0 : -overflow;
            var end = towardBottom ? -overflow : 0;
            if (face != null)
            {
                // Keep the target face inside the final viewport with headroom,
                // approaching it from the opposite end of the photograph.
                var halfFace = face.Height * height / 2;
                var lower = halfFace + v.Height * .04; var upper = v.Height - halfFace - v.Height * .04;
                var targetCenter = lower <= upper ? Math.Clamp(v.Height * .3, lower, upper) : v.Height * .5;
                var desired = targetCenter - (face.Y + face.Height * .5) * height;
                end = Math.Clamp(desired, -overflow, 0);
            }
            var left = (v.Width - width) / 2;
            var distance = Math.Abs(end - start);
            var plan = new MotionPlan(width, height, left, start, left, end, 1, 1, .5, .5,
                distance > 0 ? Math.Max(.1, distance / s.PanPixelsPerSecond) : 5);
            return s.AvoidFaceDisplayBoundaries && displayRegions != null && FaceSafeLayout.RequiresProtection(v, displayRegions)
                ? FaceSafeLayout.VerticalPan(photo, v, s, displayRegions, plan) : plan;
        }
        if (mode == CompositionMode.HorizontalPan)
        {
            var width = v.Height * photo.Aspect;
            var overflow = Math.Max(0, width - v.Width);
            if (directionFace != null) reverse = directionFace.X + directionFace.Width / 2 < .5;
            return new(width, v.Height, reverse ? -overflow : 0, 0, reverse ? 0 : -overflow, 0, 1, 1, .5, .5,
                Math.Max(5, overflow / s.PanPixelsPerSecond));
        }
        var scale = Math.Max(v.Width / photo.Width, v.Height / photo.Height);
        // Multiplication after division can land one ULP below the viewport.
        // Keep cover dimensions at least as large as the viewport so position
        // clamps never receive a positive minimum with a zero maximum.
        var w = Math.Max(v.Width, photo.Width * scale);
        var h = Math.Max(v.Height, photo.Height * scale);
        var x = (v.Width - w) / 2; var y = (v.Height - h) / 2;
        if (s.FaceAwareFraming && photo.Faces?.Count > 0)
        {
            var face = photo.Faces.OrderByDescending(f => f.Width * f.Height).First();
            centerX = Math.Clamp(face.X + face.Width / 2, 0, 1);
            centerY = Math.Clamp(face.Y + face.Height / 2, 0, 1);
            x = Math.Clamp(v.Width * .5 - centerX * w, v.Width - w, 0);
            var halfFaceHeight = face.Height * h * s.MaxZoom / 2;
            var margin = v.Height * .04;
            var lower = halfFaceHeight + margin; var upper = v.Height - halfFaceHeight - margin;
            var targetY = lower <= upper ? Math.Clamp(v.Height * .4, lower, upper) : v.Height * .5;
            y = Math.Clamp(targetY - centerY * h, v.Height - h, 0);
        }
        // Center crop minimally at scale 1, then zoom around a safe interior point.
        return new(w, h, x, y, x, y, reverse ? s.MaxZoom : 1, reverse ? 1 : s.MaxZoom,
            Math.Clamp(centerX, 0, 1), Math.Clamp(centerY, 0, 1), s.ZoomSeconds);
    }
}

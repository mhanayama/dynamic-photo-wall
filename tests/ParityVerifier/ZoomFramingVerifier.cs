using DynamicPhotoWall.Core;

// Pure geometry: runs on macOS as well as Windows, without opening a window.
static class ZoomFramingVerifier
{
    public static void Run()
    {
        var checks = 0;
        void Check(bool value, string message) { if (!value) throw new Exception(message); checks++; }
        bool Contains(FrameRect outer, FrameRect inner) => inner.X >= outer.X - .001 && inner.Y >= outer.Y - .001
            && inner.X + inner.Width <= outer.X + outer.Width + .001 && inner.Y + inner.Height <= outer.Y + outer.Height + .001;
        PhotoInfo Photo(int w, int h, params FaceRegion[] faces) => new("fixture", w, h, 1, null, 1, 0, faces);
        void Safe(MotionPlan p, PhotoInfo photo, Viewport v, IReadOnlyList<FrameRect> displays, bool covers)
        {
            var bounds = FaceSafeLayout.Bounds(photo)!;
            Check(Math.Abs(Math.Max(p.FromScale, p.ToScale) / Math.Min(p.FromScale, p.ToScale) - 1.25) < .00001
                || Math.Abs(Math.Max(p.FromScale, p.ToScale) / Math.Min(p.FromScale, p.ToScale) - 1.5) < .00001, "zoom travel retained");
            for (var tick = 0; tick <= 100; tick++)
            {
                var scale = p.FromScale + (p.ToScale - p.FromScale) * tick / 100;
                var image = new FrameRect(p.FromX + (1 - scale) * p.CenterX * p.Width,
                    p.FromY + (1 - scale) * p.CenterY * p.Height, p.Width * scale, p.Height * scale);
                var face = new FrameRect(image.X + bounds.X * image.Width, image.Y + bounds.Y * image.Height,
                    bounds.Width * image.Width, bounds.Height * image.Height);
                Check(displays.Any(d => Contains(d, face)), "all faces fit one physical output throughout zoom");
                if (covers) Check(Contains(image, new(0, 0, v.Width, v.Height)), "zoom must not expose unnecessary background");
            }
        }
        var v = new Viewport(1920, 1080);
        FrameRect[] single = [new(0, 0, v.Width, v.Height)];
        FaceRegion[] edges = [new(.04, .4, .08, .16), new(.88, .4, .08, .16), new(.45, .06, .1, .08), new(.45, .86, .1, .08)];
        foreach (var zoom in new[] { 1.25, 1.5 })
        foreach (var reverse in new[] { false, true })
        foreach (var face in edges)
        {
            var photo = Photo(1920, 1080, face);
            var p = FaceMotionSafety.Plan(CompositionMode.Zoom, photo, v, new() { MaxZoom = zoom }, reverse);
            Check(Math.Abs(p.FromX) < .00001 && Math.Abs(p.FromY) < .00001, "edge face preserves photograph's centered composition");
            Check(p.FromX == p.ToX && p.FromY == p.ToY, "zoom anchor stays stable");
            Safe(p, photo, v, single, true);
        }
        foreach (var reverse in new[] { false, true })
        foreach (var right in new[] { false, true })
        {
            var photo = Photo(4000, 1080, new FaceRegion(right ? .92 : .04, .4, .04, .1));
            var p = FaceMotionSafety.Plan(CompositionMode.Zoom, photo, v, new() { MaxZoom = 1.5 }, reverse);
            Check(Math.Abs(p.FromX - (right ? -1984 : -96)) < .00001, "cropped face needs only the smallest safe shift");
            Safe(p, photo, v, single, true);
        }
        foreach (var reverse in new[] { false, true })
        {
            var large = Photo(1920, 1080, new FaceRegion(.1, .1, .8, .8));
            var p = FaceMotionSafety.Plan(CompositionMode.Zoom, large, v, new(), reverse);
            Check(Math.Min(p.FromScale, p.ToScale) < 1 && Math.Abs(p.FromX) < .00001 && Math.Abs(p.FromY) < .00001,
                "face-safe shrink keeps photograph centered");
            Safe(p, large, v, single, false);
            foreach (var vertical in new[] { false, true })
            {
                var span = vertical ? new Viewport(1200, 8000) : new Viewport(5760, 1080);
                var displays = vertical ? Enumerable.Range(0, 4).Select(i => new FrameRect(0, i * 2000, 1200, 2000)).ToArray()
                    : Enumerable.Range(0, 3).Select(i => new FrameRect(i * 1920, 0, 1920, 1080)).ToArray();
                var photo = Photo(6000, 4000, new(.2, .1, .2, .8), new(.55, .2, .15, .3));
                Safe(FaceMotionSafety.Plan(CompositionMode.Zoom, photo, span, new(), reverse, displays: displays), photo, span, displays, false);
            }
            var noFace = Photo(3000, 2000);
            Check(FaceMotionSafety.Plan(CompositionMode.Zoom, noFace, v, new(), reverse) == MotionEngine.Plan(CompositionMode.Zoom, noFace, v, new(), reverse),
                "face-free motion stays unchanged");
            var wide = new Viewport(5760, 1080);
            var outputs = Enumerable.Range(0, 3).Reverse().Select(i => new FrameRect(i * 1920, 0, 1920, 1080)).ToArray();
            var edge = Photo(5760, 1080, new FaceRegion(.8, .4, .06, .1));
            var spanPlan = FaceMotionSafety.Plan(CompositionMode.Zoom, edge, wide, new(), reverse, displays: outputs);
            Check(Math.Abs(spanPlan.FromX) < .00001 && Math.Abs(spanPlan.FromY) < .00001, "span keeps the face on its original display when possible");
            Safe(spanPlan, edge, wide, outputs, true);
        }
        Console.WriteLine($"PASS: zoom framing, {checks} assertions (no GUI).");
    }
}

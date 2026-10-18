namespace DynamicPhotoWall.Networking;

// Pure layout geometry shared by local and network editors. The caller converts
// the preview's hit distance to physical pixels and excludes the moving display.
public static class DisplaySnapping
{
    public static (double X, double Y) Snap(FrameRect moving, IEnumerable<FrameRect> others, double threshold)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(threshold);
        var neighbors = others.ToArray();
        var x = moving.X; var y = moving.Y;
        var bestX = double.PositiveInfinity; var bestY = double.PositiveInfinity;
        foreach (var other in neighbors)
        {
            if (Gap(moving.Y, moving.Height, other.Y, other.Height) <= threshold)
                Choose(moving.X, [other.X - moving.Width, other.X + other.Width,
                    other.X, other.X + other.Width - moving.Width, other.X + (other.Width - moving.Width) / 2], ref x, ref bestX);
            if (Gap(moving.X, moving.Width, other.X, other.Width) <= threshold)
                Choose(moving.Y, [other.Y - moving.Height, other.Y + other.Height,
                    other.Y, other.Y + other.Height - moving.Height, other.Y + (other.Height - moving.Height) / 2], ref y, ref bestY);
        }
        return (x, y);

        void Choose(double value, double[] targets, ref double position, ref double best)
        {
            foreach (var target in targets)
            {
                var distance = Math.Abs(target - value);
                if (distance <= threshold && (distance < best || distance == best && target < position))
                { position = target; best = distance; }
            }
        }
    }

    private static double Gap(double a, double sizeA, double b, double sizeB)
        => Math.Max(0, Math.Max(a, b) - Math.Min(a + sizeA, b + sizeB));
}

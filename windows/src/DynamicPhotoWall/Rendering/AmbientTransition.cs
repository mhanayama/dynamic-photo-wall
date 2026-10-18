namespace DynamicPhotoWall.Rendering;

// Time-based filtering avoids both 8 Hz color steps and cadence-dependent lag.
// The state is floating point so small color changes do not get rounded away.
public sealed class AmbientTransition(double responseSeconds = .8)
{
    private double[]? current;
    private double lastAt;
    public byte[] Push(byte[] pixels, double at)
    {
        if (current == null || current.Length != pixels.Length)
            current = pixels.Select(p => (double)p).ToArray();
        else
        {
            var amount = 1 - Math.Exp(-Math.Max(0, at - lastAt) / responseSeconds);
            for (var i = 0; i < pixels.Length; i++) current[i] += (pixels[i] - current[i]) * amount;
        }
        lastAt = at;
        return current.Select(p => (byte)Math.Clamp(Math.Round(p), 0, 255)).ToArray();
    }
    public static byte[] Blend(byte[] from, byte[] to, double progress)
    {
        var result = new byte[to.Length]; var amount = Math.Clamp(progress, 0, 1);
        for (var i = 0; i < result.Length; i++) result[i] = (byte)Math.Round(from[i] + (to[i] - from[i]) * amount);
        return result;
    }
}

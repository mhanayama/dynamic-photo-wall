namespace DynamicPhotoWall.Rendering;

// Fill transparent margins with the nearest visible photo color before blurring.
// Both live playback and network-prepared ambient frames use this same operation.
public static class AmbientPixels
{
    // Lift subdued photo colors after blur. Limit chroma by the available RGB
    // headroom so highlights retain their hue instead of clipping channels.
    public static void EnhanceColors(byte[] pixels)
    {
        for (var i = 0; i < pixels.Length; i += 4)
        {
            var alpha = pixels[i + 3]; if (alpha == 0) continue;
            var b = pixels[i] * 255d / alpha; var g = pixels[i + 1] * 255d / alpha; var r = pixels[i + 2] * 255d / alpha;
            var luminance = .2126 * r + .7152 * g + .0722 * b;
            var maximumDelta = Math.Max(r, Math.Max(g, b)) - luminance;
            var minimumDelta = Math.Min(r, Math.Min(g, b)) - luminance;
            var lifted = Math.Min(luminance * 1.12, 255 - maximumDelta);
            var chroma = 1.6;
            if (maximumDelta > 0) chroma = Math.Min(chroma, (255 - lifted) / maximumDelta);
            if (minimumDelta < 0) chroma = Math.Min(chroma, lifted / -minimumDelta);
            pixels[i] = Channel(b); pixels[i + 1] = Channel(g); pixels[i + 2] = Channel(r);
            byte Channel(double value) => (byte)Math.Clamp(Math.Round((lifted + (value - luminance) * chroma) * alpha / 255), 0, alpha);
        }
    }

    public static bool ExtendPadding(byte[] pixels, int width, int height)
    {
        var rows = new List<int>(); var valid = new List<int>();
        for (var y = 0; y < height; y++)
        {
            valid.Clear();
            for (var x = 0; x < width; x++)
            {
                var i = (y * width + x) * 4; var alpha = pixels[i + 3];
                if (alpha < 16) continue;
                for (var channel = 0; channel < 3; channel++) pixels[i + channel] = (byte)Math.Min(255, pixels[i + channel] * 255 / alpha);
                pixels[i + 3] = 255; valid.Add(x);
            }
            if (valid.Count == 0) continue;
            rows.Add(y); var nearest = 0;
            for (var x = 0; x < width; x++)
            {
                while (nearest + 1 < valid.Count && Math.Abs(valid[nearest + 1] - x) < Math.Abs(valid[nearest] - x)) nearest++;
                if (pixels[(y * width + x) * 4 + 3] < 16)
                    Buffer.BlockCopy(pixels, (y * width + valid[nearest]) * 4, pixels, (y * width + x) * 4, 4);
            }
        }
        if (rows.Count == 0) return false;
        var row = 0;
        for (var y = 0; y < height; y++)
        {
            while (row + 1 < rows.Count && Math.Abs(rows[row + 1] - y) < Math.Abs(rows[row] - y)) row++;
            if (rows[row] != y) Buffer.BlockCopy(pixels, rows[row] * width * 4, pixels, y * width * 4, width * 4);
        }
        return true;
    }
}

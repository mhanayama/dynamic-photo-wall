using Net = DynamicPhotoWall.Networking;

namespace DynamicPhotoWall.Networking.Windows;

internal static class SharedDecodeSizing
{
    public static int Width(Net.SharedScenePlan plan, Net.SharedPhoto photo, IReadOnlyDictionary<string, Viewport> outputs,
        int cacheMegabytes, int assetCount)
    {
        var aspect = (double)photo.PixelWidth / photo.PixelHeight;
        var required = 1d;
        foreach (var p in plan.Placements.Where(p => p.Asset == photo.Key && (p.DisplayId == null || outputs.ContainsKey(p.DisplayId))))
        {
            var outputScale = 1d;
            foreach (var d in plan.Displays.Where(d => outputs.ContainsKey(d.Key.LayoutId) && (p.DisplayId == null || p.DisplayId == d.Key.LayoutId)))
            {
                var pixels = outputs[d.Key.LayoutId];
                outputScale = Math.Max(outputScale, Math.Max(pixels.Width / d.Width, pixels.Height / d.Height));
            }
            required = Math.Max(required, Math.Max(p.Width, p.Height * aspect) * Math.Max(p.FromScale, p.ToScale) * outputScale);
        }
        var maxPixels = Math.Min(16_000_000d, Math.Max(65536, cacheMegabytes * 1024d * 1024 / 8 / Math.Max(1, assetCount)));
        var budgetWidth = Math.Min(4096, Math.Sqrt(maxPixels * aspect));
        return Math.Max(1, (int)Math.Min(photo.PixelWidth, Math.Max(64, Math.Min(Math.Ceiling(required), budgetWidth))));
    }
}

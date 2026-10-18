using Net = DynamicPhotoWall.Networking;

namespace DynamicPhotoWall.Networking.Windows;

// A peer's physical outputs outlive plans, remote peers and logical canvases.
public static class PlaybackSurfaceLayout
{
    public static bool CanReuse(Net.SharedScenePlan before, Net.SharedScenePlan after, Guid localPeer)
    {
        var old = before.Displays.Where(d => d.Selected && d.Key.PeerId == localPeer).OrderBy(d => d.Key.LayoutId, StringComparer.Ordinal).ToArray();
        var next = after.Displays.Where(d => d.Selected && d.Key.PeerId == localPeer).OrderBy(d => d.Key.LayoutId, StringComparer.Ordinal).ToArray();
        return old.Length == next.Length && old.Zip(next).All(pair => pair.First.Key == pair.Second.Key
            && pair.First.Width == pair.Second.Width && pair.First.Height == pair.Second.Height);
    }
}

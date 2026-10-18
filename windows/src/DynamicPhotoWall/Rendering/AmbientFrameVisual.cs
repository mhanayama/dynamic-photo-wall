using System.Windows.Media.Imaging;
using Net = DynamicPhotoWall.Networking;

namespace DynamicPhotoWall.Rendering;

// Sources stay attached for the whole scene. At a timeline boundary the next
// layer becomes the opaque base; no visible Image.Source is swapped in place.
public sealed class AmbientFrameVisual
{
    private readonly Net.AmbientFrame[] frames;
    public IReadOnlyList<System.Windows.Controls.Image> Images { get; }
    public AmbientFrameVisual(Net.AmbientFrame[] frames, BitmapSource[] textures, double width, double height)
    {
        this.frames = frames;
        Images = textures.Select(texture => new System.Windows.Controls.Image
            { Width = width, Height = height, Stretch = Stretch.Fill, Source = texture, Opacity = 0 }).ToArray();
        Present(0);
    }
    public void Present(double elapsed)
    {
        var index = 0;
        while (index + 1 < frames.Length && frames[index + 1].At <= elapsed) index++;
        var next = Math.Min(index + 1, frames.Length - 1);
        var blend = next == index ? 0 : Math.Clamp((elapsed - frames[index].At) / Math.Max(.001, frames[next].At - frames[index].At), 0, 1);
        for (var i = 0; i < Images.Count; i++) Images[i].Opacity = i == index ? 1 : i == next ? blend : 0;
    }
}

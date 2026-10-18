using System.Windows.Media.Imaging;
using DynamicPhotoWall.Motion;

namespace DynamicPhotoWall.Rendering;

// Keep a persistent brush image and fade on WPF's composition clock. Retarget
// from the currently displayed pixel mix, never from a stale source texture.
public sealed class AmbientTexturePresenter(ImageBrush target, FrameworkElement root, TransitionController transitions) : IDisposable
{
    private const double FadeSeconds = .125;
    private readonly DrawingGroup drawing = new(), overlay = new();
    private readonly ImageDrawing under = new(), over = new();
    private byte[]? from, to;
    private double started;
    public BitmapSource? Texture { get; private set; }
    public void SetFrame(byte[] pixels, int width, int height, double at)
    {
        BitmapSource Bitmap(byte[] data)
        {
            var image = BitmapSource.Create(width, height, 96, 96, PixelFormats.Pbgra32, null, data, width * 4);
            image.Freeze(); return image;
        }
        var next = Bitmap(pixels);
        if (to == null)
        {
            under.ImageSource = next; under.Rect = over.Rect = new Rect(0, 0, width, height);
            drawing.Children.Add(under); overlay.Children.Add(over); drawing.Children.Add(overlay);
            overlay.Opacity = 0; target.ImageSource = new DrawingImage(drawing);
            from = to = pixels; Texture = next; started = at; return;
        }
        var displayed = AmbientTransition.Blend(from!, to, (at - started) / FadeSeconds);
        transitions.RemoveRoot(root);
        under.ImageSource = Bitmap(displayed); over.ImageSource = next; overlay.Opacity = 0;
        from = displayed; to = pixels; Texture = next; started = at;
        var fade = transitions.Create();
        TransitionController.Animate(fade, overlay, DrawingGroup.OpacityProperty, 0, 1, FadeSeconds, false);
        transitions.Start(fade, root);
    }
    public void Dispose() => transitions.RemoveRoot(root);
}

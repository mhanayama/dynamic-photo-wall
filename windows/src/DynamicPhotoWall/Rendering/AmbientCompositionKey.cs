using System.Windows.Shapes;

namespace DynamicPhotoWall.Rendering;

// Compare geometry before the expensive VisualBrush readback. Half a texture
// pixel (and 1/64 opacity) lets slow motion accumulate instead of regenerating
// identical ambient images at every sampling opportunity.
internal sealed class AmbientCompositionKey
{
    private readonly record struct Part(Visual Visual, object? Content, long X, long Y, long Width, long Height,
        long Opacity, long ClipX, long ClipY, long ClipWidth, long ClipHeight);
    private readonly List<Part> parts = [];
    public static AmbientCompositionKey Capture(Canvas foreground, Viewport viewport)
    {
        var result = new AmbientCompositionKey();
        var scale = 320 / Math.Max(viewport.Width, viewport.Height);
        long Q(double value) => double.IsFinite(value) ? (long)Math.Round(value * scale) : long.MinValue;
        void Visit(Visual visual)
        {
            if (visual is FrameworkElement element)
            {
                var rect = new Rect(element.RenderSize);
                if (visual != foreground) rect = visual.TransformToAncestor(foreground).TransformBounds(rect);
                var clip = VisualTreeHelper.GetClip(visual)?.Bounds ?? Rect.Empty;
                object? content = visual switch { System.Windows.Controls.Image image => image.Source,
                    Shape shape => shape.Fill, TextBlock text => text.Text, _ => null };
                result.parts.Add(new(visual, content, Q(rect.X), Q(rect.Y), Q(rect.Width), Q(rect.Height),
                    (long)Math.Round(element.Opacity * 64), Q(clip.X), Q(clip.Y), Q(clip.Width), Q(clip.Height)));
            }
            for (var i = 0; i < VisualTreeHelper.GetChildrenCount(visual); i++)
                if (VisualTreeHelper.GetChild(visual, i) is Visual child) Visit(child);
        }
        Visit(foreground); return result;
    }
    public bool Matches(AmbientCompositionKey? other) => other != null && parts.SequenceEqual(other.parts);
}

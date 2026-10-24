using System.Windows.Media.Imaging;
using Net = DynamicPhotoWall.Networking;

namespace DynamicPhotoWall.Rendering;

internal sealed class SharedPhotoDrawing
{
    private readonly DrawingGroup image = new();
    private readonly MatrixTransform transform = new();
    private readonly Net.ScenePlacement plan;
    public DrawingGroup Root { get; } = new();
    public SharedPhotoDrawing(Net.ScenePlacement plan, BitmapSource texture, double originX, double originY)
    {
        this.plan = plan;
        Root.Transform = new TranslateTransform(plan.Clip.X - originX, plan.Clip.Y - originY);
        Root.ClipGeometry = new RectangleGeometry(new Rect(0, 0, plan.Clip.Width, plan.Clip.Height));
        image.Transform = transform; image.Opacity = 0;
        image.ClipGeometry = new RectangleGeometry(new Rect(0, 0, plan.Width, plan.Height), plan.CornerRadius, plan.CornerRadius);
        image.Children.Add(new ImageDrawing(texture, new Rect(0, 0, plan.Width, plan.Height)));
        RenderOptions.SetBitmapScalingMode(Root, BitmapScalingMode.Linear);
    }
    public void Present(double x, double y, double scale, double opacity)
    {
        var matrix = new Matrix(scale, 0, 0, scale, x - plan.Clip.X + (1 - scale) * plan.CenterX * plan.Width,
            y - plan.Clip.Y + (1 - scale) * plan.CenterY * plan.Height);
        // Scroll plans preload the entire future strip. Keep decoded textures
        // ready, but attach drawing resources only while they can contribute
        // pixels to this clip. Leave a margin for edge filtering and rounding.
        if (opacity <= 0 || matrix.OffsetX + scale * plan.Width < -1 || matrix.OffsetX > plan.Clip.Width + 1
            || matrix.OffsetY + scale * plan.Height < -1 || matrix.OffsetY > plan.Clip.Height + 1)
        { Hide(); return; }
        if (transform.Matrix != matrix) transform.Matrix = matrix;
        if (image.Opacity != opacity) image.Opacity = opacity;
        if (Root.Children.Count == 0) Root.Children.Add(image);
    }
    public void Hide()
    {
        if (Root.Children.Count != 0) Root.Children.Clear();
        if (image.Opacity != 0) image.Opacity = 0;
    }
}

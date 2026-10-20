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
        Root.Children.Add(image);
        RenderOptions.SetBitmapScalingMode(Root, BitmapScalingMode.Linear);
    }
    public void Present(double x, double y, double scale, double opacity)
    {
        var matrix = new Matrix(scale, 0, 0, scale, x - plan.Clip.X + (1 - scale) * plan.CenterX * plan.Width,
            y - plan.Clip.Y + (1 - scale) * plan.CenterY * plan.Height);
        if (transform.Matrix != matrix) transform.Matrix = matrix;
        if (image.Opacity != opacity) image.Opacity = opacity;
    }
    public void Hide() { if (image.Opacity != 0) image.Opacity = 0; }
}

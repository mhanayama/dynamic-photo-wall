namespace DynamicPhotoWall.Rendering;

// Reference retained drawing commands directly from each output. No brush
// samples a hidden UI tree, and no source HWND is needed for these commands.
internal sealed class SharedDrawingPresenter : FrameworkElement
{
    private readonly DrawingGroup drawing;
    public Rect Region { get; }
    public SharedDrawingPresenter(DrawingGroup drawing, Rect region, double width, double height)
    {
        this.drawing = drawing; Region = region; Width = width; Height = height;
        ClipToBounds = true; IsHitTestVisible = false;
    }
    protected override void OnRender(DrawingContext dc)
    {
        base.OnRender(dc);
        dc.PushClip(new RectangleGeometry(new Rect(0, 0, Width, Height)));
        dc.PushTransform(new MatrixTransform(Width / Region.Width, 0, 0, Height / Region.Height,
            -Region.X * Width / Region.Width, -Region.Y * Height / Region.Height));
        dc.DrawDrawing(drawing); dc.Pop(); dc.Pop();
    }
}

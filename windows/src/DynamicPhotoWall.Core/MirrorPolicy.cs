namespace DynamicPhotoWall.Core;

// Compare oriented source pixels along the group's longer physical axis.
public static class MirrorPolicy
{
    public static bool IsBelowHalf(int imageWidth, int imageHeight, Viewport group)
        => group.Width >= group.Height ? imageWidth < group.Width / 2 : imageHeight < group.Height / 2;

    public static bool Supports(CompositionMode mode)
        => mode is CompositionMode.VerticalPan or CompositionMode.HorizontalPan or CompositionMode.Zoom;
}

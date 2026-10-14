using System.Windows.Media.Animation;

namespace DynamicPhotoWall.Motion;

public sealed class TransitionController
{
    private readonly List<(Storyboard Board, FrameworkElement Root)> clocks = [];
    private bool paused;
    public Storyboard Create()
    {
        // Let WPF pace its render thread against DWM/display presentation.
        // An explicit low DesiredFrameRate introduces extra motion judder.
        return new Storyboard();
    }
    public static void Animate(Storyboard board, DependencyObject target, DependencyProperty property, double from, double to, double seconds, bool smooth = true)
        => Animate(board, target, new PropertyPath(property), from, to, seconds, smooth);
    public static void Animate(Storyboard board, DependencyObject target, PropertyPath property, double from, double to, double seconds, bool smooth = true)
    {
        var animation = new DoubleAnimation(from, to, TimeSpan.FromSeconds(Math.Max(.01, seconds))) { FillBehavior = FillBehavior.HoldEnd };
        if (smooth) animation.EasingFunction = new SineEase { EasingMode = EasingMode.EaseInOut };
        Storyboard.SetTarget(animation, target); Storyboard.SetTargetProperty(animation, property); board.Children.Add(animation);
    }
    public void Start(Storyboard board, FrameworkElement root)
    {
        board.Begin(root, HandoffBehavior.SnapshotAndReplace, true); clocks.Add((board, root));
        if (paused) board.Pause(root);
    }
    public void SetPaused(bool value)
    {
        paused = value;
        foreach (var (board, root) in clocks) { if (value) board.Pause(root); else board.Resume(root); }
    }
    public void RemoveRoot(FrameworkElement root)
    {
        foreach (var item in clocks.Where(c => c.Root == root).ToArray()) { item.Board.Remove(item.Root); clocks.Remove(item); }
    }
    public void RemoveTree(FrameworkElement root)
    {
        foreach (var item in clocks.ToArray())
        {
            DependencyObject? current = item.Root;
            while (current != null && current != root) current = VisualTreeHelper.GetParent(current);
            if (current == root) { item.Board.Remove(item.Root); clocks.Remove(item); }
        }
    }
    public void Clear()
    {
        foreach (var (board, root) in clocks) board.Remove(root); clocks.Clear();
    }
}

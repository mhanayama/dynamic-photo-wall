using Net = DynamicPhotoWall.Networking;

namespace DynamicPhotoWall.UI;

// A view adapter over neutral display values. Dragging emits physical-pixel
// coordinates; it never changes the committed snapshot or owns peer sessions.
public sealed class NetworkLayoutPreview : Canvas
{
    private readonly Func<IReadOnlyList<Net.PeerDisplay>> read;
    private readonly Func<Guid, string> peerName;
    private readonly Action<Net.PeerDisplayKey, int, int> move;
    private (Net.PeerDisplay Display, Point Point)? dragging;
    private double scale = 1, left, top;
    public NetworkLayoutPreview(Func<IReadOnlyList<Net.PeerDisplay>> read, Func<Guid, string> peerName, Action<Net.PeerDisplayKey, int, int> move)
    {
        this.read = read; this.peerName = peerName; this.move = move;
        Height = 270; ClipToBounds = true; Background = new SolidColorBrush(Color.FromRgb(20, 22, 28));
        SizeChanged += (_, _) => Refresh();
        MouseMove += (_, e) =>
        {
            if (dragging is not { } start) return;
            var delta = e.GetPosition(this) - start.Point;
            move(start.Display.Key, (int)Math.Clamp(Math.Round(start.Display.X + delta.X / scale), -100000, 100000),
                (int)Math.Clamp(Math.Round(start.Display.Y + delta.Y / scale), -100000, 100000));
            Refresh();
        };
        MouseLeftButtonUp += (_, _) => { dragging = null; ReleaseMouseCapture(); Refresh(); };
    }
    public void Refresh()
    {
        Children.Clear(); var displays = read().Where(d => d.Selected).ToArray(); if (displays.Length == 0) return;
        // Freeze the view transform during a drag, so cursor motion stays stable.
        if (dragging == null)
        {
            left = displays.Min(d => d.X); top = displays.Min(d => d.Y);
            var width = displays.Max(d => (double)d.X + d.Width) - left;
            var height = displays.Max(d => (double)d.Y + d.Height) - top;
            scale = Math.Max(.001, Math.Min(Math.Max(100, ActualWidth - 32) / width, (Height - 32) / height));
        }
        foreach (var display in displays)
        {
            var name = $"{peerName(display.Key.PeerId)} / {display.Key.DisplayId}\n{display.Width}×{display.Height}";
            var card = new Border { Width = Math.Max(20, display.Width * scale), Height = Math.Max(20, display.Height * scale),
                BorderThickness = new Thickness(2), BorderBrush = display.GroupId == null ? Brushes.SlateGray : Brushes.CornflowerBlue,
                Background = new SolidColorBrush(Color.FromArgb(220, 38, 57, 82)), Cursor = System.Windows.Input.Cursors.SizeAll,
                Child = new TextBlock { Text = name, FontSize = 11, Foreground = Brushes.White, Margin = new Thickness(5), TextTrimming = TextTrimming.CharacterEllipsis } };
            SetLeft(card, 16 + (display.X - left) * scale); SetTop(card, 16 + (display.Y - top) * scale);
            card.MouseLeftButtonDown += (_, e) => { dragging = (display, e.GetPosition(this)); CaptureMouse(); e.Handled = true; };
            Children.Add(card);
        }
    }
}

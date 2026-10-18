using System.Windows.Media.Imaging;
using Net = DynamicPhotoWall.Networking;

namespace DynamicPhotoWall.Rendering;

public sealed class SharedVisual
{
    public required SceneVisual Scene { get; init; }
    public required Net.SharedScenePlan Plan { get; init; }
    public required IReadOnlyDictionary<string, BitmapSource> Images { get; init; }
    internal List<(Net.ScenePlacement Plan, FrameworkElement Image, ScaleTransform Scale, TranslateTransform Translation)> Photos { get; } = [];
    internal List<(string? Id, System.Windows.Controls.Image A, System.Windows.Controls.Image B, Net.AmbientFrame[] Frames, BitmapSource[] Images)> Backgrounds { get; } = [];
}

public sealed partial class PhotoRenderer
{
    public SharedVisual BuildShared(Net.SharedScenePlan plan, IReadOnlyDictionary<string, BitmapSource> images,
        IReadOnlyCollection<string> localDisplayIds)
    {
        SceneVisual Surface(double width, double height) => new()
        {
            Canvas = new Canvas { Width = width, Height = height, ClipToBounds = true, Background = ParseBrush(plan.Background) },
            Foreground = new Canvas { Width = width, Height = height, ClipToBounds = true },
            Mode = Enum.Parse<CompositionMode>(plan.Mode.ToString()), Viewport = new(width, height), Seconds = plan.Duration
        };
        var scene = Surface(plan.Viewport.Width, plan.Viewport.Height);
        var visual = new SharedVisual { Scene = scene, Plan = plan, Images = images };
        foreach (var id in plan.Placements.Select(p => p.DisplayId).Distinct())
        {
            if (id != null && !localDisplayIds.Contains(id)) continue;
            var display = id == null ? null : plan.Displays.First(d => d.Key.LayoutId == id);
            var x = display == null ? 0 : display.X - plan.Displays.Min(d => d.X);
            var y = display == null ? 0 : display.Y - plan.Displays.Min(d => d.Y);
            var surface = id == null ? scene : Surface(display!.Width, display.Height);
            if (id != null)
            {
                surface.DisplayId = id; surface.DisplayRegion = new(x, y, display!.Width, display.Height);
                var wrapper = new Canvas { Width = display.Width, Height = display.Height };
                Canvas.SetLeft(wrapper, x); Canvas.SetTop(wrapper, y); wrapper.Children.Add(surface.Canvas);
                scene.Foreground.Children.Add(wrapper); scene.Displays.Add(surface);
            }
            var frames = plan.Ambient.Where(f => f.DisplayId == id).OrderBy(f => f.At).ToArray();
            if (frames.Length > 0)
            {
                var a = new System.Windows.Controls.Image { Width = surface.Viewport.Width, Height = surface.Viewport.Height, Stretch = Stretch.Fill };
                var b = new System.Windows.Controls.Image { Width = a.Width, Height = a.Height, Stretch = Stretch.Fill };
                surface.Canvas.Children.Add(a); surface.Canvas.Children.Add(b);
                surface.Canvas.Children.Add(new Border { Width = a.Width, Height = a.Height,
                    Background = new SolidColorBrush(Color.FromArgb(90, 12, 17, 28)) });
                var bitmaps = frames.Select(frame =>
                {
                    using var stream = new MemoryStream(frame.Png, false);
                    var bitmap = new BitmapImage(); bitmap.BeginInit(); bitmap.CacheOption = BitmapCacheOption.OnLoad;
                    bitmap.StreamSource = stream; bitmap.EndInit(); bitmap.Freeze(); return (BitmapSource)bitmap;
                }).ToArray();
                visual.Backgrounds.Add((id, a, b, frames, bitmaps));
            }
            surface.Canvas.Children.Add(surface.Foreground);
            foreach (var p in plan.Placements.Where(p => p.DisplayId == id))
            {
                var clip = new Canvas { Width = p.Clip.Width, Height = p.Clip.Height, ClipToBounds = true };
                Canvas.SetLeft(clip, p.Clip.X - x); Canvas.SetTop(clip, p.Clip.Y - y);
                var image = new System.Windows.Controls.Image { Source = images[p.Asset.OpaqueId], Width = p.Width, Height = p.Height,
                    Stretch = Stretch.Fill, RenderTransformOrigin = new(p.CenterX, p.CenterY),
                    Clip = new RectangleGeometry(new Rect(0, 0, p.Width, p.Height), p.CornerRadius, p.CornerRadius) };
                var scale = new ScaleTransform(1, 1); var translation = new TranslateTransform();
                var transforms = new TransformGroup(); transforms.Children.Add(scale); transforms.Children.Add(translation); image.RenderTransform = transforms;
                RenderOptions.SetBitmapScalingMode(image, BitmapScalingMode.Linear);
                clip.Children.Add(image); surface.Foreground.Children.Add(clip);
                visual.Photos.Add((p, image, scale, translation));
            }
        }
        if (scene.Displays.Count > 0) scene.Canvas.Children.Add(scene.Foreground);
        return visual;
    }
    public void ShowShared(SharedVisual visual, SharedVisual? previous = null)
    {
        Clear();
        if (previous != null)
        { layers.Children.Add(previous.Scene.Canvas); visibleScenes.Add(previous.Scene); foreach (var view in views) AddPresentation(view, previous.Scene); }
        layers.Children.Add(visual.Scene.Canvas); Current = visual.Scene;
        visibleScenes.Add(visual.Scene); foreach (var view in views) AddPresentation(view, visual.Scene);
    }
    public void RemoveShared(SharedVisual visual) { layers.Children.Remove(visual.Scene.Canvas); RemovePresentation(visual.Scene); }
    public void PresentShared(SharedVisual visual, double elapsed)
    {
        foreach (var (p, image, scale, translation) in visual.Photos)
        {
            var value = Net.SceneEvaluation.Evaluate(p, Math.Min(elapsed, visual.Plan.Duration - .00001));
            scale.ScaleX = scale.ScaleY = value.Scale;
            translation.X = value.X - p.Clip.X; translation.Y = value.Y - p.Clip.Y; image.Opacity = value.Opacity;
        }
        foreach (var (_, a, b, frames, images) in visual.Backgrounds)
        {
            var index = 0;
            while (index + 1 < frames.Length && frames[index + 1].At <= elapsed) index++;
            var next = Math.Min(index + 1, frames.Length - 1);
            a.Source = images[index]; b.Source = images[next];
            b.Opacity = next == index ? 0 : Math.Clamp((elapsed - frames[index].At) / Math.Max(.001, frames[next].At - frames[index].At), 0, 1);
        }
        visual.Scene.Canvas.Opacity = visual.Plan.FadeSeconds <= 0 ? 1 : Math.Clamp(elapsed / visual.Plan.FadeSeconds, 0, 1);
    }
}

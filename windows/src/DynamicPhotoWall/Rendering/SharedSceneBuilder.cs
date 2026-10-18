using System.Windows.Media.Imaging;
using Net = DynamicPhotoWall.Networking;

namespace DynamicPhotoWall.Rendering;

// Prepare a visual tree without creating a desktop output window.
public static class SharedSceneBuilder
{
    public static SharedVisual Build(Net.SharedScenePlan plan, IReadOnlyDictionary<string, BitmapSource> images,
        IReadOnlyCollection<string> localDisplayIds)
    {
        SceneVisual Surface(double width, double height) => new()
        {
            Canvas = new Canvas { Width = width, Height = height, ClipToBounds = true, Background = PhotoRenderer.ParseBrush(plan.Background) },
            Foreground = new Canvas { Width = width, Height = height, ClipToBounds = true },
            Mode = Enum.Parse<CompositionMode>(plan.Mode.ToString()), Viewport = new(width, height), Seconds = plan.Duration,
            OutputRegions = plan.Displays.ToDictionary(d => d.Key.LayoutId,
                d => new FrameRect(d.X - plan.Displays.Min(v => v.X), d.Y - plan.Displays.Min(v => v.Y), d.Width, d.Height))
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
                var bitmaps = frames.Select(frame =>
                {
                    using var stream = new MemoryStream(frame.Png, false);
                    var bitmap = new BitmapImage(); bitmap.BeginInit(); bitmap.CacheOption = BitmapCacheOption.OnLoad;
                    bitmap.StreamSource = stream; bitmap.EndInit();
                    // Apply at the receiving display so previews from either OS
                    // gain color once, without baking enhancement into the wire PNG.
                    var converted = new FormatConvertedBitmap(bitmap, PixelFormats.Pbgra32, null, 0);
                    var pixels = new byte[converted.PixelWidth * converted.PixelHeight * 4];
                    converted.CopyPixels(pixels, converted.PixelWidth * 4, 0); AmbientPixels.EnhanceColors(pixels);
                    var texture = BitmapSource.Create(converted.PixelWidth, converted.PixelHeight, 96, 96,
                        PixelFormats.Pbgra32, null, pixels, converted.PixelWidth * 4);
                    texture.Freeze(); return texture;
                }).ToArray();
                var ambient = new AmbientFrameVisual(frames, bitmaps, surface.Viewport.Width, surface.Viewport.Height);
                foreach (var image in ambient.Images) surface.Canvas.Children.Add(image);
                surface.Canvas.Children.Add(new Border { Width = surface.Viewport.Width, Height = surface.Viewport.Height,
                    Background = new SolidColorBrush(Color.FromArgb(46, 12, 17, 28)) });
                visual.Backgrounds.Add(ambient);
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
}

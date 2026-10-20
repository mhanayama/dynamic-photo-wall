using System.Windows.Media.Imaging;
using System.Windows.Data;
using DynamicPhotoWall.Motion;

namespace DynamicPhotoWall.Rendering;

public sealed record DisplayScene(string DisplayId, FrameRect Region, CompositionPlan Plan, IReadOnlyList<BitmapSource> Bitmaps);

public sealed class SceneVisual
{
    public required Canvas Canvas { get; init; }
    public required Canvas Foreground { get; init; }
    public GlassBackground? Ambient { get; set; }
    public required CompositionMode Mode { get; init; }
    public List<PhotoInfo> Photos { get; } = [];
    public List<BitmapSource> Bitmaps { get; } = [];
    public List<Border> Slots { get; } = [];
    public double Seconds { get; set; }
    public Canvas? ScrollStrip { get; set; }
    public System.Windows.Controls.Image? MotionImage { get; set; }
    public Viewport Viewport { get; init; } = new(1, 1);
    public string? DisplayId { get; set; }
    public FrameRect? DisplayRegion { get; set; }
    public List<SceneVisual> Displays { get; } = [];
    public IReadOnlyList<FrameRect> DisplayRegions { get; init; } = [];
    public IReadOnlyDictionary<string, FrameRect> OutputRegions { get; init; } = new Dictionary<string, FrameRect>();
    internal DrawingGroup? Drawing { get; init; }
    public IEnumerable<SceneVisual> Surfaces => Displays.Count == 0 ? new[] { this } : Displays.SelectMany(d => d.Surfaces);
    public IEnumerable<PhotoInfo> DisplayedPhotos => Surfaces.SelectMany(s => s.Photos);
}

public sealed partial class PhotoRenderer : Window
{
    private readonly Canvas layers;
    private Viewport viewport;
    private readonly WallSettings settings;
    private readonly TransitionController transitions;
    private readonly AnimationScheduler scheduler;
    private readonly IReadOnlyList<FrameRect> displayRegions;
    private readonly HashSet<GlassBackground> backgrounds = [];
    private sealed record DisplayView(string? Id, FrameRect Region, Canvas Canvas);
    private readonly List<DisplayView> views = [];
    private readonly List<SceneVisual> visibleScenes = [];
    private DisplayView? primaryView;
    private Canvas? sourceCrop;
    private bool testPattern;
    public SceneVisual? Current { get; private set; }
    public PhotoRenderer(Viewport viewport, WallSettings settings, TransitionController transitions, AnimationScheduler scheduler, IReadOnlyList<FrameRect>? displayRegions = null)
    {
        this.viewport = viewport; this.settings = settings; this.transitions = transitions; this.scheduler = scheduler;
        this.displayRegions = displayRegions ?? [];
        Background = ParseBrush(settings.Background); Focusable = false; IsHitTestVisible = false;
        layers = new Canvas { Width = viewport.Width, Height = viewport.Height, ClipToBounds = true, Background = Background };
        Content = new Viewbox { Stretch = Stretch.Fill, Child = layers };
    }
    public static Brush ParseBrush(string value) { try { var b = (Brush)new BrushConverter().ConvertFromString(value)!; b.Freeze(); return b; } catch (Exception e) when (e is FormatException or NotSupportedException) { return Brushes.Black; } }
    public void SetDisplayRegion(FrameRect region, string? displayId = null)
    {
        // Local storyboards keep an attached source tree. Shared playback uses
        // retained Drawing commands and collapses this source crop below.
        ((Viewbox)Content).Child = null;
        if (VisualTreeHelper.GetParent(layers) is Panel previous) previous.Children.Remove(layers);
        var crop = new Canvas { Width = region.Width, Height = region.Height, ClipToBounds = true, Background = Background };
        sourceCrop = crop;
        var positioned = new Canvas { Width = viewport.Width, Height = viewport.Height };
        Canvas.SetLeft(positioned, -region.X); Canvas.SetTop(positioned, -region.Y);
        positioned.Children.Add(layers); crop.Children.Add(positioned);
        if (primaryView != null) views.Remove(primaryView);
        primaryView = CreateView(region, displayId);
        // Keep the source tree attached underneath an opaque presentation view.
        // Per-display scenes sample their own child even when logical display
        // rectangles overlap; spanning scenes sample the shared wall region.
        var presentation = new Grid { Width = region.Width, Height = region.Height };
        presentation.Children.Add(crop); presentation.Children.Add(primaryView.Canvas);
        Content = new Viewbox { Stretch = Stretch.Fill, Child = presentation };
    }
    public FrameworkElement CreateDisplayRegion(FrameRect region, string? displayId = null)
        => new Viewbox { Stretch = Stretch.Fill, Child = CreateView(region, displayId).Canvas };
    private DisplayView CreateView(FrameRect region, string? displayId)
    {
        var view = new DisplayView(displayId, region, new Canvas { Width = region.Width, Height = region.Height, ClipToBounds = true, Background = Background });
        views.Add(view);
        if (testPattern) view.Canvas.Children.Add(Sample(layers, region));
        else foreach (var scene in visibleScenes) AddPresentation(view, scene);
        return view;
    }
    private static System.Windows.Shapes.Rectangle Sample(Canvas source, FrameRect region) => new()
    {
        Width = region.Width, Height = region.Height,
        Fill = new VisualBrush(source) { AutoLayoutContent = false, ViewboxUnits = BrushMappingMode.Absolute,
                Viewbox = new Rect(region.X, region.Y, region.Width, region.Height), Stretch = Stretch.Fill,
                AlignmentX = AlignmentX.Left, AlignmentY = AlignmentY.Top }
    };
    private void AddPresentation(DisplayView view, SceneVisual scene)
    {
        if (sourceCrop != null) sourceCrop.Visibility = visibleScenes.All(s => s.Drawing != null) ? Visibility.Collapsed : Visibility.Visible;
        FrameworkElement rectangle;
        if (scene.Displays.Count == 0)
        {
            var region = view.Id != null && scene.OutputRegions.TryGetValue(view.Id, out var output) ? output : view.Region;
            rectangle = scene.Drawing != null
                ? new SharedDrawingPresenter(scene.Drawing, new Rect(region.X, region.Y, region.Width, region.Height), view.Region.Width, view.Region.Height)
                : Sample(scene.Canvas, region);
            rectangle.Width = view.Region.Width; rectangle.Height = view.Region.Height;
        }
        else
        {
            var child = scene.Displays.FirstOrDefault(s => s.DisplayId == view.Id)
                ?? (view.Id == null ? scene.Displays.FirstOrDefault(s => s.DisplayRegion == view.Region) : null);
            if (child == null) return;
            rectangle = child.Drawing != null
                ? new SharedDrawingPresenter(child.Drawing, new Rect(0, 0, child.Viewport.Width, child.Viewport.Height), view.Region.Width, view.Region.Height)
                : Sample(child.Canvas, new(0, 0, child.Viewport.Width, child.Viewport.Height));
            rectangle.Width = view.Region.Width; rectangle.Height = view.Region.Height;
            rectangle.SetBinding(OpacityProperty, new Binding(nameof(Opacity)) { Source = scene.Canvas });
        }
        rectangle.Tag = scene; view.Canvas.Children.Add(rectangle);
    }
    private void RemovePresentation(SceneVisual scene)
    {
        visibleScenes.Remove(scene);
        foreach (var view in views)
            foreach (var child in view.Canvas.Children.OfType<FrameworkElement>().Where(c => ReferenceEquals(c.Tag, scene)).ToArray()) view.Canvas.Children.Remove(child);
    }
    public void ShowTestPattern(WallLayout layout, string? groupName = null, IReadOnlyList<string>? displayOrder = null)
    {
        Clear(); testPattern = true;
        for (var x = 0; x <= viewport.Width; x += 120)
            layers.Children.Add(new System.Windows.Shapes.Line { X1 = x, X2 = x, Y2 = viewport.Height, Stroke = Brushes.SlateGray, StrokeThickness = 1 });
        for (var y = 0; y <= viewport.Height; y += 120)
            layers.Children.Add(new System.Windows.Shapes.Line { Y1 = y, Y2 = y, X2 = viewport.Width, Stroke = Brushes.SlateGray, StrokeThickness = 1 });
        layers.Children.Add(new System.Windows.Shapes.Line { X2 = viewport.Width, Y2 = viewport.Height, Stroke = Brushes.Cyan, StrokeThickness = 3 });
        layers.Children.Add(new System.Windows.Shapes.Line { X1 = viewport.Width, Y2 = viewport.Height, Stroke = Brushes.Cyan, StrokeThickness = 3 });
        var diameter = Math.Min(viewport.Width, viewport.Height) * .8;
        var circle = new System.Windows.Shapes.Ellipse { Width = diameter, Height = diameter, Stroke = Brushes.Gold, StrokeThickness = 3 };
        Canvas.SetLeft(circle, (viewport.Width - diameter) / 2); Canvas.SetTop(circle, (viewport.Height - diameter) / 2); layers.Children.Add(circle);
        var number = 0;
        foreach (var entry in layout.Regions)
        {
            var region = entry.Value;
            var index = displayOrder?.ToList().IndexOf(entry.Key) ?? -1;
            var title = $"{(index >= 0 ? index + 1 : ++number)}" + (groupName == null ? "" : $" · {groupName}");
            var label = new TextBlock { Text = $"{title}   {region.Width} × {region.Height}\n壁座標 ({region.X}, {region.Y})", FontSize = 32, Foreground = Brushes.White, Background = Brushes.Black, Padding = new Thickness(16) };
            Canvas.SetLeft(label, region.X + 32); Canvas.SetTop(label, region.Y + 32); layers.Children.Add(label);
        }
        layers.Measure(new Size(viewport.Width, viewport.Height)); layers.Arrange(new Rect(0, 0, viewport.Width, viewport.Height));
        foreach (var view in views) view.Canvas.Children.Add(Sample(layers, view.Region));
    }
    public SceneVisual BuildPerDisplay(IReadOnlyList<DisplayScene> displays, Random random)
    {
        if (displays.Count == 0 || displays.Any(d => d.Plan.Mode != displays[0].Plan.Mode))
            throw new InvalidOperationException("画面ごとの構成は同じ表示モードで作成してください。");
        var foreground = new Canvas { Width = viewport.Width, Height = viewport.Height, ClipToBounds = true };
        var scene = new SceneVisual { Canvas = new Canvas { Width = viewport.Width, Height = viewport.Height, ClipToBounds = true, Opacity = 0, Background = Background },
            Foreground = foreground, Mode = displays[0].Plan.Mode, Viewport = viewport };
        scene.Canvas.Children.Add(foreground);
        foreach (var display in displays)
        {
            var child = Build(display.Plan, display.Bitmaps, random, new(display.Region.Width, display.Region.Height));
            child.DisplayId = display.DisplayId; child.DisplayRegion = display.Region; child.Canvas.Opacity = 1;
            // Position a wrapper, keeping the sampled visual's own origin at 0.
            var positioned = new Canvas { Width = display.Region.Width, Height = display.Region.Height, ClipToBounds = true };
            Canvas.SetLeft(positioned, display.Region.X); Canvas.SetTop(positioned, display.Region.Y);
            positioned.Children.Add(child.Canvas); foreground.Children.Add(positioned); scene.Displays.Add(child);
        }
        // Shorter motions hold their final frame until the group's longest
        // motion completes. Fade, pause and Next remain group-wide operations.
        scene.Seconds = scene.Displays.Max(d => d.Seconds);
        return scene;
    }
    public SceneVisual Build(CompositionPlan plan, IReadOnlyList<BitmapSource> bitmaps, Random random, Viewport? renderViewport = null)
    {
        var viewport = renderViewport ?? this.viewport;
        var regions = renderViewport == null && settings.AvoidFaceDisplayBoundaries ? displayRegions : Array.Empty<FrameRect>();
        var scene = new SceneVisual { Canvas = new Canvas { Width = viewport.Width, Height = viewport.Height, ClipToBounds = true, Opacity = 0 },
            Foreground = new Canvas { Width = viewport.Width, Height = viewport.Height, ClipToBounds = true }, Mode = plan.Mode, Viewport = viewport,
            DisplayRegions = FaceSafeLayout.RequiresProtection(viewport, regions) ? regions : [] };
        scene.Photos.AddRange(plan.Photos); scene.Bitmaps.AddRange(bitmaps);
        if (settings.GlassBackground)
        {
            var backgroundBrush = new ImageBrush { Stretch = Stretch.Fill };
            var glass = new System.Windows.Shapes.Rectangle { Width = viewport.Width, Height = viewport.Height, Fill = backgroundBrush };
            RenderOptions.SetBitmapScalingMode(glass, BitmapScalingMode.Linear); scene.Canvas.Children.Add(glass);
            scene.Ambient = new GlassBackground(scene.Foreground, viewport, scheduler, backgroundBrush, transitions);
            scene.Canvas.Children.Add(new Border { Width = viewport.Width, Height = viewport.Height, Background = new SolidColorBrush(Color.FromArgb(46, 12, 17, 28)) });
        }
        scene.Canvas.Children.Add(scene.Foreground);
        if (plan.Mode == CompositionMode.Gallery)
        {
            var items = FixedGalleryLayout.Arrange(plan.Photos, viewport, settings.Gap, scene.DisplayRegions);
            scene.Photos.Clear(); scene.Bitmaps.Clear();
            foreach (var item in items)
            {
                var slot = CreateSlot(plan.Photos[item.Index], bitmaps[item.Index]); SetRect(slot, item.Frame);
                scene.Photos.Add(plan.Photos[item.Index]); scene.Bitmaps.Add(bitmaps[item.Index]); scene.Slots.Add(slot); scene.Foreground.Children.Add(slot);
            }
            if (items.Count == 0) throw new InvalidOperationException("固定サイズで写真と顔を収められる配置がありません。");
            scene.Seconds = Math.Max(90, settings.GalleryMaxSeconds * 2);
        }
        else if (plan.Mode == CompositionMode.GalleryScroll)
        {
            var strip = new Canvas { Width = viewport.Width, Height = viewport.Height, RenderTransform = new TranslateTransform() };
            scene.ScrollStrip = strip; scene.Foreground.Children.Add(strip);
            var height = Math.Max(1, viewport.Height - 2 * settings.Gap); var x = settings.Gap;
            for (var i = 0; i < plan.Photos.Count; i++)
            {
                var width = height * plan.Photos[i].Aspect;
                var slot = CreateSlot(plan.Photos[i], bitmaps[i]); SetRect(slot, new(x, (viewport.Height - height) / 2, width, height));
                strip.Children.Add(slot); scene.Slots.Add(slot); x += width + settings.Gap;
            }
            scene.Seconds = Math.Max(120, settings.GalleryMaxSeconds * 3);
        }
        else
        {
            var motion = FaceMotionSafety.Plan(plan.Mode, plan.Photos[0], viewport, settings, random.Next(2) == 0, .35 + random.NextDouble() * .3, .35 + random.NextDouble() * .3,
                renderViewport == null ? displayRegions : []);
            var image = new System.Windows.Controls.Image { Source = bitmaps[0], Width = motion.Width, Height = motion.Height, Stretch = Stretch.Fill,
                RenderTransformOrigin = new System.Windows.Point(motion.CenterX, motion.CenterY) };
            var scale = new ScaleTransform(motion.FromScale, motion.FromScale);
            var frameLeft = plan.Mode == CompositionMode.VerticalPan ? motion.FromX : 0;
            var frameWidth = plan.Mode == CompositionMode.VerticalPan ? motion.Width : viewport.Width;
            var frameHeight = Math.Min(viewport.Height, motion.Height);
            var photoFrame = new Canvas { Width = frameWidth, Height = frameHeight, ClipToBounds = true };
            Canvas.SetLeft(photoFrame, frameLeft); Canvas.SetTop(photoFrame, motion.FrameTop ?? (viewport.Height - frameHeight) / 2);
            scene.Foreground.Children.Add(photoFrame); scene.MotionImage = image;
            var translation = new TranslateTransform(motion.FromX - frameLeft, motion.FromY);
            var transform = new TransformGroup(); transform.Children.Add(scale); transform.Children.Add(translation);
            image.RenderTransform = transform;
            RenderOptions.SetBitmapScalingMode(image, BitmapScalingMode.Linear);
            Canvas.SetLeft(image, 0); Canvas.SetTop(image, 0); photoFrame.Children.Add(image);
            var board = transitions.Create();
            PropertyPath TransformPath(int index, DependencyProperty property) => new("(0).(1)[" + index + "].(2)", RenderTransformProperty, TransformGroup.ChildrenProperty, property);
            if (motion.FromX != motion.ToX) TransitionController.Animate(board, image, TransformPath(1, TranslateTransform.XProperty), motion.FromX - frameLeft, motion.ToX - frameLeft, motion.Seconds, false);
            if (motion.FromY != motion.ToY) TransitionController.Animate(board, image, TransformPath(1, TranslateTransform.YProperty), motion.FromY, motion.ToY, motion.Seconds, false);
            if (motion.FromScale != motion.ToScale)
            {
                TransitionController.Animate(board, image, TransformPath(0, ScaleTransform.ScaleXProperty), motion.FromScale, motion.ToScale, motion.Seconds);
                TransitionController.Animate(board, image, TransformPath(0, ScaleTransform.ScaleYProperty), motion.FromScale, motion.ToScale, motion.Seconds);
            }
            // Store until ShowAsync attaches this tree; start then for correct presentation timing.
            scene.Canvas.Tag = board;
            if (settings.ExifOverlay) scene.Canvas.Children.Add(Overlay(plan.Photos[0]));
            scene.Seconds = motion.Seconds + (plan.Mode == CompositionMode.VerticalPan && settings.StopAtFace && plan.Photos[0].Faces?.Count > 0 ? 3 : 0);
        }
        return scene;
    }
    public async Task AdvanceGalleryAsync(SceneVisual scene, PhotoInfo photo, BitmapSource bitmap, CancellationToken token)
    {
        var viewport = scene.Viewport;
        var strip = scene.ScrollStrip ?? throw new InvalidOperationException("スクロール用レイアウトがありません。");
        var distance = Canvas.GetLeft(scene.Slots[0]) + scene.Slots[0].Width;
        var board = transitions.Create();
        var property = new PropertyPath("(0).(1)", RenderTransformProperty, TranslateTransform.XProperty);
        TransitionController.Animate(board, strip, property, 0, -distance, distance / settings.GalleryScrollPixelsPerSecond, false);
        transitions.Start(board, strip);
        try { await scheduler.DelayAsync(distance / settings.GalleryScrollPixelsPerSecond, token); }
        catch (OperationCanceledException)
        {
            var transform = (TranslateTransform)strip.RenderTransform; transform.X = transform.X;
            transitions.RemoveRoot(strip); throw;
        }
        strip.Children.Remove(scene.Slots[0]); scene.Slots.RemoveAt(0); scene.Photos.RemoveAt(0); scene.Bitmaps.RemoveAt(0);
        foreach (var slot in scene.Slots) Canvas.SetLeft(slot, Canvas.GetLeft(slot) - distance);
        transitions.RemoveRoot(strip); ((TranslateTransform)strip.RenderTransform).X = 0;
        var last = scene.Slots.LastOrDefault();
        var height = last?.Height ?? viewport.Height - 2 * settings.Gap;
        var next = CreateSlot(photo, bitmap);
        SetRect(next, new(last == null ? settings.Gap : Canvas.GetLeft(last) + last.Width + settings.Gap,
            (viewport.Height - height) / 2, height * photo.Aspect, height));
        scene.Photos.Add(photo); scene.Bitmaps.Add(bitmap); scene.Slots.Add(next); strip.Children.Add(next);
    }
    public async Task ShowAsync(SceneVisual next, CancellationToken token)
    {
        var old = Current;
        if (testPattern) { layers.Children.Clear(); foreach (var view in views) view.Canvas.Children.Clear(); testPattern = false; }
        layers.Children.Add(next.Canvas);
        visibleScenes.Add(next);
        foreach (var view in views) AddPresentation(view, next);
        Current = next;
        next.Canvas.UpdateLayout();
        try
        {
            var ambient = next.Surfaces.Select(s => s.Ambient).OfType<GlassBackground>().ToArray();
            foreach (var background in ambient) backgrounds.Add(background);
            await Task.WhenAll(ambient.Select(b => b.StartAsync(token)));
        }
        catch (OperationCanceledException)
        {
            DisposeBackground(next); RemovePresentation(next); layers.Children.Remove(next.Canvas); Current = old; throw;
        }
        foreach (var surface in next.Surfaces)
            if (surface.Canvas.Tag is System.Windows.Media.Animation.Storyboard motion) transitions.Start(motion, surface.Canvas);
        var fade = transitions.Create(); TransitionController.Animate(fade, next.Canvas, OpacityProperty, 0, 1, settings.FadeSeconds);
        // Keep the old scene opaque under the new one to prevent a black dip.
        transitions.Start(fade, next.Canvas);
        try { await scheduler.DelayAsync(settings.FadeSeconds, token); }
        catch (OperationCanceledException)
        {
            DisposeBackground(next); RemovePresentation(next); transitions.RemoveTree(next.Canvas); layers.Children.Remove(next.Canvas); Current = old;
            throw;
        }
        if (old != null) { DisposeBackground(old); RemovePresentation(old); transitions.RemoveTree(old.Canvas); layers.Children.Remove(old.Canvas); }
    }
    public async Task<bool> ReplaceSlotAsync(SceneVisual scene, int index, PhotoInfo photo, BitmapSource bitmap, CancellationToken token)
    {
        if (Current == null || !Current.Surfaces.Contains(scene)) return false;
        var viewport = scene.Viewport;
        // Protect the resting layout. Faces may cross seams while the existing
        // slots smoothly move and resize toward their new positions.
        var change = FixedGalleryLayout.Update(scene.Photos, photo, viewport, settings.Gap, scene.DisplayRegions, index, settings.GalleryMax);
        if (change == null) return false;
        var photos = change.Photos; var items = change.Items; index = change.IncomingIndex;
        if (change.IsAddition)
        {
            var added = CreateSlot(photo, bitmap); SetRect(added, items.First(i => i.Index == index).Frame);
            scene.Slots.Insert(index, added); scene.Photos.Insert(index, photo); scene.Bitmaps.Insert(index, bitmap);
            scene.Foreground.Children.Add(added);
        }
        var slot = scene.Slots[index];
        var old = change.IsAddition ? null : slot.Child;
        var next = CreatePhoto(photo, bitmap); next.Opacity = 0;
        var replacementFrame = items.First(i => i.Index == index).Frame;
        next.Width = replacementFrame.Width; next.Height = replacementFrame.Height;
        next.HorizontalAlignment = HorizontalAlignment.Left; next.VerticalAlignment = VerticalAlignment.Top;
        if (old is FrameworkElement oldPhoto) { oldPhoto.Width = slot.Width; oldPhoto.Height = slot.Height; oldPhoto.HorizontalAlignment = HorizontalAlignment.Left; oldPhoto.VerticalAlignment = VerticalAlignment.Top; }
        var stack = new Grid(); if (old != null) { slot.Child = null; stack.Children.Add(old); } stack.Children.Add(next); slot.Child = stack;
        scene.Photos[index] = photo; scene.Bitmaps[index] = bitmap;
        var fade = transitions.Create(); TransitionController.Animate(fade, next, OpacityProperty, 0, 1, settings.FadeSeconds);
        foreach (var layout in items)
        {
            var item = scene.Slots[layout.Index]; var frame = layout.Frame;
            TransitionController.Animate(fade, item, Canvas.LeftProperty, Canvas.GetLeft(item), frame.X, settings.FadeSeconds);
            TransitionController.Animate(fade, item, Canvas.TopProperty, Canvas.GetTop(item), frame.Y, settings.FadeSeconds);
            TransitionController.Animate(fade, item, WidthProperty, item.ActualWidth > 0 ? item.ActualWidth : item.Width, frame.Width, settings.FadeSeconds);
            TransitionController.Animate(fade, item, HeightProperty, item.ActualHeight > 0 ? item.ActualHeight : item.Height, frame.Height, settings.FadeSeconds);
        }
        var kept = items.Select(i => i.Index).ToHashSet();
        for (var i = 0; i < scene.Slots.Count; i++)
            if (!kept.Contains(i)) TransitionController.Animate(fade, scene.Slots[i], OpacityProperty, 1, 0, settings.FadeSeconds);
        transitions.Start(fade, next);
        try { await scheduler.DelayAsync(settings.FadeSeconds, token); }
        finally
        {
            foreach (var layout in items) SetRect(scene.Slots[layout.Index], layout.Frame);
            // Commit final values before removing clocks, including Next/stop
            // cancellation, so the outgoing scene cannot snap back mid-fade.
            next.Opacity = 1; transitions.RemoveRoot(next);
            stack.Children.Clear(); slot.Child = next;
            var slots = scene.Slots.ToArray(); var images = scene.Bitmaps.ToArray();
            for (var i = 0; i < slots.Length; i++) if (!kept.Contains(i)) scene.Foreground.Children.Remove(slots[i]);
            scene.Slots.Clear(); scene.Photos.Clear(); scene.Bitmaps.Clear();
            foreach (var item in items) { scene.Slots.Add(slots[item.Index]); scene.Photos.Add(photos[item.Index]); scene.Bitmaps.Add(images[item.Index]); }
        }
        return true;
    }
    private Border CreateSlot(PhotoInfo photo, BitmapSource bitmap)
    {
        var border = new Border { CornerRadius = new CornerRadius(settings.CornerRadius), Child = CreatePhoto(photo, bitmap) };
        border.SizeChanged += (_, _) =>
        {
            border.Clip = new RectangleGeometry(new Rect(0, 0, Math.Max(0, border.ActualWidth), Math.Max(0, border.ActualHeight)), settings.CornerRadius, settings.CornerRadius);
        };
        return border;
    }
    private Grid CreatePhoto(PhotoInfo photo, BitmapSource bitmap)
    {
        var grid = new Grid(); grid.Children.Add(new System.Windows.Controls.Image { Source = bitmap, Stretch = Stretch.Uniform });
        if (settings.ExifOverlay) grid.Children.Add(Overlay(photo)); return grid;
    }
    private static TextBlock Overlay(PhotoInfo photo) => new()
    {
        Text = $"{Path.GetFileName(photo.Path)}  ·  {photo.Width}×{photo.Height}  {photo.TakenAt:yyyy/MM/dd HH:mm}",
        Foreground = Brushes.White, Background = new SolidColorBrush(Color.FromArgb(130, 0, 0, 0)), FontSize = 16,
        Padding = new Thickness(10), HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Bottom,
        MaxWidth = 1200, TextTrimming = TextTrimming.CharacterEllipsis
    };
    private void SetRect(FrameworkElement item, FrameRect rect)
    {
        Canvas.SetLeft(item, rect.X); Canvas.SetTop(item, rect.Y); item.Width = rect.Width; item.Height = rect.Height;
    }
    private void DisposeBackground(SceneVisual scene)
    {
        foreach (var surface in scene.Surfaces)
            if (surface.Ambient != null) { surface.Ambient.Dispose(); backgrounds.Remove(surface.Ambient); }
    }
    public void Clear()
    {
        foreach (var background in backgrounds) background.Dispose(); backgrounds.Clear();
        transitions.Clear(); layers.Children.Clear(); visibleScenes.Clear(); foreach (var view in views) view.Canvas.Children.Clear();
        Current = null; testPattern = false;
        if (sourceCrop != null) sourceCrop.Visibility = Visibility.Visible;
    }
}

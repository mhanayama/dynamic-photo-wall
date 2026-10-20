using System.Windows.Media.Imaging;
using Net = DynamicPhotoWall.Networking;

namespace DynamicPhotoWall.Rendering;

public sealed class SharedVisual
{
    public required SceneVisual Scene { get; set; }
    public required Net.SharedScenePlan Plan { get; init; }
    public required IReadOnlyDictionary<string, BitmapSource> Images { get; init; }
    internal bool IsContinuation { get; set; }
    internal bool Optimized { get; init; }
    internal double[]? NextPhotoUpdates { get; set; }
    internal double LastPresentation { get; set; } = double.NaN;
    internal long EvaluationCount { get; set; }
    internal List<SharedPhotoDrawing> PhotoDrawings { get; } = [];
    internal List<(Net.ScenePlacement Plan, FrameworkElement Image, ScaleTransform Scale, TranslateTransform Translation)> Photos { get; } = [];
    internal List<AmbientFrameVisual> Backgrounds { get; } = [];
}

public sealed partial class PhotoRenderer
{
    public bool ContinueShared(SharedVisual next, SharedVisual previous)
    {
        if (Current != previous.Scene || !next.Plan.Continues(previous.Plan)) return false;
        // Keep the presented canvases and surviving image elements. Only the
        // bounded schedule and prepared future replacements are exchanged.
        var terminal = previous.Photos.Where(p => p.Plan.VisibleUntil == previous.Plan.Duration).ToList();
        for (var index = 0; index < next.Photos.Count; index++)
        {
            var p = next.Photos[index];
            if (p.Plan.VisibleFrom != 0 || (p.Plan.FadeInSeconds ?? p.Plan.FadeSeconds) > 0) continue;
            var oldIndex = terminal.FindIndex(old => old.Plan.Asset == p.Plan.Asset && old.Plan.DisplayId == p.Plan.DisplayId
                && Math.Abs(old.Plan.ToX - p.Plan.FromX) < .001 && Math.Abs(old.Plan.ToY - p.Plan.FromY) < .001);
            if (oldIndex < 0) continue;
            var old = terminal[oldIndex]; terminal.RemoveAt(oldIndex);
            var parent = (Canvas)VisualTreeHelper.GetParent(p.Image);
            ((Canvas)VisualTreeHelper.GetParent(old.Image)).Children.Remove(old.Image);
            parent.Children.Remove(p.Image); parent.Children.Add(old.Image);
            next.Photos[index] = (p.Plan, old.Image, old.Scale, old.Translation);
        }
        foreach (var surface in next.Scene.Surfaces)
        {
            var held = previous.Scene.Surfaces.Single(s => s.DisplayId == surface.DisplayId);
            var foreground = surface.Foreground.Children.Cast<UIElement>().ToArray();
            surface.Foreground.Children.Clear(); held.Foreground.Children.Clear();
            foreach (var child in foreground) held.Foreground.Children.Add(child);
            var background = surface.Canvas.Children.Cast<UIElement>().Where(c => c != surface.Foreground).ToArray();
            surface.Canvas.Children.Clear(); held.Canvas.Children.Clear();
            foreach (var child in background) held.Canvas.Children.Add(child);
            held.Canvas.Children.Add(held.Foreground); held.Seconds = next.Plan.Duration;
            if (held.Drawing != null && surface.Drawing != null)
            {
                var drawings = surface.Drawing.Children.ToArray(); surface.Drawing.Children.Clear(); held.Drawing.Children.Clear();
                foreach (var drawing in drawings) held.Drawing.Children.Add(drawing);
            }
        }
        next.Scene = previous.Scene; next.Scene.Seconds = next.Plan.Duration; next.IsContinuation = true;
        return true;
    }
    public SharedVisual BuildShared(Net.SharedScenePlan plan, IReadOnlyDictionary<string, BitmapSource> images,
        IReadOnlyCollection<string> localDisplayIds) => SharedSceneBuilder.Build(plan, images, localDisplayIds);
    public void ShowShared(SharedVisual visual, SharedVisual? previous = null)
    {
        if (testPattern) Clear();
        if (visual.Optimized && views.Count == 0)
        {
            viewport = visual.Scene.Viewport;
            SetDisplayRegion(new(0, 0, viewport.Width, viewport.Height));
        }
        // Retain the actual outgoing tree and its presentation. Clearing and
        // rebuilding it exposes the empty backing canvas during a handoff.
        foreach (var scene in visibleScenes.Where(s => s != previous?.Scene && s != visual.Scene).ToArray())
        { DisposeBackground(scene); transitions.RemoveTree(scene.Canvas); layers.Children.Remove(scene.Canvas); RemovePresentation(scene); }
        void Attach(SceneVisual scene)
        {
            if (visibleScenes.Contains(scene)) return;
            layers.Children.Add(scene.Canvas); visibleScenes.Add(scene);
            foreach (var view in views) AddPresentation(view, scene);
        }
        if (previous != null) Attach(previous.Scene);
        viewport = visual.Scene.Viewport;
        layers.Width = viewport.Width; layers.Height = viewport.Height;
        if (VisualTreeHelper.GetParent(layers) is Canvas source) { source.Width = viewport.Width; source.Height = viewport.Height; }
        Attach(visual.Scene); Current = visual.Scene;
    }
    public void RemoveShared(SharedVisual visual) { layers.Children.Remove(visual.Scene.Canvas); RemovePresentation(visual.Scene); }
    public void PresentShared(SharedVisual visual, double elapsed)
    {
        if (!visual.Optimized) { PresentSharedReference(visual, elapsed); return; }
        var at = Math.Min(elapsed, visual.Plan.Duration - .00001);
        var seek = double.IsNaN(visual.LastPresentation) || at < visual.LastPresentation;
        visual.NextPhotoUpdates ??= Enumerable.Repeat(double.NegativeInfinity, visual.Photos.Count).ToArray();
        for (var i = 0; i < visual.Photos.Count; i++)
        {
            if (visual.Optimized && !seek && (at == visual.LastPresentation || at < visual.NextPhotoUpdates[i])) continue;
            var (p, image, scale, translation) = visual.Photos[i];
            if (visual.Optimized && (at < p.VisibleFrom || at >= p.VisibleUntil))
            {
                if (image.Opacity != 0) image.Opacity = 0;
                visual.PhotoDrawings[i].Hide(); visual.NextPhotoUpdates[i] = at < p.VisibleFrom ? p.VisibleFrom : double.PositiveInfinity;
                continue;
            }
            Net.SceneEvaluation.Evaluate(p, at, out var x, out var y, out var factor, out var opacity); visual.EvaluationCount++;
            // Internal Gallery replacements still fade. The last slot remains
            // visible until a prepared scene covers it, even after disconnection.
            if (p.VisibleUntil == visual.Plan.Duration && p.FadeSeconds > 0 && elapsed >= p.VisibleUntil - p.FadeSeconds)
                opacity = Math.Clamp((elapsed - p.VisibleFrom) / p.FadeSeconds, 0, 1);
            if (scale.ScaleX != factor) scale.ScaleX = factor;
            if (scale.ScaleY != factor) scale.ScaleY = factor;
            if (translation.X != x - p.Clip.X) translation.X = x - p.Clip.X;
            if (translation.Y != y - p.Clip.Y) translation.Y = y - p.Clip.Y;
            if (image.Opacity != opacity) image.Opacity = opacity;
            if (visual.Optimized)
            {
                visual.PhotoDrawings[i].Present(x, y, factor, opacity);
                visual.NextPhotoUpdates[i] = NextPhotoChange(p, at, visual.Plan.Duration);
            }
        }
        visual.LastPresentation = at;
        foreach (var background in visual.Backgrounds) background.Present(elapsed);
        var sceneOpacity = visual.IsContinuation || visual.Plan.FadeSeconds <= 0 ? 1 : Math.Clamp(elapsed / visual.Plan.FadeSeconds, 0, 1);
        if (visual.Scene.Canvas.Opacity != sceneOpacity) visual.Scene.Canvas.Opacity = sceneOpacity;
        if (visual.Scene.Drawing != null && visual.Scene.Drawing.Opacity != sceneOpacity) visual.Scene.Drawing.Opacity = sceneOpacity;
    }
    // Same-binary reference for offscreen parity and CLI measurements.
    private static void PresentSharedReference(SharedVisual visual, double elapsed)
    {
        foreach (var (p, image, scale, translation) in visual.Photos)
        {
            var value = Net.SceneEvaluation.Evaluate(p, Math.Min(elapsed, visual.Plan.Duration - .00001)); visual.EvaluationCount++;
            if (p.VisibleUntil == visual.Plan.Duration && p.FadeSeconds > 0 && elapsed >= p.VisibleUntil - p.FadeSeconds)
                value = value with { Opacity = Math.Clamp((elapsed - p.VisibleFrom) / p.FadeSeconds, 0, 1) };
            scale.ScaleX = scale.ScaleY = value.Scale;
            translation.X = value.X - p.Clip.X; translation.Y = value.Y - p.Clip.Y; image.Opacity = value.Opacity;
        }
        foreach (var background in visual.Backgrounds) background.Present(elapsed);
        visual.Scene.Canvas.Opacity = visual.IsContinuation || visual.Plan.FadeSeconds <= 0 ? 1 : Math.Clamp(elapsed / visual.Plan.FadeSeconds, 0, 1);
    }
    private static double NextPhotoChange(Net.ScenePlacement p, double at, double duration)
    {
        var moving = p.FromX != p.ToX || p.FromY != p.ToY || p.FromScale != p.ToScale;
        var fadeIn = p.FadeInSeconds ?? p.FadeSeconds; var fadeOut = p.FadeOutSeconds ?? p.FadeSeconds;
        if (moving && at >= p.StartSeconds && at < p.StartSeconds + p.MotionSeconds
            || fadeIn > 0 && at < p.VisibleFrom + fadeIn
            || fadeOut > 0 && at >= p.VisibleUntil - fadeOut) return double.NegativeInfinity;
        var next = p.VisibleUntil < duration ? p.VisibleUntil : double.PositiveInfinity;
        if (moving && p.StartSeconds > at) next = Math.Min(next, p.StartSeconds);
        if (fadeOut > 0 && p.VisibleUntil - fadeOut > at) next = Math.Min(next, p.VisibleUntil - fadeOut);
        return next;
    }
}

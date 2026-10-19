using System.Windows.Media.Imaging;
using Net = DynamicPhotoWall.Networking;

namespace DynamicPhotoWall.Rendering;

public sealed class SharedVisual
{
    public required SceneVisual Scene { get; set; }
    public required Net.SharedScenePlan Plan { get; init; }
    public required IReadOnlyDictionary<string, BitmapSource> Images { get; init; }
    internal bool IsContinuation { get; set; }
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
        }
        next.Scene = previous.Scene; next.Scene.Seconds = next.Plan.Duration; next.IsContinuation = true;
        return true;
    }
    public SharedVisual BuildShared(Net.SharedScenePlan plan, IReadOnlyDictionary<string, BitmapSource> images,
        IReadOnlyCollection<string> localDisplayIds) => SharedSceneBuilder.Build(plan, images, localDisplayIds);
    public void ShowShared(SharedVisual visual, SharedVisual? previous = null)
    {
        if (testPattern) Clear();
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
        foreach (var (p, image, scale, translation) in visual.Photos)
        {
            var value = Net.SceneEvaluation.Evaluate(p, Math.Min(elapsed, visual.Plan.Duration - .00001));
            // Internal Gallery replacements still fade. The last slot remains
            // visible until a prepared scene covers it, even after disconnection.
            if (p.VisibleUntil == visual.Plan.Duration && p.FadeSeconds > 0 && elapsed >= p.VisibleUntil - p.FadeSeconds)
                value = value with { Opacity = Math.Clamp((elapsed - p.VisibleFrom) / p.FadeSeconds, 0, 1) };
            scale.ScaleX = scale.ScaleY = value.Scale;
            translation.X = value.X - p.Clip.X; translation.Y = value.Y - p.Clip.Y; image.Opacity = value.Opacity;
        }
        foreach (var background in visual.Backgrounds) background.Present(elapsed);
        visual.Scene.Canvas.Opacity = visual.IsContinuation || visual.Plan.FadeSeconds <= 0 ? 1 : Math.Clamp(elapsed / visual.Plan.FadeSeconds, 0, 1);
    }
}

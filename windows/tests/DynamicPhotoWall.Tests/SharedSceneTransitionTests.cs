using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using DynamicPhotoWall.Core;
using DynamicPhotoWall.Motion;
using DynamicPhotoWall.Networking.Windows;
using DynamicPhotoWall.Rendering;
using Net = DynamicPhotoWall.Networking;

namespace DynamicPhotoWall.Tests;

// Inspect scene trees and timing only. Never show, render or capture a window.
internal static class SharedSceneTransitionTests
{
    private static readonly Guid local = Guid.NewGuid(), remote = Guid.NewGuid(), group = Guid.NewGuid(), session = Guid.NewGuid();
    private static readonly Net.SharedAssetKey asset = new(local, Guid.NewGuid(), Guid.NewGuid(), new string('a', 64));
    private static void Check(bool value, string message) { if (!value) throw new Exception(message); }
    private static Net.SharedScenePlan Plan(Net.SceneMode mode, bool individual = false, bool disconnected = false)
    {
        var offset = disconnected ? 0 : 400;
        Net.PeerDisplay[] localDisplays = [new(new(local, "left"), true, group, offset, 0, 400, 300), new(new(local, "right"), true, group, offset + 400, 0, 400, 300)];
        Net.PeerDisplay[] displays = disconnected ? localDisplays : [new(new(remote, "remote"), true, group, 0, 0, 400, 300), .. localDisplays];
        var width = disconnected ? 800 : 1200;
        var placements = individual ? localDisplays.Select((d, i) => Placement(i, d.Key.LayoutId, d.X, 400)).ToArray() : [Placement(0, null, 0, width)];
        var plan = new Net.SharedScenePlan(Guid.NewGuid(), group, session, 1, mode, new(width, 300), displays, 10, 1, "#000000", placements, []);
        plan.Validate(); return plan;
    }
    private static Net.ScenePlacement Placement(int id, string? display, double x, double width)
        => new(id, asset, display, new(x, 0, width, 300), width, 300, x, 0, x, 0, 1, 1, .5, .5, 0, 10, 0, 10, 1, 0, false);
    private static Dictionary<string, BitmapSource> Images()
    {
        var pixels = Enumerable.Range(0, 16).SelectMany(_ => new byte[] { 40, 80, 200, 255 }).ToArray();
        var bitmap = BitmapSource.Create(4, 4, 96, 96, PixelFormats.Bgra32, null, pixels, 16); bitmap.Freeze();
        return new() { [asset.OpaqueId] = bitmap };
    }
    private static SharedVisual Build(Net.SharedScenePlan plan, IReadOnlyDictionary<string, BitmapSource> images)
        => SharedSceneBuilder.Build(plan, images, plan.Displays.Where(d => d.Key.PeerId == local).Select(d => d.Key.LayoutId).ToArray());
    private static Canvas View(FrameworkElement element) => (Canvas)((Viewbox)element).Child;
    private static Rectangle Presentation(Canvas view, SharedVisual visual) => view.Children.OfType<Rectangle>().Single(r => r.Tag == visual.Scene);
    private static IEnumerable<Image> Photos(SharedVisual visual) => visual.Scene.Surfaces.SelectMany(s => s.Foreground.Children.OfType<Canvas>()).SelectMany(c => c.Children.OfType<Image>());

    public static Task PhysicalOutputsSurviveLogicalCanvasChanges()
    {
        var before = Plan(Net.SceneMode.Gallery);
        foreach (var mode in Enum.GetValues<Net.SceneMode>())
        {
            var after = Plan(mode, individual: true, disconnected: true);
            Check(PlaybackSurfaceLayout.CanReuse(before, after, local), "remote loss, canvas shrink and per-display modes must keep physical outputs");
            Check(PlaybackSurfaceLayout.CanReuse(after, before, local), "reconnection and canvas expansion must keep physical outputs");
            Check(PlaybackSurfaceLayout.CanReuse(before, after with { Displays = after.Displays.Reverse().ToArray(), SettingsRevision = 2 }, local), "inventory order and revisions do not own window lifetime");
            Check(!PlaybackSurfaceLayout.CanReuse(before, after with { Displays = after.Displays.Select((d, i) => i == 0 ? d with { Width = 500 } : d).ToArray() }, local), "actual output resolution changes require reconfiguration");
            Check(!PlaybackSurfaceLayout.CanReuse(before, after with { Displays = after.Displays.Skip(1).ToArray() }, local), "removing a local output requires reconfiguration");
        }
        return Task.CompletedTask;
    }

    public static Task HandoffsRetainTreesAndMapEachScenesOwnCanvas()
    {
        var images = Images(); var settings = new WallSettings { GlassBackground = false };
        foreach (var from in Enum.GetValues<Net.SceneMode>())
        foreach (var to in Enum.GetValues<Net.SceneMode>())
        {
            var renderer = new PhotoRenderer(new(1200, 300), settings, new TransitionController(), new AnimationScheduler());
            try
            {
                renderer.SetDisplayRegion(new(400, 0, 400, 300), new Net.PeerDisplayKey(local, "left").LayoutId);
                var primaryContent = renderer.Content;
                var output = renderer.CreateDisplayRegion(new(800, 0, 400, 300), new Net.PeerDisplayKey(local, "right").LayoutId);
                var view = View(output); var windows = Application.Current.Windows.Count;
                var old = Build(Plan(from), images); renderer.PresentShared(old, 2); renderer.ShowShared(old);
                var oldPresentation = Presentation(view, old); var oldParent = VisualTreeHelper.GetParent(old.Scene.Canvas);
                var next = Build(Plan(to, disconnected: true), images);
                Check(Application.Current.Windows.Count == windows, "preparing scenes must not create windows");
                renderer.PresentShared(next, 0); renderer.ShowShared(next, old);
                Check(ReferenceEquals(renderer.Content, primaryContent) && ReferenceEquals(((Viewbox)output).Child, view), "handoff retains output view objects");
                Check(ReferenceEquals(Presentation(view, old), oldPresentation) && ReferenceEquals(VisualTreeHelper.GetParent(old.Scene.Canvas), oldParent), "outgoing scene and presentation are never detached during a handoff");
                Check(old.Scene.Canvas.Opacity == 1 && next.Scene.Canvas.Opacity == 0, "an opaque old scene covers a transparent new first frame");
                Check(((VisualBrush)oldPresentation.Fill).Viewbox.X == 800 && ((VisualBrush)Presentation(view, next).Fill).Viewbox.X == 400,
                    "each scene crops its own canvas as a remote peer disappears");
                renderer.PresentShared(next, .5);
                Check(next.Scene.Canvas.Opacity == .5 && old.Scene.Canvas.Opacity == 1, "fade blends over a retained opaque scene");
                renderer.PresentShared(next, 2); renderer.RemoveShared(old);
                Check(view.Children.Count == 1 && VisualTreeHelper.GetParent(old.Scene.Canvas) == null, "old scene is released after the new scene is opaque");
                // Standalone/reconnect may change spanning into mirrors and back.
                var mirrored = Build(Plan(from, individual: true), images); renderer.PresentShared(mirrored, 0); renderer.ShowShared(mirrored, next);
                Check(view.Children.Count == 2 && Presentation(view, mirrored) != null && next.Scene.Canvas.Opacity == 1, "mirrors keep the spanning predecessor visible");
                var resumed = Build(Plan(to), images); renderer.PresentShared(resumed, 0); renderer.ShowShared(resumed, mirrored);
                Check(view.Children.Count == 2 && Presentation(view, mirrored) != null && Presentation(view, resumed) != null, "rapid replacements prune only the obsolete predecessor");
                try { Build(Plan(to), new Dictionary<string, BitmapSource>()); Check(false, "missing original must fail preparation"); }
                catch (KeyNotFoundException) { Check(renderer.Current == resumed.Scene && view.Children.Count == 2, "failed preparation leaves the current trees intact"); }
            }
            finally { renderer.Clear(); renderer.Close(); }
        }
        return Task.CompletedTask;
    }

    public static Task GalleryEndpointAndIsolationRepeatKeepCoverage()
    {
        var images = Images(); var renderer = new PhotoRenderer(new(1200, 300), new WallSettings(), new TransitionController(), new AnimationScheduler());
        try
        {
            var plan = Plan(Net.SceneMode.Gallery);
            plan = plan with { Placements = [plan.Placements[0] with { VisibleUntil = 5 }, plan.Placements[0] with { Id = 1, VisibleFrom = 4 }] };
            var old = Build(plan, images); var photos = Photos(old).ToArray();
            renderer.PresentShared(old, 4.5);
            Check(photos[0].Opacity == .5 && photos[1].Opacity == .5, "internal Gallery replacements retain their fades");
            renderer.PresentShared(old, 9.5);
            Check(photos[0].Opacity == 0 && photos[1].Opacity == 1, "the final Gallery slot does not fade to black before a handoff");
            renderer.PresentShared(old, 70); renderer.ShowShared(old);
            Check(photos[1].Opacity == 1 && old.Scene.Canvas.Opacity == 1, "a delayed replacement holds the terminal photo and background");
            var repeat = Build(plan, images); renderer.PresentShared(repeat, 0); renderer.ShowShared(repeat, old);
            Check(repeat.Scene.Canvas.Opacity == 0 && old.Scene.Canvas.Opacity == 1 && VisualTreeHelper.GetParent(old.Scene.Canvas) != null,
                "isolation repeats fade over a retained endpoint instead of resetting an empty canvas");
        }
        finally { renderer.Clear(); renderer.Close(); }
        return Task.CompletedTask;
    }
}

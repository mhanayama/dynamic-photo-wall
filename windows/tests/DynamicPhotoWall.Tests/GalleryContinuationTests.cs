using DynamicPhotoWall.Core;
using DynamicPhotoWall.Networking.Windows;
using DynamicPhotoWall.Rendering;
using DynamicPhotoWall.Motion;
using System.Windows.Media.Imaging;
using System.Windows.Media;
using System.Text.Json;
using Net = DynamicPhotoWall.Networking;

namespace DynamicPhotoWall.Tests;

internal static class GalleryContinuationTests
{
    private static void Check(bool value, string message) { if (!value) throw new Exception(message); }

    // Advance shared time without creating windows, decoding photos or waiting in real time.
    public static async Task Run()
    {
        var local = Guid.NewGuid(); var remote = Guid.NewGuid(); var group = Guid.NewGuid();
        var source = Guid.NewGuid(); var generation = Guid.NewGuid();
        var photos = Enumerable.Range(0, 12).Select(i => new Net.SharedPhoto(
            new(local, source, generation, i.ToString("x64")), 600, 1800, 1,
            new(1, 600, 1800, "fixture", "1", Net.FaceAnalysisState.Complete, []))).ToArray();
        Net.PeerDisplay[] displays = [new(new(local, "a"), true, group, 0, 0, 1920, 1080),
            new(new(remote, "b"), true, group, 1920, 0, 1920, 1080)];
        var bitmap = BitmapSource.Create(1, 1, 96, 96, PixelFormats.Bgra32, null, new byte[] { 20, 60, 160, 255 }, 4); bitmap.Freeze();
        var images = photos.ToDictionary(p => p.Key.OpaqueId, _ => (BitmapSource)bitmap);
        foreach (var scroll in new[] { false, true })
        foreach (var perDisplay in new[] { false, true })
        {
            var settings = new WallSettings { GalleryEnabled = !scroll, GalleryScrollEnabled = scroll,
                VerticalPanEnabled = false, HorizontalPanEnabled = false, ZoomEnabled = false,
                GalleryPerDisplay = perDisplay, GalleryScrollPerDisplay = perDisplay, GlassBackground = false };
            var wall = new Net.WallSnapshot(Guid.NewGuid(), Guid.NewGuid(), local, 1, [new(group, "gallery")], displays,
                [new(local, source, generation)], WindowsPlaybackOptions.Export(settings));
            var planner = new WindowsScenePlanner(_ => throw new Exception("planning must not decode images"));
            var clock = new Clock(); var output = new Output();
            var coordinator = new Net.SceneCoordinator(planner, output, clock);
            Net.SharedScenePlan? previous = null; SharedVisual? previousVisual = null; var previousEnd = 0d; double? lastReplacement = null;
            var renderer = new PhotoRenderer(new(3840, 1080), settings, new TransitionController(), new AnimationScheduler());
            try
            {
                for (var round = 0; round < 100; round++)
                {
                    await coordinator.PumpAsync(local, wall, [local, remote], photos, CancellationToken.None);
                    Check(output.Prepared.Count == round + 1, $"shared gallery must renew: scroll={scroll}, perDisplay={perDisplay}, round={round}");
                    var plan = output.Prepared[^1]; plan.Validate();
                    var roundtrip = JsonSerializer.Deserialize<Net.SharedScenePlan>(JsonSerializer.Serialize(plan, Net.PeerProtocol.Json), Net.PeerProtocol.Json)!;
                    roundtrip.Validate();
                    Check(roundtrip.ContinuationOf == plan.ContinuationOf && roundtrip.GallerySchedule?.NextChangeSeconds == plan.GallerySchedule?.NextChangeSeconds,
                        "continuation identity and replacement timing survive the shared wire contract");
                    Check(plan.Id != previous?.Id && plan.Mode == (scroll ? Net.SceneMode.GalleryScroll : Net.SceneMode.Gallery), "renewal preserves the enabled mode with a new plan");
                    Check(plan.Placements.Any(p => scroll ? p.FromX != p.ToX : p.VisibleFrom > 0), "every renewed plan continues moving or replacing photos");
                    Check(plan.Placements.Select(p => p.DisplayId).Distinct().Count() == (perDisplay ? 2 : 1), "renewal retains per-display routing");
                    Check(output.Commits.Count == round, "all displays must be ready before committing");
                    await coordinator.Ready(remote, new(plan.Id, group));
                    Check(output.Commits.Count == round + 1, "each renewed plan commits after readiness");
                    var commit = output.Commits[^1];
                    var visual = SharedSceneBuilder.Build(plan, images, displays.Select(d => d.Key.LayoutId).ToArray());
                    if (previous != null)
                    {
                        Check(plan.Continues(previous) && Math.Abs(commit.StartAt - previousEnd) < .000001, "a gallery continues exactly at its boundary, without restarting early");
                        CheckBoundary(previous, plan);
                        var root = previousVisual!.Scene;
                        var oldImages = previousVisual.Photos.Where(p => p.Plan.VisibleUntil == previous.Duration).ToArray();
                        renderer.PresentShared(previousVisual, previous.Duration - .00001);
                        Check(renderer.ContinueShared(visual, previousVisual), "a continued schedule must reuse the displayed gallery");
                        Check(ReferenceEquals(visual.Scene, root), "renewal must retain the gallery canvas");
                        foreach (var p in visual.Photos.Where(p => p.Plan.VisibleFrom == 0 && (p.Plan.FadeInSeconds ?? p.Plan.FadeSeconds) == 0
                            && p.Plan.FromX < p.Plan.Clip.X + p.Plan.Clip.Width && p.Plan.FromX + p.Plan.Width > p.Plan.Clip.X))
                            Check(oldImages.Any(old => ReferenceEquals(old.Image, p.Image)), "surviving photographs keep their image elements");
                    }
                    renderer.PresentShared(visual, 0);
                    if (previous != null) Check(visual.Scene.Canvas.Opacity == 1, "renewal must never fade the whole gallery");
                    renderer.ShowShared(visual);
                    if (!scroll)
                        foreach (var at in plan.Placements.Where(p => p.FadeInSeconds > 0).Select(p => p.VisibleFrom).Distinct().Order())
                        {
                            var time = commit.StartAt + at;
                            if (lastReplacement != null) Check(time - lastReplacement >= settings.FadeSeconds + settings.GalleryMinSeconds - .00001
                                && time - lastReplacement <= settings.FadeSeconds + settings.GalleryMaxSeconds + .00001,
                                "planning boundaries preserve the individual replacement interval");
                            lastReplacement = time;
                        }
                    previousEnd = commit.StartAt + plan.Duration;
                    previous = plan; previousVisual = visual;
                    clock.Time = previousEnd - 4 + .001;
                }
                Check(clock.Time >= 2 * 60 * 60, "the simulated session crosses two hours without changing settings or mode history");
                await coordinator.Control("pause"); clock.Time += 60;
                await coordinator.Control("resume");
                await coordinator.PumpAsync(local, wall, [local, remote], photos, CancellationToken.None);
                var resumed = output.Prepared[^1];
                Check(resumed.Continues(previous!), "pause and resume retain the displayed gallery");
                await coordinator.Ready(remote, new(resumed.Id, group));
                Check(Math.Abs(output.Commits[^1].StartAt - previousEnd - 60) < .000001, "a pause moves the continuation boundary without resetting it");
                await coordinator.Control("next");
                await coordinator.PumpAsync(local, wall, [local, remote], photos, CancellationToken.None);
                Check(output.Prepared[^1].ContinuationOf == null, "explicit Next still requests a new composition");
                await coordinator.Ready(remote, new(output.Prepared[^1].Id, group));
                var changed = wall with { Revision = wall.Revision + 1 };
                await coordinator.PumpAsync(local, changed, [local, remote], photos, CancellationToken.None);
                Check(output.Prepared[^1].SettingsRevision == changed.Revision && output.Prepared[^1].ContinuationOf == null,
                    "settings changes build a new composition instead of continuing stale state");
            }
            finally { renderer.Clear(); renderer.Close(); }
        }
    }

    private static void CheckBoundary(Net.SharedScenePlan previous, Net.SharedScenePlan next)
    {
        var endpoint = previous.Placements.Where(p => p.VisibleUntil == previous.Duration
            && p.ToX + p.Width > p.Clip.X && p.ToX < p.Clip.X + p.Clip.Width).ToArray();
        var initial = next.Placements.Where(p => Net.SceneEvaluation.Evaluate(p, 0).Opacity > 0
            && p.FromX + p.Width > p.Clip.X && p.FromX < p.Clip.X + p.Clip.Width).ToArray();
        Check(endpoint.Length == initial.Length, "renewal must preserve every visible photo, without redrawing the collection");
        foreach (var old in endpoint)
            Check(initial.Any(p => p.Asset == old.Asset && p.DisplayId == old.DisplayId
                && Math.Abs(p.FromX - old.ToX) < .000001 && Math.Abs(p.FromY - old.ToY) < .000001
                && p.Width == old.Width && p.Height == old.Height), "renewal must preserve photo identity, position and size");
    }

    private sealed class Clock : Net.ISharedClock
    {
        public double Time;
        public double Now => Time;
        public double Elapsed => Time;
        public void Observe(double sentAt, double remoteReceived, double remoteReplied, double receivedAt) { }
    }
    private sealed class Output : Net.IPlaybackOutput
    {
        public List<Net.SharedScenePlan> Prepared { get; } = [];
        public List<Net.SceneCommit> Commits { get; } = [];
        public Task PrepareAsync(Net.SharedScenePlan plan, CancellationToken token) { Prepared.Add(plan); return Task.CompletedTask; }
        public void Commit(Net.SceneCommit commit) => Commits.Add(commit);
        public void Control(string operation, double effectiveAt) { }
        public void SetRecovery(Net.PeerPlaybackState state, Net.WallSnapshot wall) { }
        public Task StopAsync() => Task.CompletedTask;
    }
}

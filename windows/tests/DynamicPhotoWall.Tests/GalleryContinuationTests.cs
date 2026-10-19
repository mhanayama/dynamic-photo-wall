using DynamicPhotoWall.Core;
using DynamicPhotoWall.Networking.Windows;
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
            Guid? previous = null; var previousEnd = 0d;
            for (var round = 0; round < 100; round++)
            {
                await coordinator.PumpAsync(local, wall, [local, remote], photos, CancellationToken.None);
                Check(output.Prepared.Count == round + 1, $"shared gallery must renew: scroll={scroll}, perDisplay={perDisplay}, round={round}");
                var plan = output.Prepared[^1]; plan.Validate();
                Check(plan.Id != previous && plan.Mode == (scroll ? Net.SceneMode.GalleryScroll : Net.SceneMode.Gallery), "renewal preserves the enabled mode with a new plan");
                Check(plan.Placements.Any(p => scroll ? p.FromX != p.ToX : p.VisibleFrom > 0), "every renewed plan continues moving or replacing photos");
                Check(plan.Placements.Select(p => p.DisplayId).Distinct().Count() == (perDisplay ? 2 : 1), "renewal retains per-display routing");
                Check(output.Commits.Count == round, "all displays must be ready before committing");
                await coordinator.Ready(remote, new(plan.Id, group));
                Check(output.Commits.Count == round + 1, "each renewed plan commits after readiness");
                var commit = output.Commits[^1];
                if (round > 0) Check(commit.StartAt < previousEnd, "the successor starts before the old plan expires");
                previousEnd = commit.StartAt + plan.Duration;
                previous = plan.Id;
                clock.Time = commit.StartAt + plan.Duration - 4;
            }
            Check(clock.Time >= 2 * 60 * 60, "the simulated session crosses two hours without changing settings or mode history");
        }
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

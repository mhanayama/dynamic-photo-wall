using DynamicPhotoWall.DesktopIntegration;
using DynamicPhotoWall.Motion;
using DynamicPhotoWall.Rendering;
using Net = DynamicPhotoWall.Networking;

namespace DynamicPhotoWall.Networking.Windows;

// Layout diagnostics are an overlay with their own lifetime. Playback time,
// pause/stop and the committed settings are never modified by a preview.
internal sealed class WindowsLayoutPreview(Guid local) : IDisposable
{
    private readonly List<(DesktopWindowHost Host, PhotoRenderer Renderer)> outputs = [];
    private Net.LayoutPreviewPlan? pending;
    public bool Visible => outputs.Count > 0;
    public event Action? Changed;
    public void Schedule(Net.LayoutPreviewPlan plan) => pending = plan;
    public void Update(double now)
    {
        if (pending is { } plan && plan.EffectiveAt <= now)
        {
            pending = null; Clear();
            if (plan.Enabled)
            {
                foreach (var unit in plan.Displays.Where(d => d.Selected).GroupBy(d => d.GroupId ?? Net.SceneCoordinator.StandaloneId(d.Key)))
                {
                    var placements = unit.Select(d => new DisplayPlacement { Id = d.Key.LayoutId, X = d.X, Y = d.Y, Width = d.Width, Height = d.Height }).ToArray();
                    var layout = new WallLayout(placements);
                    var name = plan.Groups.FirstOrDefault(g => g.Id == unit.Key)?.Name;
                    foreach (var display in unit.Where(d => d.Key.PeerId == local))
                    {
                        var monitor = MonitorManager.Enumerate().FirstOrDefault(m => m.Id == display.Key.DisplayId); if (monitor == null) continue;
                        var renderer = new PhotoRenderer(layout.Viewport, new WallSettings(), new TransitionController(), new AnimationScheduler());
                        renderer.ShowTestPattern(layout, name, placements.Select(p => p.Id).ToArray());
                        renderer.SetDisplayRegion(layout.Regions[display.Key.LayoutId], display.Key.LayoutId);
                        var host = new DesktopWindowHost(); host.Attach(renderer, monitor); outputs.Add((host, renderer));
                    }
                }
            }
            Changed?.Invoke();
        }
        foreach (var item in outputs) item.Host.EnsureZOrder();
    }
    private void Clear() { foreach (var item in outputs) { item.Host.Dispose(); item.Renderer.Clear(); item.Renderer.Close(); } outputs.Clear(); }
    public void Dispose() { pending = null; Clear(); }
}

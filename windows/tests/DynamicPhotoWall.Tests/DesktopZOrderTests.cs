using DynamicPhotoWall.DesktopIntegration;

namespace DynamicPhotoWall.Tests;

// Model the native sibling chain; never create or manipulate desktop windows.
internal static class DesktopZOrderTests
{
    public static Task StableOutputsAndRepair()
    {
        const int icons = 1, wallpaper = 2, preview = 3;
        nint[] outputs = [10, 11, 12, 13];
        List<nint> siblings = [icons, preview, 90, .. outputs, wallpaper, 91];
        var moves = 0;
        var order = new DesktopZOrder(window =>
        {
            var index = siblings.IndexOf(window);
            return index >= 0 && index + 1 < siblings.Count ? siblings[index + 1] : 0;
        }, (window, after) =>
        {
            moves++; siblings.Remove(window); siblings.Insert(siblings.IndexOf(after) + 1, window);
        });
        void Check(bool value, string message) { if (!value) throw new Exception(message); }
        void Frames()
        {
            for (var frame = 0; frame < 600; frame++)
            {
                order.Ensure(preview, icons, wallpaper);
                foreach (var output in outputs) order.Ensure(output, icons, wallpaper);
            }
        }

        var original = siblings.ToArray(); Frames();
        Check(moves == 0 && siblings.SequenceEqual(original), "online frames must preserve every valid output, preview and Explorer sibling without SetWindowPos");

        // Explorer can move an output behind the wallpaper or above the icons.
        foreach (var behindWallpaper in new[] { true, false })
        {
            var output = outputs[1]; siblings.Remove(output);
            siblings.Insert(behindWallpaper ? siblings.Count : 0, output);
            var others = siblings.Where(h => h != output).ToArray(); var before = moves;
            order.Ensure(output, icons, wallpaper);
            Check(moves == before + 1 && order.IsBefore(icons, output) && order.IsBefore(output, wallpaper), "an invalid output is repaired once");
            Check(siblings.Where(h => h != output).SequenceEqual(others), "repair must preserve all other Explorer and photo siblings");
            Frames(); Check(moves == before + 1, "repaired outputs must remain stable across later frames");
        }

        // Missing wallpaper handles still permit checking the icon boundary.
        var stable = moves;
        foreach (var output in outputs) order.Ensure(output, icons, 0);
        Check(moves == stable, "a missing wallpaper handle must not force repeated native reordering");

        var broken = new DesktopZOrder(window => window == icons ? wallpaper : window == wallpaper ? outputs[0] : 0, (_, _) => { });
        try { broken.Ensure(outputs[0], icons, wallpaper); throw new Exception("a failed repair must be reported"); }
        catch (InvalidOperationException) { }
        return Task.CompletedTask;
    }
}

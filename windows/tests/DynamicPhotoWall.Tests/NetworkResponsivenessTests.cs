using System.Windows.Threading;
using System.IO;
using System.Security.Cryptography;
using DynamicPhotoWall.Configuration;
using DynamicPhotoWall.Core;
using DynamicPhotoWall.Networking.Windows;

namespace DynamicPhotoWall.Tests;

internal static class NetworkResponsivenessTests
{
    // Runs the dispatcher, without opening or capturing any GUI window.
    public static async Task NotificationsYieldToInput()
    {
        var dispatcher = Dispatcher.CurrentDispatcher; var refreshed = 0;
        using var updates = new DispatcherUpdateQueue(dispatcher, () => refreshed++);
        for (var i = 0; i < 100000; i++) updates.Request();
        var inputRan = false;
        await dispatcher.InvokeAsync(() => inputRan = true, DispatcherPriority.Input);
        if (!inputRan || refreshed != 0) throw new Exception("Photo progress refreshes must yield to user input");
        for (var i = 0; i < 300 && refreshed == 0; i++) await Task.Delay(10);
        if (refreshed != 1) throw new Exception("A burst must produce one UI refresh");
        updates.Request(); updates.Dispose();
        await Task.Delay(200);
        if (refreshed != 1) throw new Exception("Disposed network hosts must ignore pending UI updates");
    }
    public static async Task CachedOriginalSkipsFaceAnalysis(string root)
    {
        var folder = Path.Combine(root, "cached-provider"); Directory.CreateDirectory(folder);
        var path = Path.Combine(folder, "synthetic-original.jpg"); var bytes = new byte[] { 1, 2, 3, 4, 5 };
        await File.WriteAllBytesAsync(path, bytes);
        var file = new FileInfo(path); var peer = Guid.NewGuid(); var generation = Guid.NewGuid(); var probes = 0;
        var settings = new WallSettings { Folders = [folder] };
        var provider = new WindowsPhotoProvider(peer, () => settings,
            () => [new PhotoInfo(path, 6000, 4000, 1, null, file.Length, file.LastWriteTimeUtc.Ticks)], key =>
            {
                probes++;
                if (key.ImageId != Convert.ToHexStringLower(SHA256.HashData(bytes))) throw new Exception("Incorrect content hash");
                return true;
            });
        var selected = new DynamicPhotoWall.Networking.SourceSelection(peer, provider.Sources.Single().SourceId, generation);
        var imported = 0;
        await foreach (var _ in provider.ReadAsync(selected, CancellationToken.None)) imported++;
        if (imported != 0 || probes != 1) throw new Exception("A restarted provider should query the existing cache before decoding or face analysis");
        await foreach (var _ in provider.ReadAsync(selected, CancellationToken.None)) imported++;
        if (imported != 0 || probes != 2) throw new Exception("The next scan should reuse the recovered file fingerprint");
    }
}

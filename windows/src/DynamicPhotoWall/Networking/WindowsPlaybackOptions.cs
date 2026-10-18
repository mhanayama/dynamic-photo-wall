using System.Text.Json;
using Net = DynamicPhotoWall.Networking;

namespace DynamicPhotoWall.Networking.Windows;

public static class WindowsPlaybackOptions
{
    // The allow-list is the neutral DTO. Folder paths, taskbar and startup settings never leave the peer.
    public static Net.PlaybackOptions Export(WallSettings settings)
    {
        var local = JsonSerializer.SerializeToElement(settings, new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase });
        var allowed = typeof(Net.PlaybackOptions).GetProperties().Select(p => JsonNamingPolicy.CamelCase.ConvertName(p.Name)).ToHashSet();
        var map = local.EnumerateObject().Where(p => allowed.Contains(p.Name)).ToDictionary(p => p.Name, p => p.Value.Clone());
        return JsonSerializer.Deserialize<Net.PlaybackOptions>(JsonSerializer.Serialize(map), Net.PeerProtocol.Json)!;
    }
    public static WallSettings Import(Net.PlaybackOptions options)
    {
        var settings = JsonSerializer.Deserialize<WallSettings>(JsonSerializer.Serialize(options, Net.PeerProtocol.Json),
            new JsonSerializerOptions { PropertyNameCaseInsensitive = true })!;
        settings.Normalize(); return settings;
    }
    public static void Apply(Net.PlaybackOptions options, WallSettings destination)
    {
        var common = Import(options);
        foreach (var property in typeof(Net.PlaybackOptions).GetProperties())
        {
            var target = typeof(WallSettings).GetProperty(property.Name);
            if (target != null) target.SetValue(destination, target.GetValue(common));
        }
    }
}

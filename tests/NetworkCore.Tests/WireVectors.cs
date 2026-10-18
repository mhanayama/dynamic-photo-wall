using System.Security.Cryptography;
using System.Text.Json;
using DynamicPhotoWall.Networking;

internal static class WireVectors
{
    public static void Export(string directory)
    {
        Directory.CreateDirectory(directory);
        var masterKey = Enumerable.Range(0, 32).Select(i => (byte)i).ToArray();
        var original = Enumerable.Range(0, 4097).Select(i => (byte)(i * 31)).ToArray();
        var a = Guid.Parse("10000000-0000-0000-0000-000000000001");
        var b = Guid.Parse("10000000-0000-0000-0000-000000000002");
        var source = Guid.Parse("30000000-0000-0000-0000-000000000001");
        var generation = Guid.Parse("40000000-0000-0000-0000-000000000001");
        var group = Guid.Parse("20000000-0000-0000-0000-000000000001");
        var photo = new SharedPhoto(new(a, source, generation, Convert.ToHexStringLower(SHA256.HashData(original))), 6000, 4000, original.Length,
            new(1, 6000, 4000, "synthetic-vector", "1", FaceAnalysisState.Complete, [new(.1, .2, .3, .4)]));
        var now = new DateTimeOffset(2026, 10, 18, 0, 0, 0, TimeSpan.Zero);
        var cacheRoot = Path.Combine(directory, "encrypted-vector");
        using var cache = new EncryptedPhotoCache(cacheRoot, masterKey);
        cache.ActivateGeneration(a, generation); cache.Put(photo, new MemoryStream(original), now);
        var encrypted = File.ReadAllBytes(Path.Combine(cacheRoot, a.ToString("N"), generation.ToString("N"), photo.Key.OpaqueId + ".pwc"));
        var displays = new[] { new PeerDisplay(new(a, "screen1"), true, group, 0, 0, 1920, 1080) { Name = "DELL U2723QE" },
            new PeerDisplay(new(b, "screen1"), true, group, 1920, 0, 1920, 1080) { Name = "Studio Display" } };
        var wall = new WallSnapshot(Guid.Parse("50000000-0000-0000-0000-000000000001"), Guid.Parse("60000000-0000-0000-0000-000000000001"), a, 1,
            [new(group, "shared wall")], displays, [new(a, source, generation)], new()) { AppliedRequests = [Guid.Parse("70000000-0000-0000-0000-000000000001")] };
        var scene = new SharedScenePlan(Guid.Parse("80000000-0000-0000-0000-000000000001"), group, wall.SessionId, wall.Revision, SceneMode.HorizontalPan,
            new(3840, 1080), displays, 20, 1.2, "#101116",
            [new(0, photo.Key, null, new(0, 0, 3840, 1080), 5000, 1080, 0, 0, -200, 0, 1, 1, .5, .5, 0, 20, 0, 20, 0, 0, false)], []);
        var result = new { version = 1, masterKey, original, encrypted, now, photo, wall, scene, packet = PeerPacket.Create("scenePrepare", scene),
            opaqueId = photo.Key.OpaqueId, layoutId = displays[0].Key.LayoutId };
        File.WriteAllText(Path.Combine(directory, "NetworkWire.v1.json"), JsonSerializer.Serialize(result, new JsonSerializerOptions(PeerProtocol.Json) { WriteIndented = true }));
    }
    public static void Verify(string root)
    {
        using var json = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Fixtures", "NetworkWire.v1.json")));
        var value = json.RootElement;
        var photo = value.GetProperty("photo").Deserialize<SharedPhoto>(PeerProtocol.Json)!; photo.Validate();
        value.GetProperty("wall").Deserialize<WallSnapshot>(PeerProtocol.Json)!.Validate();
        value.GetProperty("scene").Deserialize<SharedScenePlan>(PeerProtocol.Json)!.Validate();
        using var cache = new EncryptedPhotoCache(root, value.GetProperty("masterKey").GetBytesFromBase64());
        cache.ActivateGeneration(photo.Key.ProviderId, photo.Key.GenerationId);
        var path = Path.Combine(root, photo.Key.ProviderId.ToString("N"), photo.Key.GenerationId.ToString("N"), photo.Key.OpaqueId + ".pwc");
        File.WriteAllBytes(path, value.GetProperty("encrypted").GetBytesFromBase64());
        var found = cache.Read(photo.Key, value.GetProperty("now").GetDateTimeOffset())!;
        if (!found.Image.SequenceEqual(value.GetProperty("original").GetBytesFromBase64())) throw new Exception("Shared cache vector differs");
    }
}

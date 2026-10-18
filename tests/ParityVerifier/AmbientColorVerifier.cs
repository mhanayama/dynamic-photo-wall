using System.Text.Json;
using DynamicPhotoWall.Rendering;

internal static class AmbientColorVerifier
{
    internal sealed record Sample(string Name, int[] Rgba, int[] Expected);
    internal sealed record Fixture(int Version, Sample[] Cases);
    private static int[] Enhance(int[] rgba)
    {
        byte[] bgra = [(byte)rgba[2], (byte)rgba[1], (byte)rgba[0], (byte)rgba[3]];
        AmbientPixels.EnhanceColors(bgra);
        return [bgra[2], bgra[1], bgra[0], bgra[3]];
    }
    public static void Run(string[] args, JsonSerializerOptions options)
    {
        var path = args.Last(a => !a.StartsWith("--"));
        if (args.Contains("--generate"))
        {
            (string Name, int[] Rgba)[] colors = [
                ("warm", [200, 80, 40, 255]), ("cool", [40, 80, 200, 255]),
                ("neutral", [100, 100, 100, 255]), ("black", [0, 0, 0, 255]),
                ("white", [255, 255, 255, 255]), ("red-gamut", [255, 20, 10, 255]),
                ("highlight", [250, 230, 180, 255]), ("dark", [20, 30, 10, 255]),
                ("transparent", [0, 0, 0, 0]), ("partial-warm", [100, 40, 20, 128]),
                ("partial-neutral", [50, 50, 50, 128]), ("tiny-alpha", [1, 0, 0, 1])];
            File.WriteAllText(path, JsonSerializer.Serialize(new Fixture(1, colors.Select(c => new Sample(c.Name, c.Rgba, Enhance(c.Rgba))).ToArray()), options));
        }
        var fixture = JsonSerializer.Deserialize<Fixture>(File.ReadAllBytes(path), options)!;
        foreach (var sample in fixture.Cases)
            if (!Enhance(sample.Rgba).SequenceEqual(sample.Expected)) throw new Exception($"Ambient color differs: {sample.Name}");
        Console.WriteLine($"PASS: {fixture.Cases.Length} ambient color cases against Windows production code (no WPF or GUI).");
    }
}

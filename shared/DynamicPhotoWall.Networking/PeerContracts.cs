using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Diagnostics.CodeAnalysis;

namespace DynamicPhotoWall.Networking;

// Versioned DTOs contain identifiers and geometry, never local paths or credentials.
public static class PeerProtocol
{
    public const int Version = 1;
    public static JsonSerializerOptions Json { get; } = CreateJson();

    private static JsonSerializerOptions CreateJson()
    {
        var options = new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
            MaxDepth = 32
        };
        options.Converters.Add(new JsonStringEnumConverter(JsonNamingPolicy.CamelCase, allowIntegerValues: false));
        options.MakeReadOnly(populateMissingResolver: true);
        return options;
    }

    internal static void Require([DoesNotReturnIf(false)] bool condition, string message)
    {
        if (!condition) throw new InvalidDataException(message);
    }
}

public sealed record PeerHello(int ProtocolVersion, Guid PeerId, string Name, string Platform)
{
    public void Validate()
    {
        PeerProtocol.Require(ProtocolVersion == PeerProtocol.Version, "Unsupported peer protocol version.");
        PeerProtocol.Require(PeerId != Guid.Empty, "Missing peer identity.");
        PeerProtocol.Require(!string.IsNullOrWhiteSpace(Name) && Name.Length <= 128, "Invalid peer name.");
        PeerProtocol.Require(Platform is "windows" or "macos", "Unsupported peer platform.");
    }
}

public sealed record PeerDisplayKey(Guid PeerId, string DisplayId)
{
    public void Validate()
    {
        PeerProtocol.Require(PeerId != Guid.Empty && !string.IsNullOrWhiteSpace(DisplayId) && DisplayId.Length <= 256,
            "Invalid display identity.");
    }

    // Length prefix prevents delimiter collisions in OS display identifiers.
    [JsonIgnore] public string LayoutId => $"{PeerId:N}:{DisplayId.Length}:{DisplayId}";
}

public sealed record PeerDisplay(PeerDisplayKey Key, bool Selected, Guid? GroupId, int X, int Y, int Width, int Height)
{
    public string? Name { get; init; }
    [JsonIgnore] public string DisplayName => string.IsNullOrWhiteSpace(Name) ? "ディスプレイ" : Name;
    public void Validate()
    {
        PeerProtocol.Require(Key != null, "Missing display identity.");
        Key!.Validate();
        PeerProtocol.Require(Name == null || Name.Length <= 256, "Invalid display name.");
        PeerProtocol.Require(GroupId != Guid.Empty && Width > 0 && Height > 0, "Invalid display placement.");
    }
}

public static class PeerGroupLayout
{
    public static PeerCanvasLayout Create(Guid groupId, IReadOnlyList<PeerDisplay> displays)
    {
        PeerProtocol.Require(groupId != Guid.Empty, "Missing group identity.");
        foreach (var display in displays) display.Validate();
        PeerProtocol.Require(displays.Select(d => d.Key).Distinct().Count() == displays.Count, "Duplicate display identity.");
        var members = displays.Where(d => d.Selected && d.GroupId == groupId).ToArray();
        PeerProtocol.Require(members.Length > 0, "Group has no selected displays.");
        var left = members.Min(d => (long)d.X); var top = members.Min(d => (long)d.Y);
        var width = members.Max(d => (long)d.X + d.Width) - left;
        var height = members.Max(d => (long)d.Y + d.Height) - top;
        PeerProtocol.Require(width <= 32768 && height <= 32768, "Canvas exceeds 32768 pixels.");
        return new(new(width, height), members.ToDictionary(d => d.Key.LayoutId,
            d => new FrameRect(d.X - left, d.Y - top, d.Width, d.Height)));
    }
}

public sealed record FaceRegion(double X, double Y, double Width, double Height);
public sealed record Viewport(double Width, double Height);
public sealed record FrameRect(double X, double Y, double Width, double Height);
public sealed record PeerCanvasLayout(Viewport Viewport, IReadOnlyDictionary<string, FrameRect> Regions);

public enum FaceAnalysisState { Pending, Complete, Failed }

public sealed record SharedFaceMetadata(int Version, int PixelWidth, int PixelHeight, string Detector,
    string DetectorVersion, FaceAnalysisState State, FaceRegion[] Faces)
{
    public void Validate()
    {
        PeerProtocol.Require(Version == 1 && PixelWidth > 0 && PixelHeight > 0, "Invalid face metadata version or dimensions.");
        PeerProtocol.Require(!string.IsNullOrWhiteSpace(Detector) && Detector.Length <= 128
            && !string.IsNullOrWhiteSpace(DetectorVersion) && DetectorVersion.Length <= 128, "Missing detector version.");
        PeerProtocol.Require(Enum.IsDefined(State) && Faces != null && Faces.Length <= 4096, "Invalid face analysis result.");
        PeerProtocol.Require(State == FaceAnalysisState.Complete || Faces!.Length == 0, "Unfinished analysis cannot contain faces.");
        foreach (var face in Faces!)
            PeerProtocol.Require(face != null && double.IsFinite(face.X + face.Y + face.Width + face.Height)
                && face.X >= 0 && face.Y >= 0 && face.Width > 0 && face.Height > 0
                && face.X + face.Width <= 1 && face.Y + face.Height <= 1, "Invalid normalized face rectangle.");
    }
}

public sealed record SharedAssetKey(Guid ProviderId, Guid SourceId, Guid GenerationId, string ImageId)
{
    public void Validate()
    {
        PeerProtocol.Require(ProviderId != Guid.Empty && SourceId != Guid.Empty && GenerationId != Guid.Empty,
            "Missing asset scope.");
        PeerProtocol.Require(ImageId != null && ImageId.Length == 64 && ImageId.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f'),
            "Image identity must be a lowercase SHA-256 digest.");
    }

    [JsonIgnore] public string OpaqueId => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(
        $"{ProviderId:N}:{SourceId:N}:{GenerationId:N}:{ImageId}")));
}

public sealed record SharedPhoto(SharedAssetKey Key, int PixelWidth, int PixelHeight, long ByteLength, SharedFaceMetadata FaceMetadata)
{
    public int Orientation { get; init; } = 1;
    public void Validate()
    {
        PeerProtocol.Require(Key != null && FaceMetadata != null, "Missing photo identity or face metadata.");
        Key!.Validate(); FaceMetadata!.Validate();
        PeerProtocol.Require(PixelWidth > 0 && PixelHeight > 0 && ByteLength > 0 && Orientation is >= 1 and <= 8
            && PixelWidth == FaceMetadata.PixelWidth && PixelHeight == FaceMetadata.PixelHeight, "Photo/metadata dimensions differ.");
    }

    [JsonIgnore] public bool IsReadyForPlanning => FaceMetadata.State != FaceAnalysisState.Pending;
}

public sealed record PhotoCacheHeader(int Version, SharedPhoto Photo, DateTimeOffset CachedAt, DateTimeOffset ExpiresAt)
{
    public static readonly TimeSpan Lifetime = TimeSpan.FromDays(14);

    public void Validate()
    {
        PeerProtocol.Require(Version == 1 && Photo != null, "Invalid cache header.");
        Photo!.Validate();
        PeerProtocol.Require(CachedAt != default && ExpiresAt - CachedAt == Lifetime, "Invalid cache lifetime.");
    }
}

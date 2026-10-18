using System.Text.Json;

namespace DynamicPhotoWall.Networking;

public sealed record PeerCandidate(PeerHello Hello, string Host, int Port);
public sealed record SharedGroup(Guid Id, string Name);
public sealed record SharedSource(Guid ProviderId, Guid SourceId, string Name);
public sealed record SourceSelection(Guid ProviderId, Guid SourceId, Guid GenerationId);
public sealed record PeerMember(PeerCandidate Candidate);

public sealed record PlaybackOptions
{
    public bool RandomOrder { get; init; } = true;
    public bool GalleryEnabled { get; init; } = true;
    public bool GalleryScrollEnabled { get; init; } = true;
    public bool VerticalPanEnabled { get; init; } = true;
    public bool HorizontalPanEnabled { get; init; } = true;
    public bool ZoomEnabled { get; init; } = true;
    public bool GalleryPerDisplay { get; init; }
    public bool GalleryScrollPerDisplay { get; init; }
    public bool VerticalPanPerDisplay { get; init; }
    public bool HorizontalPanPerDisplay { get; init; }
    public bool ZoomPerDisplay { get; init; }
    public bool StopAtFace { get; init; } = true;
    public bool FaceAwareFraming { get; init; } = true;
    public bool FaceAwarePanDirection { get; init; } = true;
    public bool AvoidFaceDisplayBoundaries { get; init; } = true;
    public bool GlassBackground { get; init; } = true;
    public int RecentCount { get; init; } = 30;
    public int GalleryMax { get; init; } = 5;
    public int GalleryWeight { get; init; } = 45;
    public int PanWeight { get; init; } = 35;
    public int ZoomWeight { get; init; } = 20;
    public double PanPixelsPerSecond { get; init; } = 120;
    public double GalleryScrollPixelsPerSecond { get; init; } = 40;
    public double PanWidthFraction { get; init; } = .96;
    public double MaxPanUpscale { get; init; } = 4;
    public double ZoomSeconds { get; init; } = 45;
    public double MaxZoom { get; init; } = 1.08;
    public double FadeSeconds { get; init; } = 1.2;
    public double GalleryMinSeconds { get; init; } = 30;
    public double GalleryMaxSeconds { get; init; } = 60;
    public double Gap { get; init; } = 8;
    public double CornerRadius { get; init; } = 8;
    public string Background { get; init; } = "#101116";
    public void Validate()
    {
        PeerProtocol.Require(RecentCount is >= 0 and <= 10000 && GalleryMax is >= 1 and <= 5
            && GalleryWeight is >= 0 and <= 10000 && PanWeight is >= 0 and <= 10000 && ZoomWeight is >= 0 and <= 10000,
            "Invalid playback weights or photo count.");
        foreach (var v in new[] { PanPixelsPerSecond, GalleryScrollPixelsPerSecond, PanWidthFraction,
            MaxPanUpscale, ZoomSeconds, MaxZoom, FadeSeconds, GalleryMinSeconds, GalleryMaxSeconds, Gap, CornerRadius })
            PeerProtocol.Require(double.IsFinite(v) && v >= 0 && v <= 100000, "Invalid playback parameter.");
        PeerProtocol.Require(PanPixelsPerSecond > 0 && GalleryScrollPixelsPerSecond > 0 && PanWidthFraction > 0
            && MaxPanUpscale >= 1 && MaxZoom >= 1 && ZoomSeconds > 0 && GalleryMinSeconds > 0
            && GalleryMaxSeconds >= GalleryMinSeconds && Background.Length == 7 && Background[0] == '#'
            && Background[1..].All(Uri.IsHexDigit), "Invalid playback interval or background.");
    }
}

public sealed record WallSnapshot(Guid WallId, Guid SessionId, Guid LeaderId, long Revision,
    SharedGroup[] Groups, PeerDisplay[] Displays, SourceSelection[] Sources, PlaybackOptions Playback)
{
    public long Term { get; init; }
    public Guid[] AppliedRequests { get; init; } = [];
    public Guid[] MergedWalls { get; init; } = [];
    public void Validate()
    {
        PeerProtocol.Require(WallId != Guid.Empty && SessionId != Guid.Empty && LeaderId != Guid.Empty && Revision >= 0 && Term >= 0,
            "Invalid shared wall identity.");
        PeerProtocol.Require(Groups != null && Displays != null && Sources != null && Playback != null
            && Groups.Length <= 128 && Displays.Length <= 128 && Sources.Length <= 1024, "Invalid wall size.");
        Playback!.Validate();
        PeerProtocol.Require(AppliedRequests != null && AppliedRequests.Length <= 1024
            && AppliedRequests.All(id => id != Guid.Empty) && AppliedRequests.Distinct().Count() == AppliedRequests.Length, "Invalid applied request history.");
        PeerProtocol.Require(MergedWalls != null && MergedWalls.Length <= 1024 && !MergedWalls.Contains(WallId), "Invalid wall merge history.");
        PeerProtocol.Require(Groups!.All(g => g.Id != Guid.Empty && !string.IsNullOrWhiteSpace(g.Name) && g.Name.Length <= 128)
            && Groups.Select(g => g.Id).Distinct().Count() == Groups.Length, "Invalid groups.");
        foreach (var display in Displays!)
        {
            display.Validate();
            PeerProtocol.Require(display.GroupId == null || Groups.Any(g => g.Id == display.GroupId), "Unknown group.");
        }
        PeerProtocol.Require(Displays.Select(d => d.Key).Distinct().Count() == Displays.Length, "Duplicate display.");
        foreach (var group in Groups.Where(g => Displays.Any(d => d.Selected && d.GroupId == g.Id)))
            _ = PeerGroupLayout.Create(group.Id, Displays);
        foreach (var source in Sources!)
            PeerProtocol.Require(source.ProviderId != Guid.Empty && source.SourceId != Guid.Empty && source.GenerationId != Guid.Empty,
                "Invalid photo source selection.");
        PeerProtocol.Require(Sources.Select(s => (s.ProviderId, s.SourceId)).Distinct().Count() == Sources.Length
            && Sources.GroupBy(s => s.ProviderId).All(g => g.Select(s => s.GenerationId).Distinct().Count() == 1), "Conflicting source generations.");
    }
}

public sealed record StateProposal(Guid RequestId, long ExpectedRevision, SharedGroup[] Groups,
    PeerDisplay[] Displays, SourceSelection[] Sources, PlaybackOptions Playback);
public sealed record StateResult(Guid RequestId, bool Accepted, string? Error, WallSnapshot Snapshot);
public sealed record Heartbeat(PeerCandidate[] Members, Guid LeaderId, Guid SessionId, long Revision);
public sealed record ClockPing(Guid RequestId, double SentAt);
public sealed record ClockPong(Guid RequestId, double SentAt, double ReceivedAt, double RepliedAt);
public sealed record AssetRequest(Guid RequestId, SharedAssetKey Key);
public sealed record AssetChunk(Guid RequestId, SharedPhoto Photo, int Index, byte[] Data, bool Last);
public sealed record CatalogBatch(SharedPhoto[] Photos);
public sealed record PlaybackOperation(Guid RequestId, string Operation);
public sealed record PlaybackControl(string Operation, double EffectiveAt);
public sealed record PlaybackStatus(bool Paused, bool Stopped, double EffectiveAt);
public sealed record PeerInventory(PeerCandidate Candidate, PeerDisplay[] Displays, SharedSource[] Sources);
public sealed record SnapshotNotice(WallSnapshot Snapshot, Guid[] Members);
public sealed record LayoutPreviewRequest(bool Enabled, PeerDisplay[] Displays, SharedGroup[] Groups);
public sealed record LayoutPreviewPlan(bool Enabled, double EffectiveAt, PeerDisplay[] Displays, SharedGroup[] Groups);
public sealed record WallMergeRequest(Guid RequestId, WallSnapshot Previous, PeerCandidate[] Members);
public sealed record WallMigration(Guid RequestId, Guid PreviousWallId, WallSnapshot Snapshot, PeerCandidate[] Members);

public sealed record PeerPacket(string Type, JsonElement Body)
{
    public static PeerPacket Create<T>(string type, T body) => new(type, JsonSerializer.SerializeToElement(body, PeerProtocol.Json));
    public T Decode<T>() => Body.Deserialize<T>(PeerProtocol.Json) ?? throw new InvalidDataException("Missing message body.");
}

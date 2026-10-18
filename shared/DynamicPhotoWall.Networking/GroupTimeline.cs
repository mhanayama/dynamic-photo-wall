namespace DynamicPhotoWall.Networking;

// Shared seconds are supplied by a clock adapter. No receive timestamp is used here.
public sealed record PlaybackAnchor(double SharedTime, double Position, bool Paused)
{
    public void Validate() => PeerProtocol.Require(double.IsFinite(SharedTime) && double.IsFinite(Position) && Position >= 0,
        "Invalid playback anchor.");

    public double PositionAt(double sharedNow)
    {
        Validate();
        PeerProtocol.Require(double.IsFinite(sharedNow) && sharedNow >= SharedTime, "Time precedes the playback anchor.");
        var result = Position + (Paused ? 0 : sharedNow - SharedTime);
        PeerProtocol.Require(double.IsFinite(result), "Playback position overflowed.");
        return result;
    }
}

public sealed record PlaybackChange(long Sequence, double EffectiveAt, bool Paused, double? SeekPosition = null);

public sealed class GroupTimeline
{
    private readonly PlaybackAnchor initial;
    private readonly List<PlaybackChange> changes = [];

    public GroupTimeline(PlaybackAnchor initial) { initial.Validate(); this.initial = initial; }

    public void Schedule(PlaybackChange change)
    {
        PeerProtocol.Require(change.Sequence > 0 && double.IsFinite(change.EffectiveAt)
            && change.EffectiveAt >= initial.SharedTime
            && (change.SeekPosition == null || double.IsFinite(change.SeekPosition.Value) && change.SeekPosition >= 0),
            "Invalid playback change.");
        var duplicate = changes.Find(c => c.Sequence == change.Sequence);
        if (duplicate != null)
        {
            PeerProtocol.Require(duplicate == change, "A command sequence was reused with different content.");
            return;
        }
        if (changes.Count > 0)
            PeerProtocol.Require(change.Sequence > changes[^1].Sequence && change.EffectiveAt >= changes[^1].EffectiveAt,
                "Playback changes must follow committed order and time.");
        changes.Add(change);
    }

    public double PositionAt(double sharedNow)
    {
        var anchor = initial;
        foreach (var change in changes)
        {
            if (change.EffectiveAt > sharedNow) break;
            anchor = new(change.EffectiveAt, change.SeekPosition ?? anchor.PositionAt(change.EffectiveAt), change.Paused);
        }
        return anchor.PositionAt(sharedNow);
    }

    public double SceneProgress(double sharedNow, double sceneStartPosition, double duration)
    {
        PeerProtocol.Require(double.IsFinite(sceneStartPosition) && sceneStartPosition >= 0
            && double.IsFinite(duration) && duration > 0, "Invalid scene interval.");
        return Math.Clamp((PositionAt(sharedNow) - sceneStartPosition) / duration, 0, 1);
    }
}

using System.Collections.Concurrent;

namespace DynamicPhotoWall.Networking;

public sealed partial class PeerSession
{
    private readonly ConcurrentDictionary<Guid, WallSnapshot> explicitJoins = new();
    private readonly HashSet<Guid> migrations = [];
    private PeerCandidate[] Endpoints() => targets.Values.Where(p => links.ContainsKey(p.Hello.PeerId)).Append(Self).ToArray();
    private async Task JoinWall(IPeerLink link, SnapshotNotice notice)
    {
        var selected = explicitJoins.TryRemove(link.Remote.PeerId, out var beforeJoin);
        var previous = selected ? beforeJoin! : Snapshot;
        if (previous.WallId == notice.Snapshot.WallId)
        {
            if (Leadership.PreferIncoming(previous, notice.Snapshot)) { state.Adopt(notice.Snapshot); ApplyState(); }
            return;
        }
        if (!selected && !notice.Snapshot.MergedWalls.Contains(previous.WallId))
        {
            if (previous.MergedWalls.Contains(notice.Snapshot.WallId))
                await link.SendAsync(PeerPacket.Create("wallMigration", new WallMigration(Guid.NewGuid(), notice.Snapshot.WallId, previous, Endpoints())), lifetime.Token);
            return;
        }
        var members = Endpoints(); state.Adopt(notice.Snapshot); ApplyState();
        await link.SendAsync(PeerPacket.Create("inventory", new PeerInventory(Self, localDisplays, provider.Sources.ToArray())), lifetime.Token);
        if (selected) await link.SendAsync(PeerPacket.Create("wallMergeRequest", new WallMergeRequest(Guid.NewGuid(), previous, members)), lifetime.Token);
    }
    private async Task MergeWall(WallMergeRequest request)
    {
        request.Previous.Validate();
        PeerProtocol.Require(request.Members.Length <= 128 && request.RequestId != Guid.Empty, "Invalid wall merge.");
        if (Snapshot.LeaderId != local.PeerId)
        {
            if (links.TryGetValue(Snapshot.LeaderId, out var leader))
                await leader.Link.SendAsync(PeerPacket.Create("wallMergeRequest", request), lifetime.Token);
            return;
        }
        if (migrations.Contains(request.RequestId)) return;
        var previous = request.Previous;
        if (previous.WallId == Snapshot.WallId) return;
        var groups = Snapshot.Groups.Concat(previous.Groups.Where(g => !Snapshot.Groups.Any(old => old.Id == g.Id)).Select(g =>
            Snapshot.Groups.Any(old => old.Name == g.Name) ? g with { Name = $"{g.Name[..Math.Min(110, g.Name.Length)]} ({g.Id.ToString("N")[..8]})" } : g)).ToArray();
        var displays = previous.Displays.Select(d => d with { Name = Snapshot.Displays.FirstOrDefault(current => current.Key == d.Key)?.Name ?? d.Name })
            .Concat(Snapshot.Displays.Where(d => !previous.Displays.Any(old => old.Key == d.Key))).ToArray();
        var sources = Snapshot.Sources.Concat(previous.Sources.Where(s => !Snapshot.Sources.Any(old => old.ProviderId == s.ProviderId))).ToArray();
        var next = Snapshot with { Revision = checked(Snapshot.Revision + 1), Groups = groups, Displays = displays, Sources = sources,
            AppliedRequests = Snapshot.AppliedRequests.Concat(previous.AppliedRequests).Distinct().TakeLast(1024).ToArray(),
            MergedWalls = Snapshot.MergedWalls.Concat(previous.MergedWalls).Append(previous.WallId).Where(id => id != Snapshot.WallId).Distinct().TakeLast(1024).ToArray() };
        state.Adopt(next); ApplyState(); migrations.Add(request.RequestId);
        var endpoints = Endpoints().Concat(request.Members).DistinctBy(m => m.Hello.PeerId).ToArray();
        var migration = new WallMigration(request.RequestId, previous.WallId, next, endpoints);
        await Broadcast(PeerPacket.Create("wallMigration", migration)); await PublishState();
    }
    private async Task MigrateWall(IPeerLink link, WallMigration migration)
    {
        migration.Snapshot.Validate();
        PeerProtocol.Require(migration.RequestId != Guid.Empty && migration.Members.Length <= 128
            && migration.Snapshot.MergedWalls.Contains(migration.PreviousWallId), "Invalid wall migration.");
        if (!migrations.Add(migration.RequestId)) return;
        while (migrations.Count > 1024) migrations.Remove(migrations.First());
        if (Snapshot.WallId != migration.PreviousWallId && Snapshot.WallId != migration.Snapshot.WallId) return;
        if (Snapshot.WallId == migration.PreviousWallId || Leadership.PreferIncoming(Snapshot, migration.Snapshot))
        { state.Adopt(migration.Snapshot); ApplyState(); }
        var endpoints = migration.Members.Select(member => member.Hello.PeerId == link.Remote.PeerId
            ? member with { Host = link.RemoteHost } : targets.GetValueOrDefault(member.Hello.PeerId) ?? member).ToArray();
        foreach (var member in endpoints.Where(m => m.Hello.PeerId != local.PeerId)) targets[member.Hello.PeerId] = member;
        await Broadcast(PeerPacket.Create("wallMigration", migration with { Members = endpoints }));
    }
}

namespace DynamicPhotoWall.Networking;

// Selection policy is pure; transport liveness is supplied by the membership layer.
public static class Leadership
{
    public static Guid Select(Guid previous, IEnumerable<Guid> livePeers)
    {
        var live = livePeers.Distinct().OrderBy(p => p.ToString("N"), StringComparer.Ordinal).ToArray();
        PeerProtocol.Require(live.Length > 0, "No live peer can coordinate the wall.");
        return live.Contains(previous) ? previous : live[0];
    }
    public static bool PreferIncoming(WallSnapshot current, WallSnapshot incoming)
    {
        if (incoming.WallId != current.WallId) return false;
        if (incoming.SessionId == current.SessionId) return incoming.Revision > current.Revision;
        if (incoming.Term != current.Term) return incoming.Term > current.Term;
        return string.CompareOrdinal(incoming.LeaderId.ToString("N"), current.LeaderId.ToString("N")) < 0;
    }
}

public sealed class SharedStateCoordinator(Guid localPeer, INetworkPersistence persistence, WallSnapshot initial)
{
    private readonly Dictionary<Guid, StateResult> results = [];
    private readonly Queue<Guid> resultOrder = [];
    public WallSnapshot Current { get; private set; } = Validate(initial);
    private static WallSnapshot Validate(WallSnapshot state) { state.Validate(); return state; }

    public StateResult Apply(StateProposal proposal)
    {
        if (results.TryGetValue(proposal.RequestId, out var known)) return known;
        if (Current.AppliedRequests.Contains(proposal.RequestId)) return new(proposal.RequestId, true, null, Current);
        var accepted = false; string? error = null;
        if (proposal.RequestId == Guid.Empty) error = "変更要求のIDがありません。";
        else if (Current.LeaderId != localPeer) error = "進行役の交代後に再試行してください。";
        else if (proposal.ExpectedRevision != Current.Revision) error = "別のピアで設定が更新されました。最新版を確認してください。";
        else
        {
            try
            {
                var next = Current with { Revision = checked(Current.Revision + 1), Groups = proposal.Groups,
                    Displays = proposal.Displays, Sources = proposal.Sources, Playback = proposal.Playback,
                    AppliedRequests = Current.AppliedRequests.Append(proposal.RequestId).TakeLast(1024).ToArray() };
                next.Validate(); persistence.Save(next); Current = next; accepted = true;
            }
            catch (InvalidDataException e) { error = e.Message; }
        }
        var result = new StateResult(proposal.RequestId, accepted, error, Current);
        results[proposal.RequestId] = result; resultOrder.Enqueue(proposal.RequestId);
        while (resultOrder.Count > 1024) results.Remove(resultOrder.Dequeue());
        return result;
    }
    public void Adopt(WallSnapshot state) { state.Validate(); persistence.Save(state); Current = state; }
    public void TakeLeadership()
    {
        Adopt(Current with { LeaderId = localPeer, SessionId = Guid.NewGuid(), Term = checked(Current.Term + 1) });
    }
}

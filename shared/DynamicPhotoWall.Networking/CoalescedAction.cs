namespace DynamicPhotoWall.Networking;

// Keep at most one scheduled callback even when a producer outruns its consumer.
// Scheduling policy (UI dispatcher, priority and delay) belongs to the adapter.
public sealed class CoalescedAction(Action<Action> schedule, Action update) : IDisposable
{
    private int dirty, pending, disposed;
    public void Request()
    {
        if (Volatile.Read(ref disposed) != 0) return;
        Interlocked.Exchange(ref dirty, 1);
        if (Interlocked.CompareExchange(ref pending, 1, 0) != 0) return;
        try { schedule(Flush); }
        catch { Interlocked.Exchange(ref pending, 0); throw; }
    }
    private void Flush()
    {
        Interlocked.Exchange(ref dirty, 0);
        try { if (Volatile.Read(ref disposed) == 0) update(); }
        finally
        {
            Interlocked.Exchange(ref pending, 0);
            if (Volatile.Read(ref dirty) != 0) Request();
        }
    }
    public void Dispose() => Interlocked.Exchange(ref disposed, 1);
}

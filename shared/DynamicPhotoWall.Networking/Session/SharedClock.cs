using System.Diagnostics;

namespace DynamicPhotoWall.Networking;

public sealed class SharedClock : ISharedClock
{
    private readonly long origin = Stopwatch.GetTimestamp();
    private readonly double utc = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000d;
    private readonly object gate = new();
    private double correction, target, lastSlew;
    public double Elapsed => Stopwatch.GetElapsedTime(origin).TotalSeconds;
    public double Now
    {
        get
        {
            lock (gate)
            {
                var elapsed = Elapsed;
                var step = Math.Max(0, elapsed - lastSlew) * .005;
                correction += Math.Clamp(target - correction, -step, step); lastSlew = elapsed;
                return utc + elapsed + correction;
            }
        }
    }
    public void Observe(double sentAt, double remoteReceived, double remoteReplied, double receivedAt)
    {
        if (!new[] { sentAt, remoteReceived, remoteReplied, receivedAt }.All(double.IsFinite)) return;
        var delay = receivedAt - sentAt - (remoteReplied - remoteReceived);
        if (delay < 0 || delay > .25 || remoteReplied < remoteReceived) return;
        var offset = ((remoteReceived - sentAt) + (remoteReplied - receivedAt)) / 2;
        lock (gate) target = correction + Math.Clamp(offset, -.5, .5);
    }
}

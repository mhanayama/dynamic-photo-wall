using System.Diagnostics;

namespace DynamicPhotoWall.Motion;

public sealed class AnimationScheduler
{
    private readonly Stopwatch activeTime = Stopwatch.StartNew();
    private TaskCompletionSource resumed = Completed();
    private bool paused;
    public bool IsPaused => paused;
    public event Action? PauseChanged;
    public double ElapsedSeconds => activeTime.Elapsed.TotalSeconds;
    private static TaskCompletionSource Completed() { var value = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); value.SetResult(); return value; }
    public void SetPaused(bool value)
    {
        if (paused == value) return;
        paused = value;
        if (value) { activeTime.Stop(); resumed = new(TaskCreationOptions.RunContinuationsAsynchronously); }
        else { activeTime.Start(); resumed.TrySetResult(); }
        PauseChanged?.Invoke();
    }
    public async Task DelayAsync(double seconds, CancellationToken token)
    {
        var until = activeTime.Elapsed.TotalSeconds + seconds;
        while (activeTime.Elapsed.TotalSeconds < until)
        {
            await resumed.Task.WaitAsync(token);
            var remaining = until - activeTime.Elapsed.TotalSeconds;
            if (remaining > 0) await Task.Delay(TimeSpan.FromSeconds(Math.Min(.5, remaining)), token);
        }
        token.ThrowIfCancellationRequested();
    }
}

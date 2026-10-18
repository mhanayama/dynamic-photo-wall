using System.Windows.Threading;
using DynamicPhotoWall.Networking;

namespace DynamicPhotoWall.Networking.Windows;

// A burst of transfer events gets one background-priority UI refresh per 100ms.
public sealed class DispatcherUpdateQueue : IDisposable
{
    private readonly CoalescedAction updates;
    public DispatcherUpdateQueue(Dispatcher dispatcher, Action update)
    {
        updates = new(callback => dispatcher.BeginInvoke(DispatcherPriority.Background, new Action(() =>
        {
            var timer = new DispatcherTimer(DispatcherPriority.Background, dispatcher) { Interval = TimeSpan.FromMilliseconds(100) };
            timer.Tick += (_, _) => { timer.Stop(); callback(); }; timer.Start();
        })), update);
    }
    public void Request() => updates.Request();
    public void Dispose() => updates.Dispose();
}

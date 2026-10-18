using System.Net;
using System.Net.Sockets;
using System.Text.Json;

namespace DynamicPhotoWall.Networking;

// Discovery advertises endpoint metadata only. It never opens a peer session.
// This wire format is also implemented by the native Swift discovery adapter.
public sealed class LanPeerDiscovery(int discoveryPort = 47391) : IPeerDiscovery
{
    public const string MulticastAddress = "239.255.77.87";
    private readonly CancellationTokenSource lifetime = new();
    private UdpClient? socket;
    private Task? receiving, advertising;
    public event Action<PeerCandidate>? Found;
    private sealed record Advertisement(string Service, PeerHello Hello, int Port);
    public Task StartAsync(PeerHello hello, int port, CancellationToken token)
    {
        socket = new UdpClient(AddressFamily.InterNetwork);
        socket.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
        socket.Client.Bind(new IPEndPoint(IPAddress.Any, discoveryPort));
        socket.JoinMulticastGroup(IPAddress.Parse(MulticastAddress));
        socket.MulticastLoopback = true;
        receiving = Receive(hello.PeerId, token);
        advertising = Advertise(hello, port, token);
        return Task.CompletedTask;
    }
    private async Task Advertise(PeerHello hello, int port, CancellationToken token)
    {
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(token, lifetime.Token);
        var data = JsonSerializer.SerializeToUtf8Bytes(new Advertisement("photowall-v1", hello, port), PeerProtocol.Json);
        try
        {
            while (!linked.IsCancellationRequested)
            {
                await socket!.SendAsync(data, new IPEndPoint(IPAddress.Parse(MulticastAddress), discoveryPort), linked.Token);
                await Task.Delay(TimeSpan.FromSeconds(2), linked.Token);
            }
        }
        catch (Exception e) when (linked.IsCancellationRequested && e is OperationCanceledException or SocketException or ObjectDisposedException) { }
    }
    private async Task Receive(Guid self, CancellationToken token)
    {
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(token, lifetime.Token);
        try
        {
            while (!linked.IsCancellationRequested)
            {
                var datagram = await socket!.ReceiveAsync(linked.Token);
                if (datagram.Buffer.Length > 2048) continue;
                try
                {
                    var advert = JsonSerializer.Deserialize<Advertisement>(datagram.Buffer, PeerProtocol.Json);
                    if (advert == null || advert.Hello == null || advert.Service != "photowall-v1" || advert.Hello.PeerId == self || advert.Port is <= 0 or > 65535) continue;
                    advert.Hello.Validate();
                    Found?.Invoke(new(advert.Hello, datagram.RemoteEndPoint.Address.ToString(), advert.Port));
                }
                catch (Exception e) when (e is JsonException or InvalidDataException) { }
            }
        }
        catch (Exception e) when (linked.IsCancellationRequested && e is OperationCanceledException or SocketException or ObjectDisposedException) { }
    }
    public async ValueTask DisposeAsync()
    {
        await lifetime.CancelAsync(); socket?.Dispose();
        if (receiving != null) await receiving;
        if (advertising != null) await advertising;
        lifetime.Dispose();
    }
}

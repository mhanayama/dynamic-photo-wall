using System.Net;
using System.Net.Sockets;
using System.Text.Json;
using DynamicPhotoWall.Networking;

// A short-lived loopback counterpart for the native Swift transport. Synthetic
// identities live in memory; neither side accesses the user's Keychain or photos.
internal static class NetworkInterop
{
    public static async Task<int> Run(string output, bool withDiscovery = false)
    {
        Directory.CreateDirectory(output);
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(40));
        using var identity = new PeerIdentity(new NetworkIntegration.MemorySecrets());
        var hello = new PeerHello(1, identity.PeerId, "Interop .NET", "windows");
        var incomingDone = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        await using var server = new TlsPeerTransport(hello, identity.Certificate, identity, IPAddress.Loopback);
        await server.StartAsync(async link =>
        {
            try
            {
                await using var reader = link.ReceiveAsync(timeout.Token).GetAsyncEnumerator();
                if (!await reader.MoveNextAsync()) throw new Exception("Missing Swift ping");
                var ping = reader.Current.Decode<ClockPing>();
                if (ping.SentAt != 100) throw new Exception("Swift ping changed");
                await link.SendAsync(PeerPacket.Create("clockPong", new ClockPong(ping.RequestId, 100, 101, 102)), timeout.Token);
                incomingDone.TrySetResult();
            }
            catch (Exception e) { incomingDone.TrySetException(e); }
        }, timeout.Token);
        var discoveryPort = ReserveDiscoveryPort();
        await using var discovery = new LanPeerDiscovery(discoveryPort);
        var discovered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        if (withDiscovery)
        {
            discovery.Found += candidate => { if (candidate.Hello.Name == "Interop Swift") discovered.TrySetResult(); };
            // Select an isolated multicast port, separate from live app discovery.
            await discovery.StartAsync(hello, server.Port, timeout.Token);
            await File.WriteAllTextAsync(Path.Combine(output, "discovery-port.json"), discoveryPort.ToString(), timeout.Token);
        }
        await File.WriteAllTextAsync(Path.Combine(output, "dotnet-endpoint.json"),
            JsonSerializer.Serialize(new PeerCandidate(hello, "127.0.0.1", server.Port), PeerProtocol.Json), timeout.Token);
        await incomingDone.Task.WaitAsync(timeout.Token);
        var nativeFile = Path.Combine(output, "swift-endpoint.json");
        while (!File.Exists(nativeFile)) await Task.Delay(50, timeout.Token);
        var candidate = JsonSerializer.Deserialize<PeerCandidate>(await File.ReadAllTextAsync(nativeFile, timeout.Token), PeerProtocol.Json)!;
        await using var outgoing = await server.ConnectAsync(candidate, timeout.Token);
        var request = new ClockPing(Guid.NewGuid(), 200);
        await outgoing.SendAsync(PeerPacket.Create("clockPing", request), timeout.Token);
        await using var replies = outgoing.ReceiveAsync(timeout.Token).GetAsyncEnumerator();
        if (!await replies.MoveNextAsync()) throw new Exception("Missing Swift pong");
        var reply = replies.Current.Decode<ClockPong>();
        if (reply.RequestId != request.RequestId || reply.RepliedAt != 202) throw new Exception("Swift pong changed");
        if (withDiscovery) { await discovered.Task.WaitAsync(timeout.Token); Console.WriteLine("PASS .NET discovers Swift multicast advertisement on isolated port"); }
        Console.WriteLine("PASS Swift ↔ .NET mutual TLS, both connection directions, framed ping/pong");
        return 0;
    }
    private static int ReserveDiscoveryPort()
    {
        using var socket = new UdpClient(new IPEndPoint(IPAddress.Loopback, 0));
        return ((IPEndPoint)socket.Client.LocalEndPoint!).Port;
    }
}

using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Runtime.CompilerServices;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

namespace DynamicPhotoWall.Networking;

public sealed class TlsPeerTransport(PeerHello local, X509Certificate2 identity, IPeerTrust trust,
    IPAddress? listenAddress = null, int port = 0) : IPeerTransport
{
    private readonly TcpListener listener = new(listenAddress ?? IPAddress.Any, port);
    private readonly CancellationTokenSource lifetime = new();
    private readonly HashSet<Task> handlers = [];
    private Task? accepting;
    public event Action<Exception>? Error;
    public int Port => listener.LocalEndpoint is IPEndPoint endpoint ? endpoint.Port : 0;

    public Task StartAsync(Func<IPeerLink, Task> accept, CancellationToken token)
    {
        local.Validate(); token.ThrowIfCancellationRequested();
        listener.Start(32);
        accepting = AcceptLoop(accept, token);
        return Task.CompletedTask;
    }
    private async Task AcceptLoop(Func<IPeerLink, Task> accept, CancellationToken external)
    {
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(external, lifetime.Token);
        try
        {
            while (!linked.IsCancellationRequested)
            {
                var tcp = await listener.AcceptTcpClientAsync(linked.Token);
                lock (handlers)
                {
                    if (handlers.Count >= 32) { tcp.Dispose(); continue; }
                    var task = Handle(tcp, accept, linked.Token); handlers.Add(task);
                    _ = task.ContinueWith(done => { lock (handlers) handlers.Remove(done); }, TaskScheduler.Default);
                }
            }
        }
        catch (Exception e) when (linked.IsCancellationRequested && e is OperationCanceledException or SocketException or ObjectDisposedException) { }
    }
    private async Task Handle(TcpClient tcp, Func<IPeerLink, Task> accept, CancellationToken token)
    {
        try { await using var link = await Authenticate(tcp, false, null, token); await accept(link); }
        catch (Exception e)
        { tcp.Dispose(); if (!token.IsCancellationRequested) Error?.Invoke(e); }
    }
    public async Task<IPeerLink> ConnectAsync(PeerCandidate candidate, CancellationToken token)
    {
        candidate.Hello.Validate();
        PeerProtocol.Require(candidate.Port is > 0 and <= 65535 && candidate.Hello.PeerId != local.PeerId, "Invalid peer endpoint.");
        var tcp = new TcpClient { NoDelay = true };
        try
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token, lifetime.Token);
            timeout.CancelAfter(TimeSpan.FromSeconds(8));
            await tcp.ConnectAsync(candidate.Host, candidate.Port, timeout.Token);
            return await Authenticate(tcp, true, candidate.Hello.PeerId, timeout.Token);
        }
        catch { tcp.Dispose(); throw; }
    }
    private async Task<IPeerLink> Authenticate(TcpClient tcp, bool outbound, Guid? expected, CancellationToken token)
    {
        tcp.NoDelay = true;
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token, lifetime.Token);
        timeout.CancelAfter(TimeSpan.FromSeconds(8));
        var ssl = new SslStream(tcp.GetStream(), false, (_, cert, _, _) => cert != null);
        try
        {
            if (outbound)
                await ssl.AuthenticateAsClientAsync(new SslClientAuthenticationOptions
                {
                    TargetHost = "photowall", ClientCertificates = new X509CertificateCollection { identity },
                    EnabledSslProtocols = SslProtocols.Tls12 | SslProtocols.Tls13,
                    CertificateRevocationCheckMode = X509RevocationMode.NoCheck
                }, timeout.Token);
            else
                await ssl.AuthenticateAsServerAsync(new SslServerAuthenticationOptions
                {
                    ServerCertificate = identity, ClientCertificateRequired = true,
                    EnabledSslProtocols = SslProtocols.Tls12 | SslProtocols.Tls13,
                    CertificateRevocationCheckMode = X509RevocationMode.NoCheck
                }, timeout.Token);
            PeerProtocol.Require(ssl.IsEncrypted && ssl.RemoteCertificate != null, "TLS identity is required.");
            await PacketFraming.WriteAsync(ssl, PeerPacket.Create("hello", local), timeout.Token);
            var first = await PacketFraming.ReadAsync(ssl, timeout.Token);
            PeerProtocol.Require(first?.Type == "hello", "Peer must introduce its protocol and identity.");
            var remote = first!.Decode<PeerHello>(); remote.Validate();
            PeerProtocol.Require(remote.PeerId != local.PeerId && (expected == null || expected == remote.PeerId), "Peer identity differs from candidate.");
            var digest = Convert.ToHexStringLower(SHA256.HashData(ssl.RemoteCertificate!.GetRawCertData()));
            PeerProtocol.Require(trust.Accept(remote.PeerId, digest), "Registered peer certificate changed.");
            return new TlsPeerLink(tcp, ssl, remote, outbound);
        }
        catch { await ssl.DisposeAsync(); throw; }
    }
    public async ValueTask DisposeAsync()
    {
        await lifetime.CancelAsync(); listener.Stop();
        if (accepting != null) await accepting;
        Task[] remaining; lock (handlers) remaining = handlers.ToArray();
        await Task.WhenAll(remaining);
        lifetime.Dispose();
    }
}

internal sealed class TlsPeerLink(TcpClient tcp, SslStream stream, PeerHello remote, bool outbound) : IPeerLink
{
    private readonly SemaphoreSlim writer = new(1, 1);
    public PeerHello Remote => remote;
    public bool Outbound => outbound;
    public string RemoteHost => ((IPEndPoint)tcp.Client.RemoteEndPoint!).Address.ToString();
    public async ValueTask SendAsync(PeerPacket packet, CancellationToken cancellation)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        timeout.CancelAfter(TimeSpan.FromSeconds(5));
        await writer.WaitAsync(timeout.Token);
        try { await PacketFraming.WriteAsync(stream, packet, timeout.Token); }
        catch { tcp.Dispose(); throw; }
        finally { writer.Release(); }
    }
    public async IAsyncEnumerable<PeerPacket> ReceiveAsync([EnumeratorCancellation] CancellationToken cancellation)
    {
        while (await PacketFraming.ReadAsync(stream, cancellation) is { } packet) yield return packet;
    }
    public async ValueTask DisposeAsync() { tcp.Dispose(); await stream.DisposeAsync(); }
}

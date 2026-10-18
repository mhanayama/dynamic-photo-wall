using System.Buffers.Binary;
using System.Text.Json;

namespace DynamicPhotoWall.Networking;

public static class PacketFraming
{
    public const int MaximumBytes = 4 * 1024 * 1024;
    public static async ValueTask WriteAsync(Stream stream, PeerPacket packet, CancellationToken token)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(packet, PeerProtocol.Json);
        PeerProtocol.Require(bytes.Length is > 0 and <= MaximumBytes, "Peer packet is too large.");
        var header = new byte[4]; BinaryPrimitives.WriteInt32BigEndian(header, bytes.Length);
        await stream.WriteAsync(header, token); await stream.WriteAsync(bytes, token); await stream.FlushAsync(token);
    }
    public static async ValueTask<PeerPacket?> ReadAsync(Stream stream, CancellationToken token)
    {
        var header = new byte[4];
        var first = await stream.ReadAsync(header.AsMemory(0, 1), token);
        if (first == 0) return null;
        await stream.ReadExactlyAsync(header.AsMemory(1), token);
        var length = BinaryPrimitives.ReadInt32BigEndian(header);
        PeerProtocol.Require(length is > 0 and <= MaximumBytes, "Invalid peer packet length.");
        var bytes = new byte[length]; await stream.ReadExactlyAsync(bytes, token);
        var packet = JsonSerializer.Deserialize<PeerPacket>(bytes, PeerProtocol.Json)
            ?? throw new InvalidDataException("Missing peer packet.");
        PeerProtocol.Require(!string.IsNullOrWhiteSpace(packet.Type) && packet.Type.Length <= 64
            && packet.Body.ValueKind == JsonValueKind.Object, "Invalid peer packet.");
        return packet;
    }
}

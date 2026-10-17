using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace DynamicPhotoWall.Core.Networking;

public sealed record CachedPhoto(PhotoCacheHeader Header, byte[] Image);

// This storage primitive never persists a key. Production callers must supply an
// OS-protected key; only synthetic fixtures and ephemeral keys are used by tests.
public sealed class EncryptedPhotoCache : IDisposable
{
    private static readonly byte[] Magic = "DPWCAC01"u8.ToArray();
    private static readonly byte[] KeyInfo = "DynamicPhotoWall/photo-cache/v1"u8.ToArray();
    private const int ChunkBytes = 64 * 1024;
    private const int MaxHeaderBytes = 1024 * 1024;
    private readonly object gate = new();
    private readonly string root;
    private readonly byte[] masterKey;
    private readonly long maxImageBytes;
    private readonly Dictionary<Guid, Guid> activeGenerations = [];
    private bool disposed;

    public EncryptedPhotoCache(string directory, ReadOnlySpan<byte> key, long maxImageBytes = 256L * 1024 * 1024)
    {
        if (key.Length != 32) throw new ArgumentException("A 256-bit cache key is required.", nameof(key));
        if (maxImageBytes <= 0 || maxImageBytes > int.MaxValue) throw new ArgumentOutOfRangeException(nameof(maxImageBytes));
        root = Path.GetFullPath(directory); masterKey = key.ToArray(); this.maxImageBytes = maxImageBytes;
        Directory.CreateDirectory(root); CheckDirectory(root);
    }

    public void ActivateGeneration(Guid providerId, Guid generationId)
    {
        PeerProtocol.Require(providerId != Guid.Empty && generationId != Guid.Empty, "Missing cache generation.");
        lock (gate)
        {
            CheckAlive();
            var provider = DirectoryPath(providerId);
            Directory.CreateDirectory(provider); CheckDirectory(provider);
            // Invalidate before deleting so an I/O failure cannot reactivate old work.
            activeGenerations[providerId] = generationId;
            foreach (var old in Directory.EnumerateDirectories(provider))
            {
                CheckDirectory(old);
                if (Path.GetFileName(old) == generationId.ToString("N")
                    || !Guid.TryParseExact(Path.GetFileName(old), "N", out _)) continue;
                // Only files owned by this cache are removed; no recursive deletion.
                foreach (var file in Directory.EnumerateFiles(old).Where(f => Path.GetExtension(f) is ".pwc" or ".tmp"))
                    File.Delete(file);
            }
            var current = DirectoryPath(providerId, generationId);
            Directory.CreateDirectory(current); CheckDirectory(current);
        }
    }

    public PhotoCacheHeader Put(SharedPhoto photo, Stream original, DateTimeOffset cachedAt, CancellationToken token = default)
    {
        photo.Validate();
        PeerProtocol.Require(photo.ByteLength <= maxImageBytes && cachedAt != default, "Photo exceeds the cache entry limit or has no timestamp.");
        var header = new PhotoCacheHeader(1, photo, cachedAt.ToUniversalTime(), cachedAt.ToUniversalTime() + PhotoCacheHeader.Lifetime);
        header.Validate();
        var headerBytes = JsonSerializer.SerializeToUtf8Bytes(header, PeerProtocol.Json);
        PeerProtocol.Require(headerBytes.Length <= MaxHeaderBytes, "Cache metadata is too large.");
        lock (gate)
        {
            CheckAlive(); RequireActive(photo.Key);
            var path = ObjectPath(photo.Key);
            var temporary = Path.Combine(Path.GetDirectoryName(path)!, $"{Guid.NewGuid():N}.tmp");
            var salt = RandomNumberGenerator.GetBytes(32);
            var fileKey = HKDF.DeriveKey(HashAlgorithmName.SHA256, masterKey, 32, salt, KeyInfo);
            var plain = new byte[ChunkBytes];
            try
            {
                token.ThrowIfCancellationRequested();
                using var cipher = new AesGcm(fileKey, 16);
                using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
                using (var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                {
                    output.Write(Magic); output.Write(salt);
                    WriteBlock(output, cipher, photo.Key, 0, headerBytes);
                    long remaining = photo.ByteLength;
                    ulong block = 1;
                    while (remaining > 0)
                    {
                        token.ThrowIfCancellationRequested();
                        var count = (int)Math.Min(remaining, plain.Length);
                        original.ReadExactly(plain.AsSpan(0, count));
                        hash.AppendData(plain.AsSpan(0, count));
                        WriteBlock(output, cipher, photo.Key, block++, plain.AsSpan(0, count));
                        remaining -= count;
                    }
                    PeerProtocol.Require(original.ReadByte() == -1, "Photo is longer than declared.");
                    PeerProtocol.Require(Convert.ToHexStringLower(hash.GetHashAndReset()) == photo.Key.ImageId,
                        "Photo content does not match its identity.");
                    token.ThrowIfCancellationRequested();
                    output.Flush(flushToDisk: true);
                }
                // The lock serializes generation changes with publication.
                File.Move(temporary, path, overwrite: true);
                return header;
            }
            finally
            {
                CryptographicOperations.ZeroMemory(fileKey);
                CryptographicOperations.ZeroMemory(plain);
                CryptographicOperations.ZeroMemory(headerBytes);
                if (File.Exists(temporary)) File.Delete(temporary);
            }
        }
    }

    public CachedPhoto? Read(SharedAssetKey key, DateTimeOffset now)
    {
        key.Validate();
        lock (gate)
        {
            CheckAlive(); RequireActive(key);
            var path = ObjectPath(key);
            if (!File.Exists(path)) return null;
            CheckDirectory(Path.GetDirectoryName(path)!);
            RejectLink(path);
            byte[]? fileKey = null;
            byte[]? image = null;
            var success = false;
            try
            {
                PhotoCacheHeader header;
                using (var input = File.OpenRead(path))
                {
                    var magic = new byte[Magic.Length]; input.ReadExactly(magic);
                    PeerProtocol.Require(magic.AsSpan().SequenceEqual(Magic), "Unsupported encrypted cache format.");
                    var salt = new byte[32]; input.ReadExactly(salt);
                    fileKey = HKDF.DeriveKey(HashAlgorithmName.SHA256, masterKey, 32, salt, KeyInfo);
                    using var cipher = new AesGcm(fileKey, 16);
                    var headerBytes = ReadBlock(input, cipher, key, 0, MaxHeaderBytes);
                    try
                    {
                        header = JsonSerializer.Deserialize<PhotoCacheHeader>(headerBytes, PeerProtocol.Json)
                            ?? throw new InvalidDataException("Missing cache metadata.");
                        header.Validate();
                        PeerProtocol.Require(header.Photo.Key == key && header.Photo.ByteLength <= maxImageBytes,
                            "Cache identity or entry length differs.");
                    }
                    finally { CryptographicOperations.ZeroMemory(headerBytes); }
                    if (now >= header.ExpiresAt)
                    {
                        input.Dispose(); File.Delete(path);
                        return null;
                    }
                    PeerProtocol.Require(now >= header.CachedAt, "Clock precedes cache creation.");
                    image = new byte[(int)header.Photo.ByteLength];
                    using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
                    var offset = 0;
                    ulong block = 1;
                    while (offset < image.Length)
                    {
                        var expected = Math.Min(ChunkBytes, image.Length - offset);
                        var bytes = ReadBlock(input, cipher, key, block++, expected);
                        try
                        {
                            PeerProtocol.Require(bytes.Length == expected, "Invalid cache chunk length.");
                            bytes.CopyTo(image, offset); hash.AppendData(bytes); offset += bytes.Length;
                        }
                        finally { CryptographicOperations.ZeroMemory(bytes); }
                    }
                    PeerProtocol.Require(input.ReadByte() == -1, "Unexpected cache trailing data.");
                    PeerProtocol.Require(Convert.ToHexStringLower(hash.GetHashAndReset()) == key.ImageId, "Cache content hash differs.");
                }
                success = true;
                return new(header, image);
            }
            finally
            {
                if (fileKey != null) CryptographicOperations.ZeroMemory(fileKey);
                if (!success && image != null) CryptographicOperations.ZeroMemory(image);
            }
        }
    }

    private static void WriteBlock(Stream stream, AesGcm cipher, SharedAssetKey key, ulong block, ReadOnlySpan<byte> plain)
    {
        var encrypted = new byte[plain.Length];
        Span<byte> tag = stackalloc byte[16];
        cipher.Encrypt(Nonce(block), plain, encrypted, tag, AssociatedData(key, block, plain.Length));
        Span<byte> length = stackalloc byte[4]; BinaryPrimitives.WriteInt32LittleEndian(length, encrypted.Length);
        stream.Write(length); stream.Write(encrypted); stream.Write(tag);
    }

    private static byte[] ReadBlock(Stream stream, AesGcm cipher, SharedAssetKey key, ulong block, int maximum)
    {
        Span<byte> length = stackalloc byte[4]; stream.ReadExactly(length);
        var count = BinaryPrimitives.ReadInt32LittleEndian(length);
        PeerProtocol.Require(count > 0 && count <= maximum, "Invalid encrypted block length.");
        var encrypted = new byte[count]; stream.ReadExactly(encrypted);
        Span<byte> tag = stackalloc byte[16]; stream.ReadExactly(tag);
        var plain = new byte[count];
        try { cipher.Decrypt(Nonce(block), encrypted, tag, plain, AssociatedData(key, block, count)); return plain; }
        catch { CryptographicOperations.ZeroMemory(plain); throw; }
    }

    private static byte[] Nonce(ulong block)
    {
        var nonce = new byte[12]; BinaryPrimitives.WriteUInt64BigEndian(nonce.AsSpan(4), block); return nonce;
    }

    private static byte[] AssociatedData(SharedAssetKey key, ulong block, int length)
        => Encoding.UTF8.GetBytes(FormattableString.Invariant($"DPWCAC01:{key.OpaqueId}:{block}:{length}"));

    private string DirectoryPath(Guid provider, Guid? generation = null)
        => generation == null ? Path.Combine(root, provider.ToString("N"))
            : Path.Combine(root, provider.ToString("N"), generation.Value.ToString("N"));

    private string ObjectPath(SharedAssetKey key)
        => Path.Combine(DirectoryPath(key.ProviderId, key.GenerationId), key.OpaqueId + ".pwc");

    private void RequireActive(SharedAssetKey key)
    {
        PeerProtocol.Require(activeGenerations.TryGetValue(key.ProviderId, out var current) && current == key.GenerationId,
            "Asset belongs to an inactive cache generation.");
        CheckDirectory(DirectoryPath(key.ProviderId)); CheckDirectory(DirectoryPath(key.ProviderId, key.GenerationId));
    }

    private void CheckDirectory(string path)
    {
        var relative = Path.GetRelativePath(root, path);
        PeerProtocol.Require(relative != ".." && !relative.StartsWith(".." + Path.DirectorySeparatorChar)
            && !Path.IsPathRooted(relative), "Cache path escaped its root.");
        RejectLink(root);
        RejectLink(path);
    }

    private static void RejectLink(string path)
        => PeerProtocol.Require((File.GetAttributes(path) & FileAttributes.ReparsePoint) == 0, "Cache paths cannot be links.");

    private void CheckAlive() => ObjectDisposedException.ThrowIf(disposed, this);

    public void Dispose()
    {
        lock (gate)
        {
            if (disposed) return;
            disposed = true; CryptographicOperations.ZeroMemory(masterKey);
        }
    }
}

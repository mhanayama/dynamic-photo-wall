using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text.Json;

namespace DynamicPhotoWall.Networking;

public interface ISecretStore
{
    byte[]? Read(string name);
    void Write(string name, byte[] value);
}

public sealed class PeerIdentity : IPeerTrust, IDisposable
{
    private sealed record StoredIdentity(Guid PeerId, byte[] CacheKey, byte[] Certificate);
    private readonly ISecretStore secrets;
    private readonly Dictionary<Guid, string> trusted;
    private readonly object gate = new();
    public Guid PeerId { get; }
    public byte[] CacheKey { get; }
    public X509Certificate2 Certificate { get; }
    public PeerIdentity(ISecretStore secrets)
    {
        this.secrets = secrets;
        var bytes = secrets.Read("identity");
        StoredIdentity state;
        if (bytes == null)
        {
            using var signing = ECDsa.Create(ECCurve.NamedCurves.nistP256);
            var request = new CertificateRequest("CN=photowall", signing, HashAlgorithmName.SHA256);
            request.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature, true));
            var usages = new OidCollection { new("1.3.6.1.5.5.7.3.1"), new("1.3.6.1.5.5.7.3.2") };
            request.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension(usages, false));
            using var cert = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddYears(10));
            state = new(Guid.NewGuid(), RandomNumberGenerator.GetBytes(32), cert.Export(X509ContentType.Pfx));
            secrets.Write("identity", JsonSerializer.SerializeToUtf8Bytes(state, PeerProtocol.Json));
        }
        else
        {
            try { state = JsonSerializer.Deserialize<StoredIdentity>(bytes, PeerProtocol.Json) ?? throw new InvalidDataException("Missing identity."); }
            finally { CryptographicOperations.ZeroMemory(bytes); }
        }
        PeerProtocol.Require(state.PeerId != Guid.Empty && state.CacheKey.Length == 32, "Invalid protected peer identity.");
        PeerId = state.PeerId; CacheKey = state.CacheKey;
        // Schannel cannot use ephemeral PFX keys for every TLS credential path.
        // DefaultKeySet is temporary (not PersistKeySet) and is released on disposal.
        Certificate = X509CertificateLoader.LoadPkcs12(state.Certificate, null, X509KeyStorageFlags.DefaultKeySet);
        CryptographicOperations.ZeroMemory(state.Certificate);
        var storedTrust = secrets.Read("trust");
        try { trusted = storedTrust == null ? [] : JsonSerializer.Deserialize<Dictionary<Guid, string>>(storedTrust, PeerProtocol.Json)!; }
        finally { if (storedTrust != null) CryptographicOperations.ZeroMemory(storedTrust); }
    }
    public bool Accept(Guid peerId, string digest)
    {
        lock (gate)
        {
            if (trusted.TryGetValue(peerId, out var existing)) return existing == digest;
            trusted[peerId] = digest;
            secrets.Write("trust", JsonSerializer.SerializeToUtf8Bytes(trusted, PeerProtocol.Json));
            return true;
        }
    }
    public void Dispose() { Certificate.Dispose(); CryptographicOperations.ZeroMemory(CacheKey); }
}

public sealed class EncryptedStateStore(string path, byte[] key) : INetworkPersistence
{
    public WallSnapshot? Load()
    {
        if (!File.Exists(path)) return null;
        var bytes = File.ReadAllBytes(path);
        PeerProtocol.Require(bytes.Length is > 28 and <= 1048604, "Invalid shared state file.");
        var plain = new byte[bytes.Length - 28];
        try
        {
            using var cipher = new AesGcm(key, 16);
            cipher.Decrypt(bytes.AsSpan(0, 12), bytes.AsSpan(28), bytes.AsSpan(12, 16), plain, "photowall-state-v1"u8);
            var state = JsonSerializer.Deserialize<WallSnapshot>(plain, PeerProtocol.Json)!; state.Validate(); return state;
        }
        finally { CryptographicOperations.ZeroMemory(plain); }
    }
    public void Save(WallSnapshot state)
    {
        state.Validate();
        var plain = JsonSerializer.SerializeToUtf8Bytes(state, PeerProtocol.Json);
        PeerProtocol.Require(plain.Length <= 1048576, "Shared state is too large.");
        var bytes = new byte[28 + plain.Length]; RandomNumberGenerator.Fill(bytes.AsSpan(0, 12));
        try
        {
            using var cipher = new AesGcm(key, 16);
            cipher.Encrypt(bytes.AsSpan(0, 12), plain, bytes.AsSpan(28), bytes.AsSpan(12, 16), "photowall-state-v1"u8);
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
            var staging = path + ".tmp";
            try { File.WriteAllBytes(staging, bytes); File.Move(staging, path, true); }
            finally { if (File.Exists(staging)) File.Delete(staging); }
        }
        finally { CryptographicOperations.ZeroMemory(plain); }
    }
}

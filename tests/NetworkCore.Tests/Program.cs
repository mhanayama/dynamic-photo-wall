using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using DynamicPhotoWall.Networking;

if (args.Length == 2 && args[0] == "--export-fixtures") { WireVectors.Export(Path.GetFullPath(args[1])); return 0; }
if (args.Length != 1)
{
    Console.Error.WriteLine("Usage: NetworkCore.Tests <isolated-artifact-directory>");
    return 2;
}
var output = Path.GetFullPath(args[0]);
Directory.CreateDirectory(output);
var runRoot = Path.Combine(output, Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(runRoot);
var cases = new List<object>();
var failed = 0;
var assertions = 0;
var now = new DateTimeOffset(2026, 10, 18, 0, 0, 0, TimeSpan.Zero);
var fixture = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Fixtures", "PeerProtocol.v1.json")));

void Check(bool condition, string message)
{
    assertions++;
    if (!condition) throw new Exception(message);
}
void Throws<T>(Action action) where T : Exception
{
    assertions++;
    try { action(); }
    catch (T) { return; }
    throw new Exception($"Expected {typeof(T).Name}.");
}
void Test(string name, Action test)
{
    try { test(); cases.Add(new { name, passed = true }); Console.WriteLine($"PASS {name}"); }
    catch (Exception e)
    {
        failed++; cases.Add(new { name, passed = false, error = e.ToString() }); Console.WriteLine($"FAIL {name}: {e}");
    }
}
T Decode<T>(JsonElement element) => element.Deserialize<T>(PeerProtocol.Json)!;
SharedPhoto Photo(byte[] bytes, Guid? provider = null, Guid? generation = null)
    => new(new(provider ?? Guid.NewGuid(), Guid.NewGuid(), generation ?? Guid.NewGuid(), Convert.ToHexStringLower(SHA256.HashData(bytes))),
        6000, 4000, bytes.Length,
        new(1, 6000, 4000, "synthetic-detector", "1", FaceAnalysisState.Complete, [new(.1, .2, .3, .4)]));
string ObjectFile(string directory, SharedAssetKey key)
    => Path.Combine(directory, key.ProviderId.ToString("N"), key.GenerationId.ToString("N"), key.OpaqueId + ".pwc");

Test("cross-peer groups retain standalone screens and normalized geometry", () =>
{
    var hello = Decode<PeerHello>(fixture.RootElement.GetProperty("hello")); hello.Validate();
    var displays = Decode<PeerDisplay[]>(fixture.RootElement.GetProperty("displays"));
    var groupId = fixture.RootElement.GetProperty("groupId").GetGuid();
    var layout = PeerGroupLayout.Create(groupId, displays);
    Check(layout.Viewport == new Viewport(3840, 1080), "cross-peer group shares one physical canvas");
    Check(layout.Regions.Count == 2 && layout.Regions[displays[0].Key.LayoutId].X == 0
        && layout.Regions[displays[1].Key.LayoutId].X == 1920, "same OS display name from different peers is not conflated");
    Check(!layout.Regions.ContainsKey(displays[2].Key.LayoutId), "standalone output stays outside group");
    Throws<InvalidDataException>(() => PeerGroupLayout.Create(groupId, [displays[0], displays[0]]));
    Throws<InvalidDataException>(() => (hello with { ProtocolVersion = 2 }).Validate());
    var json = JsonSerializer.Serialize(hello, PeerProtocol.Json);
    Check(!json.Contains("LayoutId") && json.Contains("protocolVersion"), "wire JSON uses declared camelCase names");
});

Test("photo and face metadata have a strict shared wire representation", () =>
{
    var photo = Decode<SharedPhoto>(fixture.RootElement.GetProperty("photo")); photo.Validate();
    var json = JsonSerializer.Serialize(photo, PeerProtocol.Json);
    var copy = JsonSerializer.Deserialize<SharedPhoto>(json, PeerProtocol.Json)!; copy.Validate();
    Check(copy.Key == photo.Key && copy.FaceMetadata.Faces.SequenceEqual(photo.FaceMetadata.Faces), "IDs and face geometry round trip");
    Check(copy.IsReadyForPlanning, "completed face result is usable");
    var none = photo with { FaceMetadata = photo.FaceMetadata with { Faces = [] } };
    none.Validate(); Check(none.IsReadyForPlanning, "no-face analysis is ready");
    var pending = photo with { FaceMetadata = none.FaceMetadata with { State = FaceAnalysisState.Pending } };
    pending.Validate(); Check(!pending.IsReadyForPlanning, "pending analysis is not interpreted as no faces");
    var failure = photo with { FaceMetadata = none.FaceMetadata with { State = FaceAnalysisState.Failed } };
    failure.Validate(); Check(failure.IsReadyForPlanning, "failed analysis can use a shared faceless plan");
    Throws<InvalidDataException>(() => (photo with { FaceMetadata = photo.FaceMetadata with { PixelWidth = 100 } }).Validate());
    Throws<InvalidDataException>(() => (photo with { FaceMetadata = photo.FaceMetadata with { Faces = [new(.9, 0, .2, .1)] } }).Validate());
    Throws<InvalidDataException>(() => (photo with { Key = photo.Key with { ImageId = "../escape" } }).Validate());
    var facesJson = JsonSerializer.Serialize(photo.FaceMetadata, PeerProtocol.Json);
    Throws<JsonException>(() => JsonSerializer.Deserialize<SharedFaceMetadata>(facesJson.Replace("\"complete\"", "99"), PeerProtocol.Json));
    Throws<JsonException>(() => JsonSerializer.Deserialize<PeerHello>("{\"peerId\":\"10000000-0000-0000-0000-000000000001\",\"unexpected\":1}", PeerProtocol.Json));
});

Test("preloaded timeline evaluates shared time through pause resume and Next", () =>
{
    var data = fixture.RootElement.GetProperty("timeline");
    var first = new GroupTimeline(Decode<PlaybackAnchor>(data.GetProperty("anchor")));
    var second = new GroupTimeline(Decode<PlaybackAnchor>(data.GetProperty("anchor")));
    foreach (var change in Decode<PlaybackChange[]>(data.GetProperty("changes"))) { first.Schedule(change); second.Schedule(change); }
    foreach (var sample in data.GetProperty("samples").EnumerateArray())
    {
        var time = sample.GetProperty("sharedTime").GetDouble();
        Check(first.PositionAt(time) == sample.GetProperty("position").GetDouble(), "fixture playback position");
        Check(second.PositionAt(time) == first.PositionAt(time), "receive time never enters evaluation");
    }
    Check(first.SceneProgress(102, 0, 10) == .2, "preloaded scene is 20 percent complete at shared second 102");
    Check(Math.Abs(first.PositionAt(102.1) - 2.1) < 1e-10, "late frame goes directly to current position");
    var firstChange = Decode<PlaybackChange[]>(data.GetProperty("changes"))[0];
    first.Schedule(firstChange); // Idempotent retry after later commands.
    Throws<InvalidDataException>(() => first.Schedule(firstChange with { Paused = false }));
    Throws<InvalidDataException>(() => first.Schedule(new(4, 107, false)));
    Throws<InvalidDataException>(() => first.PositionAt(double.NaN));
    Throws<InvalidDataException>(() => first.SceneProgress(102, 0, 0));
    Throws<InvalidDataException>(() => new PlaybackAnchor(0, double.MaxValue, false).PositionAt(double.MaxValue));
});

Test("only isolated peer repeats then falls back at exactly sixty seconds", () =>
{
    var remaining = new PeerPlaybackRecovery(); remaining.SetOnline(true, 0); remaining.SynchronizationEstablished(0);
    var isolated = new PeerPlaybackRecovery(); isolated.SetOnline(true, 0); isolated.SynchronizationEstablished(0);
    Check(remaining.ConnectionLost(10, true) == PeerConnectionNotice.Disconnected, "remaining side reports disconnection");
    Check(isolated.ConnectionLost(10, false) == PeerConnectionNotice.Disconnected, "isolated side reports disconnection");
    Check(isolated.ConnectionLost(11, false) == null, "retry does not duplicate OS notice");
    remaining.Tick(70, 170); isolated.Tick(69.999, 169.999);
    Check(remaining.State == PeerPlaybackState.Synchronized, "remaining peers continue synchronization");
    Check(isolated.State == PeerPlaybackState.IsolatedRepeating, "still repeating before deadline");
    isolated.Tick(70, 170);
    Check(isolated.State == PeerPlaybackState.Standalone && isolated.ShouldRetry, "standalone does not stop network retry");
});

Test("transport recovery cannot reset the deadline or bypass scheduled synchronization", () =>
{
    var peer = new PeerPlaybackRecovery(); peer.SetOnline(true, 0); peer.SynchronizationEstablished(0);
    peer.ConnectionLost(10, false);
    Check(peer.ConnectionRestored(30) == PeerConnectionNotice.Reconnected, "reconnect notice");
    Check(peer.ConnectionRestored(31) == null, "no repeated reconnect notice");
    peer.ConnectionLost(40, false); peer.ConnectionRestored(50);
    peer.PrepareSynchronization(50, 1000, 1030);
    peer.Tick(70, 1020);
    Check(peer.State == PeerPlaybackState.Standalone, "handshake and flapping never restart grace");
    peer.Tick(80, 1030);
    Check(peer.State == PeerPlaybackState.Synchronized && !peer.ShouldRetry, "return occurs at reserved shared time");
    peer.ConnectionLost(81, false); peer.SetOnline(false, 82);
    Check(peer.State == PeerPlaybackState.Offline && !peer.ShouldRetry, "intentional offline ends retries");
    Check(peer.ConnectionRestored(83) == null, "late connect after offline is ignored");
    Throws<InvalidDataException>(() => peer.Tick(82, 1031));
});

Test("online discovery alone does not connect and accepted sessions can prepare", () =>
{
    var peer = new PeerPlaybackRecovery(); peer.SetOnline(true, 0);
    Check(!peer.ShouldRetry, "online waiting is not implicit connection to candidates");
    Check(peer.ConnectionRestored(1) == null, "an unrequested connection cannot mark playback as connected");
    peer.BeginConnection(2);
    Check(peer.ShouldRetry, "clicking connect or accepting inbound creates a retry target");
    peer.ConnectionRestored(3);
    Check(peer.IsPreparingSynchronization && !peer.ShouldRetry, "initial connection still needs a timed playback join");
    peer.PrepareSynchronization(3, 100, 102); peer.Tick(5, 102);
    Check(peer.State == PeerPlaybackState.Synchronized, "initial join uses reserved shared time");
});

Test("original bytes and faces survive encrypted multi-chunk storage and restart", () =>
{
    var directory = Path.Combine(runRoot, "roundtrip"); var secret = RandomNumberGenerator.GetBytes(32);
    var bytes = RandomNumberGenerator.GetBytes(150000);
    Encoding.UTF8.GetBytes("synthetic-original-photo-marker").CopyTo(bytes, 0);
    var photo = Photo(bytes);
    using (var cache = new EncryptedPhotoCache(directory, secret))
    {
        cache.ActivateGeneration(photo.Key.ProviderId, photo.Key.GenerationId);
        var header = cache.Put(photo, new MemoryStream(bytes), now);
        Check(header.ExpiresAt == now.AddDays(14), "lifetime is fourteen days after completed ingestion");
        var stored = File.ReadAllBytes(ObjectFile(directory, photo.Key));
        Check(!Encoding.UTF8.GetString(stored).Contains("synthetic-original-photo-marker")
            && !Encoding.UTF8.GetString(stored).Contains("synthetic-detector"), "image and face metadata are not persisted as plaintext");
        var loaded = cache.Read(photo.Key, now.AddDays(13))!;
        Check(loaded.Image.SequenceEqual(bytes), "original image bytes are unchanged");
        Check(loaded.Header.Photo.PixelWidth == 6000 && loaded.Header.Photo.PixelHeight == 4000
            && loaded.Header.Photo.FaceMetadata.Faces.SequenceEqual(photo.FaceMetadata.Faces), "original dimensions and shared faces survive");
        Check(loaded.Header.ExpiresAt == now.AddDays(14), "reading does not extend lifetime");
        Check(!Directory.EnumerateFiles(directory, "*.tmp", SearchOption.AllDirectories).Any(), "successful write leaves no staging files");
    }
    using (var cache = new EncryptedPhotoCache(directory, secret))
    {
        cache.ActivateGeneration(photo.Key.ProviderId, photo.Key.GenerationId);
        Check(cache.Read(photo.Key, now.AddDays(13))!.Image.SequenceEqual(bytes), "restart reuses valid same-generation data");
        Check(cache.Read(photo.Key, now.AddDays(14)) == null, "expired cache is unavailable at the exact boundary");
        Check(!File.Exists(ObjectFile(directory, photo.Key)), "expired encrypted file is deleted");
    }
});

Test("source reapply rejects old work and deletes only the selected provider cache", () =>
{
    var directory = Path.Combine(runRoot, "generation");
    using var cache = new EncryptedPhotoCache(directory, RandomNumberGenerator.GetBytes(32));
    var bytes = Encoding.UTF8.GetBytes("synthetic-photo-generation");
    var first = Photo(bytes); var other = Photo(bytes);
    cache.ActivateGeneration(first.Key.ProviderId, first.Key.GenerationId);
    cache.ActivateGeneration(other.Key.ProviderId, other.Key.GenerationId);
    cache.Put(first, new MemoryStream(bytes), now); cache.Put(other, new MemoryStream(bytes), now);
    var fresh = first with { Key = first.Key with { GenerationId = Guid.NewGuid() } };
    cache.ActivateGeneration(fresh.Key.ProviderId, fresh.Key.GenerationId);
    Check(!File.Exists(ObjectFile(directory, first.Key)), "source reapply deletes old provider files");
    Throws<InvalidDataException>(() => cache.Put(first, new MemoryStream(bytes), now));
    Throws<InvalidDataException>(() => cache.Read(first.Key, now));
    Check(cache.Read(other.Key, now)!.Image.SequenceEqual(bytes), "other provider is preserved despite identical image hash");
    cache.Put(fresh, new MemoryStream(bytes), now.AddHours(1));
    Check(cache.Read(fresh.Key, now.AddHours(1))!.Header.ExpiresAt == now.AddHours(1).AddDays(14), "new generation has a new lifetime");
});

Test("wrong key tampering truncation trailing data and object substitution are rejected", () =>
{
    var directory = Path.Combine(runRoot, "integrity"); var secret = RandomNumberGenerator.GetBytes(32);
    var bytes = RandomNumberGenerator.GetBytes(140000); var photo = Photo(bytes);
    using var cache = new EncryptedPhotoCache(directory, secret);
    cache.ActivateGeneration(photo.Key.ProviderId, photo.Key.GenerationId);
    cache.Put(photo, new MemoryStream(bytes), now);
    var path = ObjectFile(directory, photo.Key); var valid = File.ReadAllBytes(path);
    using (var wrong = new EncryptedPhotoCache(directory, RandomNumberGenerator.GetBytes(32)))
    {
        wrong.ActivateGeneration(photo.Key.ProviderId, photo.Key.GenerationId);
        Throws<CryptographicException>(() => wrong.Read(photo.Key, now));
        Check(File.Exists(path), "wrong key cannot erase a valid entry");
    }
    foreach (var index in new[] { 12, 60, valid.Length - 1 })
    {
        var corrupt = valid.ToArray(); corrupt[index] ^= 1; File.WriteAllBytes(path, corrupt);
        Throws<CryptographicException>(() => cache.Read(photo.Key, now));
    }
    File.WriteAllBytes(path, valid[..^1]); Throws<EndOfStreamException>(() => cache.Read(photo.Key, now));
    File.WriteAllBytes(path, [.. valid, 1]); Throws<InvalidDataException>(() => cache.Read(photo.Key, now));
    var oversized = valid.ToArray();
    System.Buffers.Binary.BinaryPrimitives.WriteInt32LittleEndian(oversized.AsSpan(40, 4), int.MaxValue);
    File.WriteAllBytes(path, oversized); Throws<InvalidDataException>(() => cache.Read(photo.Key, now));
    var headerLength = System.Buffers.Binary.BinaryPrimitives.ReadInt32LittleEndian(valid.AsSpan(40, 4));
    var chunkOffset = 44 + headerLength + 16;
    const int fullChunkLength = 4 + 65536 + 16;
    var reordered = valid.ToArray();
    valid.AsSpan(chunkOffset + fullChunkLength, fullChunkLength).CopyTo(reordered.AsSpan(chunkOffset));
    valid.AsSpan(chunkOffset, fullChunkLength).CopyTo(reordered.AsSpan(chunkOffset + fullChunkLength));
    File.WriteAllBytes(path, reordered); Throws<CryptographicException>(() => cache.Read(photo.Key, now));
    var substituted = photo.Key with { SourceId = Guid.NewGuid() };
    File.WriteAllBytes(ObjectFile(directory, substituted), valid);
    Throws<CryptographicException>(() => cache.Read(substituted, now));
    File.WriteAllBytes(path, valid);
    Check(cache.Read(photo.Key, now)!.Image.SequenceEqual(bytes), "valid cache remains usable after failed reads");
});

Test("failed and cancelled ingress never publishes plaintext or partial cache", () =>
{
    var directory = Path.Combine(runRoot, "ingress");
    using var cache = new EncryptedPhotoCache(directory, RandomNumberGenerator.GetBytes(32), maxImageBytes: 1000);
    var bytes = Encoding.UTF8.GetBytes("synthetic-original-content"); var photo = Photo(bytes);
    cache.ActivateGeneration(photo.Key.ProviderId, photo.Key.GenerationId);
    Throws<EndOfStreamException>(() => cache.Put(photo, new MemoryStream(bytes[..^1]), now));
    Throws<InvalidDataException>(() => cache.Put(photo, new MemoryStream([.. bytes, 1]), now));
    Throws<InvalidDataException>(() => cache.Put(photo, new MemoryStream(new byte[bytes.Length]), now));
    using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
    Throws<OperationCanceledException>(() => cache.Put(photo, new MemoryStream(bytes), now, cancelled.Token));
    Throws<InvalidDataException>(() => cache.Put(photo with { ByteLength = 1001 }, new MemoryStream(new byte[1001]), now));
    Check(!Directory.EnumerateFiles(directory, "*", SearchOption.AllDirectories).Any(), "all failed writes remove encrypted staging files");
    cache.Put(photo, new MemoryStream(bytes), now);
    Check(cache.Read(photo.Key, now)!.Image.SequenceEqual(bytes), "a later valid ingress succeeds");
});

Test("state revisions and coordinator succession are independent of OS adapters", NetworkIntegration.StateAndLeadership);
Test("actual mutually authenticated TLS loopback and packet framing", () => NetworkIntegration.TlsLoopback().GetAwaiter().GetResult());
Test("selected-source background transfer preserves originals and face metadata", () => NetworkIntegration.PhotoTransfer(Path.Combine(runRoot, "transfer")).GetAwaiter().GetResult());
Test("scene readiness barrier commits shared future time", () => NetworkIntegration.SceneBarrier().GetAwaiter().GetResult());
Test("disk quota defers originals without a transfer loop", () => NetworkIntegration.TransferQuota(Path.Combine(runRoot, "quota")).GetAwaiter().GetResult());
assertions += NetworkIntegration.Assertions;
Test("three-peer configuration, transfer, failover and background rejoin", () => PeerMeshIntegration.Run(Path.Combine(runRoot, "mesh")).GetAwaiter().GetResult());
Test("two connected walls merge into one four-peer inventory", () => PeerMeshIntegration.MergeExistingWalls(Path.Combine(runRoot, "merge")).GetAwaiter().GetResult());
assertions += PeerMeshIntegration.Assertions;
Test("shared native wire and encrypted cache vectors", () => WireVectors.Verify(Path.Combine(runRoot, "wire-vector")));
fixture.Dispose();
File.WriteAllText(Path.Combine(output, "test-results.json"), JsonSerializer.Serialize(new { failed, assertions, cases },
    new JsonSerializerOptions { WriteIndented = true }));
Console.WriteLine($"{cases.Count} cases, {assertions} assertions, {failed} failures. Results: {output}");
return failed == 0 ? 0 : 1;

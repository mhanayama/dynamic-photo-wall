using System.Collections.Concurrent;
using System.Text.Json;
using DynamicPhotoWall.Configuration;

namespace DynamicPhotoWall.PhotoLibrary;

public sealed class PhotoScanner : IDisposable
{
    private static readonly HashSet<string> extensions = new(StringComparer.OrdinalIgnoreCase) { ".jpg", ".jpeg", ".png", ".webp", ".heic", ".heif" };
    private readonly List<FileSystemWatcher> watchers = [];
    private readonly SemaphoreSlim scanGate = new(1, 1);
    private readonly CancellationTokenSource lifetime = new();
    private readonly System.Threading.Timer reconciliation;
    private readonly ConcurrentDictionary<string, PhotoInfo> metadata = new(StringComparer.OrdinalIgnoreCase);
    private CancellationTokenSource? debounce;
    private WallSettings settings = new();
    private PhotoInfo[] photos = [];
    public IReadOnlyList<PhotoInfo> Photos => Volatile.Read(ref photos);
    public event Action? Changed;
    public string CachePath => Path.Combine(Log.DataDirectory, "metadata.json");
    public PhotoScanner()
    {
        reconciliation = new System.Threading.Timer(_ => Schedule(), null, TimeSpan.FromMinutes(5), TimeSpan.FromMinutes(5));
        try
        {
            if (File.Exists(CachePath))
            {
                foreach (var p in JsonSerializer.Deserialize<PhotoInfo[]>(File.ReadAllText(CachePath)) ?? [])
                    if (p != null && !string.IsNullOrWhiteSpace(p.Path) && p.RawWidth > 0 && p.RawHeight > 0 &&
                        (long)p.RawWidth * p.RawHeight <= 500_000_000 && p.Orientation is >= 1 and <= 8 && p.Length >= 0)
                        metadata[p.Path] = p;
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException) { Log.Write("メタデータキャッシュを再生成します。", e); }
    }
    public async Task ConfigureAsync(WallSettings s, CancellationToken token)
    {
        foreach (var watcher in watchers) watcher.Dispose(); watchers.Clear();
        settings = SettingsManager.Clone(s);
        foreach (var folder in s.Folders.Where(Directory.Exists))
        {
            try
            {
                var w = new FileSystemWatcher(folder) { IncludeSubdirectories = s.Recursive, NotifyFilter = NotifyFilters.FileName | NotifyFilters.DirectoryName | NotifyFilters.LastWrite | NotifyFilters.Size };
                w.Created += OnChange; w.Deleted += OnChange; w.Changed += OnChange; w.Renamed += OnRename; w.Error += (_, e) => { Log.Write("フォルダー監視の再走査を予約しました。", e.GetException()); Schedule(); };
                w.EnableRaisingEvents = true; watchers.Add(w);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException) { Log.Write("フォルダーを監視できません。", e); }
        }
        await ScanAsync(token);
    }
    private void OnChange(object sender, FileSystemEventArgs e) => Schedule();
    private void OnRename(object sender, RenamedEventArgs e) => Schedule();
    private void Schedule()
    {
        lock (watchers)
        {
            if (lifetime.IsCancellationRequested) return;
            debounce?.Cancel(); debounce?.Dispose();
            debounce = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
            var token = debounce.Token;
            _ = RescanAfterDelay(token);
        }
    }
    private async Task RescanAfterDelay(CancellationToken token)
    {
        try { await Task.Delay(1000, token); await ScanAsync(token); }
        catch (OperationCanceledException) { }
        catch (Exception e) { Log.Write("フォルダーの再走査に失敗しました。", e); }
    }
    public async Task ScanAsync(CancellationToken token)
    {
        await scanGate.WaitAsync(token);
        try
        {
            var snapshot = settings;
            var result = await Task.Run(() =>
            {
                var list = new List<PhotoInfo>();
                var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                foreach (var root in snapshot.Folders)
                {
                    var pending = new Stack<string>(); pending.Push(root);
                    while (pending.Count > 0)
                    {
                        token.ThrowIfCancellationRequested();
                        var directory = pending.Pop();
                        try
                        {
                            var options = new EnumerationOptions { IgnoreInaccessible = true, AttributesToSkip = FileAttributes.ReparsePoint };
                            foreach (var path in Directory.EnumerateFiles(directory, "*", options))
                            {
                                token.ThrowIfCancellationRequested();
                                if (!extensions.Contains(Path.GetExtension(path))) continue;
                                var full = Path.GetFullPath(path);
                                if (!seen.Add(full)) continue;
                                try
                                {
                                    var info = new FileInfo(full);
                                    if (!metadata.TryGetValue(full, out var p) || p.Length != info.Length || p.ModifiedTicks != info.LastWriteTimeUtc.Ticks)
                                        metadata[full] = p = MetadataExtractor.Read(full);
                                    list.Add(p);
                                }
                                catch (Exception e) when (e is not OperationCanceledException and not OutOfMemoryException) { Log.Write($"画像をスキップ: {full}", e); }
                            }
                            if (snapshot.Recursive) foreach (var sub in Directory.EnumerateDirectories(directory, "*", options)) pending.Push(sub);
                        }
                        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException) { Log.Write($"フォルダーをスキップ: {directory}", e); }
                    }
                }
                foreach (var path in metadata.Keys) if (!seen.Contains(path)) metadata.TryRemove(path, out _);
                try
                {
                    Directory.CreateDirectory(Log.DataDirectory);
                    File.WriteAllText(CachePath + ".tmp", JsonSerializer.Serialize(metadata.Values));
                    File.Move(CachePath + ".tmp", CachePath, true);
                }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException) { Log.Write("メタデータキャッシュを保存できません。", e); }
                return list.ToArray();
            }, token);
            Volatile.Write(ref photos, result); Changed?.Invoke();
        }
        finally { scanGate.Release(); }
    }
    public void Dispose()
    {
        reconciliation.Dispose();
        lifetime.Cancel();
        lock (watchers) { debounce?.Cancel(); debounce?.Dispose(); foreach (var w in watchers) w.Dispose(); watchers.Clear(); }
        lifetime.Dispose();
    }
}

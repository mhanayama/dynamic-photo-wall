using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace DpwSpatial;

internal sealed record PortraitScene(Pixels Background, float[] Vertices, uint[] Indices, int Width, int Height,
    float FovY, float Pivot, float MaximumAngle, string Directory, string Generator, double GenerationSeconds)
{
    // Optional for synthetic fixtures and old scene files. The worker already saves this full-resolution RGBA.
    public Pixels? SourcePhoto { get; init; }
    public static PortraitScene Load(string manifestPath)
    {
        var directory = Path.GetDirectoryName(Path.GetFullPath(manifestPath))!;
        using var json = JsonDocument.Parse(File.ReadAllText(manifestPath)); var root = json.RootElement;
        foreach (var required in new[] { "background.png", "person.mesh" })
            if (!root.GetProperty("hashes").TryGetProperty(required, out _)) throw new InvalidDataException("Missing scene asset hash: " + required);
        foreach (var entry in root.GetProperty("hashes").EnumerateObject()) {
            if (Path.GetFileName(entry.Name) != entry.Name) throw new InvalidDataException("Scene asset path must be a file name.");
            if (DepthPipeline.HashFile(Path.Combine(directory, entry.Name)) != entry.Value.GetString()) throw new InvalidDataException("Scene asset hash mismatch: " + entry.Name);
        }
        var background = Pixels.Load(Path.Combine(directory, "background.png"));
        using var input = new BinaryReader(File.OpenRead(Path.Combine(directory, "person.mesh")));
        if (Encoding.ASCII.GetString(input.ReadBytes(8)) != "DPWMESH1") throw new InvalidDataException("Unknown mesh format.");
        var vertexCount = input.ReadUInt32(); var indexCount = input.ReadUInt32();
        if (vertexCount < 3 || vertexCount > 999996 || indexCount < 3 || indexCount > 5999994 || indexCount % 3 != 0) throw new InvalidDataException("Invalid mesh count.");
        if (input.BaseStream.Length != 16L + vertexCount * 32L + indexCount * 4L) throw new InvalidDataException("Invalid mesh length.");
        var bounds = root.GetProperty("backgroundBounds").EnumerateArray().Select(v => v.GetSingle()).ToArray();
        if (bounds.Length != 4 || bounds.Any(v => !float.IsFinite(v)) || bounds[0] >= bounds[1] || bounds[2] >= bounds[3]) throw new InvalidDataException("Invalid background bounds.");
        var depth = root.GetProperty("backgroundDepth").GetSingle();
        var vertices = new float[(vertexCount + 4) * 8];
        // Four background vertices precede the independent, genuinely volumetric person mesh.
        float[] plane = [bounds[0], bounds[3], depth, 1, 1, 1, 0, 0, bounds[1], bounds[3], depth, 1, 1, 1, 1, 0,
            bounds[0], bounds[2], depth, 1, 1, 1, 0, 1, bounds[1], bounds[2], depth, 1, 1, 1, 1, 1];
        plane.CopyTo(vertices, 0);
        for (var i = 32; i < vertices.Length; i++) { vertices[i] = input.ReadSingle(); if (!float.IsFinite(vertices[i])) throw new InvalidDataException("Non-finite vertex."); }
        var indices = new uint[indexCount + 6]; uint[] planeIndices = [0, 1, 2, 2, 1, 3]; planeIndices.CopyTo(indices, 0);
        for (var i = 6; i < indices.Length; i++) { var index = input.ReadUInt32(); if (index >= vertexCount) throw new InvalidDataException("Mesh index out of bounds."); indices[i] = index + 4; }
        var width = root.GetProperty("width").GetInt32(); var height = root.GetProperty("height").GetInt32();
        var fov = root.GetProperty("fovY").GetSingle(); var pivot = root.GetProperty("pivot").GetSingle(); var angle = root.GetProperty("maximumAngle").GetSingle();
        if (width is < 1 or > 4096 || height is < 1 or > 4096 || !float.IsFinite(fov) || fov is < 10 or > 90 || !float.IsFinite(pivot) || pivot <= .1f || !float.IsFinite(angle) || angle is < 0 or > 60 || !float.IsFinite(depth) || depth <= pivot)
            throw new InvalidDataException("Invalid portrait camera.");
        Pixels? sourcePhoto = null;
        if (root.GetProperty("hashes").TryGetProperty("person.png", out _)) {
            sourcePhoto = Pixels.Load(Path.Combine(directory, "person.png"));
            if (sourcePhoto.Width != width || sourcePhoto.Height != height) throw new InvalidDataException("Source photo does not match scene camera.");
        }
        return new(background, vertices, indices, width, height, fov, pivot, angle, directory,
            root.GetProperty("generator").GetString() ?? "unknown", root.GetProperty("seconds").GetDouble()) { SourcePhoto = sourcePhoto };
    }
}

internal static class PortraitPipeline
{
    public static string OutputDirectory {
        get {
            var workspace = TrialPaths.FindWorkspace(TrialPaths.ExecutableDirectory);
            return workspace is null ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "DynamicPhotoWall.PortraitAlpha/cache")
                : Path.Combine(workspace, "artifacts/windows/portrait-alpha/cache");
        }
    }
    public static string RuntimeDirectory {
        get {
            var adjacent = Path.Combine(TrialPaths.ExecutableDirectory, "portrait-runtime");
            if (File.Exists(Path.Combine(adjacent, "runtime.json"))) return adjacent;
            var workspace = TrialPaths.FindWorkspace(TrialPaths.ExecutableDirectory);
            return workspace is null ? adjacent : Path.Combine(workspace, ".tools/portrait-alpha");
        }
    }
    public static string WorkerPath {
        get {
            var adjacent = Path.Combine(TrialPaths.ExecutableDirectory, "PortraitWorker", "worker.py");
            if (File.Exists(adjacent)) return adjacent;
            var workspace = TrialPaths.FindWorkspace(TrialPaths.ExecutableDirectory);
            return workspace is null ? adjacent : Path.Combine(workspace, "windows/experiments/SpatialPhoto/PortraitWorker/worker.py");
        }
    }
    public static async Task<PortraitScene> GenerateAsync(string photo, string output, Action<string>? progress = null, CancellationToken token = default)
    {
        var runtime = RuntimeDirectory;
        var python = Path.Combine(runtime, "python/python.exe");
        if (!File.Exists(python) || !File.Exists(Path.Combine(runtime, "runtime.json"))) throw new FileNotFoundException("人物生成ランタイムがありません。Setup-PortraitAlpha.ps1を実行してください。");
        Directory.CreateDirectory(output);
        var start = new ProcessStartInfo(python) { UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true, StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8 };
        foreach (var argument in new[] { "-u", WorkerPath, "--input", Path.GetFullPath(photo), "--runtime", runtime, "--output", Path.GetFullPath(output) }) start.ArgumentList.Add(argument);
        start.Environment["PYTHONUTF8"] = "1";
        start.Environment["PYTHONPYCACHEPREFIX"] = Path.Combine(output, "worker-pycache");
        start.Environment["NUMBA_CACHE_DIR"] = Path.Combine(output, "numba-cache");
        start.Environment["HF_HUB_OFFLINE"] = "1"; start.Environment["TRANSFORMERS_OFFLINE"] = "1";
        start.Environment["HF_HOME"] = Path.Combine(runtime, "hf-cache"); start.Environment["TORCH_HOME"] = Path.Combine(runtime, "torch-cache");
        using var process = Process.Start(start) ?? throw new IOException("人物生成プロセスを起動できません。");
        using var cancellation = token.Register(() => { try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { } });
        var errors = process.StandardError.ReadToEndAsync(); string? manifest = null, failure = null;
        while (await process.StandardOutput.ReadLineAsync(token) is { } line) {
            try {
                using var json = JsonDocument.Parse(line); var root = json.RootElement;
                var stage = root.GetProperty("stage").GetString(); var message = root.GetProperty("message").GetString() ?? "";
                if (stage == "complete") manifest = message;
                else if (stage == "error") failure = message;
                else progress?.Invoke(message);
            } catch (JsonException) { /* Third-party diagnostic output is not a status message. */ }
        }
        await process.WaitForExitAsync(token);
        var errorText = await errors;
        await File.WriteAllTextAsync(Path.Combine(output, "last-worker-stderr.txt"), errorText, token);
        if (process.ExitCode != 0 || manifest is null) throw new InvalidOperationException(failure ?? "人物3D生成に失敗しました。last-worker-stderr.txtを確認してください。");
        token.ThrowIfCancellationRequested();
        var expectedRoot = Path.GetFullPath(output) + Path.DirectorySeparatorChar;
        if (!Path.GetFullPath(manifest).StartsWith(expectedRoot, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Worker returned an unexpected scene path.");
        return await Task.Run(() => PortraitScene.Load(manifest), token);
    }
}

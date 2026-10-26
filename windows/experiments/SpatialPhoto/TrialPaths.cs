namespace DpwSpatial;

internal static class TrialPaths
{
    // IncludeAllContentForSelfExtract moves AppContext.BaseDirectory to the bundle
    // extraction area; models remain next to the physical EXE.
    public static string ExecutableDirectory => string.Equals(Path.GetFileNameWithoutExtension(Environment.ProcessPath), "dotnet", StringComparison.OrdinalIgnoreCase)
        ? AppContext.BaseDirectory : Path.GetDirectoryName(Environment.ProcessPath) ?? AppContext.BaseDirectory;
    internal static string? FindWorkspace(string executableDirectory)
    {
        for (var directory = new DirectoryInfo(executableDirectory); directory is not null; directory = directory.Parent)
            if (File.Exists(Path.Combine(directory.FullName, "windows/experiments/SpatialPhoto/SpatialPhoto.csproj"))) return directory.FullName;
        return null;
    }
    public static string Model(string executableDirectory)
    {
        var adjacent = Path.Combine(executableDirectory, "models", "model.onnx");
        if (File.Exists(adjacent)) return adjacent;
        var workspace = FindWorkspace(executableDirectory);
        return workspace is null ? adjacent : Path.Combine(workspace, ".tools/models/depth-anything-v2-small/model.onnx");
    }
    public static string Cache(string executableDirectory)
    {
        var workspace = FindWorkspace(executableDirectory);
        return workspace is null
            ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "DynamicPhotoWall.SpatialPhotoTest", "cache")
            : Path.Combine(workspace, "artifacts/windows/spatial-photo/cache");
    }
}

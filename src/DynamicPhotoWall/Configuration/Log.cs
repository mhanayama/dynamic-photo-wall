namespace DynamicPhotoWall.Configuration;

public static class Log
{
    private static readonly object gate = new();
    public static string DataDirectory { get; set; } = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "DynamicPhotoWall");
    public static void Write(string message, Exception? exception = null)
    {
        try
        {
            lock (gate)
            {
                Directory.CreateDirectory(DataDirectory);
                var path = Path.Combine(DataDirectory, "app.log");
                if (File.Exists(path) && new FileInfo(path).Length > 2_000_000) File.Move(path, path + ".1", true);
                File.AppendAllText(path, $"{DateTimeOffset.Now:O} {message} {exception?.ToString()}\n");
            }
        }
        catch (IOException) { } catch (UnauthorizedAccessException) { }
    }
}

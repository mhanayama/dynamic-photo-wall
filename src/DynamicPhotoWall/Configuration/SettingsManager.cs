using System.Text.Json;
using Microsoft.Win32;

namespace DynamicPhotoWall.Configuration;

public sealed class SettingsManager
{
    public string FilePath => Path.Combine(Log.DataDirectory, "settings.json");
    public string? Warning { get; private set; }
    public WallSettings Load()
    {
        try
        {
            if (!File.Exists(FilePath)) return new();
            var result = JsonSerializer.Deserialize<WallSettings>(File.ReadAllText(FilePath)) ?? throw new JsonException("設定がnullです。");
            result.Normalize(); return result;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException or NotSupportedException)
        {
            Warning = "設定ファイルを読み込めませんでした。初期設定で起動しました。";
            Log.Write(Warning, e);
            try { File.Copy(FilePath, FilePath + $".invalid-{DateTime.Now:yyyyMMddHHmmss}", true); } catch (Exception backup) when (backup is IOException or UnauthorizedAccessException) { }
            return new();
        }
    }
    public void Save(WallSettings settings)
    {
        settings.Normalize();
        Directory.CreateDirectory(Log.DataDirectory);
        var temp = FilePath + ".tmp";
        File.WriteAllText(temp, JsonSerializer.Serialize(settings, new JsonSerializerOptions { WriteIndented = true }));
        File.Move(temp, FilePath, true);
    }
    public static WallSettings Clone(WallSettings settings) => JsonSerializer.Deserialize<WallSettings>(JsonSerializer.Serialize(settings))!;
    public static void SetAutoStart(bool enabled)
    {
        using var key = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");
        if (enabled)
        {
            var executable = Environment.ProcessPath ?? throw new InvalidOperationException("実行ファイルの場所を取得できません。");
            if (Path.GetFileNameWithoutExtension(executable).Equals("dotnet", StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("自動起動は配布用exeから設定してください。");
            key.SetValue("DynamicPhotoWall", $"\"{executable}\" --tray");
        }
        else key.DeleteValue("DynamicPhotoWall", false);
    }
}

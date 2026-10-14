using System.Collections.ObjectModel;
using System.Windows.Media;
using DynamicPhotoWall.Configuration;
using DynamicPhotoWall.DesktopIntegration;

namespace DynamicPhotoWall.UI;

public partial class SettingsWindow : Window
{
    private readonly WallController controller;
    private readonly SettingsManager manager;
    private readonly WallSettings draft;
    private readonly ObservableCollection<string> folders;
    public SettingsWindow(WallController controller, SettingsManager manager)
    {
        InitializeComponent(); this.controller = controller; this.manager = manager;
        draft = SettingsManager.Clone(controller.Settings); folders = new(draft.Folders);
        DataContext = draft; FolderList.ItemsSource = folders; LoadMonitors();
        controller.Changed += UpdateStatus; Closed += (_, _) => controller.Changed -= UpdateStatus;
        UpdateStatus();
    }
    private void LoadMonitors()
    {
        var id = MonitorPicker.SelectedValue as string ?? draft.MonitorId;
        var monitors = MonitorManager.Enumerate(); MonitorPicker.ItemsSource = monitors;
        MonitorPicker.SelectedItem = monitors.FirstOrDefault(m => m.Id == id) ?? (id == null ? monitors.OrderByDescending(m => (double)m.Width / m.Height).FirstOrDefault() : null);
        ConnectionStatus.Text = id != null && monitors.All(m => m.Id != id) ? "保存済みのディスプレイは未接続です。再接続するか表示対象を選び直してください。" : $"{monitors.Count}台接続中。選択画面だけに写真を表示します。";
    }
    private void RefreshDisplays(object sender, RoutedEventArgs e) => LoadMonitors();
    private void UpdateStatus() => StatusText.Text = $"{controller.Status}  ·  ライブラリ {controller.PhotoCount}枚";
    private void AddFolder(object sender, RoutedEventArgs e)
    {
        using var dialog = new System.Windows.Forms.FolderBrowserDialog { Description = "写真フォルダーを選択", UseDescriptionForTitle = true };
        if (dialog.ShowDialog() == System.Windows.Forms.DialogResult.OK && !folders.Contains(dialog.SelectedPath, StringComparer.OrdinalIgnoreCase)) folders.Add(dialog.SelectedPath);
    }
    private void RemoveFolder(object sender, RoutedEventArgs e) { if (FolderList.SelectedItem is string path) folders.Remove(path); }
    private static bool HasErrors(DependencyObject parent)
    {
        if (Validation.GetHasError(parent)) return true;
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(parent); i++) if (HasErrors(VisualTreeHelper.GetChild(parent, i))) return true;
        return false;
    }
    private async Task<bool> SaveAsync()
    {
        try
        {
            if (HasErrors(this)) throw new InvalidOperationException("数値を正しく入力してください。");
            draft.Folders = folders.ToList(); draft.MonitorId = MonitorPicker.SelectedValue as string ?? draft.MonitorId;
            if (!((draft.GalleryEnabled || draft.GalleryScrollEnabled) && draft.GalleryWeight > 0 || (draft.VerticalPanEnabled || draft.HorizontalPanEnabled) && draft.PanWeight > 0 || draft.ZoomEnabled && draft.ZoomWeight > 0))
                throw new InvalidOperationException("少なくとも1つの表示モードを有効にして、ウェイトを1以上にしてください。");
            _ = new BrushConverter().ConvertFromString(draft.Background);
            draft.Normalize();
            SaveButton.IsEnabled = false;
            if (draft.AutoStart != controller.Settings.AutoStart) SettingsManager.SetAutoStart(draft.AutoStart);
            manager.Save(draft);
            await controller.ApplyAsync(SettingsManager.Clone(draft));
            DataContext = null; DataContext = draft;
            UpdateStatus(); return true;
        }
        catch (Exception e) { Log.Write("設定を適用できません。", e); StatusText.Text = e.Message; return false; }
        finally { SaveButton.IsEnabled = true; }
    }
    private async void SaveClicked(object sender, RoutedEventArgs e) => await SaveAsync();
    private async void StartClicked(object sender, RoutedEventArgs e) { if (await SaveAsync()) await WallController.GuardAsync(controller.StartAsync); }
    private async void StopClicked(object sender, RoutedEventArgs e) => await WallController.GuardAsync(controller.StopAsync);
    private void PauseClicked(object sender, RoutedEventArgs e) => controller.TogglePause();
    private void NextClicked(object sender, RoutedEventArgs e) => controller.Next();
    private void CloseClicked(object sender, RoutedEventArgs e) => Close();
}

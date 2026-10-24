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
    private readonly DisplayLayoutEditor displayEditor = new();
    private readonly NetworkSettingsPanel networkPanel;
    public SettingsWindow(WallController controller, SettingsManager manager)
    {
        InitializeComponent(); this.controller = controller; this.manager = manager;
        networkPanel = new(controller, manager); NetworkPanelHost.Content = networkPanel;
        draft = SettingsManager.Clone(controller.Settings); folders = new(draft.Folders);
        if (controller.Network.Session is { } session) Networking.Windows.WindowsPlaybackOptions.Apply(session.Snapshot.Playback, draft);
        networkPanel.SharedOptionsChanged += options =>
        {
            Networking.Windows.WindowsPlaybackOptions.Apply(options, draft);
            DataContext = null; DataContext = draft;
        };
        draft.DisplayTestPattern = false;
        DataContext = draft; FolderList.ItemsSource = folders; DisplayEditorHost.Content = displayEditor;
        DisplaySelectionHost.Content = displayEditor.SelectionView; TaskbarSettingsHost.Content = displayEditor.TaskbarView; LoadMonitors();
        controller.Changed += UpdateStatus; Closed += (_, _) => { controller.Changed -= UpdateStatus; networkPanel.Dispose(); };
        UpdateStatus();
        AddHandler(System.Windows.Controls.Primitives.ButtonBase.ClickEvent, new RoutedEventHandler((_, e) => MarkSharedEdit(e.OriginalSource)));
        AddHandler(TextBox.TextChangedEvent, new TextChangedEventHandler((_, e) => MarkSharedEdit(e.OriginalSource)));
    }
    private void MarkSharedEdit(object source)
    {
        for (var node = source as DependencyObject; node != null; node = node is Visual ? VisualTreeHelper.GetParent(node) : LogicalTreeHelper.GetParent(node))
            if (node is TabItem tab)
            {
                if (tab.Header is "写真" or "表示モード" or "動き" or "見た目") networkPanel.MarkOptionsEdited();
                return;
            }
    }
    private void LoadMonitors()
    {
        displayEditor.Load(draft);
        ConnectionStatus.Text = $"{MonitorManager.Enumerate().Count}台接続中。保存済みの未接続画面は、再接続時に復帰します。";
    }
    private void RefreshDisplays(object sender, RoutedEventArgs e) => LoadMonitors();
    private void UpdateStatus()
    {
        if (controller.Network.Online)
        {
            DisplayEditorHost.Content = networkPanel.GroupView;
            DisplaySelectionHost.Content = networkPanel.SelectionView;
        }
        else
        {
            DisplayEditorHost.Content = displayEditor;
            DisplaySelectionHost.Content = displayEditor.SelectionView;
        }
        StatusText.Text = $"{controller.Status}  ·  ライブラリ {controller.PhotoCount}枚";
        TestPatternButton.Content = controller.TestPatternVisible || controller.Network.PreviewVisible ? "表示停止" : "表示";
    }
    private async void TestPatternClicked(object sender, RoutedEventArgs e)
    {
        TestPatternButton.IsEnabled = false;
        try
        {
            if (controller.Network.Online) { await networkPanel.TogglePreviewAsync(); return; }
            if (controller.TestPatternVisible) await controller.HideTestPatternAsync();
            else
            {
                if (HasErrors(this)) throw new InvalidOperationException("座標を正しく入力してください。");
                var preview = SettingsManager.Clone(draft); preview.Displays = displayEditor.SelectedPlacements();
                await controller.ShowTestPatternAsync(preview);
            }
        }
        catch (Exception error) { Log.Write("テストパターンを切り替えられません。", error); StatusText.Text = error.Message; }
        finally { TestPatternButton.IsEnabled = true; TestPatternButton.Content = controller.TestPatternVisible || controller.Network.PreviewVisible ? "表示停止" : "表示"; }
    }
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
            draft.Folders = folders.ToList(); draft.Displays = displayEditor.SelectedPlacements();
            draft.DisplayGroupNames = displayEditor.GroupNames.ToList(); draft.DisplayTestPattern = false;
            if (draft.Displays.Count == 0 && !controller.Network.Online) throw new InvalidOperationException("表示する画面を1台以上選択してください。");
            foreach (var group in DisplayGroups.Create(draft.Displays)) _ = new WallLayout(group.Displays);
            draft.MonitorId = draft.Displays.FirstOrDefault()?.Id;
            if (!((draft.GalleryEnabled || draft.GalleryScrollEnabled) && draft.GalleryWeight > 0 || (draft.VerticalPanEnabled || draft.HorizontalPanEnabled) && draft.PanWeight > 0 || draft.ZoomEnabled && draft.ZoomWeight > 0))
                throw new InvalidOperationException("少なくとも1つの表示モードを有効にして、ウェイトを1以上にしてください。");
            _ = new BrushConverter().ConvertFromString(draft.Background);
            draft.Normalize();
            draft.OnlineMode = controller.Settings.OnlineMode;
            SaveButton.IsEnabled = false;
            if (!await networkPanel.ApplyAsync(draft)) return false;
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

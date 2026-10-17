using System.ComponentModel;
using System.Collections.ObjectModel;
using System.Runtime.CompilerServices;
using System.Windows.Data;
using System.Windows.Input;
using DynamicPhotoWall.DesktopIntegration;

namespace DynamicPhotoWall.UI;

public sealed class DisplayChoice : INotifyPropertyChanged
{
    public required string Id { get; init; }
    public required string Label { get; init; }
    public int Width { get; init; }
    public int Height { get; init; }
    private bool selected;
    private string? groupId;
    private bool hideTaskbar;
    private int x, y;
    public bool Selected { get => selected; set { selected = value; Notify(); } }
    public int X { get => x; set { x = value; Notify(); } }
    public int Y { get => y; set { y = value; Notify(); } }
    public string? GroupId { get => groupId; set { groupId = value; Notify(); } }
    public bool HideTaskbar { get => hideTaskbar; set { hideTaskbar = value; Notify(); } }
    public event PropertyChangedEventHandler? PropertyChanged;
    private void Notify([CallerMemberName] string? name = null) => PropertyChanged?.Invoke(this, new(name));
    public DisplayPlacement Placement() => new() { Id = Id, X = X, Y = Y, Width = Width, Height = Height, GroupId = GroupId, HideTaskbar = HideTaskbar };
}

public sealed class DisplayLayoutEditor : StackPanel
{
    private sealed record GroupOption(string? Id, string Name);
    private readonly ObservableCollection<GroupOption> groupOptions = [new(null, "独立して表示")];
    private readonly Canvas preview = new() { Height = 140, Background = PhotoRendererBrush("#10131B"), ClipToBounds = true, Margin = new Thickness(0, 12, 0, 8), ToolTip = "カードをドラッグして位置や隙間を調整できます。" };
    private readonly StackPanel rows = new();
    private readonly StackPanel coordinateRows = new();
    private readonly WrapPanel groupList = new();
    private readonly TextBlock groupCount = new() { FontSize = 16, Foreground = Brushes.White, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock summary = new() { Foreground = Brushes.LightSteelBlue };
    public StackPanel SelectionView { get; } = new();
    public StackPanel TaskbarView { get; } = new();
    public List<DisplayChoice> Choices { get; private set; } = [];
    public IReadOnlyList<string> GroupNames => groupOptions.Where(g => g.Id != null).Select(g => g.Id!).ToArray();
    private bool dragging, loaded, updatingGroups;
    private double scale, originX, originY;
    private static Brush PhotoRendererBrush(string color) => Rendering.PhotoRenderer.ParseBrush(color);
    public DisplayLayoutEditor()
    {
        var header = new DockPanel { Margin = new Thickness(0, 0, 0, 8) };
        var addGroup = new Button { Name = "AddGroupButton", Content = "＋ グループを追加", HorizontalAlignment = HorizontalAlignment.Right };
        addGroup.Click += (_, _) => AddGroup();
        DockPanel.SetDock(addGroup, Dock.Right); header.Children.Add(addGroup); header.Children.Add(groupCount);
        Children.Add(header); Children.Add(groupList);
        Children.Add(new TextBlock { Text = "グループを削除すると、所属画面は「独立して表示」に戻ります。", Foreground = Brushes.LightSteelBlue, FontSize = 12 });
        Children.Add(new TextBlock { Text = "画面の割り当て", Foreground = Brushes.LightSteelBlue, Margin = new Thickness(0, 8, 0, 8) });
        Children.Add(rows); Children.Add(preview); Children.Add(summary);
        Children.Add(new Expander { Header = "配置を数値で調整", Content = coordinateRows, Foreground = Brushes.LightSteelBlue, Margin = new Thickness(0, 12, 0, 8) });
        preview.SizeChanged += (_, _) => Draw();
    }
    public void Load(WallSettings settings)
    {
        var connected = MonitorManager.Enumerate();
        var previous = Choices.ToDictionary(c => c.Id);
        var saved = Choices.Count > 0 ? Choices.Where(c => c.Selected).Select(c => c.Placement()).ToList() : settings.Displays;
        var ids = saved.Select(d => d.Id).Concat(connected.Select(m => m.Id)).Distinct().ToArray();
        var defaultId = settings.MonitorId ?? connected.OrderByDescending(m => (double)m.Width / m.Height).FirstOrDefault()?.Id;
        Choices = ids.Select(id =>
        {
            var m = connected.FirstOrDefault(m => m.Id == id); var p = saved.FirstOrDefault(p => p.Id == id);
            var old = previous.GetValueOrDefault(id);
            return new DisplayChoice { Id = id, Label = $"{m?.Device.Replace(@"\\.\", "") ?? "未接続"} · {m?.Name ?? "保存済み画面"} · {m?.Width ?? p!.Width} × {m?.Height ?? p!.Height}",
                Selected = p != null || previous.Count == 0 && saved.Count == 0 && id == defaultId, X = old?.X ?? p?.X ?? m!.X, Y = old?.Y ?? p?.Y ?? m!.Y,
                Width = m?.Width ?? p!.Width, Height = m?.Height ?? p!.Height,
                GroupId = old != null ? old.GroupId : p?.GroupId, HideTaskbar = old?.HideTaskbar ?? p?.HideTaskbar ?? settings.HideTaskbar };
        }).ToList();
        // Refresh uses the editor's draft catalog; importing saved names again
        // would resurrect groups deleted before saving.
        if (!loaded)
            foreach (var name in settings.DisplayGroupNames.Where(n => !string.IsNullOrWhiteSpace(n)))
                if (groupOptions.All(g => g.Id != name)) groupOptions.Add(new(name, name));
        foreach (var choice in Choices.Where(c => !string.IsNullOrWhiteSpace(c.GroupId)))
            if (groupOptions.All(g => g.Id != choice.GroupId)) groupOptions.Add(new(choice.GroupId, choice.GroupId!));
        loaded = true;
        SelectionView.Children.Clear();
        foreach (var choice in Choices)
        {
            choice.PropertyChanged += (_, e) =>
            {
                if (e.PropertyName == nameof(DisplayChoice.Selected)) BuildSelectedViews();
                if (!updatingGroups && e.PropertyName != nameof(DisplayChoice.HideTaskbar)) Draw();
            };
            var check = new CheckBox { Content = choice.Label, DataContext = choice, Padding = new Thickness(4), Margin = new Thickness(0) };
            check.SetBinding(CheckBox.IsCheckedProperty, new Binding(nameof(DisplayChoice.Selected)) { Mode = BindingMode.TwoWay });
            SelectionView.Children.Add(new Border { Child = check, Padding = new Thickness(12), Margin = new Thickness(0, 0, 0, 10), Background = PhotoRendererBrush("#252A36"), CornerRadius = new CornerRadius(6) });
        }
        BuildSelectedViews(); Draw();
    }
    private void BuildSelectedViews()
    {
        rows.Children.Clear(); coordinateRows.Children.Clear(); TaskbarView.Children.Clear();
        var reset = new Button { Content = "Windowsの配置に戻す", HorizontalAlignment = HorizontalAlignment.Left };
        reset.Click += (_, _) => UseDesktopLayout(); coordinateRows.Children.Add(reset);
        var selected = Choices.Where(c => c.Selected).ToArray();
        if (selected.Length == 0)
        {
            rows.Children.Add(new TextBlock { Text = "「使用ディスプレイ」で画面を選択してください。", Foreground = Brushes.LightSteelBlue });
            TaskbarView.Children.Add(new TextBlock { Text = "使用するディスプレイを選ぶと、ここで設定できます。", Foreground = Brushes.LightSteelBlue });
        }
        foreach (var choice in selected)
        {
            var row = new Grid { Margin = new Thickness(0, 0, 0, 8) };
            row.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) }); row.ColumnDefinitions.Add(new() { Width = new GridLength(180) });
            row.Children.Add(new TextBlock { Text = choice.Label, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 12, 0), Foreground = Brushes.White });
            var picker = new ComboBox { ItemsSource = groupOptions, DisplayMemberPath = nameof(GroupOption.Name), Padding = new Thickness(8), Foreground = Brushes.Black,
                SelectedItem = groupOptions.FirstOrDefault(g => g.Id == choice.GroupId) ?? groupOptions[0], ToolTip = "同じグループを選んだ画面をつなぎます。" };
            picker.SelectionChanged += (_, _) => { if (picker.SelectedItem is GroupOption option) choice.GroupId = option.Id; };
            Grid.SetColumn(picker, 1); row.Children.Add(picker); rows.Children.Add(row);
            var taskbar = new CheckBox { Content = choice.Label, DataContext = choice, Margin = new Thickness(0, 4, 0, 10), Foreground = Brushes.White };
            taskbar.SetBinding(CheckBox.IsCheckedProperty, new Binding(nameof(DisplayChoice.HideTaskbar)) { Mode = BindingMode.TwoWay }); TaskbarView.Children.Add(taskbar);
            var coordinates = new StackPanel { Orientation = Orientation.Horizontal };
            foreach (var axis in new[] { nameof(DisplayChoice.X), nameof(DisplayChoice.Y) })
            {
                coordinates.Children.Add(new TextBlock { Text = axis + " (px)", Width = 55, Foreground = Brushes.LightSteelBlue, VerticalAlignment = VerticalAlignment.Center });
                var box = new TextBox { DataContext = choice, Width = 120, Margin = new Thickness(0, 0, 16, 0) };
                box.SetBinding(TextBox.TextProperty, new Binding(axis) { Mode = BindingMode.TwoWay, UpdateSourceTrigger = UpdateSourceTrigger.PropertyChanged, ValidatesOnExceptions = true });
                coordinates.Children.Add(box);
            }
            coordinateRows.Children.Add(new TextBlock { Text = choice.Label, Foreground = Brushes.LightSteelBlue }); coordinateRows.Children.Add(coordinates);
        }
    }
    public List<DisplayPlacement> SelectedPlacements() => Choices.Where(c => c.Selected).Select(c => c.Placement()).ToList();
    public void AddGroup()
    {
        var number = 1; while (groupOptions.Any(g => g.Id == $"グループ{number}")) number++;
        groupOptions.Add(new($"グループ{number}", $"グループ{number}")); RefreshGroupList();
    }
    public bool RemoveGroup(string name)
    {
        var option = groupOptions.FirstOrDefault(g => g.Id == name && g.Id != null);
        if (option == null) return false;
        updatingGroups = true;
        try
        {
            // Include deselected screens so selecting them again cannot restore
            // membership in a group that no longer exists.
            foreach (var choice in Choices.Where(c => c.GroupId?.Trim() == name)) choice.GroupId = null;
            groupOptions.Remove(option);
            BuildSelectedViews();
        }
        finally { updatingGroups = false; }
        Draw(); return true;
    }
    private static readonly string[] groupColors = ["#294875", "#355A45", "#674568", "#6B512C", "#365C65"];
    private Brush GroupBrush(string? id) => PhotoRendererBrush(string.IsNullOrWhiteSpace(id) ? "#333B4C" : groupColors[Math.Max(0, groupOptions.ToList().FindIndex(g => g.Id == id) - 1) % groupColors.Length]);
    private void RefreshGroupList()
    {
        groupList.Children.Clear(); groupCount.Text = $"グループ一覧（{GroupNames.Count}）";
        foreach (var name in GroupNames)
        {
            var members = Choices.Where(c => c.Selected && c.GroupId?.Trim() == name).ToArray();
            var content = new StackPanel();
            var header = new DockPanel { Margin = new Thickness(0, 0, 0, 4) };
            var remove = new Button { Name = "RemoveGroupButton", Tag = name, Content = "削除", Padding = new Thickness(8, 4, 8, 4), Margin = new Thickness(12, 0, 0, 0), VerticalAlignment = VerticalAlignment.Top,
                ToolTip = "グループを削除し、所属画面を「独立して表示」に戻します。保存時に反映します。" };
            remove.Click += (_, _) => RemoveGroup(name);
            DockPanel.SetDock(remove, Dock.Right); header.Children.Add(remove);
            header.Children.Add(new TextBlock { Text = $"{name} · {members.Length}画面", Foreground = Brushes.White, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0) });
            content.Children.Add(header);
            content.Children.Add(new TextBlock { Text = members.Length == 0 ? "画面未割り当て" : string.Join(", ", members.Select(c => c.Label.Split('·')[0].Trim())), Foreground = Brushes.LightSteelBlue, FontSize = 12, Margin = new Thickness(0) });
            groupList.Children.Add(new Border { Child = content, Background = GroupBrush(name), CornerRadius = new CornerRadius(6), Padding = new Thickness(12, 8, 12, 8), Margin = new Thickness(0, 0, 8, 8), MinWidth = 150, MaxWidth = 250 });
        }
    }
    public void UseDesktopLayout()
    {
        var monitors = MonitorManager.Enumerate();
        foreach (var choice in Choices) { var m = monitors.FirstOrDefault(m => m.Id == choice.Id); if (m != null) { choice.X = m.X; choice.Y = m.Y; } }
        Draw();
    }
    private void Draw()
    {
        RefreshGroupList();
        if (dragging) return;
        preview.Children.Clear();
        var selected = Choices.Where(c => c.Selected).ToArray();
        if (selected.Length == 0) { summary.Text = "表示する画面を1台以上選択してください。"; return; }
        var minX = selected.Min(c => (double)c.X); var minY = selected.Min(c => (double)c.Y);
        var width = selected.Max(c => (double)c.X + c.Width) - minX; var height = selected.Max(c => (double)c.Y + c.Height) - minY;
        scale = Math.Min(Math.Max(1, preview.ActualWidth - 32) / width, (preview.Height - 24) / height);
        originX = (preview.ActualWidth - width * scale) / 2 - minX * scale; originY = (preview.Height - height * scale) / 2 - minY * scale;
        var groups = DisplayGroups.Create(SelectedPlacements());
        summary.Text = string.Join(" / ", groups.Select(g => $"{g.Name}: {g.Displays.Count}画面"));
        foreach (var choice in selected)
        {
            var groupIndex = groups.ToList().FindIndex(g => g.Displays.Any(d => d.Id == choice.Id));
            var card = new Border { Width = choice.Width * scale, Height = choice.Height * scale, Background = GroupBrush(choice.GroupId), BorderBrush = Brushes.LightSkyBlue, BorderThickness = new Thickness(2), Cursor = Cursors.SizeAll,
                Child = new TextBlock { Text = $"{Array.IndexOf(selected, choice) + 1} · {groups[groupIndex].Name}\n{choice.Width} × {choice.Height}", TextAlignment = TextAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Foreground = Brushes.White } };
            Canvas.SetLeft(card, originX + choice.X * scale); Canvas.SetTop(card, originY + choice.Y * scale); preview.Children.Add(card);
            Point start = default; int startX = 0, startY = 0;
            card.MouseLeftButtonDown += (_, e) => { dragging = true; start = e.GetPosition(preview); startX = choice.X; startY = choice.Y; card.CaptureMouse(); e.Handled = true; };
            card.MouseMove += (_, e) =>
            {
                if (!card.IsMouseCaptured) return;
                var point = e.GetPosition(preview);
                choice.X = Snap((int)Math.Round(startX + (point.X - start.X) / scale), choice, true);
                choice.Y = Snap((int)Math.Round(startY + (point.Y - start.Y) / scale), choice, false);
                Canvas.SetLeft(card, originX + choice.X * scale); Canvas.SetTop(card, originY + choice.Y * scale);
            };
            card.MouseLeftButtonUp += (_, _) => { card.ReleaseMouseCapture(); dragging = false; Draw(); };
            card.LostMouseCapture += (_, _) => { dragging = false; Draw(); };
        }
    }
    private int Snap(int value, DisplayChoice moving, bool horizontal)
    {
        var size = horizontal ? moving.Width : moving.Height;
        var candidates = Choices.Where(c => c.Selected && c != moving && !string.IsNullOrWhiteSpace(moving.GroupId) && c.GroupId?.Trim() == moving.GroupId.Trim()).SelectMany(c =>
        {
            var pos = horizontal ? c.X : c.Y; var otherSize = horizontal ? c.Width : c.Height;
            return new[] { pos, pos + otherSize, pos - size, pos + otherSize - size, pos + (otherSize - size) / 2 };
        }).ToArray();
        var closest = candidates.OrderBy(c => Math.Abs((double)c - value)).FirstOrDefault(value);
        return Math.Clamp(Math.Abs((double)closest - value) * scale <= 10 ? closest : value, -32768, 32768);
    }
}

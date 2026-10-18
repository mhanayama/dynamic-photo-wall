using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Windows.Data;
using DynamicPhotoWall.Configuration;
using Net = DynamicPhotoWall.Networking;

namespace DynamicPhotoWall.UI;

// View owns drafts only. Transport, settings authority and photo work live behind the host.
public sealed class NetworkSettingsPanel : StackPanel, IDisposable
{
    private sealed record GroupChoice(Guid? Id, string Name);
    private sealed class DisplayRow(Net.PeerDisplay value, Action changed) : INotifyPropertyChanged
    {
        public Net.PeerDisplay Value = value;
        public string Name => $"{Value.Key.PeerId.ToString("N")[..8]} / {Value.Key.DisplayId}";
        public bool Selected { get => Value.Selected; set { Value = Value with { Selected = value }; Notify(nameof(Selected)); } }
        public Guid? GroupId { get => Value.GroupId; set { Value = Value with { GroupId = value }; Notify(nameof(GroupId)); } }
        public int X { get => Value.X; set { Value = Value with { X = value }; Notify(nameof(X)); } }
        public int Y { get => Value.Y; set { Value = Value with { Y = value }; Notify(nameof(Y)); } }
        public string Size => $"{Value.Width}×{Value.Height}";
        public event PropertyChangedEventHandler? PropertyChanged;
        private void Notify(string name) { changed(); PropertyChanged?.Invoke(this, new(name)); }
    }
    private readonly WallController controller;
    private readonly SettingsManager manager;
    private readonly CheckBox online = new() { Content = "オンラインモード" };
    private readonly TextBlock status = new();
    private readonly ListBox candidates = new() { Height = 130, DisplayMemberPath = "Hello.Name",
        Background = new SolidColorBrush(Color.FromRgb(28, 32, 42)), Foreground = Brushes.White,
        BorderBrush = new SolidColorBrush(Color.FromRgb(70, 80, 102)), Padding = new Thickness(8) };
    private readonly StackPanel sources = new();
    private readonly TextBlock draftStatus = new();
    private readonly NetworkLayoutPreview preview;
    private readonly ObservableCollection<DisplayRow> rows = [];
    private readonly ObservableCollection<GroupChoice> groupChoices = [new(null, "単独表示")];
    private readonly Dictionary<(Guid, Guid), (Net.SharedSource Source, CheckBox Check)> sourceChecks = [];
    private readonly HashSet<Guid> refreshProviders = [];
    private Net.WallSnapshot? baseline;
    private List<Net.SharedGroup> groups = [];
    private bool dirty, refreshing, disposed;
    private string sourceSignature = "";
    public FrameworkElement GroupView { get; }
    public FrameworkElement SelectionView { get; }
    public event Action<Net.PlaybackOptions>? SharedOptionsChanged;
    public void MarkOptionsEdited() { if (!refreshing && controller.Network.Online) dirty = true; }
    public Task TogglePreviewAsync() => controller.Network.Session?.PreviewAsync(new(!controller.Network.PreviewVisible,
        rows.Select(r => r.Value).ToArray(), groups.ToArray())) ?? Task.CompletedTask;
    public NetworkSettingsPanel(WallController controller, SettingsManager manager)
    {
        this.controller = controller; this.manager = manager;
        preview = new(() => rows.Select(r => r.Value).ToArray(), (key, x, y) =>
        { var row = rows.First(r => r.Value.Key == key); row.X = x; row.Y = y; });
        Children.Add(new TextBlock { Text = "ピア接続", FontSize = 24 }); Children.Add(online); Children.Add(status);
        Children.Add(new TextBlock { Text = "接続候補" }); Children.Add(candidates);
        AddButton(this, "接続", async () =>
        {
            if (candidates.SelectedItem is Net.PeerCandidate peer && controller.Network.Session is { } session)
                await session.ConnectAsync(peer);
        });
        Children.Add(new TextBlock { Text = "写真ソース", FontSize = 18 }); Children.Add(sources);
        AddButton(this, "選択した写真キャッシュを更新", async () =>
        {
            foreach (var item in sourceChecks.Values.Where(v => v.Check.IsChecked == true)) refreshProviders.Add(item.Source.ProviderId);
            if (controller.Network.Session is { } session)
                await ApplyAsync(Networking.Windows.WindowsPlaybackOptions.Import(baseline?.Playback ?? session.Snapshot.Playback));
        });
        Children.Add(new TextBlock { Text = "写真と顔データは原寸の暗号化キャッシュとして転送します。有効期限は14日です。", TextWrapping = TextWrapping.Wrap });
        var groupView = new StackPanel();
        groupView.Children.Add(new TextBlock { Text = "全ピアの画面グルーピング", FontSize = 22 }); groupView.Children.Add(draftStatus);
        var buttons = new WrapPanel();
        AddButton(buttons, "グループを追加", () =>
        {
            var number = 1; while (groups.Any(g => g.Name == $"グループ{number}")) number++;
            groups.Add(new(Guid.NewGuid(), $"グループ{number}")); dirty = true; UpdateChoices(); return Task.CompletedTask;
        });
        AddButton(buttons, "最新版を読み直す", () => { dirty = false; baseline = null; Refresh(); return Task.CompletedTask; });
        groupView.Children.Add(buttons);
        var groupList = new StackPanel(); groupView.Children.Add(groupList);
        groupChoices.CollectionChanged += (_, _) =>
        {
            groupList.Children.Clear();
            foreach (var group in groups.ToArray())
            {
                var line = new WrapPanel(); line.Children.Add(new TextBlock { Text = group.Name, Width = 180 });
                AddButton(line, "削除", () =>
                {
                    foreach (var row in rows.Where(r => r.GroupId == group.Id)) row.GroupId = null;
                    groups.RemoveAll(g => g.Id == group.Id); dirty = true; UpdateChoices(); return Task.CompletedTask;
                });
                groupList.Children.Add(line);
            }
        };
        groupView.Children.Add(preview); groupView.Children.Add(CreateGrid(includeLayout: true)); GroupView = groupView;
        SelectionView = CreateGrid(includeLayout: false);
        online.Checked += OnlineChanged; online.Unchecked += OnlineChanged;
        controller.Network.Changed += Refresh; Refresh();
    }
    private DataGrid CreateGrid(bool includeLayout)
    {
        var grid = new DataGrid { ItemsSource = rows, AutoGenerateColumns = false, CanUserAddRows = false,
            CanUserDeleteRows = false, MinHeight = 150, MaxHeight = 400, Background = new SolidColorBrush(Color.FromRgb(28, 32, 42)),
            Foreground = Brushes.White, RowBackground = new SolidColorBrush(Color.FromRgb(37, 42, 54)) };
        grid.Columns.Add(new DataGridCheckBoxColumn { Header = "使用", Binding = new Binding(nameof(DisplayRow.Selected)) });
        grid.Columns.Add(new DataGridTextColumn { Header = "画面", Binding = new Binding(nameof(DisplayRow.Name)), IsReadOnly = true, Width = new(1, DataGridLengthUnitType.Star) });
        grid.Columns.Add(new DataGridComboBoxColumn { Header = "所属", ItemsSource = groupChoices, DisplayMemberPath = "Name", SelectedValuePath = "Id",
            SelectedValueBinding = new Binding(nameof(DisplayRow.GroupId)) { UpdateSourceTrigger = UpdateSourceTrigger.PropertyChanged } });
        if (includeLayout)
        {
            grid.Columns.Add(new DataGridTextColumn { Header = "X", Binding = new Binding(nameof(DisplayRow.X)) { ValidatesOnExceptions = true } });
            grid.Columns.Add(new DataGridTextColumn { Header = "Y", Binding = new Binding(nameof(DisplayRow.Y)) { ValidatesOnExceptions = true } });
            grid.Columns.Add(new DataGridTextColumn { Header = "解像度", Binding = new Binding(nameof(DisplayRow.Size)), IsReadOnly = true });
        }
        return grid;
    }
    private void AddButton(Panel panel, string name, Func<Task> action)
    {
        var button = new Button { Content = name };
        button.Click += async (_, _) =>
        {
            button.IsEnabled = false;
            try { await action(); }
            catch (Exception error) { status.Text = error.Message; Log.Write("ネットワーク設定を反映できません。", error); }
            finally { button.IsEnabled = true; }
        };
        panel.Children.Add(button);
    }
    private async void OnlineChanged(object sender, RoutedEventArgs e)
    {
        if (refreshing) return;
        online.IsEnabled = false;
        try
        {
            await controller.SetNetworkOnlineAsync(online.IsChecked == true);
            manager.Save(controller.Settings);
        }
        catch (Exception error) { status.Text = error.Message; }
        finally { online.IsEnabled = true; Refresh(); }
    }
    private void UpdateChoices()
    {
        foreach (var old in groupChoices.Where(g => g.Id != null && !groups.Any(wanted => wanted.Id == g.Id)).ToArray()) groupChoices.Remove(old);
        foreach (var group in groups.Where(g => !groupChoices.Any(old => old.Id == g.Id))) groupChoices.Add(new(group.Id, group.Name));
    }
    private void Refresh()
    {
        if (disposed) return;
        refreshing = true;
        try
        {
            online.IsChecked = controller.Network.Online; status.Text = controller.Network.Status;
            var session = controller.Network.Session;
            var selected = (candidates.SelectedItem as Net.PeerCandidate)?.Hello.PeerId;
            if (session == null) { candidates.ItemsSource = null; return; }
            candidates.ItemsSource = session.Candidates.Where(c => !session.ConnectedPeers.Contains(c.Hello.PeerId)).ToArray();
            candidates.SelectedItem = candidates.Items.OfType<Net.PeerCandidate>().FirstOrDefault(c => c.Hello.PeerId == selected);
            if (!dirty && (baseline == null || baseline.SessionId != session.Snapshot.SessionId || baseline.Revision != session.Snapshot.Revision))
            {
                baseline = session.Snapshot; groups = baseline.Groups.ToList();
                sourceSignature = "";
                UpdateChoices();
                rows.Clear(); foreach (var display in baseline.Displays) rows.Add(new(display, () => { if (!refreshing) dirty = true; preview.Refresh(); }));
                preview.Refresh();
                SharedOptionsChanged?.Invoke(baseline.Playback);
            }
            draftStatus.Text = dirty && baseline?.Revision != session.Snapshot.Revision ? "他のピアで設定が更新されました。未保存の編集を保持しています。" : "画面はピアをまたいでグループまたは単独表示へ割り当てられます。";
            var advertised = session.Sources.Concat(session.Snapshot.Sources.Where(s => !session.Sources.Any(a => a.ProviderId == s.ProviderId && a.SourceId == s.SourceId))
                .Select(s => new Net.SharedSource(s.ProviderId, s.SourceId, "未接続の写真ソース"))).ToArray();
            var signature = string.Join("|", advertised.Select(s => $"{s.ProviderId}:{s.SourceId}:{s.Name}"));
            if (!dirty && (sourceSignature != signature || !sourceChecks.Keys.ToHashSet().SetEquals(advertised.Select(s => (s.ProviderId, s.SourceId)))))
            {
                sourceSignature = signature; sourceChecks.Clear(); sources.Children.Clear();
                foreach (var source in advertised)
                {
                    var check = new CheckBox { Content = $"{source.Name} ({source.ProviderId.ToString("N")[..8]})",
                        IsChecked = session.Snapshot.Sources.Any(s => s.ProviderId == source.ProviderId && s.SourceId == source.SourceId) };
                    check.Checked += (_, _) => { dirty = true; refreshProviders.Add(source.ProviderId); };
                    check.Unchecked += (_, _) => { dirty = true; refreshProviders.Add(source.ProviderId); };
                    sourceChecks[(source.ProviderId, source.SourceId)] = (source, check); sources.Children.Add(check);
                }
            }
        }
        finally { refreshing = false; }
    }
    public async Task<bool> ApplyAsync(WallSettings localSettings)
    {
        var session = controller.Network.Session;
        if (session == null) return true;
        baseline ??= session.Snapshot;
        var old = baseline;
        var generations = old.Sources.GroupBy(s => s.ProviderId).ToDictionary(g => g.Key,
            g => refreshProviders.Contains(g.Key) ? Guid.NewGuid() : g.First().GenerationId);
        var selected = sourceChecks.Values.Where(item => item.Check.IsChecked == true).Select(item =>
        {
            if (!generations.TryGetValue(item.Source.ProviderId, out var generation)) generations[item.Source.ProviderId] = generation = Guid.NewGuid();
            return new Net.SourceSelection(item.Source.ProviderId, item.Source.SourceId, generation);
        }).ToArray();
        var result = await session.ProposeAsync(new(Guid.NewGuid(), old.Revision, groups.ToArray(), rows.Select(r => r.Value).ToArray(),
            selected, Networking.Windows.WindowsPlaybackOptions.Export(localSettings)));
        if (!result.Accepted) { status.Text = result.Error; return false; }
        dirty = false; refreshProviders.Clear(); baseline = null; sourceSignature = ""; Refresh(); return true;
    }
    public void Dispose() { disposed = true; controller.Network.Changed -= Refresh; }
}

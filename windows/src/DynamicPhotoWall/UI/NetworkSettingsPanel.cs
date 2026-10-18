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
    private sealed class DisplayRow(Net.PeerDisplay value, Func<Guid, string> peerName, Func<Net.PeerDisplayKey, bool> connected, Action changed) : INotifyPropertyChanged
    {
        public Net.PeerDisplay Value = value;
        public string Name => $"{peerName(Value.Key.PeerId)} / {Value.DisplayName}";
        public bool IsConnected => connected(Value.Key);
        public string Connection => IsConnected ? "接続中" : "未接続";
        private string? lastName;
        private bool? lastConnected;
        public void RefreshName()
        {
            var name = Name; var available = IsConnected;
            if (lastName != name) { lastName = name; PropertyChanged?.Invoke(this, new(nameof(Name))); }
            if (lastConnected != available) { lastConnected = available; PropertyChanged?.Invoke(this, new(nameof(Connection))); }
        }
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
    private readonly ListBox connectedPeers = new() { MaxHeight = 120,
        Background = new SolidColorBrush(Color.FromRgb(28, 32, 42)), Foreground = Brushes.White,
        BorderBrush = new SolidColorBrush(Color.FromRgb(70, 80, 102)), Padding = new Thickness(8) };
    private readonly CheckBox showDisconnectedSources = new() { Content = "未接続の写真ソースも表示" };
    private readonly TextBlock draftStatus = new();
    private readonly NetworkLayoutPreview preview;
    private readonly ObservableCollection<DisplayRow> rows = [];
    private readonly ICollectionView visibleRows;
    private string displayVisibilitySignature = "";
    private (Net.PeerDisplay Display, string PeerName, bool Connected)[] previewState = [];
    private static readonly DependencyProperty ShowDisconnectedDisplaysProperty = DependencyProperty.Register(
        nameof(ShowDisconnectedDisplays), typeof(bool), typeof(NetworkSettingsPanel),
        new PropertyMetadata(false, (owner, _) => ((NetworkSettingsPanel)owner).RefreshDisplayVisibility()));
    public bool ShowDisconnectedDisplays
    {
        get => (bool)GetValue(ShowDisconnectedDisplaysProperty);
        set => SetValue(ShowDisconnectedDisplaysProperty, value);
    }
    private readonly ObservableCollection<GroupChoice> groupChoices = [new(null, "単独表示")];
    private readonly Dictionary<(Guid, Guid), (Net.SharedSource Source, CheckBox Check)> sourceChecks = [];
    private readonly HashSet<Guid> refreshProviders = [];
    private Net.WallSnapshot? baseline;
    private List<Net.SharedGroup> groups = [];
    private bool dirty, refreshing, disposed;
    public FrameworkElement GroupView { get; }
    public FrameworkElement SelectionView { get; }
    public event Action<Net.PlaybackOptions>? SharedOptionsChanged;
    public void MarkOptionsEdited() { if (!refreshing && controller.Network.Online) dirty = true; }
    public Task TogglePreviewAsync() => controller.Network.Session?.PreviewAsync(new(!controller.Network.PreviewVisible,
        rows.Select(r => r.Value).ToArray(), groups.ToArray())) ?? Task.CompletedTask;
    public NetworkSettingsPanel(WallController controller, SettingsManager manager)
    {
        this.controller = controller; this.manager = manager;
        visibleRows = new ListCollectionView(rows) { Filter = item => ShowDisconnectedDisplays || ((DisplayRow)item).IsConnected };
        preview = new(() => rows.Where(r => ShowDisconnectedDisplays || r.IsConnected).Select(r => r.Value).ToArray(), PeerName, IsDisplayConnected, (key, x, y) =>
        { var row = rows.First(r => r.Value.Key == key); row.X = x; row.Y = y; });
        Children.Add(new TextBlock { Text = "ピア接続", FontSize = 24 });
        Children.Add(new TextBlock { Text = $"このPC: {Environment.MachineName}", TextWrapping = TextWrapping.Wrap });
        Children.Add(online); Children.Add(status);
        Children.Add(new TextBlock { Text = "接続済みのピア" }); Children.Add(connectedPeers);
        AddButton(this, "選択したピアの接続を解除", async () =>
        {
            if (connectedPeers.SelectedItem is ListBoxItem { Tag: Guid peer } && controller.Network.Session is { } session)
                await session.DisconnectAsync(peer);
        });
        Children.Add(new TextBlock { Text = "解除すると、オンラインモードを終了するまで相手からの再接続も止めます。再開するにはこのPCの接続候補から接続してください。", TextWrapping = TextWrapping.Wrap });
        Children.Add(new TextBlock { Text = "接続候補" }); Children.Add(candidates);
        AddButton(this, "接続", async () =>
        {
            if (candidates.SelectedItem is Net.PeerCandidate peer && controller.Network.Session is { } session)
                await session.ConnectAsync(peer);
        });
        Children.Add(new TextBlock { Text = "写真ソース", FontSize = 18 });
        Children.Add(showDisconnectedSources); Children.Add(sources);
        showDisconnectedSources.Checked += (_, _) => Refresh();
        showDisconnectedSources.Unchecked += (_, _) => Refresh();
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
        groupView.Children.Add(CreateDisplayFilter()); groupView.Children.Add(preview); groupView.Children.Add(CreateGrid(includeLayout: true)); GroupView = groupView;
        var selection = new StackPanel(); selection.Children.Add(CreateDisplayFilter()); selection.Children.Add(CreateGrid(includeLayout: false)); SelectionView = selection;
        online.Checked += OnlineChanged; online.Unchecked += OnlineChanged;
        controller.Network.Changed += Refresh; Refresh();
    }
    private DataGrid CreateGrid(bool includeLayout)
    {
        var grid = new DataGrid { ItemsSource = visibleRows, AutoGenerateColumns = false, CanUserAddRows = false,
            CanUserDeleteRows = false, MinHeight = 150, MaxHeight = 400, Background = new SolidColorBrush(Color.FromRgb(28, 32, 42)),
            Foreground = Brushes.White, RowBackground = new SolidColorBrush(Color.FromRgb(37, 42, 54)) };
        grid.Columns.Add(new DataGridCheckBoxColumn { Header = "使用", Binding = new Binding(nameof(DisplayRow.Selected)) });
        grid.Columns.Add(new DataGridTextColumn { Header = "画面", Binding = new Binding(nameof(DisplayRow.Name)), IsReadOnly = true, Width = new(1, DataGridLengthUnitType.Star) });
        grid.Columns.Add(new DataGridTextColumn { Header = "接続", Binding = new Binding(nameof(DisplayRow.Connection)), IsReadOnly = true });
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
    private CheckBox CreateDisplayFilter()
    {
        var check = new CheckBox { Content = "未接続の画面も表示", ToolTip = "未接続の画面の配置・グループ設定は保持されています。" };
        check.SetBinding(CheckBox.IsCheckedProperty, new Binding(nameof(ShowDisconnectedDisplays)) { Source = this, Mode = BindingMode.TwoWay });
        return check;
    }
    private bool IsDisplayConnected(Net.PeerDisplayKey key) => controller.Network.Session?.IsDisplayConnected(key) == true;
    private void RefreshDisplayVisibility()
    {
        var signature = $"{ShowDisconnectedDisplays}:" + string.Join(",", rows.Select(r => r.IsConnected));
        if (displayVisibilitySignature != signature && visibleRows is IEditableCollectionView { IsEditingItem: false, IsAddingNew: false })
        { visibleRows.Refresh(); displayVisibilitySignature = signature; }
        var state = rows.Where(r => ShowDisconnectedDisplays || r.IsConnected)
            .Select(r => (r.Value, PeerName(r.Value.Key.PeerId), r.IsConnected)).ToArray();
        if (!previewState.SequenceEqual(state)) { previewState = state; preview?.Refresh(); }
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
    private string PeerName(Guid peerId) => controller.Network.Session?.PeerName(peerId) ?? "未接続の端末";
    private void Refresh()
    {
        if (disposed) return;
        refreshing = true;
        try
        {
            online.IsChecked = controller.Network.Online; status.Text = controller.Network.Status;
            var session = controller.Network.Session;
            var selected = (candidates.SelectedItem as Net.PeerCandidate)?.Hello.PeerId;
            if (session == null)
            {
                candidates.ItemsSource = null; connectedPeers.Items.Clear(); rows.Clear(); sources.Children.Clear(); sourceChecks.Clear();
                baseline = null; groups.Clear(); UpdateChoices(); refreshProviders.Clear(); dirty = false;
                RefreshDisplayVisibility(); return;
            }
            var connected = session.ConnectedPeers.Order().ToArray();
            if (!connectedPeers.Items.OfType<ListBoxItem>().Select(item => (Guid)item.Tag).SequenceEqual(connected))
            {
                var selectedPeer = (connectedPeers.SelectedItem as ListBoxItem)?.Tag;
                connectedPeers.Items.Clear();
                foreach (var peer in connected)
                {
                    var item = new ListBoxItem { Content = PeerName(peer), Tag = peer };
                    connectedPeers.Items.Add(item);
                    if (Equals(selectedPeer, peer)) connectedPeers.SelectedItem = item;
                }
                if (connectedPeers.SelectedItem == null && connectedPeers.Items.Count > 0) connectedPeers.SelectedIndex = 0;
            }
            var discovered = session.Candidates.Where(c => !session.ConnectedPeers.Contains(c.Hello.PeerId)).ToArray();
            if (!candidates.Items.OfType<Net.PeerCandidate>().SequenceEqual(discovered))
            {
                candidates.ItemsSource = discovered;
                candidates.SelectedItem = candidates.Items.OfType<Net.PeerCandidate>().FirstOrDefault(c => c.Hello.PeerId == selected);
            }
            if (!dirty && (baseline == null || baseline.SessionId != session.Snapshot.SessionId || baseline.Revision != session.Snapshot.Revision))
            {
                var optionsChanged = baseline == null || baseline.Playback != session.Snapshot.Playback;
                baseline = session.Snapshot; groups = baseline.Groups.ToList();
                UpdateChoices();
                rows.Clear(); foreach (var display in baseline.Displays) rows.Add(new(display, PeerName, IsDisplayConnected, () => { if (!refreshing) dirty = true; preview.Refresh(); }));
                if (optionsChanged) SharedOptionsChanged?.Invoke(baseline.Playback);
            }
            foreach (var row in rows)
            {
                var current = session.Snapshot.Displays.FirstOrDefault(d => d.Key == row.Value.Key);
                if (current != null) row.Value = row.Value with { Name = current.Name };
                row.RefreshName();
            }
            RefreshDisplayVisibility();
            draftStatus.Text = dirty && baseline?.Revision != session.Snapshot.Revision ? "他のピアで設定が更新されました。未保存の編集を保持しています。" : "画面はピアをまたいでグループまたは単独表示へ割り当てられます。";
            // Keep hidden selections and existing controls while editing. Availability
            // must still update when a peer disappears or publishes a new inventory.
            var selections = (dirty ? baseline : session.Snapshot)?.Sources ?? [];
            var advertised = session.Sources.Concat(selections.Select(s => new Net.SharedSource(s.ProviderId, s.SourceId, "未接続の写真ソース")))
                .Concat(dirty ? sourceChecks.Values.Select(item => item.Source) : [])
                .DistinctBy(s => (s.ProviderId, s.SourceId)).ToArray();
            var keys = advertised.Select(s => (s.ProviderId, s.SourceId)).ToHashSet();
            foreach (var key in sourceChecks.Keys.Where(key => !keys.Contains(key)).ToArray())
            {
                sources.Children.Remove(sourceChecks[key].Check); sourceChecks.Remove(key);
            }
            foreach (var source in advertised)
            {
                var key = (source.ProviderId, source.SourceId);
                if (!sourceChecks.TryGetValue(key, out var item))
                {
                    var check = new CheckBox { IsChecked = selections.Any(s => s.ProviderId == source.ProviderId && s.SourceId == source.SourceId) };
                    check.Checked += (_, _) => { if (!refreshing) { dirty = true; refreshProviders.Add(source.ProviderId); } };
                    check.Unchecked += (_, _) => { if (!refreshing) { dirty = true; refreshProviders.Add(source.ProviderId); } };
                    item = (source, check); sources.Children.Add(check);
                }
                sourceChecks[key] = (source, item.Check);
                if (!dirty) item.Check.IsChecked = selections.Any(s => s.ProviderId == source.ProviderId && s.SourceId == source.SourceId);
                var available = session.IsSourceConnected(source);
                item.Check.Content = $"{source.Name}（{PeerName(source.ProviderId)}）{(available ? "" : " · 未接続")}";
                item.Check.Visibility = showDisconnectedSources.IsChecked == true || available ? Visibility.Visible : Visibility.Collapsed;
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
        dirty = false; refreshProviders.Clear(); baseline = null; Refresh(); return true;
    }
    public void Dispose() { disposed = true; controller.Network.Changed -= Refresh; }
}

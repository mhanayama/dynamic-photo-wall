using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Microsoft.Win32;

namespace DpwSpatial;
internal static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        string? Value(string key) { var i = Array.IndexOf(args, key); return i >= 0 && i + 1 < args.Length ? args[i + 1] : null; }
        var model = Path.GetFullPath(Value("--model") ?? TrialPaths.Model(TrialPaths.ExecutableDirectory));
        var output = Path.GetFullPath(Value("--output") ?? TrialPaths.Cache(TrialPaths.ExecutableDirectory));
        try {
            if (args.Contains("--portrait-test")) return PortraitTests.Run(Path.GetFullPath(Value("--output") ?? PortraitPipeline.OutputDirectory), Value("--scene"), args.Contains("--warp"));
            if (Value("--portrait-generate") is { } portraitPhoto) {
                var scene = PortraitPipeline.GenerateAsync(portraitPhoto, Path.GetFullPath(Value("--output") ?? PortraitPipeline.OutputDirectory), Console.WriteLine).GetAwaiter().GetResult();
                Console.WriteLine(Path.Combine(scene.Directory, "manifest.json")); return 0;
            }
            if (args.Contains("--portrait-alpha") || string.Equals(Path.GetFileNameWithoutExtension(Environment.ProcessPath), "PortraitAlpha", StringComparison.OrdinalIgnoreCase)) {
                var portraitApp = new Application { ShutdownMode = ShutdownMode.OnMainWindowClose };
                var portraitWindow = new PortraitAlphaWindow(Path.GetFullPath(Value("--output") ?? PortraitPipeline.OutputDirectory));
                var portraitInitial = Value("--photo");
                if (portraitInitial is null && args.Length == 1 && PhotoDrop.TrySelect(args, out var portraitDrop, out _)) portraitInitial = portraitDrop;
                if (portraitInitial is not null) portraitWindow.Loaded += async (_, _) => await portraitWindow.LoadPhoto(portraitInitial);
                portraitApp.Run(portraitWindow); return 0;
            }
            if (args.Contains("--test")) return SelfTest.Run(output, File.Exists(model) ? model : null, Value("--photo"), args.Contains("--warp"));
            if (Value("--generate") is { } photo) {
                var pair = DepthPipeline.Generate(photo, model, output, Value("--backend") ?? "auto", args.Contains("--force"), Console.WriteLine);
                Console.WriteLine($"{pair.Backend}; cacheHit={pair.CacheHit}; {pair.Directory}"); return 0;
            }
            var app = new Application { ShutdownMode = ShutdownMode.OnMainWindowClose };
            var window = new TrialWindow(model, output);
            var initial = Value("--photo");
            if (initial is null && args.Length == 1 && PhotoDrop.TrySelect(args, out var dropped, out _)) initial = dropped;
            if (initial is not null) window.Loaded += async (_, _) => await window.LoadPhoto(initial);
            app.Run(window); return 0;
        } catch (Exception e) { Console.Error.WriteLine(e); return 1; }
    }
}

internal sealed class NativeSurface : HwndHost
{
    private nint child;
    private NativeRenderer? renderer;
    private NativePhotoDrop? dropTarget;
    private DepthPair? pair;
    private PortraitScene? portrait;
    private double portraitDegrees;
    private bool portraitUsePhoto = true;
    private double position = -1;
    private float amplitude;
    private bool invert;
    public event Action<Exception>? Failed;
    public event Action<string>? PhotoDropped;
    public string Adapter => renderer?.Adapter ?? "Direct3D 12";
    [DllImport("user32", CharSet = CharSet.Unicode, SetLastError = true)] private static extern nint CreateWindowEx(int ex, string cls, string name, int style, int x, int y, int w, int h, nint parent, nint menu, nint instance, nint param);
    [DllImport("user32")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool DestroyWindow(nint hwnd);
    protected override HandleRef BuildWindowCore(HandleRef parent)
    {
        child = CreateWindowEx(0, "static", "Spatial Photo", 0x40000000 | 0x10000000, 0, 0, 1, 1, parent.Handle, 0, 0, 0);
        if (child == 0) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        try {
            dropTarget = new NativePhotoDrop(child, path => PhotoDropped?.Invoke(path));
            var dpi = VisualTreeHelper.GetDpi(this);
            renderer = new NativeRenderer(child, Math.Max(1, (int)(ActualWidth * dpi.DpiScaleX)), Math.Max(1, (int)(ActualHeight * dpi.DpiScaleY)));
            if (portrait is not null) { renderer.SetPortrait(portrait); renderer.RenderPortrait(portraitDegrees, portraitUsePhoto); }
            else if (pair is not null) { renderer.SetPair(pair); renderer.Render(position, amplitude, invert); }
        } catch (Exception e) { Dispatcher.BeginInvoke(() => Failed?.Invoke(e)); }
        return new(this, child);
    }
    protected override void DestroyWindowCore(HandleRef hwnd) { dropTarget?.Dispose(); dropTarget = null; renderer?.Dispose(); renderer = null; pair = null; portrait = null; DestroyWindow(hwnd.Handle); child = 0; }
    protected override void OnRenderSizeChanged(SizeChangedInfo info)
    {
        base.OnRenderSizeChanged(info);
        if (renderer is null) return;
        try {
            var dpi = VisualTreeHelper.GetDpi(this); renderer.Resize(Math.Max(1, (int)(ActualWidth * dpi.DpiScaleX)), Math.Max(1, (int)(ActualHeight * dpi.DpiScaleY)));
            if (portrait is not null) renderer.RenderPortrait(portraitDegrees, portraitUsePhoto);
            else if (pair is not null) renderer.Render(position, amplitude, invert);
        } catch (Exception e) { Failed?.Invoke(e); }
    }
    public void SetPair(DepthPair value) { pair = value; portrait = null; renderer?.SetPair(value); }
    public void SetPortraitScene(PortraitScene value) { portrait = value; pair = null; renderer?.SetPortrait(value); }
    public void RenderPortrait(double degrees, bool usePhoto = true) { portraitDegrees = degrees; portraitUsePhoto = usePhoto; renderer?.RenderPortrait(degrees, usePhoto); }
    public void Render(double position, float amplitude, bool invert) {
        this.position = position; this.amplitude = amplitude; this.invert = invert;
        renderer?.Render(position, amplitude, invert);
    }
}

internal sealed class TrialWindow : Window
{
    private readonly string model, output;
    private readonly Grid stage = new() { Background = Brushes.Black };
    private readonly Image original = new() { Stretch = Stretch.Uniform };
    private readonly TextBlock status = new() { Text = "画像をここへドラッグ＆ドロップすると、深度を生成して再生します。", TextWrapping = TextWrapping.Wrap, Margin = new Thickness(8) };
    private readonly ComboBox mode = new(), direction = new(), backend = new();
    private readonly Slider amplitude = new() { Minimum = 0, Maximum = 100, Value = SpatialMotion.DefaultStrength, TickFrequency = 1, IsSnapToTickEnabled = true };
    private readonly Slider duration = new() { Minimum = 1, Maximum = 120, Value = 10, TickFrequency = 1, IsSnapToTickEnabled = true };
    private readonly CheckBox manual = new() { Content = "視点を手動で確認" };
    private readonly Slider viewpoint = new() { Minimum = -1, Maximum = 1, Value = 0, SmallChange = .05, LargeChange = .5 };
    private readonly CheckBox enabled = new() { Content = "Spatial Photo を有効にする", IsChecked = true };
    private readonly CheckBox invert = new() { Content = "深度の白黒を反転" };
    private readonly Button choose = new() { Content = "写真を選択して深度生成", Margin = new Thickness(4), Padding = new Thickness(8) };
    private readonly Stopwatch frameClock = new();
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromSeconds(1.0 / 30) };
    private DepthPair? pair;
    private NativeSurface? surface;
    private string? selected;
    private bool paused, generating, closed, depthPreview;
    private double elapsed;
    private int photoIndex = -1, resolvedDirection = 1;
    private string? gpuFailure;
    private BitmapSource? photoBitmap;
    private (string Path, bool Force)? pendingPhoto;

    public TrialWindow(string model, string output)
    {
        this.model = model; this.output = output;
        Title = "Dynamic Photo Wall · Spatial Photo / 強度調整版"; Width = 1280; Height = 900;
        Background = new SolidColorBrush(Color.FromRgb(20, 26, 33)); Foreground = Brushes.White;
        AllowDrop = true;
        PreviewDragOver += (sender, e) => {
            var files = e.Data.GetDataPresent(DataFormats.FileDrop) ? e.Data.GetData(DataFormats.FileDrop) as string[] : null;
            e.Effects = PhotoDrop.TrySelect(files, out _, out _) && (e.AllowedEffects & DragDropEffects.Copy) != 0 ? DragDropEffects.Copy : DragDropEffects.None;
            e.Handled = true;
        };
        PreviewDrop += async (_, e) => {
            e.Handled = true;
            var files = e.Data.GetDataPresent(DataFormats.FileDrop) ? e.Data.GetData(DataFormats.FileDrop) as string[] : null;
            if (PhotoDrop.TrySelect(files, out var path, out var reason)) { e.Effects = DragDropEffects.Copy; await LoadPhoto(path); }
            else { e.Effects = DragDropEffects.None; status.Text = reason; }
        };
        var root = new DockPanel { Margin = new Thickness(16) }; Content = root;
        var settings = new StackPanel { Margin = new Thickness(12, 0, 0, 0) };
        var settingsScroll = new ScrollViewer { Width = 310, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Content = settings };
        DockPanel.SetDock(settingsScroll, Dock.Right); root.Children.Add(settingsScroll);
        settings.Children.Add(new TextBlock { Text = "Spatial Photo", FontSize = 24, Margin = new Thickness(4, 0, 0, 12) });
        settings.Children.Add(new TextBlock { Text = "JPEG・PNG・WebPを1枚ドロップ\n生成完了後、自動で再生します。", TextWrapping = TextWrapping.Wrap, Margin = new Thickness(4, 0, 4, 12) });
        settings.Children.Add(new TextBlock { Text = "実験機能 · GPU高負荷\n消費電力・温度・ファン動作が増える場合があります。ゲームとの同時利用は推奨しません。", TextWrapping = TextWrapping.Wrap, Foreground = Brushes.Gold, Margin = new Thickness(4, 0, 0, 16) });
        settings.Children.Add(choose); settings.Children.Add(enabled);
        Add(settings, "深度生成", backend, ["自動（DirectML優先／CPU代替）", "DirectML", "CPU"]);
        Add(settings, "動き方", mode, ["片道 · 終点で保持", "往復"]);
        Add(settings, "初期方向", direction, ["左 → 右", "右 → 左", "写真ごとに交互", "写真ごとにランダム"]);
        AddSlider(settings, "片道の時間", duration, "秒"); AddSlider(settings, "視差の強さ", amplitude, "%"); settings.Children.Add(invert);
        settings.Children.Add(new TextBlock { Text = "強くすると輪郭や背景の歪みも増えます。実際のカメラ角度を指定する設定ではありません。", TextWrapping = TextWrapping.Wrap, Margin = new Thickness(4, 8, 4, 8) });
        settings.Children.Add(manual);
        var viewpointLabels = new DockPanel { Margin = new Thickness(4, 6, 4, 2) };
        var rightLabel = new TextBlock { Text = "右の視点", HorizontalAlignment = HorizontalAlignment.Right }; DockPanel.SetDock(rightLabel, Dock.Right); viewpointLabels.Children.Add(rightLabel);
        viewpointLabels.Children.Add(new TextBlock { Text = "左の視点" }); settings.Children.Add(viewpointLabels); settings.Children.Add(viewpoint);
        var endpoints = new UniformGrid { Columns = 3, Margin = new Thickness(4) };
        foreach (var (label, position) in new[] { ("左端", -1.0), ("中央", 0.0), ("右端", 1.0) }) {
            var button = new Button { Content = label, Margin = new Thickness(2), Padding = new Thickness(4) };
            button.Click += (_, _) => { manual.IsChecked = true; viewpoint.Value = position; Reconcile(); }; endpoints.Children.Add(button);
        }
        settings.Children.Add(endpoints);
        var pause = new Button { Content = "一時停止 / 再生", Margin = new Thickness(4), Padding = new Thickness(6) }; settings.Children.Add(pause);
        var restart = new Button { Content = "最初から再開 / GPU再試行", Margin = new Thickness(4), Padding = new Thickness(6) }; settings.Children.Add(restart);
        var preview = new Button { Content = "深度 / 写真を切り替え", Margin = new Thickness(4), Padding = new Thickness(6) }; settings.Children.Add(preview);
        var regenerate = new Button { Content = "深度を再生成（キャッシュ無視）", Margin = new Thickness(4), Padding = new Thickness(6) }; settings.Children.Add(regenerate);
        settings.Children.Add(new TextBlock { Text = "AI処理は画像ごとに1回。生成物は独立キャッシュに保存します。設定変更は先頭から再生します。", TextWrapping = TextWrapping.Wrap, Margin = new Thickness(4, 12, 4, 4) });
        var center = new DockPanel(); root.Children.Add(center); DockPanel.SetDock(status, Dock.Bottom); center.Children.Add(status); center.Children.Add(stage); stage.Children.Add(original);
        choose.Click += async (_, _) => { var dialog = new OpenFileDialog { Filter = "Photos|*.jpg;*.jpeg;*.png;*.webp" }; if (dialog.ShowDialog(this) == true) await LoadPhoto(dialog.FileName); };
        regenerate.Click += async (_, _) => { if (selected is not null) await LoadPhoto(selected, true); };
        pause.Click += (_, _) => { paused = !paused; Reconcile(); };
        restart.Click += (_, _) => { gpuFailure = null; elapsed = 0; paused = false; manual.IsChecked = false; Reconcile(); };
        preview.Click += (_, _) => { depthPreview = !depthPreview; Reconcile(); };
        foreach (var combo in new[] { mode, direction }) combo.SelectionChanged += (_, _) => { elapsed = 0; ResolveDirection(); Reconcile(); };
        amplitude.ValueChanged += (_, _) => { elapsed = 0; Reconcile(); }; duration.ValueChanged += (_, _) => { elapsed = 0; Reconcile(); };
        enabled.Click += (_, _) => Reconcile(); invert.Click += (_, _) => Reconcile();
        manual.Click += (_, _) => Reconcile();
        viewpoint.ValueChanged += (_, _) => { manual.IsChecked = true; Reconcile(); };
        StateChanged += (_, _) => Reconcile(); IsVisibleChanged += (_, _) => Reconcile();
        SystemParameters.StaticPropertyChanged += SystemSettingsChanged;
        Closed += (_, _) => { closed = true; timer.Stop(); frameClock.Stop(); ReleaseGpu(); SystemParameters.StaticPropertyChanged -= SystemSettingsChanged; pair = null; photoBitmap = null; original.Source = null; };
        timer.Tick += (_, _) => { elapsed += frameClock.Elapsed.TotalSeconds; frameClock.Restart(); Draw(); };
    }
    private void SystemSettingsChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs args) => Dispatcher.BeginInvoke(Reconcile);
    private static void Add(StackPanel parent, string label, ComboBox box, string[] items) {
        parent.Children.Add(new TextBlock { Text = label, Margin = new Thickness(4, 14, 4, 4) }); foreach (var item in items) box.Items.Add(item); box.SelectedIndex = 0; parent.Children.Add(box);
    }
    private static void AddSlider(StackPanel parent, string label, Slider slider, string unit) {
        var text = new TextBlock { Margin = new Thickness(4, 14, 4, 4) }; void Update() => text.Text = $"{label}: {slider.Value:0}{unit}";
        Update(); slider.ValueChanged += (_, _) => Update(); parent.Children.Add(text); parent.Children.Add(slider);
    }
    private void ResolveDirection() => resolvedDirection = direction.SelectedIndex switch { 1 => -1, 2 => photoIndex % 2 == 0 ? 1 : -1, 3 => Random.Shared.Next(2) == 0 ? 1 : -1, _ => 1 };
    public async Task LoadPhoto(string path, bool force = false)
    {
        if (closed) return;
        if (!PhotoDrop.TrySelect([path], out path, out var reason)) { status.Text = reason; return; }
        if (generating) { pendingPhoto = (path, force); status.Text = "生成中です。完了後に最後にドロップした画像を生成します。"; return; }
        generating = true; choose.IsEnabled = false; timer.Stop(); frameClock.Stop(); ReleaseGpu();
        try {
            var pixels = await Task.Run(() => Pixels.Load(path)); if (closed) return; selected = path;
            pair = null; photoBitmap = Bitmap(pixels); original.Source = photoBitmap; photoIndex++; ResolveDirection();
            var provider = backend.SelectedIndex switch { 1 => "directml", 2 => "cpu", _ => "auto" };
            var result = await Task.Run(() => DepthPipeline.Generate(path, model, output, provider, force,
                message => Dispatcher.BeginInvoke(() => { if (!closed) status.Text = message; })));
            if (closed || pendingPhoto is not null) return; pair = result; elapsed = 0; gpuFailure = null; depthPreview = false;
            status.Text = $"{pair.Backend} · {(pair.CacheHit ? "キャッシュから読み込み" : "生成完了")}\n{pair.Directory}";
        } catch (Exception e) { if (!closed) status.Text = $"深度を生成できないため静止画を表示します: {e.Message}"; }
        finally {
            generating = false;
            if (!closed) {
                choose.IsEnabled = true;
                if (pendingPhoto is { } pending) { pendingPhoto = null; await LoadPhoto(pending.Path, pending.Force); }
                else Reconcile();
            }
        }
    }
    private static BitmapSource Bitmap(Pixels pixels) {
        var bgra = (byte[])pixels.Rgba.Clone(); for (var i = 0; i < bgra.Length; i += 4) (bgra[i], bgra[i + 2]) = (bgra[i + 2], bgra[i]);
        var bitmap = BitmapSource.Create(pixels.Width, pixels.Height, 96, 96, PixelFormats.Bgra32, null, bgra, pixels.Width * 4); bitmap.Freeze(); return bitmap;
    }
    private void ReleaseGpu() { if (surface is null) return; stage.Children.Remove(surface); surface.Dispose(); surface = null; }
    private void Reconcile()
    {
        timer.Stop(); frameClock.Reset();
        if (closed || generating || pair is null) return;
        if (depthPreview) {
            ReleaseGpu(); var rgba = new byte[pair.Depth.Length * 4];
            for (var i = 0; i < pair.Depth.Length; i++) { rgba[i * 4] = rgba[i * 4 + 1] = rgba[i * 4 + 2] = pair.Depth[i]; rgba[i * 4 + 3] = 255; }
            original.Source = Bitmap(new(pair.DepthWidth, pair.DepthHeight, rgba)); return;
        }
        original.Source = photoBitmap;
        if (!IsVisible || WindowState == WindowState.Minimized || enabled.IsChecked != true || !SystemParameters.ClientAreaAnimation || gpuFailure is not null) {
            ReleaseGpu(); if (gpuFailure is not null) status.Text = $"GPU描画を停止して静止画へ戻しました: {gpuFailure}"; return;
        }
        try {
            if (surface is null) {
                surface = new NativeSurface(); surface.Failed += e => Dispatcher.BeginInvoke(() => { gpuFailure = e.Message; Reconcile(); });
                surface.PhotoDropped += path => Dispatcher.BeginInvoke(async () => await LoadPhoto(path));
                surface.SetPair(pair); stage.Children.Add(surface);
            }
            Draw(); if (!paused && manual.IsChecked != true && amplitude.Value > 0 && surface is not null && !SpatialMotion.At(elapsed, duration.Value, mode.SelectedIndex == 1, resolvedDirection).Done) { frameClock.Start(); timer.Start(); }
        } catch (Exception e) { gpuFailure = e.Message; ReleaseGpu(); status.Text = $"静止画表示: {e.Message}"; }
    }
    private void Draw()
    {
        if (surface is null) return;
        try {
            var motion = SpatialMotion.At(elapsed, duration.Value, mode.SelectedIndex == 1, resolvedDirection);
            surface.Render(manual.IsChecked == true ? viewpoint.Value : motion.Position, SpatialMotion.Amplitude(amplitude.Value), invert.IsChecked == true);
            if (manual.IsChecked == true) status.Text = $"{surface.Adapter} · 手動視点 {viewpoint.Value:+0.00;-0.00;0.00} · 強さ {amplitude.Value:0}%";
            else if (motion.Done) { timer.Stop(); frameClock.Stop(); status.Text = $"{surface.Adapter} · 片道の終点で保持中"; }
        } catch (Exception e) { gpuFailure = e.Message; Reconcile(); }
    }
}

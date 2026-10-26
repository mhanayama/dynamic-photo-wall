using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Microsoft.Win32;

namespace DpwSpatial;

internal sealed class PortraitAlphaWindow : Window
{
    private readonly string output;
    private readonly Grid stage = new() { Background = Brushes.Black };
    private readonly Image still = new() { Stretch = Stretch.Uniform };
    private readonly TextBlock status = new() { Text = "上半身または全身の写真を1枚ドロップしてください。", TextWrapping = TextWrapping.Wrap, Margin = new Thickness(8) };
    private readonly Slider viewpoint = new() { Minimum = -60, Maximum = 60, Value = 0, SmallChange = 1, LargeChange = 15 };
    private readonly Slider range = new() { Minimum = 0, Maximum = 60, Value = 30, TickFrequency = 1, IsSnapToTickEnabled = true };
    private readonly CheckBox automatic = new() { Content = "カメラを左右に自動移動", IsChecked = false, Margin = new Thickness(4, 14, 4, 4) };
    private readonly CheckBox photoTexture = new() { Content = "元写真を見えていた面へ投影", IsChecked = true, Margin = new Thickness(4, 14, 4, 4) };
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromSeconds(1.0 / 30) };
    private readonly Stopwatch clock = new();
    private CancellationTokenSource? generation;
    private NativeSurface? surface;
    private PortraitScene? scene;
    private BitmapSource? original;
    private int generationId;
    private double elapsed;
    private bool closed, previewBackground;
    private string? gpuError;

    public PortraitAlphaWindow(string output)
    {
        this.output = output;
        Title = "DPW Portrait 3D — Alpha 2（元写真の投影）"; Width = 1280; Height = 900;
        Background = new SolidColorBrush(Color.FromRgb(20, 26, 33)); Foreground = Brushes.White; AllowDrop = true;
        var root = new DockPanel { Margin = new Thickness(16) }; Content = root;
        var panel = new StackPanel { Margin = new Thickness(14, 0, 0, 0) };
        var scroll = new ScrollViewer { Width = 310, Content = panel, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        DockPanel.SetDock(scroll, Dock.Right); root.Children.Add(scroll);
        panel.Children.Add(new TextBlock { Text = "Portrait 3D · Alpha 2", FontSize = 24, Margin = new Thickness(4, 0, 4, 14) });
        panel.Children.Add(new TextBlock { Text = "人物抽出 → 背景補完 → 人物3D生成\n人物の3Dメッシュと背景1枚を、同じカメラで描画します。", TextWrapping = TextWrapping.Wrap, Margin = new Thickness(4, 0, 4, 16) });
        panel.Children.Add(new TextBlock { Text = "初回生成はCPUで数分かかる場合があります。形状・側面・髪・手足の品質に制限があります。まず正面と固定視点で比較してください。", TextWrapping = TextWrapping.Wrap, Foreground = Brushes.Gold, Margin = new Thickness(4, 0, 4, 16) });
        var choose = Button(panel, "写真を選択して生成");
        choose.Click += async (_, _) => { var dialog = new OpenFileDialog { Filter = "Photos|*.jpg;*.jpeg;*.png;*.webp" }; if (dialog.ShowDialog(this) == true) await LoadPhoto(dialog.FileName); };
        var cancel = Button(panel, "生成を中止"); cancel.Click += (_, _) => generation?.Cancel();
        var source = Button(panel, "元写真を表示"); source.Click += (_, _) => { previewBackground = false; Stop(); Release(); still.Source = original; };
        var bg = Button(panel, "補完した背景を確認"); bg.Click += (_, _) => { if (scene is null) return; previewBackground = true; Refresh(); };
        var render = Button(panel, "人物3D＋背景を表示"); render.Click += (_, _) => { previewBackground = false; gpuError = null; Refresh(); };
        panel.Children.Add(photoTexture); photoTexture.Click += (_, _) => Refresh();
        panel.Children.Add(new TextBlock { Text = "OFFで旧版の生成色と比較。元写真に写っていない側面の品質は未解決です。", TextWrapping = TextWrapping.Wrap, Margin = new Thickness(4) });
        panel.Children.Add(automatic); automatic.Click += (_, _) => Refresh();
        var label = new TextBlock { Text = "移動範囲：左右30°", Margin = new Thickness(4, 14, 4, 4) }; panel.Children.Add(label); panel.Children.Add(range);
        range.ValueChanged += (_, _) => { label.Text = $"移動範囲：左右{range.Value:0}°"; Refresh(); };
        panel.Children.Add(new TextBlock { Text = "手動視点（実際のカメラ角度）", Margin = new Thickness(4, 14, 4, 4) }); panel.Children.Add(viewpoint);
        viewpoint.ValueChanged += (_, _) => { automatic.IsChecked = false; Refresh(); };
        foreach (var degrees in new[] { -60, -30, 0, 30, 60 }) {
            var button = Button(panel, $"{degrees:+0;-0;0}°から確認");
            button.Click += (_, _) => { automatic.IsChecked = false; viewpoint.Value = degrees; Refresh(); };
        }
        panel.Children.Add(new TextBlock { Text = "側面はモデルの推定です。背景は平面のため、大きな移動では遠近感が不自然になる場合があります。生成結果はキャッシュされ、再生中にAI推論は行いません。", TextWrapping = TextWrapping.Wrap, Margin = new Thickness(4, 16, 4, 4) });
        var center = new DockPanel(); root.Children.Add(center); DockPanel.SetDock(status, Dock.Bottom); center.Children.Add(status); center.Children.Add(stage); stage.Children.Add(still);
        PreviewDragOver += (sender, e) => {
            var files = e.Data.GetDataPresent(DataFormats.FileDrop) ? e.Data.GetData(DataFormats.FileDrop) as string[] : null;
            e.Effects = PhotoDrop.TrySelect(files, out _, out _) ? DragDropEffects.Copy : DragDropEffects.None; e.Handled = true;
        };
        PreviewDrop += async (_, e) => {
            e.Handled = true;
            var files = e.Data.GetDataPresent(DataFormats.FileDrop) ? e.Data.GetData(DataFormats.FileDrop) as string[] : null;
            if (PhotoDrop.TrySelect(files, out var path, out var reason)) await LoadPhoto(path); else status.Text = reason;
        };
        timer.Tick += (_, _) => { elapsed += clock.Elapsed.TotalSeconds; clock.Restart(); Draw(); };
        StateChanged += (_, _) => Refresh(); IsVisibleChanged += (_, _) => Refresh();
        Closed += (_, _) => { closed = true; generationId++; generation?.Cancel(); Stop(); Release(); scene = null; still.Source = null; original = null; };
    }
    private static Button Button(Panel panel, string label) { var button = new Button { Content = label, Padding = new Thickness(8), Margin = new Thickness(4) }; panel.Children.Add(button); return button; }
    internal static BitmapSource Bitmap(Pixels pixels) {
        var bgra = (byte[])pixels.Rgba.Clone(); for (var i = 0; i < bgra.Length; i += 4) (bgra[i], bgra[i + 2]) = (bgra[i + 2], bgra[i]);
        var result = BitmapSource.Create(pixels.Width, pixels.Height, 96, 96, PixelFormats.Bgra32, null, bgra, pixels.Width * 4); result.Freeze(); return result;
    }
    public async Task LoadPhoto(string path)
    {
        if (closed) return;
        if (!PhotoDrop.TrySelect([path], out path, out var reason)) { status.Text = reason; return; }
        var id = ++generationId; generation?.Cancel();
        var cancellation = new CancellationTokenSource(); generation = cancellation; Stop(); Release(); scene = null;
        try {
            var pixels = await Task.Run(() => Pixels.Load(path), cancellation.Token);
            if (closed || id != generationId) return;
            original = Bitmap(pixels); still.Source = original; status.Text = "人物生成ワーカーを起動しています…";
            var result = await PortraitPipeline.GenerateAsync(path, output,
                message => Dispatcher.BeginInvoke(() => { if (!closed && id == generationId) status.Text = message; }), cancellation.Token);
            if (closed || id != generationId) return;
            scene = result; previewBackground = false; gpuError = null; elapsed = 0; automatic.IsChecked = false; viewpoint.Value = 0;
            status.Text = $"生成済み · {scene.Vertices.Length / 8 - 4:N0}頂点 · {(scene.Indices.Length - 6) / 3:N0}面\n{scene.Directory}";
            Refresh();
        } catch (OperationCanceledException) { if (!closed && id == generationId) status.Text = "生成を中止しました。"; }
        catch (Exception e) { if (!closed && id == generationId) status.Text = $"人物3Dを生成できませんでした: {e.Message}"; }
        finally { cancellation.Dispose(); if (generation == cancellation) generation = null; }
    }
    private void Stop() { timer.Stop(); clock.Reset(); }
    private void Release() { if (surface is null) return; stage.Children.Remove(surface); surface.Dispose(); surface = null; }
    private void Refresh()
    {
        Stop();
        if (closed || scene is null) return;
        if (previewBackground) { Release(); still.Source = Bitmap(scene.Background); return; }
        still.Source = original;
        if (!IsVisible || WindowState == WindowState.Minimized || gpuError is not null) { Release(); return; }
        try {
            if (surface is null) {
                surface = new NativeSurface(); surface.SetPortraitScene(scene);
                surface.PhotoDropped += path => Dispatcher.BeginInvoke(async () => await LoadPhoto(path));
                surface.Failed += error => Dispatcher.BeginInvoke(() => { gpuError = error.Message; Stop(); Release(); status.Text = $"D3D12描画を停止しました: {gpuError}"; });
                stage.Children.Add(surface);
            }
            Draw();
            if (surface is not null && automatic.IsChecked == true && range.Value > 0 && SystemParameters.ClientAreaAnimation) { clock.Start(); timer.Start(); }
        } catch (Exception e) { gpuError = e.Message; Release(); status.Text = $"D3D12描画を停止しました: {e.Message}"; }
    }
    private void Draw()
    {
        if (surface is null || scene is null) return;
        try {
            var angle = automatic.IsChecked == true ? SpatialMotion.At(elapsed, 10, true, 1).Position * Math.Min(range.Value, scene.MaximumAngle)
                : Math.Clamp(viewpoint.Value, -scene.MaximumAngle, scene.MaximumAngle);
            surface.RenderPortrait(angle, photoTexture.IsChecked == true);
        } catch (Exception e) { gpuError = e.Message; Stop(); Release(); status.Text = $"3D描画を停止しました: {e.Message}"; }
    }
}

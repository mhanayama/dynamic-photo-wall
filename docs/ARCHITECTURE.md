# Dynamic Photo Wall — 設計と主要リスク

## 境界

`DynamicPhotoWall.Core` はOS/UIに依存しない設定モデル、写真選択、適性判定、重み抽選、レイアウト、距離基準のモーション計算を担当する。
WPFアプリは `DesktopIntegration`、`PhotoLibrary`、`Rendering`、`Motion`、`UI`、`Configuration` に分離する。
画像はローカルで処理する。ネットワーク通信、テレメトリ、壁紙設定APIは使用しない。

## Phase 1の方針

1. モニターを物理ピクセル座標で列挙する。負座標を許容する。
2. Progmanへタイムアウト付きのWorkerW生成要求を送り、アイコン用SHELLDLL_DefViewの後ろにあるWorkerWだけを選ぶ。
3. 非表示のWPFウィンドウをWS_CHILDへ変更して接続し、親と実座標・寸法を検証してからSW_SHOWNOACTIVATEで表示する。
   ProgmanにWS_EX_NOREDIRECTIONBITMAPがあるWindows 11では、不透明なWS_EX_LAYERED子ウィンドウとして合成する。WPFがWM_STYLECHANGINGでこのフラグを除去するため、写真用HWNDのフックで保持する。WPFのPerPixelOpacityは有効にしない。
4. 接続できない場合は表示を中止する。通常ウィンドウを最背面に置く代替方式は採用しない。
5. アプリ自身の子ウィンドウのみ破棄する。Explorerのウィンドウを削除・非表示にしない。

## リスクと対応

- 全画面表示は対象モニターのShell_TrayWnd / Shell_SecondaryTrayWndだけを一時的に隠す。通常のアプリを最前面で覆わない。停止・スリープ・画面遮蔽時に元に戻す。非表示前に独立した復元プロセスの準備を確認し、所有プロセスの終了または解除イベントで復元する。最初から非表示だったタスクバーは所有・復元対象にしない。

- WorkerWは非公開Shell実装。将来のWindowsで互換性は保証できない。未知の階層では安全に停止しログを残す。
- SetParentは異なるDPIコンテキスト間でプロセスDPIを変えることがある。親のDPIコンテキストに合わせて描画HWNDを作成し、接続後に物理座標を照合する。WPF設定画面はPerMonitorV2を使用する。
- Explorer再起動で子HWNDが消える。独立した通知用HWNDとTaskbarCreated、低頻度の生存確認で再生成する。
- モニター消失時は別画面へ自動移動しない。選択IDを保存したまま停止し、同じ画面の復帰を待つ。
- WebPには明示的なデコーダーを用意する。HEICはWindows WICコーデックがある場合のみ対応。
- デコードはバックグラウンドで実行し、凍結BitmapSourceだけをUIへ渡す。LRUキャッシュをメモリ予算で制限する。
- モーションはWPFのアニメーションクロックを使用する。UIタイマーで毎フレーム描画しない。
- 遮蔽判定はforeground/location/minimizeのWinEventを集約する。完全に画面を覆う単一の前景ウィンドウで停止する。複数ウィンドウの和による完全遮蔽は初期版では検出しない。

## 動的なアンビエント背景

参考はYouTubeのアンビエントモード。YouTubeが2022年に公開した説明では、サムネイルとシーク用プレビュー画像を引き伸ばし、ぼかしと暗幕を重ねて映像の色を周囲へ広げている。端末の性能に応じた簡略化も説明されている。現在の内部コードや更新頻度は公開情報からは確定できない。

Photo Wallでは以下の独自実装で、今見えている写真の色を反映する。

- 写真用Canvasを背景・EXIF表示から分離。固定の元写真や画面外の待機写真ではなく、移動・切り取り・フェード後の表示部分をVisualBrushで取得する。背景の再取り込みによるフィードバックを防ぐ。
- プレビューは長辺160px。3840×1100画面では160×46px。背景専用タイマーで最大8回/秒取得し、処理中には追加ジョブを積まない。写真の移動は従来どおりWPFアニメーションクロックで描画する。
- 写真間や縦写真の周囲の透明な余白へ、最寄りの写真の色を伸ばす。黒い余白をぼかして背景を暗くしてしまうことを防ぐ。
- UIスレッド外でガウスぼかし（プレビュー上のsigma=7）を適用。直前の結果と50%ずつ混合して色の切り替わりを緩やかにする。拡大した背景に薄い暗幕と光のグラデーションを重ねる。
- 背景の更新はImageBrushのImageSourceのみを変更し、写真レイアウトの再計算を起こさない。停止・画面遮蔽・スリープ中は更新を休止。シーンの破棄時にタイマーを解除し、処理をキャンセルする。
- 写真・フレームのOpacityMaskによる4pxのフチぼかしを削除。既存settings.jsonのEdgeFeatherPixelsは未知の項目として無視され、次回保存時に消える。

横スクロールでは高さを画面高さ−上下のGapに固定する。全枚数を画面幅内へ縮小せず、表示範囲と先読み分を埋める枚数を選ぶ。従来のGalleryは全体が収まる配置を維持する。

参考:

- [YouTube公式: Decoding YouTube’s new design language（2022-11-28）](https://blog.youtube/inside-youtube/youtube-ambient-color-mode-visual-language-redesign/)
- [WPF VisualBrush](https://learn.microsoft.com/en-us/dotnet/api/system.windows.media.visualbrush?view=windowsdesktop-10.0)
- [WPF RenderTargetBitmap](https://learn.microsoft.com/en-us/dotnet/api/system.windows.media.imaging.rendertargetbitmap?view=windowsdesktop-10.0)

## 根拠

- .NET 10 LTS: https://dotnet.microsoft.com/en-us/platform/support/policy/dotnet-core
- SetParentのスタイル/DPI制約: https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setparent
- DPI: https://learn.microsoft.com/en-us/windows/win32/hidpi/high-dpi-desktop-application-development-on-windows
- 新しいShellの合成方式: https://github.com/lively-community/lively/issues/2074
- WPFのLayeredスタイル処理: https://github.com/dotnet/wpf/blob/main/src/Microsoft.DotNet.Wpf/src/PresentationCore/System/Windows/InterOp/HwndTarget.cs

各フェーズの検証結果と手動受け入れ項目はTEST-RESULTS.mdに記載する。

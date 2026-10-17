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

## Windows内の共通キャンバス

設定画面は「一般」「使用ディスプレイ」「画面グルーピング」を分ける。タスクバー設定は使用ディスプレイに配置する。`DisplayGroupNames`に未割り当てを含むグループ定義を保存し、グループ一覧は実際に使用中のキャンバスとは別に管理する。

テストパターンは`WallController.ShowTestPatternAsync`でドラフトを複製して一時表示し、通常の`Settings`・保存ファイル・写真ライブラリー設定を変更しない。停止時はテスト用セッションを破棄し、元の再生希望・一時停止状態で写真セッションを作り直す。表示前から停止していた場合は停止へ戻る。通常の開始・停止操作もテスト表示を解除する。古い設定の`DisplayTestPattern`は読み込み時に無効化し、次回起動へテスト表示を持ち越さない。

`WallSettings.Displays`に画面ID・壁座標・最後の解像度・GroupId・HideTaskbarを保存する。`DisplayGroups`で同じGroupIdの画面をまとめ、空欄は画面ごとに独立させる。`WallLayout`はグループごとに負座標・隙間・上下位置を含む外接矩形を原点へ正規化し、各画面の切り出し領域を計算する。OSの物理座標はHWND配置だけに使い、壁座標とは分離する。従来の`MonitorId`だけの設定も読める。GroupIdが未保存の旧設定は「グループ1」、HideTaskbarが未保存なら従来の全体設定を引き継ぐ。

`WallController`はライブラリー監視・画像キャッシュ・顔検出・環境通知を共有し、グループごとの`WallPlaybackSession`を管理する。各セッションは抽選・アニメーションクロックを1セット持つ。描画元Canvasをグループの最初の接続画面へ接続したまま、各画面の表示用CanvasでVisualBrushを使って現在／旧シーンを提示する。スパンは壁の担当領域を切り出し、画面単位モードは画面IDに対応する子シーンを提示する。配置が重なっていても別画面の子シーンが混ざらず、スパンとのフェードも維持する。全画面でViewboxを使い物理画素数からDIPへ変換する。位置調整は描画元Canvas自身ではなく外側のラッパーへ行い、VisualBrushの原点を動かさない。各画面は独立したDesktopWindowHostとTaskbarVisibilityを持ち、画面自身のHideTaskbarで非表示を判断する。

`GalleryPerDisplay` / `GalleryScrollPerDisplay` / `VerticalPanPerDisplay` / `HorizontalPanPerDisplay` / `ZoomPerDisplay`は欠落時false。`CompositionEngine.Next`は各モードの表示範囲で適性を判定し、画面単位モードでは接続中の全画面に候補があるモードだけを抽選する。`ForMode`で各画面の写真を選び、`PreparedGroup`として1つ先の構成を保持する。各子シーンは画面寸法のレイアウト・画像・背景を持ち、グループ共通のクロック・フェードと最長のシーン時間で切り替わる。Gallery交換・scroll流入は子シーンの寸法を使用する。ライブラリー変更・失敗除外・表示中除外は全子シーンを集約する。

## スパン時の顔と画面境界

`AvoidFaceDisplayBoundaries`は欠落時true。複数画面のグループでGallery／Vertical Panがスパンする場合に顔検出を準備する。接続中の画面が1台になっても、保存済みキャンバス内の未接続領域へ顔を配置しない。方向選択・顔位置停止とは独立してGalleryにも顔検出を接続し、交換写真も同じ経路へ通す。未検出なら既存の幾何計算を維持する。

`FaceSafeLayout`は写真ごとの全検出顔の外接矩形を使い、各画面の内側24px（小さい画面では短辺の3%）へ収める。Galleryは写真順序・非重複・最小間隔を維持し、位置を調整しても実現できない場合だけ共通の高さを縮小する。可能な最大高さを二分探索する。安全なGalleryの交換では旧／新レイアウトのフェードを使い、顔を境界越しに移動させない。背景はこのフェードを含めた前景から採取する。

Vertical Panは写真のXを固定し、顔が画面内に入る位置へ寄せる。必要なら幅を縮小し、顔停止の終点も画面内へ補正する。内部の上下境界がある画面では移動範囲も制限する。画像が壁より低くなる場合の配置用Yは`MotionPlan.FrameTop`へ保持する。横スクロール・横Pan・Zoomの幾何は変更しない。検出不能な顔まで保護する保証はない。

対象画面の消失では同じグループの残りの画面で表示を続け、消失領域を詰めない。画面の増減・解像度変更・Explorer復旧では影響するセッションの表示部と構成を再生成する。時計はグループ内の全画面を同一の前景ウィンドウが覆ったときだけ遮蔽によって停止し、ほかのグループは継続する。ユーザーの開始・停止・一時停止・次の構成は全グループへ適用する。WPF/DWMの各出力の走査タイミングまでは同期を保証しない。

## リスクと対応

- 全画面表示は対象モニターのShell_TrayWnd / Shell_SecondaryTrayWndだけを一時的に隠す。通常のアプリを最前面で覆わない。停止・スリープ・画面遮蔽時に元に戻す。非表示前に独立した復元プロセスの準備を確認し、所有プロセスの終了または解除イベントで復元する。最初から非表示だったタスクバーは所有・復元対象にしない。

- WorkerWは非公開Shell実装。将来のWindowsで互換性は保証できない。未知の階層では安全に停止しログを残す。
- SetParentは異なるDPIコンテキスト間でプロセスDPIを変えることがある。親のDPIコンテキストに合わせて描画HWNDを作成し、接続後に物理座標を照合する。WPF設定画面はPerMonitorV2を使用する。
- Explorer再起動で子HWNDが消える。独立した通知用HWNDとTaskbarCreated、低頻度の生存確認で再生成する。
- モニター消失時は別画面へ自動移動しない。選択ID・領域を保持し、接続中の選択画面だけで共通キャンバスの表示を続ける。全対象が消えた場合は停止して復帰を待つ。
- WebPには明示的なデコーダーを用意する。HEICはWindows WICコーデックがある場合のみ対応。
- デコードはバックグラウンドで実行し、凍結BitmapSourceだけをUIへ渡す。LRUキャッシュをメモリ予算で制限する。
- モーションはWPFのアニメーションクロックを使用する。UIタイマーで毎フレーム描画しない。
- 遮蔽判定はforeground/location/minimizeのWinEventを集約する。グループ内の全対象画面を覆う単一の前景ウィンドウで、そのグループを停止する。複数ウィンドウの和による完全遮蔽は初期版では検出しない。

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

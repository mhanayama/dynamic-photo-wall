# Windows / macOS 機能差レビュー

**2026-10-17追記:** 次に移植する機能は[Windows追加分の引き継ぎ](WINDOWS_DELTA_HANDOVER.md)のD01〜D07を参照。以下の最新判定はv1.0.1時点で、今回追加された画面グループ・即時テスト表示・顔によるパン方向・モード別の画面単位描画・スパン中の顔境界回避を含まない。

更新日: 2026-10-15（日本時間）。最新の実装・判定・全TODOは [MACOS_PARITY_TODO](MACOS_PARITY_TODO.md) を正本とする。

**最新判定:** フォルダー行の削除操作と保存後の再起動をUIで検証し、次構成の先読み、FSEvents監視、永続metadata／顔キャッシュ、Vision顔検出とPan／Zoom位置調整、前景配置からの動的背景、遮蔽休止、ログイン起動、完全な設定ドラフト／原子的保存、ログ、単一起動を追加した。Pan／Zoomのキャプションを移動画像の外へ固定し、SineEaseのフェードと、大きな顔で高さが画面未満になる縦Panの中央配置もWindowsへ整合。Windows Coreの共通fixtureと隔離した単体74件／UI 3件のテストを実行し、arm64 Releaseのコンパイルも成功。実機受け入れの残件を明記したうえで、2026-10-15のユーザー承認により[v1.0.1 build 3を公開](https://github.com/mhanayama/dynamic-photo-wall/releases/tag/macos-v1.0.1)した。

Dock／メニューバーはmacOS側の設定に従う仕様をユーザーが了承した。これ以外のOS合成画面・抜差し・スリープ・実ログイン・長時間運転は未検証のまま合格扱いにしない。

以下は2026-10-14〜15の修正前／追加実装前のレビュー記録。本文中の「未実装」「CLIのみ」は当時の状態で、現在の残件を表さない。公開済みv1.0.0のタグ・配布物は保持し、v1.0.1は当初公開を見送ったが、その後の実装・自動検証とユーザーの公開承認を経てbuild 3を公開した。

## UIとキャプションの追加確認（2026-10-15）

Windowsの `SettingsWindow.xaml` / `SettingsWindow.xaml.cs` / `TrayController.cs` / `PhotoRenderer.cs` とmacOSの設定・メニュー・写真上の表示を照合した。共通の数値設定は既定値・正規化範囲とも一致している。

| 差分 | macOSの対応 |
|---|---|
| 横Galleryの名称、Horizontal Panの説明 | `Scrolling Gallery`、`パノラマを左右に見せる`へ統一 |
| 抽選ウェイトとパン設定の補足不足 | 0で抽選対象外、拡大率の初期値4倍、表示幅が画面幅の割合であることを明記 |
| EXIF設定名は撮影日時を含まず、写真上は2行・ロケール依存の日付 | 設定名に撮影日時を追加。キャプションを1行にし、`yyyy/MM/dd HH:mm`、長い名前の末尾省略へ統一 |
| 現在モードの表示が `horizontalGallery` 等の内部名 | 設定と同じ `Scrolling Gallery` / `Cinematic Zoom` 等の表示名へ変更 |
| 写真フォルダーの削除操作がリストの削除操作だけ | 複数選択と「選択を削除」ボタンを追加。フォルダー表記も統一 |
| メニューと設定ウィンドウの名称・初期サイズ | 「スライドショー開始」「表示停止」「次の写真 / 構成」「設定を開く」、設定タイトル、880×760へ統一 |
| ディスプレイ接続の説明不足 | 接続台数・選択画面だけに表示する説明、保存画面が未接続の案内を追加 |
| 背景設定が「表示中の写真に追従」と案内していた | 現実装に合わせ「写真をぼかしたガラス風の背景」へ修正 |

OS固有の説明はmacOSの動作に合わせる。終了操作はメニューバー、画像形式はmacOSのImageIO対応を案内する。顔位置調整・前景に追従する背景・ログイン起動・遮蔽休止などは既存TODOの残件で、このUI修正を機能同等性の完了とは扱わない。

修正版はアプリv1.0.1（build 2）としてReleaseへ反映する。公開済みv1.0.0のタグ・配布物は保持する。検証は引き続きCLIのコンパイルとパッケージの整合性確認までとし、実画面・テスト本体は実行しない。

## 修正状況

| 指摘 | 対応した動作 | 残る確認 |
|---|---|---|
| R01 | 写真候補を再生中に差し替え、追加だけではウィンドウ・scene ID・時計をリセットしない。表示中写真の削除／更新では旧ビットマップを保持して次画像を準備。走査結果が0枚でも最後の表示を保持して待機 | 写真の追加・上書き・削除、手動／5分照合、外付けストレージでの表示 |
| R02 | 次流入写真を先読みして保持。成功した写真を右側へ配置してからscrollを進め、先頭退出後に座標を補正。未準備時は現在位置で待ち、失敗候補はstripへ入れず別候補へ進む | 遅いストレージ、破損画像、小規模ライブラリ、右端の連続性 |
| R03 | 再生要求・ウィンドウ保持・エラー待機を分離。全候補失敗時は「待機中」を表示。Nextと「再検索して再試行」で失敗集合を解除し、元の写真候補から復旧可能にした | 全件失敗→ファイル修復→再試行、pause中の復旧 |
| R04 | モード・物理viewportから必要幅を計算。元解像度・幅8192・約16MPを上限にImageIO縮小。パス／更新情報／デコード寸法で画像をキャッシュし、解像度を上げる間も既存ビットマップを保持 | Retina・極端な縦写真の実画質、デコード時間とプロセスメモリ |

併せて、極端な縦Panのアスペクト比クランプを撤去し、Gallery初回・再交換の待機をフェード後から数えるようにした。横Gallery流入も縦写真を優先する。次scene自体の事前先読み、顔検出、前景に追従する背景、常駐運用機能は別の残件。

## 優先問題の指摘記録（修正前）

### R01 / P1 — ライブラリ更新で壁表示を破棄し、点滅が再発する

写真を追加・削除・上書きし、手動または5分ごとの再走査で一覧が変わると、`AppModel.reloadPhotos` は `suspendWall()` を呼ぶ。この処理はウィンドウを閉じ、再生コントローラーの旧画像・outgoingも消す。その後にウィンドウを作り直すため、新しいシーンの準備完了待ちがあっても旧表示を保てない。

Windowsはライブラリ追加だけで表示を破棄せず、表示中ファイルが消えた時だけNextを要求する。macOSの直近のブラックアウト修正は通常のscene切替を対象としており、この経路には適用されていない。

- macOS: [AppModel.reloadPhotos / suspendWall](DynamicPhotoWall/AppModel.swift)（一覧変更判定付近、206行／242行）。
- Windows: [WallController.LibraryChanged](../windows/src/DynamicPhotoWall/WallController.cs)（256行）。
- 対応: ライブラリ候補だけを更新し、現在のウィンドウ・旧ビットマップを維持。現在写真の削除は準備済み画像への切替にする。新TODO M39。

### R02 / P1 — 横Galleryの新規流入にデコード完了保証がない

`updateScroll` は先頭を削除して新しい写真を末尾へ追加した後で `prepare(scene.assets)` を開始する。シーン初期表示の `waitingForImages` とGallery交換の待機処理は、流入写真には使われない。遅いストレージや破損画像では、その写真が見える位置に来ても `PhotoImageView` が `Color.clear` を描き、空欄になる。

さらに `prepare` は失敗写真に到達すると残りの処理を打ち切るが、scroll側は返り値・failedKeysを処理しない。失敗写真がstripにある間、後続写真の準備まで止まり得る。Windowsは流入候補を先読みし、デコード成功した画像だけを `AdvanceGalleryAsync` へ渡す。

- macOS: [WallPlaybackController.updateScroll](DynamicPhotoWall/WallPlaybackController.swift)（283行）、[PhotoImageStore.prepare](DynamicPhotoWall/PhotoImageStore.swift)（93行）、[PhotoImageView](DynamicPhotoWall/PhotoImageView.swift)（11行）。
- Windows: [PrepareScrollPhotoAsync / ScrollGalleryAsync](../windows/src/DynamicPhotoWall/WallController.cs)（201行／214行）。
- 対応: 次流入写真1枚を準備済みとして保持。失敗候補を除外し、準備不足時はstripを空けずに待機する。M12 / M13 / M19。

### R03 / P2 — 全画像失敗後に「再生中」のままNextが無効になる

全候補がデコードに失敗すると `moveToNext` は `currentScene = nil` にする。一方、`AppModel.isPlaying` はtrueのままで、15秒の健全性確認も `!isPlaying` を満たさず再生を再構成しない。メニューは再生中の操作を表示するが、NextはcurrentSceneなしのguardで戻る。停止→開始や設定適用で復旧操作はできるものの、表示と操作状態が一致していない。

Windowsは準備できない場合の待機・再試行ループを維持する。macOSも「最後の写真を保持して待機」と「再生中」を状態として分ける必要がある。

- macOS: [moveToNext / next](DynamicPhotoWall/WallPlaybackController.swift)（195行／112行）、[AppModel.reconcilePlayback](DynamicPhotoWall/AppModel.swift)（228行）。
- Windows: [WallController.PlayAsync](../windows/src/DynamicPhotoWall/WallController.cs)（141行）。
- 対応: エラー待機状態をモデルとメニューへ反映し、再試行を有効にする。新TODO M40。

### R04 / P2 — 表示寸法に応じたデコードがなく、画質・負荷が異なる

macOSはすべての写真を「長辺最大4096、約16MPまで」でデコードし、Galleryの小さな枠でも同じ寸法を使用する。Windowsはモードと物理viewportから必要幅を計算し、デコード幅もキーに含める。

この差により、高解像度写真の小さなGalleryでは余分なメモリとデコード負荷が生じる。一方、非常に縦長のPanでは長辺4096制限が先に働き、必要な表示幅を満たせず柔らかくなりやすい。LRU予算が実装されたことと、表示中を含めたプロセスメモリがその予算内に収まることは別。両OSとも表示中画像等はキャッシュ予算外であり、macOSだけの予算違反とは扱わない。

- macOS: [PhotoImageDecoder.decode](DynamicPhotoWall/PhotoImageStore.swift)（31行）。
- Windows: [PrepareAsync](../windows/src/DynamicPhotoWall/WallController.cs)（192行）、[ImageCache.LoadAsync](../windows/src/DynamicPhotoWall/PhotoLibrary/ImageCache.cs)（16行）。
- 対応: 必要な物理幅・向き・画素上限から寸法を決め、寸法付きキーでキャッシュする。M11 / M12。

## その他の動作差の記録（修正前・今回コード修正済み）

- **極端な縦写真のPan**: macOSの高さ計算は `width / max(aspect, 0.01)`、Windowsは `width / aspect`。縦横比0.01未満でサイズ・移動距離・速度計算が変わる。例: 500×100000の画像は走査の5億画素上限内だが、計画上の高さがWindowsの半分になる。通常写真の幾何一致だけで全画像対応と判定できない。[WallMotionGeometry](DynamicPhotoWall/WallScene.swift)、[MotionEngine](../windows/src/DynamicPhotoWall.Core/MotionEngine.cs)。M17 / T02。
- **Gallery初回交換時刻**: macOSはscene開始から `min + slot×3秒`。Windowsはsceneフェード完了後に同じ待機を始めるため、macOSの方がfadeSecondsだけ早い。致命的な不具合ではないが、同じ設定・時刻の厳密比較では一致しない。M18 / T02。
- **横Gallery流入の縦写真優先**: Windowsは流入選択で縦写真を優先するが、macOSのscroll replacementは全候補から選ぶ。初期構成の縦写真優先だけではこの差は解消しない。M08 / M19。

## 機能の到達状況

| 領域 | 現在のmacOS判定 |
|---|---|
| 5モード、重み抽選、直近履歴、逐次順序 | 本番経路に接続済み。通常の適格条件・基本幾何はWindowsと同系。統計・全境界条件の実行確認は未 |
| 通常scene／Gallery交換のブラックアウト対策 | 旧ビットマップ保持、準備完了後のフェード、安定したview IDを実装。実画面の解消判定は未 |
| pause、Next、画面ID保持、切断待ち、スリープ通知 | 実装あり。実機での復帰・Spaces・混在Retinaは未確認 |
| 顔検出、縦Panの顔停止、Zoom顔位置調整 | 未実装。Windowsは実装あり |
| 表示中の切抜き／移動に追従する背景 | 未実装。macOSは先頭元写真由来の背景と交換時フェード。Windowsは前景の動的採取 |
| 次sceneの事前先読み | 未実装。macOSは切替要求後に準備して旧表示を保持。Windowsはscene再生中から準備 |
| フォルダのイベント監視 | 未実装。macOSは手動／5分照合。Windowsは変更通知と1秒デバウンスも実装 |
| metadata／faces永続キャッシュ、ローテーションログ | 未実装 |
| 他アプリによる遮蔽時の休止、ログイン自動起動 | 未実装 |
| Dock／Menu Barの対象画面限定制御 | 未実装・同等仕様の実機調査が必要 |
| 設定ドラフト・キャンセル・保存の完全分離 | 部分実装。適用済み設定は分離したが、フォルダ登録等は即時変更 |

## 今回の確認範囲

- 修正後のCLI `xcodebuild build` と `build-for-testing` は成功。Swiftソースのコンパイル警告なし（AppIntentsメタデータ未使用のツール通知は除く）。単体テストは11件追加した計45件と、UIテストをコンパイルした。
- 追加ケースは、ライブラリ追加／削除時のウィンドウ保持、同名更新中の旧画素保持、scroll準備待ち／失敗除外、全件失敗後のモデル状態と再試行、寸法別キャッシュ、極端な縦Pan、ImageIOの実縮小を対象とする。
- 最新ログ: `artifacts/macos-parity-fixes-build.log`。DerivedData: `artifacts/macos-parity-fixes/DerivedData`。初回レビューのログは `artifacts/macos-parity-review-build.log`。いずれもGit対象外。
- ユーザー指定に従い、テスト実行・実行中アプリ操作・packagingは行っていない。45件PASSとは判定していない。上記の不具合の指摘はソース経路からの判断で、実機再現・解消結果ではない。
- Windows実行環境がないためWPFの再実行はしていない。既存Windows実機記録は [TEST-RESULTS](../windows/docs/TEST-RESULTS.md) を参照。

次の確認はXcodeからの実表示と追加回帰テストの実行。その後の実装は、次scene先読み・イベント監視、顔検出・動的背景、常駐運用の不足を進める。全TODOは [MACOS_PARITY_TODO](MACOS_PARITY_TODO.md) を参照。

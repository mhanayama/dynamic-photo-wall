# Windows / macOS 機能差レビュー

確認日: 2026-10-14（日本時間）。対象: `6a2ff97`。WindowsとmacOSのローカル実装を静的に照合した。今回のレビューではアプリ実装を変更していない。

**判定: 基本表示・選択・一時停止は揃ってきたが、未解消の不具合と未実装機能があり、Windows版と同等の品質として合格にはできない。** シーン切替とGallery交換の画像準備待ちは実装されている。ただし横Gallery流入、ライブラリ更新、エラー終了には別の表示欠落経路が残る。

## 優先して直す問題

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

## その他の正確な動作差

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

- CLI `xcodebuild build-for-testing` は **TEST BUILD SUCCEEDED**。Swiftソースのコンパイル警告なし（AppIntentsメタデータ未使用のツール通知は除く）。34件の単体テストコードとUIテストをコンパイルした。
- ログ: `artifacts/macos-parity-review-build.log`。DerivedData: `artifacts/macos-parity-review/DerivedData`。いずれもGit対象外。
- 前のユーザー指定に従い、テスト実行・実行中アプリ操作・packagingは行っていない。上記の不具合はソース経路から判断したもので、今回の実機再現結果ではない。
- Windows実行環境がないためWPFの再実行はしていない。既存Windows実機記録は [TEST-RESULTS](../windows/docs/TEST-RESULTS.md) を参照。

推奨修正順: **R01・R02 → R03 → R04 → 顔検出・動的背景・常駐運用の不足**。全TODOは [MACOS_PARITY_TODO](MACOS_PARITY_TODO.md) を参照。

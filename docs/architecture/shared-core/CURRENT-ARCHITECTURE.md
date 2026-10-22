# Current Architecture Analysis — Shared Core調査

調査日: 2026-10-22 JST。基準: `8354c857f50d99287873f0669fe0b6e9fb67cf8c`。調査開始時の作業ツリーに変更なし。
本資料はコードを読んだ設計調査であり、Rust実装・性能改善の実証・Macでの再実行を意味しない。

関連成果物: [全体設計・Render Plan・FFI](PROPOSED-ARCHITECTURE.md)、[移行・検証計画](MIGRATION-ROADMAP.md)、[リスク](RISK-ASSESSMENT.md)、[ADR](ADR-0001-SHARED-CORE.md)。
既存の[壁の共通仕様](../../CROSS-PLATFORM-WALL-PLAN.md)、[LAN仕様](../../NETWORK-CORE.md)、[Mac差分合意](../../../macos/WINDOWS_DELTA_HANDOVER.md)を再定義せず、責務の移動だけを提案する。

## 1. 現行の実行経路

### Windows

```text
WallController.InitializeAsync / StartAsync
  ├─ PhotoScanner.ConfigureAsync → ScanAsync → MetadataExtractor.Read
  └─ グループごと WallPlaybackSession.Start → PlayAsync
       ├─ PrepareAsync → CompositionEngine.Next / ForMode → PhotoSelector.Pick
       ├─ PreparePartAsync → ImageCache.LoadAsync → FaceAnalyzer.AnalyzeAsync
       ├─ PhotoRenderer.Build / BuildPerDisplay
       │    ├─ FixedGalleryLayout.Arrange / FaceMotionSafety.Plan
       │    └─ TransitionController → WPF Storyboard
       └─ Gallery交換 / Scroll流入 / 次構成の先読み

WindowsNetworkHost → PeerSession → SceneCoordinator.PumpAsync
  → WindowsScenePlanner.PrepareAsync → Prepare (Task.Run)
  → CompositionEngine / GalleryTimeline / FaceMotionSafety
  → WindowsAmbientBuilder.Build → SharedScenePlan
  → WindowsPlaybackOutput.PrepareAsync → SharedSceneBuilder.Build
  → Ready / SceneCommit → CompositionTarget.Rendering → PresentShared
```

根拠: [WallController](../../../windows/src/DynamicPhotoWall/WallController.cs)、[WallPlaybackSession](../../../windows/src/DynamicPhotoWall/WallPlaybackSession.cs)、[WindowsScenePlanner](../../../windows/src/DynamicPhotoWall/Networking/WindowsScenePlanner.cs)、[WindowsPlaybackOutput](../../../windows/src/DynamicPhotoWall/Networking/WindowsPlaybackOutput.cs)。
ローカルの`CompositionPlan`は写真・モード中心で、描画側`Build`にもレイアウト計算・乱数が残る。一方LAN経路は始点・終点まで事前決定する。この差が移行上の重要な接続点になる。

### macOS

```text
AppModel.reloadPhotos → PhotoLibrary.scan / PhotosAlbumLibrary.scan
AppModel.reconcileOutputs → WallGroupPlayback
  → WallScenePlanner.nextGroup / next → PhotoSelector.pick
  → WallPlaybackController.start / prepareScene
  → PhotoImageStore.prepare → PhotoImageDecoder / PhotosAlbumLibrary.decode
                             → PhotoFaceAnalyzer.analyze
  → update / presentation → FixedGalleryLayout / FaceMotionSafety
  → DesktopWallView / WallSceneViews / AmbientBackground

PNPeerSession → PNSceneCoordinator.pump → PNScenePlanner.prepare
  → PNPlanningCatalog.prepare (actor、全写真のID・参照表を再利用)
  → WallScenePlanner.nextGroup / GalleryTimeline.buildPlan
  → ambient → PNScene
  → PNPlayback.prepare → PNCommit → PNDisplayFrameDriver
  → PNPresentation → PNSceneView → PNLayerCompositor (CALayer)
```

根拠: [AppModel](../../../macos/DynamicPhotoWall/AppModel.swift)、[WallGroupPlayback](../../../macos/DynamicPhotoWall/WallGroupPlayback.swift)、[WallPlaybackController](../../../macos/DynamicPhotoWall/WallPlaybackController.swift)、[PeerPlayback](../../../macos/DynamicPhotoWall/Networking/PeerPlayback.swift)、[PeerPlaybackOutput](../../../macos/DynamicPhotoWall/Networking/PeerPlaybackOutput.swift)。
`WallScenePlanner`とローカル再生制御はMainActor。LANのcatalog変換だけは専用actorへ分離済みで、Shared Core導入時にもこの再利用を失ってはならない。

## 2. 12機能の移管判定

分類: **C**=Shared Core、**R**=Native Renderer、**A**=Platform Adapter、**保留**=OS差または互換性を先に確認。既存のネイティブ再生ホストはR/Aを接続する薄い調整役として残す。

| 機能 | Windowsの根拠 | macOSの根拠 | 推奨する境界 |
|---|---|---|---|
| 1. 列挙・選択 | `PhotoScanner.ConfigureAsync/ScanAsync`、`MetadataExtractor.Read`、`CompositionEngine.SelectPhotos` | `PhotoLibrary.scan/makeAsset`、`PhotosAlbumLibrary.scan`、`AppModel.uniquePhotos`、`WallScenePlanner.next` | ファイル列挙・更新監視・権限・PhotoKit=A。カタログを入力にした適性・選択=C。OSごとの隠しファイル／リンク規則は維持 |
| 2. 乱数・重複回避 | `PhotoSelector.Pick/Sample/Remember`、`ModeSelection.Pick` | 同名Swiftの`pick/sample/remember`、`ModeSelection.pick`、`SeededRandomNumberGenerator` | C。ただし現在のRNGと名前順の不一致を互換入力で吸収。ローカルselectorは内容hashで別ファイルを同一視しない。LANの資産IDは既存の内容hashを利用 |
| 3. 履歴・状態 | selectorの`recent/selected/sequentialAfter`、engineの`previous/repeats`、sessionの`failed` | selectorの`recentURLs/selectedURLs`、plannerの`previous/repeats`、controllerの`failedVersions/pendingSlots` | 履歴・rotation・モード履歴=C。画像task・取消・ネイティブ失敗の収集=A/R。失敗versionの選択除外はCへ入力 |
| 4. レイアウト | `FixedGalleryLayout.Arrange/Update`、`WallLayout` | `FixedGalleryLayout.arrange/update`、`DisplayLayout.groups` | C。OS画面原点から壁配置への初期変換はA。現在の固定短辺Galleryを移す |
| 5. モードごとの配置 | `CompositionEngine.Next/ForMode`、`PhotoRenderer.Build/ReplaceSlotAsync`、`GalleryTimeline.BuildPlan`、`MirrorPolicy` | `WallScenePlanner.next/nextGroup`、`WallMotionGeometry`、controllerの`replaceSlot/updateScroll`、`GalleryTimeline.buildPlan` | 配置・追加／交換・mirror・continuation=C。WPF要素／SwiftUI／CALayer構築・途中補間=R |
| 6. アスペクト・顔・構図 | `PhotoInfo.Width/Height`、`MotionEngine.Plan`、`FaceMotionSafety.TryPlan`、`FaceSafeLayout.Bounds/VerticalPan`、`FaceAnalyzer` | `PhotoAsset`、`WallMotionGeometry.plan`、`FaceMotionSafety.plan`、`PhotoFaceAnalyzer.analyze` | 向き補正済み寸法と顔矩形を受ける計算=C。EXIF読取り・実ピクセル回転・OS検出=A/R。検出結果自体の一致は保証外 |
| 7. タイミング | `AnimationScheduler.DelayAsync`、`PlayAsync/UpdateGalleryGroupAsync`、`SceneCoordinator`、`SharedClock` | `WallPlaybackClock`、`WallGroupPlayback.update`、`WallPlaybackController.update`、`PNSceneCoordinator/PNSharedClock` | 次イベント時刻・保持・pause理由の状態=C。時計読取り／wake／task待機=A。LAN障壁・時計補正は当面既存通信モジュール |
| 8. アニメーション | `TransitionController.Animate/Start/RemoveTree`、`PhotoRenderer.PresentShared`、`SceneEvaluation.Evaluate` | `WallAnimation.ease`、`PNPlacement.evaluate`、`PNPresentation`、`PNLayerCompositor.update`、`PNDisplayFrameDriver` | Cはcurveと端点・時刻を出力。毎フレーム評価・補間・フェード描画はR。display linkやWPF描画周期をRust timerに置換しない |
| 9. デコード・cache・GPU | `ImageCache.LoadAsync/Decode/ClearAsync`、`ImageDecodeStream`、`SharedDecodeSizing`、`PreparedAmbientTextures`、`SharedSceneBuilder` | `PhotoImageDecoder.decode`、`PhotoImageStore.prepare/setDisplayedAssets`、`PNPlayback.prepare/Frame`、`PNLayerCompositor` | すべてR（写真バイト取得はA）。CはID・幾何・必要資産だけ。GPU面／画素／画像LRUをRustと二重所有しない |
| 10. 複数画面 | `MonitorManager.Enumerate`、`DisplayGroups.Create/WallLayout`、`DesktopWindowHost.Attach`、`WallPlaybackSession.RecoverAsync` | `ScreenDescriptor.availableScreens`、`DisplayLayout.physicalOrigins/groups`、`AppModel.reconcileOutputs`、`DesktopWindowController` | 壁の正規化・切出し・グループ政策=C。列挙／DPI／接続通知=A、window／表示面=R。画面ID永続性は保留 |
| 11. LAN | `shared/DynamicPhotoWall.Networking`の`PeerSession/SceneCoordinator/PhotoTransferService`、`WindowsNetworkHost` | `Networking/PeerSession.swift`、`PeerTransport/PeerPhotos/PeerStorage/PeerFileSecrets` | 具体的計画=C、wire変換=A。TLS・発見・鍵・写真転送・暗号化cache・選出は既存モジュールを維持。全体のRust化は別ADR |
| 12. 設定 | `WallSettings.Normalize`、`SettingsManager.Load/Save/SetAutoStart`、`WindowsPlaybackOptions.Import` | `WallSettings`のdecode/正規化、`SettingsRepository.load/save`、`PeerSettingsAdapter`、`FolderBookmarkStore` | 共通再生値の検証・既定値=Cへ段階移管。JSON/UserDefaults・draft取消・bookmark・login・鍵=A。既存保存形式は維持 |

上表のファイル入口: [Windows Core](../../../windows/src/DynamicPhotoWall.Core/)、[Windows PhotoLibrary](../../../windows/src/DynamicPhotoWall/PhotoLibrary/)、[Windows Rendering](../../../windows/src/DynamicPhotoWall/Rendering/)、[macOS本体](../../../macos/DynamicPhotoWall/)、[既存C#通信](../../../shared/DynamicPhotoWall.Networking/)。

対応部品の直接参照:

| 対象 | Windows | macOS |
|---|---|---|
| 走査・監視 | [PhotoScanner.cs](../../../windows/src/DynamicPhotoWall/PhotoLibrary/PhotoScanner.cs) | [PhotoLibrary.swift](../../../macos/DynamicPhotoWall/PhotoLibrary.swift) / [PhotoFolderWatcher.swift](../../../macos/DynamicPhotoWall/PhotoFolderWatcher.swift) |
| selectorとmode | [PhotoSelector.cs](../../../windows/src/DynamicPhotoWall.Core/PhotoSelector.cs) / [CompositionEngine.cs](../../../windows/src/DynamicPhotoWall.Core/CompositionEngine.cs) | [PhotoSelector.swift](../../../macos/DynamicPhotoWall/PhotoSelector.swift) / [WallScene.swift](../../../macos/DynamicPhotoWall/WallScene.swift) |
| Gallery・安全幾何 | [FixedGalleryLayout.cs](../../../windows/src/DynamicPhotoWall.Core/FixedGalleryLayout.cs) / [FaceMotionSafety.cs](../../../windows/src/DynamicPhotoWall.Core/FaceMotionSafety.cs) | [FixedGalleryLayout.swift](../../../macos/DynamicPhotoWall/FixedGalleryLayout.swift) / [FaceMotionSafety.swift](../../../macos/DynamicPhotoWall/FaceMotionSafety.swift) |
| metadata・顔 | [MetadataExtractor.cs](../../../windows/src/DynamicPhotoWall/PhotoLibrary/MetadataExtractor.cs) / [FaceAnalyzer.cs](../../../windows/src/DynamicPhotoWall/PhotoLibrary/FaceAnalyzer.cs) | [PhotoAsset.swift](../../../macos/DynamicPhotoWall/PhotoAsset.swift) / [PhotoFaceAnalyzer.swift](../../../macos/DynamicPhotoWall/PhotoFaceAnalyzer.swift) |
| decode・cache | [ImageCache.cs](../../../windows/src/DynamicPhotoWall/PhotoLibrary/ImageCache.cs) | [PhotoImageStore.swift](../../../macos/DynamicPhotoWall/PhotoImageStore.swift) / [PhotosAlbumLibrary.swift](../../../macos/DynamicPhotoWall/PhotosAlbumLibrary.swift) |
| 描画・背景・補間 | [PhotoRenderer.cs](../../../windows/src/DynamicPhotoWall/Rendering/PhotoRenderer.cs) / [TransitionController.cs](../../../windows/src/DynamicPhotoWall/Motion/TransitionController.cs) / [GlassBackground.cs](../../../windows/src/DynamicPhotoWall/Rendering/GlassBackground.cs) | [AmbientBackground.swift](../../../macos/DynamicPhotoWall/AmbientBackground.swift) / [WallSceneViews.swift](../../../macos/DynamicPhotoWall/WallSceneViews.swift) / [PeerLayerCompositor.swift](../../../macos/DynamicPhotoWall/Networking/PeerLayerCompositor.swift) |
| 画面と壁 | [MonitorManager.cs](../../../windows/src/DynamicPhotoWall/DesktopIntegration/MonitorManager.cs) / [WallLayout.cs](../../../windows/src/DynamicPhotoWall.Core/WallLayout.cs) | [ScreenDescriptor.swift](../../../macos/DynamicPhotoWall/ScreenDescriptor.swift) / [DisplayLayout.swift](../../../macos/DynamicPhotoWall/DisplayLayout.swift) |
| LAN stateと障壁 | [PeerSession.cs](../../../shared/DynamicPhotoWall.Networking/Session/PeerSession.cs) / [SceneCoordinator.cs](../../../shared/DynamicPhotoWall.Networking/Playback/SceneCoordinator.cs) | [PeerSession.swift](../../../macos/DynamicPhotoWall/Networking/PeerSession.swift) |
| 設定・保存 | [Models.cs](../../../windows/src/DynamicPhotoWall.Core/Models.cs) / [SettingsManager.cs](../../../windows/src/DynamicPhotoWall/Configuration/SettingsManager.cs) | [WallSettings.swift](../../../macos/DynamicPhotoWall/WallSettings.swift) / [SettingsRepository.swift](../../../macos/DynamicPhotoWall/SettingsRepository.swift) |

## 3. 挙動として維持するものと差分

### 3.1 選択・履歴は単なるshuffleではない

両selectorは「同時表示除外 → 未選択集合 → recent除外 → 候補が尽きたら最古recentへ緩和」を持つ。全未選択が尽きると、その候補集合を既選択集合から取り除いて一巡を再開する。`Remember/remember`は選択時に更新され、実際の表示開始時ではない。先読みも履歴を進めるため、取消で履歴を巻き戻す設計は互換性変更になる。

`Sample`は候補を評価するだけで履歴を記録しない。ただしWindowsは乱数キーによるsort、Swiftは`shuffled`で、乱数消費も異なる。Windowsは`.NET Random`、SwiftはSplitMix64系の独自generator＋標準ライブラリの範囲抽選。現時点で同一seedの同一抽選列は実装されていない。

Windowsのパス比較は主に`OrdinalIgnoreCase`、Swiftの並べ替えは`localizedCaseInsensitiveCompare`、同一性は`URL/Set<URL>`。`PhotoLibrary.scan`の最終sortには`localizedStandardCompare`もある。同じ名前の異なる大文字小文字、自然数順、Unicode、case-sensitive volumeで同値と決めつけない。

小ライブラリーの除外も呼出側次第で異なる。Windowsの`PrepareAsync`は選択不能なら現在表示の除外なしで再試行し、`WallScenePlanner.next`にも候補ゼロ時の緩和がある。`nextGroup`の画面単位は`compactMap`で、Windowsの準備はpart失敗でグループ全体を返さない。失敗入力での完全同一挙動は未証明。差を新Coreの「修正」として吸収せず、移行時の明示policyと回帰ケースにする。

### 3.2 Galleryと顔保護の現行経路

- `FixedGalleryLayout.Arrange/arrange`: 壁の長辺方向へ配置し、短辺は`cross - 2*gap`を維持。収まらない候補は除外し、1枚が壁より長い場合には外縁cropを許す。追加可能な位置を先に試し、置換時にはincomingをpinして再配置する。
- `FaceSafeLayout.Bounds/bounds`: 有効な全顔の外接矩形。顔保護の余白は`min(24px, display短辺*0.03)`。現在のモーションは元の`MotionEngine/WallMotionGeometry`を呼んだあと`FaceMotionSafety`が安全な出力・移動量・scaleを選び、成立しなければ候補から外す。
- `MotionEngine.PrimaryFace`と`WallMotionGeometry.primaryFace`: 面積降順→Y→X。方向の基準`0.5`の包含、縦の顔停止後3秒保持、横PanとZoomの条件を区別する。古い素のモーションfixtureを現在の安全guardの代用にしない。
- `CompositionEngine.GalleryLayout`、`FaceSafeLayout.Gallery`、`GalleryComposition`は歴史的な縮小型の計算も残す。Swiftの`canImproveGallery/needsPreparedGallery`は現在`false`。Windowsの現行sessionには旧GalleryCompositionの呼出なし。存在するファイルをすべて稼働経路とは数えない。
- `MirrorPolicy.IsBelowHalf/isBelowHalf`: 向き補正後の画像寸法をグループ長辺方向の半分と比較し、等号ではmirrorにしない。Pan/Zoomが対象で、手動の画面別写真選択とは区別する。古いhandoverの縦Pan限定説明より現在のコードを優先する。

### 3.3 ローカルとLANは同一の実行政策ではない

`ModeSelection`はGallery系80／Motion系20を先に抽選し、系統内の有効モードを均等抽選する。旧45/35/20の移行もある。Gallery再当選はローカルでskipする一方、LANでは有限計画を延長するため`allowGalleryRepeat=true`。

ローカルGalleryのscene時間はWindows `PhotoRenderer.Build`とSwift `WallMotionGeometry.duration`で`max(90, galleryMaxSeconds*2)`、LANの初期chunkは`max(90, galleryMaxSeconds*3)`。scrollは120秒以上。LAN Galleryは`GalleryTimeline.BuildPlan/buildPlan`で交換を境界で分断せず、終端写真・frame・`NextChangeSeconds/updated`を次chunkへ持ち越す。移行では`execution_policy=local|lan`を明示する。

fadeにも差がある。Windows localの`ShowAsync/ReplaceSlotAsync`とMac localの`transitionProgress/ForegroundGeometry`はsine ease、LANの`SceneEvaluation/PNPlacement.evaluate/PNPresentation`はlinearのscene／photo fadeを使う。GalleryのframeサイズはWindows localが補間し、Mac localは`replaceSlot`で新サイズを先に適用する。共通Planでcurveとsize trackを明示し、これらを勝手に統一しない。

既存`SharedScenePlan/PNScene`には写真・画面・clip・motion端点・scale・可視期間・独立fade・continuationがある。[SharedScenePlan.cs](../../../shared/DynamicPhotoWall.Networking/Playback/SharedScenePlan.cs)と[PeerContracts.swift](../../../macos/DynamicPhotoWall/Networking/PeerContracts.swift)が契約の根拠。新規Render Planはこれを置き換えるwire versionではなく、最初はこれへ変換する内部契約とする。

### 3.4 キャッシュは3種類を分ける

| 資源 | 現行所有者と性質 | 移行時の扱い |
|---|---|---|
| メタデータ・顔 | Scanner/metadata cache、FaceAnalyzer、PhotoMetadataCache、PhotoFaceAnalyzer。サイズ／更新時刻を含むキー | A。Cへ向き補正済み値をsnapshotで渡す。未解析と検出済み顔なしを区別 |
| 表示画像・texture | Windows `ImageCache`は256MiB既定LRU、FreezeしたBitmapSource。Mac `PhotoImageStore`はLRUと表示中画像を分け、`owners`のpin・必要幅を集約。LANはplan単位の画像保持も持つ | R。予算はprocess全体で集計し、グループ数だけ増やさない。LRU設定は全プロセスメモリの上限ではない |
| LAN原寸写真 | `EncryptedPhotoCache/PNPhotoCache`、transfer service。原寸・顔・generation・TTL・暗号化 | 通信＋A。表示用縮小decodeと別予算。Rust計算部にはバイト列も鍵も渡さない |

`PhotoImageStore.setDisplayedAssets(...owner:)`はすでに所有者別に集約済み。古いhandoverの「単一pin集合だから要改修」は現在の実装評価に転用しない。

Windows LANは`PrepareAsync`で画像と背景PNGをworker上で準備し、UIで`SharedSceneBuilder.Build`する。表示中の`SharedVisual`と先読みを無制限に保存しないことが重要。[メモリ解析](../../../windows/docs/PROCESS-MEMORY-BREAKDOWN-2026-10-21.md)では生存managedよりネイティブ領域が大きく、CoreをRustに置き換えるだけで全体メモリが減る根拠はない。

### 3.5 OS固有の合理的な分離

WindowsはWorkerWへの`DesktopWindowHost.Attach`、Explorer復旧、タスクバーの所有・復元、WPF clockを維持する。Macはdesktop levelのNSWindow、Spaces、Dock／メニューバーのOS設定、security-scoped bookmark、PhotoKitとVisionを維持する。OS画面の座標はWindows物理pxとMac points／下原点で異なる。壁は双方すでに物理px／左上原点である。

顔検出: Windowsは向き補正済みbitmapから640px以下のGray8を作りFaceDetectorへ渡す。MacはVisionの下原点を`y=1-box.maxY`で変換する。Cへ渡す際に再反転・再EXIF回転をしない。検出器の精度・対応codec・色管理・失敗の戻り値はOS差として扱う。

## 4. 重複削減の実益と限界

対応する8組（PhotoSelector、ModeSelection、FixedGalleryLayout、FaceSafeLayout、FaceMotionSafety、MirrorPolicy、GalleryTimeline、GalleryRotation）はWindows計550行、Swift計532行（空行・コメントを含む物理行）。このほかCompositionEngineとWallScenePlanner、MotionEngineとWallMotionGeometryにも重複がある。ただしFaceSafeLayoutには旧fixture用処理もあり、1,082行をそのまま削除可能という見積りではない。

実益は顔・Gallery・mirror・mode重みの変更を2言語へ同期する保守負担の削減。描画やLAN全体まで共通化すると、既存の効果的なOS統合を失いFFI範囲を広げる。FFI wrapper・schema・ビルド2系統の費用は増えるため、まず幾何計算で利益を検証し、選択・状態は後段とする。

## 5. 今回の検証と未確認

2026-10-22、Windows上で`tests/ParityVerifier`をRelease／`--no-restore`で再ビルドし、生成せずに既存fixtureを照合した。

| 検証 | 結果 |
|---|---|
| WindowsParity.json | 36 motion/eligibility、9旧Gallery layout、2 selector、704 assertions成功 |
| WindowsDelta.json | 52 motion、4 face-safe layout、4旧Gallery fill、472 assertions成功 |
| AmbientColors.v1.json | 12ケース成功、WPF/GUIなし |
| `--zoom-framing` | 5,120 assertions成功、GUIなし |

ログ: `artifacts/windows/shared-core-design/parity-checks.txt`（Git対象外）。ビルドは成功したがNU1900警告あり。ネットワーク制限によりNuGet脆弱性情報を取得できず、脆弱性確認成功とは扱わない。
これらは既存C#計算の基準値確認であり、現行FixedGallery・全状態遷移・Rust・Swift実行の合格ではない。Mac build、Rust FFI、提示時刻・GPU・長時間稼働の計測は今回行っていない。本番アプリ・配布物・個人設定・GUI操作は変更していない。

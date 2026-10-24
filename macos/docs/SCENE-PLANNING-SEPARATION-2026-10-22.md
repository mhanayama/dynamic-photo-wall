# 同期切替前の計算負荷とShared Coreへの分離準備

2026-10-22 JST。対象はMacのネットワーク同期。通常アプリ・配布物・設定は更新せず、GUI自動操作も行わない。

## 参照した設計

`docs/shared-core-native-renderer-design`の`01def470a83604cff94e94eb0d01a150f8c67133`を取得して参照した。ブランチ全体のマージやWindows側の実装修正の取り込みは行っていない。

- [ADR-0001](https://github.com/mhanayama/dynamic-photo-wall/blob/01def470a83604cff94e94eb0d01a150f8c67133/docs/architecture/shared-core/ADR-0001-SHARED-CORE.md)
- [Proposed Architecture](https://github.com/mhanayama/dynamic-photo-wall/blob/01def470a83604cff94e94eb0d01a150f8c67133/docs/architecture/shared-core/PROPOSED-ARCHITECTURE.md)
- [Migration Roadmap](https://github.com/mhanayama/dynamic-photo-wall/blob/01def470a83604cff94e94eb0d01a150f8c67133/docs/architecture/shared-core/MIGRATION-ROADMAP.md)
- [Risk Assessment](https://github.com/mhanayama/dynamic-photo-wall/blob/01def470a83604cff94e94eb0d01a150f8c67133/docs/architecture/shared-core/RISK-ASSESSMENT.md)

設計はRust計算Core＋C ABIを提案し、S0基準固定・S1 headless PoCの後に段階採用する。本変更は既存Swift計算の分離準備とMainActor占有の修正であり、Rust導入、FFI/schema確定、S0〜S6完了ではない。

## 調査と修正

`PNSceneCoordinator.pump`は現在の場面の終了4秒前から次の場面を準備する。写真ID・URL等のcatalog変換は既に`PNPlanningCatalog` actorへ移動済みだったが、その後の全写真の適性判定、選択・sort、Gallery配置、将来の交換予定生成は`PNScenePlanner`のMainActorで実行していた。動いているPan／scrollと次場面の計算が競合する経路が残っていた。

写真512枚・同じ計算をMainActorへ戻す比較では、Gallery約331ms、scroll約702msの計算中にMainActorの試験callbackは0回となり、応答性テストが両条件で失敗した。これは合成metadataによるDebug単体比較で、稼働中の報告瞬間を採取したtraceや実提示フレーム計測ではない。実機の全カクつきの原因を確定したとは扱わない。

現在はserial actorが計算sessionを所有する。catalogと入力・結果は値snapshotとして渡し、同じplanner/selectorインスタンスをMainActorと共有しない。準備tokenとTask取消をawait前後で検証し、古い結果を上位へ返さない。既存のNext・Stop・進行役変更時の世代確認とReady／予約Commitはホストに残す。

## 今回作った境界

| 所有者 | 処理・データ | 移行時の扱い |
|---|---|---|
| `PNPlanningCatalog` | metadata snapshotとnative側のID/URL索引。全groupで再利用 | catalog登録adapterの入口。毎sceneの全件変換を復活させない |
| `WallScenePlanner` / `PhotoSelector` | 従来の選択・履歴・RNG | 非Sendableの可変session。各ホストactorに閉じ、S4で比較してから置換 |
| `WallSceneTimelinePlanner` | 適性・選択・配置・motion・Gallery交換予定・終端引継ぎ | LAN v1の既存計算。LAN型、画像、clock、timer、I/Oを参照しない |
| `WallSceneTimeline` | 写真metadata、native display ID、物理pxの幾何、相対秒、個別fade、次交換予定 | Swift内の値。Rust契約・canonical planとして公開しない |
| `PNScenePlanWorker` / `PNSceneTimelineAdapter` | serial session所有、session/revision/topologyの継続検証、wire IDと計算値の変換、`PNScene`生成 | 将来はこの内側からCoreを呼ぶ。LAN世代・UUID・wire変換をCoreへ入れない |
| `PNScenePlanner` | catalogと計画の準備を接続し、背景を付加、古い準備結果を拒否 | 既存`PNScenePlanning`ポートを維持 |
| `PNImageDecode` / `PNPlayback` | ImageIO、背景色補正、画像保持・decode予算、表示準備 | Native Renderer／adapter側に維持 |
| `PNSceneCoordinator` / `PNPeerSession` | Ready、予約Commit、時計、選出、再接続 | 今回のCore移行対象外 |
| `PNPresentation` / compositor / display driver | frame補間、前後場面の保持、CALayer、提示周期、window | Coreを毎frame呼ばない。plan変更でwindowを作り直さない |

幾何・modeの定義を持つgroup plannerは、Observableな再生ホストからファイルも分ける。新しい汎用DI frameworkや多数のprotocolは追加しない。

## まだ分離が必要な箇所と順序

1. S0でローカル／LANの互換fixtureを固定する。`WallSceneTimelinePlanner`はLANの90/120秒chunk・Gallery継続・linear fadeを対象とし、ローカルのskip・duration・sine fadeへ流用しない。
2. S1でopaque ID、content version、native sort rank、Q/U/µs、schemaを確定する。今回のSwift値は`PhotoAsset.url`、`UInt32`の画面ID、Doubleを保持する。これは従来の同一性・順序・丸めを維持する中間形であり、そのままFFIへserializeしない。現LAN adapterが生成する連番のdisplay IDもこの中間形の前提として維持している。`byURL/byID`はnative adapterだけが保持する。
3. S2/S3は既存`WallMotionGeometry`・`FaceMotionSafety`・`FixedGalleryLayout`等の関数へ同じ選択済み入力を渡して比較する。RNG・履歴を二重消費しない。今回のlegacy sessionにはclone/decision tapeがなく、stateful shadowは未対応。
4. `WallPlaybackController.update/preloadNextScene/updateGallery/updateScroll`と`WallGroupPlayback.buildBatch/update`はまだMainActor上で意思決定・画像準備・時刻管理が混在する。S5では準備完了・期限・取消をeventに分け、画像pinとclock・fadeはホストへ残す。今回の同期修正をローカル性能改善として扱わない。
5. `ForegroundGeometryCache`はローカル描画／背景の共通幾何cache。S2/S3では計算結果の受け渡しへ寄せ、SwiftUI bodyからCoreやFFIを直接呼ばない。
6. `PNScenePlanner.ambient`はnativeのまま。画像読込・decode・`AmbientProcessor`は別処理だが、card作成・PNG encodeはMainActorへ戻る箇所が残る。`PNPlayback.Frame`の索引構築や初回の画像texture準備も別の負荷候補。計画計算の分離だけでここまで解消したとしない。
7. S6のCore差し替え時は`PNScenePlanWorker`の内側でtyped値へ変換し、既存wireへ戻す。Rustのstate atomicity・受理時点・取消後の履歴はS4/S6のgateで検証する。今回の既存Swift plannerは計算中に履歴を消費し、未受理提案のrollback機能は持たない。

## 検証

`bash macos/scripts/verify.sh --unit-only`が成功。Swift単体215件／31 suites、共通fixture704＋472 assertions、背景色12ケース、Zoom構図5,120 assertions、ネットワーク26件／241 assertions／0 failures、arm64 Releaseコンパイルを確認した。コンパイラーのwarning/errorは0件。XcodeのCoreSimulator版不一致と既存のCore Image `MDB_MAP_FULL`通知は出たが、macOS試験・ビルドは成功している。

- 応答性試験はcatalog準備を先に終え、512枚のGallery／scroll計算中にMainActor callbackが実行できることを確認する。callback数は試験並列実行・負荷に依存し、FPSや実提示周期へ換算しない。
- wireと計算値の往復は、全placement field、負の座標、小数、scale/anchor、時刻、clip、corner、curve、未指定fadeと明示0秒fadeを照合する。
- 既存の静止／scroll × span／画面別の各100計画・仮想2時間以上の継続、pause／Next、共有wire・背景色・構図の回帰を維持する。
- 合成試験は描画・GPU・実LAN・長時間の実機受け入れの代用にしない。通常アプリを更新した後の体感確認は別途必要。

最終ログは`artifacts/macos/scene-transition-stutter/verify-final.log`、MainActorへ戻した負例は`main-actor-baseline.log`。ルート直下の実ファイル一覧は検証前後で一致し、`git diff --check`も成功した。

ログ・比較結果・DerivedDataはGit対象外の`artifacts/macos/scene-transition-stutter/`と既存`artifacts/macos/verification/`へ置く。

## 同モード再当選の再確認

ユーザーの追加確認により、変更前HEADと比較した。`ModeSelection`は無変更。移動したgroup plannerの選択・継続分岐も、actor隔離注釈を除いて変更前と一致する。同期のplanner/selectorはgroupごとに保持し、計画ごとに作り直さない。

既存規則は以下を維持する。

- ローカルの同じGallery／scroll再当選はskipし、現在表示の更新を続けて5秒後に再抽選。
- 同期の同じGallery／scroll再当選は有限計画の継ぎ足し。写真・終端位置・次の交換予定を引き継ぎ、場面全体を再フェードしない。
- Pan／Zoomの同モード再当選は可能。動き系の適格候補が複数なら3連続を抑止し、1モードしかなければ継続可能。

GUI操作なしで`ModeWeightTests`、`PlaybackRegressionTests`、`GalleryBehaviorTests`、`NetworkModuleTests`、`NetworkPresentationTests`を再実行し、49件／5 suitesすべて成功。同期Galleryの4条件×100計画・仮想2時間以上の継続と、同じsurface・画像・不透明度1の維持を含む。ログは`artifacts/macos/scene-transition-stutter/same-mode-recheck.log`。この確認による製品ロジックの変更はない。

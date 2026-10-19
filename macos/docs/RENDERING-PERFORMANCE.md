# macOS描画負荷の監査と計測

2026-10-19 / [Issue #1](https://github.com/mhanayama/dynamic-photo-wall/issues/1)。ソース基準はbuild 14の`7a711db`。今回は不要な背景生成と幾何計算・再描画要求を減らす段階の実装。その後、稼働build 14のCPU/GPU採取と、同一fixtureによる変更前後の比較を実施した。[2026-10-19の測定結果](RENDERING-MEASUREMENTS-2026-10-19.md)を参照。通常の全画面表示での前後比較、電力、提示フレーム時間は未確認で、Issue全体の完了判定は残す。

## 確認した経路と変更

| 経路 | 確認結果と対応 |
|---|---|
| ローカル背景 | `AmbientSampler`は従来、構成が変わらなくても8Hzの経過時刻で`AmbientProcessor`を呼んでいた。静止Galleryから時間を除いた更新キーへ変更。写真・配置・設定・viewport・画像準備の変更で無効化する。 |
| Pan/Zoom・Galleryの交換/移動 | 動いている区間だけ共有再生時刻から最大8Hzで候補を取る。160px背景上の0.5px単位の位置・寸法・角丸、1/64単位の不透明度で実際の生成を判定。小さい変化は直近の生成位置との差が蓄積してから反映し、動きの終端でも判定する。Scrolling Galleryの読込み待ちなど同じ構図では生成しない。 |
| 背景の色追従 | ローカルはCPU上の反復平滑化をやめ、未平滑化の生成結果へ0.8秒の時定数で表示側が追従する。静止した目標も生成し直さず最終色へ到達。途中の目標変更時だけ小画像の現在の混色を固定し、通常フレームは保持した2画像の不透明度を変える。残差が1/255未満なら完了する。 |
| 非同期生成 | 生成中の変更は最新の1要求へ集約。最後の静止構図を捨てない。pause/停止/破棄時に保留を消し、世代番号とキャンセルで古い結果の公開を防ぐ。resumeはその時点の構成を再判定する。 |
| グループ背景 | 従来の独立した8Hzバケットを廃止し、surfaceごとのsamplerが同じ更新規則を使う。既存samplerを辞書へ毎フレーム再代入しない。複数タイルは同じ生成結果を共有する。 |
| 前景幾何 | 顔保護を含む`WallMotionPlan`と静止Galleryのpackingをキャッシュ。scene/写真の顔情報/slot/配置/settings/viewportの変更で再計算し、位置・倍率・不透明度は従来と同じ再生時刻で評価する。 |
| 写真の描画 | `AppKitPhotoView`からの無条件`needsDisplay = true`を廃止。同じ不変NSImageと同じcontentModeなら再要求せず、画像/fit・fill/サイズの変更で再要求する。画像の補間や描画方式は維持。 |
| 画像ストア | ImageIOの向き補正・16MP上限・幅別LRU/pinを確認。デコード/退避/要求幅変更のrevisionを追加し、背景の変更判定時に毎フレーム全画像variantを検索しない。デコード方式・予算・写真のpin契約は維持する。 |
| 同期表示 | `PNScenePlanner`の背景は有限計画ごとに最大24サンプル/出力を事前生成する経路で、ローカルの永久8Hzループとは異なる。PNGの基底色・受信時の一度だけの色補正・wire時刻/補間を維持。既存のCPU平滑化はこの有限生成用の既定経路として残す。 |
| アーキテクチャ | Debug/Releaseとも`ARCHS = arm64`、macOS 27.0対象。Intel/Rosetta向けへの変更は不要。 |

`DesktopWallView`/グループの`TimelineView`と、同期出力の16msの進行処理は今回維持する。生成の停止と、進行処理全体の停止は別である。交換期限、画像準備、将来のcommit/control、フェード、ネットワーク復旧を正しく起床させるdeadline設計なしに表示時計を停止しない。静止時のCPUがゼロになったという主張はしない。次の実機プロファイルで、これらの待機中wake-upと同期側`PNSceneView`の再描画を測定し、期限駆動への移行範囲を決める。

## Core Image / Metalの判断

`AmbientProcessor`の`CIContext(options: [.useSoftwareRenderer: true])`は確認済み。これは背景のぼかし経路の指定であり、SwiftUI/AppKit/Core Animationを含むアプリ全体がCPU描画という証拠ではない。

背景は最大辺160px。現在はCPUで縮小構図を描く → 余白色を延長 → Core Imageでclamp/blur → CGImageへ読み戻す → 色補正、という経路を通る。Metal-backed CIContextはぼかしをGPUへ移せても、このアップロード・読戻し・色補正を自動でなくさない。GPU版への切替、MTKViewへの全面移行は採用していない。今回の生成頻度の削減とCPU経路を基準として、次の条件を実測してから判断する。

- software/Metalの両経路で、生成パイプライン全体のCPU時間・GPU時間・電力・割当・画像転送と画素差を比較する。
- 1画面・複数画面、静止時・Pan/Zoom中を分ける。初回コンテキスト作成とキャッシュのwarm-upを定常値へ混ぜない。
- Metalでは同じ色空間・clamp・ぼかし半径・余白延長・色補正を守り、GPU不在時のfallbackを残す。
- カスタムMetalの検討は、背景以外の前景compositingが実測上の主要因で、Core Animationによる変換・キャッシュでは不足する場合に限る。

## GUI操作なしの回帰検証

```sh
bash macos/scripts/verify.sh
```

専用bundle IDと`artifacts/macos/verification/`を使用する。`--ui`は使用しない。2026-10-19の結果:

- Swift単体193件 / 30 suites成功（今回11件を追加）。
- 従来fixture704 assertions、delta fixture472 assertions、背景色12ケース、Zoom構図5120 assertions成功。
- .NETネットワーク26ケース / 241 assertions成功。
- arm64 Releaseコンパイル成功。

新規の`AmbientSchedulingTests`とグループ回帰で、次の処理回数・機能を確認する。これらは合成画像と仮想再生時刻による結果であり、実アプリのCPU改善率ではない。

| 条件 | 回帰結果 |
|---|---|
| 不変の静止Gallery / 仮想60秒・3,600更新 | 背景生成1回 |
| 同じグループを2タイルから仮想60秒・各3,600更新 | 共有背景生成1回 |
| 写真交換・viewport変更・画像準備完了・高解像度variantの追加 | 時刻バケットを待たずに背景を更新 |
| Pan/Zoom/scroll、Galleryのフェード/再配置 | 動作中に更新し、停止した構図では生成回数が増えない |
| 同じ0.5px量子化区画内の小さな移動 | 変化が蓄積するまで再生成を抑制 |
| 遅い生成中の連続変更・キャンセル直後のresume | 最新の静止構図を反映し、古い世代を公開しない |
| キャッシュした顔保護の幾何 | 601表示時刻で準備1回。従来の都度計算と座標が一致し、顔/設定/viewport変更で再準備 |
| 同じ写真ビューへ600回の同一画像更新 | 追加の再描画要求なし。fit/fillとサイズ変更では要求する |

初回の実装検証では、通常アプリの置換・再起動、release配布物の更新、GUI操作、スクリーンショット、実端末間の表示試験は実施していない。後続の独立ウィンドウでの実描画計測は[別記録](RENDERING-MEASUREMENTS-2026-10-19.md)へ分ける。Xcode sandbox内ではSwift macro/test通知が制限されたため通常権限で再実行。テスト時にCoreSimulatorのバージョン警告とCore Imageの`MDB_MAP_FULL`ログが出たが、macOS単体・画素回帰とReleaseビルドは成功した。これらのログを性能測定値として使わない。

## 通常の全画面表示での前後比較手順（未実施）

専用設定・同一fixture写真・同じ表示配置/倍率/更新周波数を使用する。通常の個人設定・写真ライブラリを比較用に変更しない。比較元は`7a711db`、比較先はこのIssueのPR。Release設定・同じ署名条件で別々に起動し、両版を同時に動かさない。GUI操作を伴う自動試験は別途明示依頼がある場合だけ行う。

各条件はwarm-up後60秒を3回採取する。静止Galleryだけは交換間隔を測定区間より長くし、交換/再配置は別区間で採取する。環境、写真寸法、設定、CPU平均/ピーク、GPU時間、電力/energy、p50/p95 frame time、memory/allocations、背景生成回数/時間を生データとともに保存する。

1. 静止Gallery: 背景ON/OFF、pause/resume、写真交換・再配置、scene遷移。
2. Horizontal/Vertical Pan、顔で停止している保持区間、Zoom、Scrolling Galleryの動作中・画像読込み待ち。
3. 1画面/複数画面、スパン/画面別/自動ミラー、独立グループ。
4. Mac進行役/Windows進行役、長時間Gallery継続、同期pause/resume、切断/復旧。

`AmbientProcessor.render`全体を`OSSignposter`のsubsystem `asia.dix.mhanayama.DynamicPhotoWall`、category `Ambient`、interval `Generate`で囲んだ。InstrumentsのLogging/Points of Interestで生成回数・所要時間を調べ、スタックと合わせてCGContext描画/blur/readback/色補正の残る比率を確認する。ローカルsamplerの`updateCount`は正常公開した結果の数、signpostはキャンセル/失敗も含む生成試行の数なので区別する。`AspectImageView.redrawRequestCount`はアプリ側の明示要求数であり、OSの実描画数ではない。

既に専用設定で起動した対象PIDへCLIでattachする例（1条件・1ツールずつ、アプリは起動しない）:

```sh
mkdir -p artifacts/macos/rendering-performance
wall_pid=12345  # 比較対象の専用アプリのPIDへ置換
xcrun xctrace record --template 'Time Profiler' --attach "$wall_pid" \
  --time-limit 60s --output artifacts/macos/rendering-performance/candidate-static-cpu.trace
xcrun xctrace record --template 'Animation Hitches' --attach "$wall_pid" \
  --time-limit 60s --output artifacts/macos/rendering-performance/candidate-static-frames.trace
xcrun xctrace record --template 'Metal System Trace' --attach "$wall_pid" \
  --time-limit 60s --output artifacts/macos/rendering-performance/candidate-static-gpu.trace
```

この環境の`xctrace list templates`で上記3つと`Allocations`、`Logging`、`Power Profiler`の存在を確認済み。attach・各計器の計測可否は未確認。システム全体の電力は他プロセス/熱状態の影響も記録する。背景生成回数の削減だけでGPU・電力・知覚上の滑らかさが改善したと結論しない。色管理、フェード、顔保護、EXIF、画面境界、ネットワークの見え方を受け入れ確認してからIssueを完了にする。

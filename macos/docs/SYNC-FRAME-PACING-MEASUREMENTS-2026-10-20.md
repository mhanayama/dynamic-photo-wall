# Mac同期表示の更新間隔の原因調査（2026-10-20）

**ユーザー確認:** build 17配布後の手動テストで「カクつかなくなった」と確認され、mainへの統合指示を受けた。以下の実機未確認・未修正の記述は、それぞれの調査時点の状態。受け入れの範囲は[build 17のノート](RELEASE-NOTES-v1.1.0-build17.md)を参照。

**後続の修正:** ユーザー指示により、画面同期と全候補写真のID・参照表生成の専用actorへの移動・再利用をbuild 17へ反映し、`release/macos/arm64/`のAPP／ZIP／DMGを更新した。単体209件と共有fixture・ネットワーク・arm64 Release、配布物の一致・署名が成功。実機の改善は手動確認待ちで、初回画像表示準備の別経路は未変更。[リリースノート](RELEASE-NOTES-v1.1.0-build17.md)を参照。以下の「未修正」は調査時点の状態。

## 結論

**描画後の16ms相対待機は、60Hz画面に対して更新を遅らせ、写真の位置が繰り返される要因であることを隔離比較で再現した。** 同じ本体の再生・描画処理と合成画像でdriverだけを変更すると、旧方式の約57.5更新/秒が60更新/秒になり、画面更新通知での状態の据え置きが約4.2%から0%になった。描画処理時間は両方式ともp95で約0.44msで、大きな描画負荷を加えなくても再現した。

これはアプリの状態更新と画面更新通知の計測であり、ディスプレイに提示された画素の直接計測ではない。通常アプリで報告された症状の唯一の原因、実機での解消、通信・画像準備・モード遷移時の停止要因まで確認したとは扱わない。通常アプリと配布物は更新していない。

**追加の実運転トレースでは、16ms相対待機とは別に、次計画の作成による116ms・72msのメインスレッド占有と、初回画像表示準備による約48msの占有を特定した。** 次計画作成の停止と、実際のフレーム更新の116.640ms・72.201msの空白が同じ時刻に一致する。したがってdisplay linkへの置換だけでカクつき全体を修正したとは言えない。今回の製品コードの追加修正は行っておらず、これらは次の修正対象として残る。

## 比較条件

- ソースは `c509f6f` のMac本体。Xcode 27.1 / macOS 27.0.1 / arm64、Release最適化。
- 接続画面は1台、物理1920×1080、60Hz。専用通常ウィンドウ960×540pt、計画のviewportは1920×1080px。
- 合成縦写真の120px/秒の縦Pan。開始前に画像の暗号化一時キャッシュ、デコード、計画準備を完了し、測定中に終端・交換・新規画像準備を含めない。
- 同じ実行ファイルで本体の `PNPlayback.prepare` → `render` → `PNSceneView` → `PNLayerCompositor` を通し、driverだけを切り替えた。旧方式は `b5103a0` の `startTimer()` と同じrender後16ms sleep、新方式は本体の `PNDisplayFrameDriver`。
- 再生位置は両方式で同じ単調時計から算出。全採取位置で `y = -13320 + elapsed × 120` が一致した。display linkのcallback回数を再生時計には使わない。
- 準備3秒、測定要求20秒、AB→BA→ABの順で各3回。実測区間は旧20.003〜20.012秒、新21.073〜21.269秒。終了待機の遅延を含む実測wall時間を保存し、更新率は最初と最後のcallback時刻から計算した。
- 独立した同じ画面のdisplay linkを両方式で動かし、各通知時のアプリの更新番号と位置を採取。通常のbuild 16は稼働を継続し、テスト・ビルド・トレースの同時実行は行っていない。他アプリの負荷は固定していない。
- 個人写真・設定・ネットワーク接続・desktop windowのorderingを比較プログラムへ含めない。デコード済み画像を保持する描画経路は本体と同じ。

## 結果

| 指標 | 旧16ms相対待機 | display link |
|---|---:|---:|
| 更新率（各回） | 57.525 / 57.465 / 57.523回/秒 | 60.000 / 60.000 / 60.000回/秒 |
| 更新間隔の中央値（3回平均） | 17.456ms | 16.666ms |
| 更新間隔p95（3回平均） | 17.709ms | 16.702ms |
| render処理時間p95（3回平均） | 0.434ms | 0.449ms |
| 画面更新通知で状態が据え置かれた回数（各回） | 49 / 51 / 52回 | 0 / 0 / 0回 |
| 同据え置き率（3回平均） | 4.223% | 0% |
| CPU（3回平均、計測プログラム全体） | 3.684% | 2.680% |

画面側の通知間隔は約16.667msで、全6回で1.5周期を超える通知間隔は0件。旧方式のrender完了から次回renderまでの待機中央値は17.199〜17.221msあり、指定した16msにスケジューリング等の遅延が加わっていた。さらにrender処理時間が加わるため、毎秒約2.5回、画面更新に新しい位置が間に合わない。共有時計で位置を計算しているため、その後の更新で現在時刻の位置へ追いつく。速度そのものを変えずに動きが不均等になる説明と一致する。

`duplicate_probe_percent`は実提示の欠落率ではない。producerとprobeのcallback順序、Core Animationのcommit、WindowServer・GPU・走査までの経路を含まない点に注意する。一方でrenderの更新数・間隔でも独立に差を確認でき、据え置き率だけに依存した結論ではない。

## 稼働中build 16の確認

PID 90895、v1.1.0 build 16、約21時間稼働のプロセスを10秒間 `sample` で採取した。通常アプリが旧 `PNPlayback.startTimer()` → `render()` → `PNWindowSurface.present()` → 保持レイヤー更新を実行していることを確認した。メインスレッドの採取5573点中4851点はrun loopの待機経路で、恒常的なCPU飽和を示す結果ではない。Core Animationのcommit、画面列挙、ネットワーク受信とJSON decodeなども現れるが、この統計スタックから個々の更新間隔や長い停止時間は決定できない。

続いて同じPIDへ `Animation Hitches` を20秒attachし、約20.98秒のトレースを採取した（合成比較とは別の時間帯）。`hitches-updates`の当該プロセス1129件は更新間隔中央値17.617ms、p95 18.482ms、最大116.640ms。最大3つの空白は、同じトレースの `potential-hangs` とCPUスタックに次のように対応した。

| トレース開始からの時刻 | メインスレッド占有 | 更新の空白 | 同時刻のスタック |
|---|---:|---:|---|
| 5.634〜5.750秒 | 116.119ms | 116.640ms | `PNScenePlanner.prepare`、116採取点すべてがこの処理内、97点が`PNAssetKey.opaqueId`を含む |
| 8.036〜8.084秒 | 47.601ms | 64.330ms | 48採取点中42点がCore Animationの`prepare_image`、色変換・コピー。5点が背景画像の不透明判定（カテゴリの重複あり） |
| 17.575〜17.647秒 | 72.041ms | 72.201ms | `PNScenePlanner.prepare`、72採取点すべてがこの処理内、55点が`PNAssetKey.opaqueId`を含む |

次計画の作成は`PNPeerSession.pump` → `PNSceneCoordinator.pump`からMainActor上で実行され、`PeerPlayback.swift`の全候補写真からのasset・参照表生成で`opaqueId`を反復計算する。`opaqueId`はUUIDの文字列化・置換とSHA-256の結果の`String(format:)`による16進表記を含み、その処理がスタックに現れる。この間はdisplay linkも同じメインスレッドを使うため描画を進められない。ここは単なる16ms周期のずれと分けて修正する必要がある。

`displayed-surfaces-interval`には16.667msを超える表示保持も記録された。ただしこの表はアプリ以外のsurfaceも含むため、写真だけの提示欠落率へ集計しない。トレースには5件のhitchがあり、プロファイラ自体の負荷も含む。現在の表示モード・写真・ネットワーク条件を固定した前後比較ではないので、普段の発生頻度や修正後の改善率には換算しない。それでも同時刻のCPUスタックと更新の空白が一致するため、計画作成と初回画像準備が実運転の更新を止めていた証拠として扱える。

## 再現と証跡

[計測ハーネスの手順](../Benchmarks/README.md#同期再生の更新間隔の比較)を参照。

```sh
python3 macos/scripts/frame-pacing-benchmark.py build
python3 macos/scripts/frame-pacing-benchmark.py measure \
  --output artifacts/macos/sync-frame-pacing/comparison-new
```

今回のGit対象外の証跡:

- `artifacts/macos/sync-frame-pacing/comparison-20261020/`：各回の生データ6件、ログ、summary、ソース・ハーネス・バイナリのSHA-256とビルド条件。
- `artifacts/macos/sync-frame-pacing/harness/`：実行ファイル、ビルドログ。
- `artifacts/macos/sync-frame-pacing/investigation/live-sample.txt`：稼働build 16の呼び出しスタック。
- 同ディレクトリの `live-animation.trace`、`live-updates.xml`、`live-animation-cpu.xml`、`live-potential-hangs.xml`：同時刻を照合した実運転トレースとXML。`live-updates-summary.json`、`live-hang-categories.json`、`live-hang-stacks-summary.json`に集計を保存。トレースには端末・プロセス情報が含まれるためGit対象外。

製品コードの追加変更はなく、このブランチのdisplay link修正を検証した。直前の引き継ぎでSwift単体206件 / 31 suites、共通fixture・色・Zoom構図、ネットワーク26件 / 241 assertions、arm64 Releaseが成功済み。今回追加した計測プログラムも同じ製品ソースでReleaseコンパイルが成功し、全6回を完走した。

次の修正対象は、次計画作成時の全写真の参照表・ID生成をメインスレッドから外す、または安全に再利用してメインスレッドの占有を短くすること。計画取消・写真metadata更新・Gallery継続・モード履歴の寿命を維持する。画像の初回表示時の色変換・コピー・不透明判定も別に検証する。その後、候補を実際のMac↔Windows同期条件で動かした際の滑らかさと、計画切替・通信・複数画面・スリープ復帰を確認する。

# 描画負荷の実測 — 2026-10-19

Issue #1 / PR #3。ローカルの背景生成削減には効果が見られた。一方、現在稼働しているbuild 14は同期表示の経路でCPUを使っており、PR #3のローカル背景変更だけで現在の負荷を解消するとは判断できない。次の調査・修正対象は、同期出力の無条件再描画と画面更新処理。

## 環境と測定範囲

Mac mini / Apple M1（CPU 8コア、GPU 8コア）、16GB、macOS 27.0.1 (26A434)、1920×1080の1画面。Xcode 27.1 (27A9275)。稼働中アプリは`/Applications/DynamicPhotoWall.app`の1.1.0 build 14、PID 44753。通常アプリの置換・再起動・設定変更・ネットワーク操作はしていない。

稼働中プロセスへのread-only採取と、合成画像を表示する独立した計測用ウィンドウを使用した。測定用ウィンドウは各回の終了時に閉じ、個人写真/設定/ログイン項目を使用しない。操作画面のスクリーンショットは採取していない。

比較元は`7a711db`、比較先は`a091a6b`。`-O -whole-module-optimization`、arm64、同一ハーネスを使用した。ハーネスSHA-256は両版とも`505f4c88191868058084d8bb82dafb89f1d88fa2cac4ad8083dac96d201cbe1c`。詳細は[ハーネスの説明](../Benchmarks/README.md)。

## 稼働中build 14の測定

| 項目 | 結果 |
|---|---|
| プロセス平均CPU | 35.07%（累積CPU 10.67秒 / wall 30.425秒、1コアで100%） |
| 1秒区間のCPU最大 | 54.29%（30区間中の最大。瞬間最大ではない） |
| RSS範囲 | 130.36〜146.61MiB |
| `sample`時のphysical footprint | 466.5M。RSSとは異なる計器で、直接比較しない |
| Time Profiler | 20秒指定、対象PIDのCPUサンプル重み合計7.078秒 |
| Metal System Trace | trace 16.031秒、対象PIDのGPU Active区間のunion 1.376秒 |
| GPUチャネル別Active区間union | Vertex 0.178秒、Fragment 1.338秒、Compute 0.00042秒。重なりがあるため合計しない |

Time Profilerのinclusive重み:

| スタック分類 | CPUサンプル重み |
|---|---:|
| Core Animation transaction/commit | 1.889秒 |
| Metal関連のCPU呼出し | 2.153秒 |
| `PNPlayback.render` | 0.601秒 |
| `PNSceneView.draw` | 0.454秒 |
| Window ordering関連 | 0.192秒 |
| `AmbientProcessor` | 0秒（この採取区間ではサンプルなし） |

分類は重複するため合計しない。GPU Active区間時間はGPU演算器使用率やワット数ではない。稼働アプリのモード・写真は固定しておらず、この値は現在の運転状態の観察。CPUとGPUの採取時刻も異なる。

スタックには`PNPlayback.startTimer` → `render`と、Core Animation backing store/Metalへの処理が現れていた。描画はすでにOSのGPU経路も利用している。今回の採取ではローカル背景のぼかしを主な負荷源とする証拠は得られなかった。同期側の画面更新頻度とcompositing/転送を先に調べる根拠になる。

## 同一fixtureによる前後比較

準備5秒＋計測10秒/回。ローカル/同期の静止Galleryは各3回、AB→BA→ABの順。背景OFFは初回値のばらつきから追加3回比較し、それ以外は各1回の探索測定。Panは40px/s、Zoomは120秒で、低速に動き続けるfixture条件。製品既定値（120px/s、30秒）での改善率を示す測定ではない。CPUはプロセスのuser＋system CPU秒/wall秒。背景生成回数と描画関数の回数は準備期間を除外する。

| 条件 | 回数/版 | CPU 変更前 → PR版 | 背景生成/10秒 変更前 → PR版 | 描画/10秒 変更前 → PR版 |
|---|---:|---:|---|---|
| ローカル 静止Gallery | 3 | 22.28% → 12.05% | 80 → 0 | 0 → 0 |
| 同期 静止Gallery | 3 | 5.65% → 5.49% | 0 → 0 | 561〜563 → 559〜562 |
| ローカル 静止Gallery・背景OFF（追加比較） | 3 | 11.29% → 10.24% | 0 → 0 | 0 → 0 |
| ローカル 一時停止 | 1 | 0.97% → 1.20% | 0 → 0 | 0 → 0 |
| ローカル Vertical Pan | 1 | 17.72% → 12.64% | 80 → 67 | 0 → 0 |
| ローカル Zoom | 1 | 14.74% → 10.55% | 80 → 6 | 0 → 0 |
| ローカル Scrolling Gallery | 1 | 25.53% → 25.68% | 80 → 80 | 0 → 0 |
| 同期 elapsed固定（一時停止相当） | 1 | 5.60% → 5.05% | 0 → 0 | 559 → 583 |

静止GalleryのCPU範囲は、変更前21.36〜23.89%、PR版10.92〜14.00%。平均差は約10.23ポイント。同期静止Galleryは変更前5.18〜6.26%、PR版4.97〜6.00%で、今回の変更による差を主張しない。

背景OFFは初回1回が8.19%→9.55%、追加3回は変更前10.86〜11.66%、PR版9.27〜10.75%と、初回の方向が逆転した。小さい差の優劣を断定せず、生データを両方残す。

`local-gallery`の背景生成は準備期間に初回を完了しており、測定区間の0回は起動時にも生成しないという意味ではない。既存単体回帰の「起動を含む仮想60秒で1回」と整合する。NSViewの描画0回でもSwiftUI/タイムラインとcompositorの仕事は残る。

`pn-*`は現行の`PNWindowSurface.present`と同じ16ms周期の`layers`/`needsDisplay`更新で、本体の`PNSceneView`を描く。静止やelapsed固定の一時停止でも再描画が続く。PNPlaybackの通信・復旧・画面検出・window ordering全体はハーネスに含めていない。

960×540ptの独立ウィンドウで1920×1080の仮想viewportを縮小表示しており、稼働中の全画面・実写真・共有計画と条件は違う。稼働中の通常アプリと他アプリも継続している。短時間の比較と小標本なので、改善率を本番へ外挿しない。動作モード等の1回測定は確定的な優劣判定に使わない。

描画関数p50/p95、driver起床間隔p50/p95、プロセス生涯最大RSSも生データへ保存した。driver起床間隔や描画関数の時間は、実ディスプレイへ提示されたフレーム時間・欠落率ではない。

## 計測できていない項目

- 電力: Power Profilerはこの環境で「macOS非対応」と終了。`sudo -n powermetrics`はpasswordが必要で実行不可。CPU低下から消費電力の改善値を推定しない。
- 実ディスプレイへの提示フレーム時間、知覚上の滑らかさ、カーソル停止、色管理の見え方。
- 複数の実画面、異なるDPI、実Windows端末との同期、長時間運転での前後比較。
- software Core ImageとMetal-backed Core Imageの同一パイプライン比較。

## 次に対応する箇所

1. `PNWindowSurface.present`で、時刻が進んでも実際の構図が同じなら`needsDisplay`を要求しない。表示写真/座標/倍率/不透明度/背景の補間/画面サイズが変わる時には確実に更新し、最初のdraw完了を待つ契約を維持する。
2. `orderFrontRegardless`と画面検出を毎16msで繰り返す必要性を切り分ける。preview、スリープ、Spaces、画面再接続時に表示を失わないイベント設計を先に定める。
3. 同期のcommit/control/計画境界/復旧とローカルの交換・画像準備に必要な期限を保ち、静止中の描画時計を休ませる。単に16msタスクを止める変更にはしない。
4. Zoomでの再描画が多ければ、画像の不変contentsを保持してCore Animationのtransformへ寄せる案を同じfixtureで比較する。背景のCore ImageをMetalへ替える判断は別に計測する。

## 証跡と再現

生データはGit対象外の`artifacts/macos/rendering-performance/`に保持する。

- `live-cpu.csv` / `live-summary.json`: 30秒の累積CPU/RSS。
- `live-sample.txt`、`live-cpu.trace` / `live-time-profile.xml`: スタック。
- `live-gpu.trace` / `live-gpu-intervals.xml` / `live-analysis.json`: CPU/GPU区間解析。
- `live-power-command.log` / `live-powermetrics-command.log`: 電力計測の制約。
- `comparison/*.json` / `comparison/summary.json` / `comparison-run.log`: fixture比較。
- `comparison-off/*.json` / `comparison-off/summary.json`: 背景OFFの追加3回比較。
- `baseline/` / `candidate/`: refごとのstagingソース、計測カウンターを加えたRelease CLI、ビルドログとハーネスhash。

[ビルド・実行・解析コマンド](../Benchmarks/README.md)で再現できる。製品ソースはこの計測で変更していない。PR #3は実画面・同期描画の受け入れが残るためDraftとし、Issue #1は継続する。

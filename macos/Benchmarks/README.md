# 描画計測用ハーネス

ユーザーが実描画の計測実行を明示した場合に使用する。合成グラデーションと独立した960×540ptのウィンドウで、物理1920×1080pxの仮想viewportを表示する。通常アプリのエントリーポイント、設定、写真、ネットワーク接続、ログイン項目、単一起動ロックを使用しない。ウィンドウは測定ごとに閉じる。計測中に他のビルド/テスト/トレースを並行実行しない。

## ビルド

リポジトリのルートから:

```sh
python3 macos/scripts/rendering-benchmark.py --ref 7a711db --name baseline
python3 macos/scripts/rendering-benchmark.py --ref a091a6b --name candidate
```

生成先は`artifacts/macos/rendering-performance/{baseline,candidate}/`。`git archive`で指定refのアプリソースをstagingへ展開し、同じ`RenderingBenchmark.swift`をコピーしてRelease最適化でCLIへコンパイルする。`WORKTREE`も指定可能だが、固定commit同士の比較を推奨する。ソースへ加える計測処理は、描画関数の回数/所要時間と、背景生成の正常公開回数のカウンターだけ。計測処理はstaging内に限り、製品ソースを書き換えない。

`build-metadata.json`に比較ref、コンパイル条件、ハーネスのSHA-256を保存する。runnerは両バイナリのハーネスが同一であることを確認する。Swiftマクロのsandbox制約がある環境では、ビルドに通常権限が必要になる。

## 実行

```sh
python3 macos/scripts/measure-rendering.py
```

既定は準備5秒＋測定10秒。ローカル/同期の静止Galleryは3回、順番をAB→BA→ABと入れ替える。それ以外は各1回の探索測定。出力は`artifacts/macos/rendering-performance/comparison/`へ保存する。時間を延ばす場合:

```sh
python3 macos/scripts/measure-rendering.py --seconds 60 --warmup 10 --gallery-repeats 3 \
  --output artifacts/macos/rendering-performance/comparison-60s
```

`local-*`は本体の`DesktopWallView`、`WallPlaybackController`、`WallSceneLayer`と背景samplerを使用。`pn-*`は本体の`PNSceneView`とprepared frameを使い、16ms周期でlayersを更新する。旧ソースは毎回`needsDisplay`を要求し、保持レイヤー対応版は初回だけ描画して以降はレイヤーの座標・不透明度を更新する。同期fixtureは4枚表示＋将来用60 placementと固定背景1枚を持つ。`pn-ambient`は余白を残し、異なる背景2枚を120秒で補間する。背景は20行単位の帯で塗った独立グラデーションで、本番の写真由来の余白延長/blurを通していない。写真との縦境界や帯状の段差は合成素材の作り方に起因し、この表示を本番の見え方の判定に使わない。PNPlayback全体、通信、共有計画の生成、実際のデスクトップウィンドウのorderingはこの同期fixtureに含まれない。

同期描画変更の比較は、同じ現在のハーネスで両版をビルドして実行する:

```sh
python3 macos/scripts/rendering-benchmark.py --ref 378ec0c --name baseline-sync
python3 macos/scripts/rendering-benchmark.py --ref b491a68 --name candidate-sync-final
python3 macos/scripts/measure-rendering.py --baseline-name baseline-sync --candidate-name candidate-sync-final \
  --scenarios pn-gallery pn-ambient pn-paused pn-zoom --repeats 3 \
  --output artifacts/macos/rendering-performance/comparison-sync-final
```

保持レイヤー版は`DPW_LAYER_COMPOSITOR`を付けてビルドする。`pn-bitmap-gallery` / `pn-bitmap-ambient`では保持版ソースの従来描画fallbackも比較できる。通常の製品は保持レイヤーを使用する。

一時停止はローカルではplayback clockを止め、同期fixtureではelapsedを固定する。背景OFFはローカルGalleryのみ。Panの速度40px/s、Zoom120秒を指定し、測定中に動きが終わらないようにする。これらは製品の既定値を変更する操作ではない。

平均CPUはプロセスの`getrusage(RUSAGE_SELF)`によるuser＋system CPU秒を測定wall秒で割る（1コア使用で100%）。`max_rss_mib`は起動・準備も含むプロセス生涯の最大RSSであり、定常メモリー/physical footprintではない。`draw_ms_p95`は描画関数の実行時間、`driver_interval_ms_p95`は測定driverの起床間隔。いずれも実ディスプレイに提示されたフレーム時間や欠落率ではない。画面キャプチャを行わず、見え方の受け入れを自動判定しない。

本番の全画面/複数画面/写真/同期状態とは条件が異なるため、このCPU値を稼働中アプリの改善率へ直接置き換えない。同じMac上の他アプリの稼働、熱状態、GPU競合の影響もある。比較の生データとばらつきを併記する。

## 稼働アプリのトレース解析

Time Profiler/Metal System Traceの採取は[描画負荷の監査](../docs/RENDERING-PERFORMANCE.md)を参照。`xctrace export`から`time-profile`と`metal-gpu-intervals`表をXMLへ出し、次のように集計できる。

```sh
python3 macos/scripts/analyze-rendering-trace.py --pid 44753 \
  --cpu artifacts/macos/rendering-performance/live-time-profile.xml \
  --gpu artifacts/macos/rendering-performance/live-gpu-intervals.xml \
  --gpu-toc artifacts/macos/rendering-performance/live-gpu-toc.xml \
  > artifacts/macos/rendering-performance/live-analysis.json
```

PIDは実際の測定対象へ置き換える。CPUのinclusiveカテゴリは重複し、合計して100%にはできない。GPUは対象PIDのActive区間を結合して、入れ子のencoder/command bufferや重なるチャネルを二重計上しない。GPU区間時間はGPU演算器の使用率や消費電力とは異なる。生トレースには端末名・パスなどが入るためGitへ含めない。

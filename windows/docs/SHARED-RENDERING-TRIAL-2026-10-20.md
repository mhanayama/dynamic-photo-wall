# Issue #2: DX12移行前の4項目の置き換え

対象はWindowsのオンライン共有再生。WPF・共有計画・時計・通信を維持し、2026-10-20の[追加監査](RENDERER-AUDIT-2026-10-20.md)で挙げた4項目を実装した。ローカルのstoryboard再生やShell接続方式は維持する。

## 変更内容

1. 各画面への`VisualBrush`を、`SharedDrawingPresenter.OnRender`からの`DrawDrawing`に置き換える。写真・背景は保持したDrawing命令を参照し、元のUIツリーを接続したcropは共有再生中にCollapsedにする。画面ごとのクリップ、壁座標のずれ、独立画面の同一座標、前後シーンのfadeと継続時の出力要素を保つ。WPF内部の中間面・GPU pass数は未測定で、ブラシを除去したことだけを速度向上の証明にはしない。
2. 同じ寸法の凍結済み不透明な背景は、低解像度のまま補間と暗色overlayをまとめ、1枚のWriteableBitmapを描く。進行率は1/1024単位で丸め、変化時だけ書き込む。同一画像は書き込まない。半透明または寸法が異なる背景は、拡大後のsource-overとの違いを避けるため従来の合成順をDrawingで維持する。DX12やcustom shaderは追加していない。
3. 写真のデコード幅をplacementの最大幅・高さ・scaleと出力の物理サイズから求め、原画像・既存のキャッシュ予算・4096幅上限で制限する。現在のグループに同じassetと適切な大きさのbitmapがあればモード間でも再利用する。ready前の準備は維持し、将来の写真も計画分を準備する。EXIFで縦横が入れ替わるWebPの縮小率も表示後の幅を基準に訂正した。
4. 写真ごとに次の表示／動作／fade境界を記録し、非表示や静止区間の評価を省く。動作中は毎フレーム評価し、戻るseekでは再評価する。共通`SceneEvaluation`に割当なしのout引数版を追加し、計算式は既存APIと共用する。同じプロパティ値の再設定も省く。終端直前に始まった最終写真は、幾何の時刻が終端で止まった後もfadeを完了させる。Renderingの購読・control／commitのスケジュールは維持する。

## 検証

Releaseビルドは警告・エラー0。Windows単体51ケース、共有ネットワーク26ケース／241 assertionsが成功。GUI操作は行っていない。出力全体と各画面のcropには同じ新経路を使い、全5モードの実planner、Gallery継続・分断時の終端保持を既存回帰で確認した。

新規のoffscreen比較はスパン／画面別、5モード指定、透明／不透明、角丸・移動・scale・fade・境界・終端・巻き戻しの680出力で旧表示との差が最大2/255。表示を一度描いた同じpresenterが後のDrawing変更・計画継続を反映し、出力要素を交換しないことも確認した。デコード幅は最大Zoom、物理出力倍率、キャッシュ上限、原画像寸法で照合し、PNG／WebPの全8方向で指定した表示幅になることを確認した。

## CLIでの仕事量比較

同じバイナリに保持した旧経路と新経路を比較する。100 placementのうち表示中は1件、残り99件は後で表示する条件。60更新の準備後、仮想10秒に相当する600回のPresentを実行し、旧→新／新→旧／旧→新の3試行を行った。背景は256×96。以下はPresent呼出し区間のwall timeの平均で、GPU処理・layout・提示フレームや通常アプリのCPU使用率ではない。

| 前景／背景 | 写真評価 旧→新 / 600更新 | 呼出し時間 旧→新（ms） | このスレッドのmanaged割当 旧→新（bytes） |
|---|---:|---:|---:|
| 静止／同一 | 60,000 → 0 | 34.39 → 0.87 | 10,094,440 → 40 |
| 動作／同一 | 60,000 → 600 | 57.04 → 1.79 | 10,094,440 → 57,640 |
| 静止／変化 | 60,000 → 0 | 26.38 → 22.74 | 10,152,040 → 68,584 |
| 動作／変化 | 60,000 → 600 | 54.40 → 24.14 | 10,152,040 → 126,184 |

変化する背景の新経路は、この条件で171回、計16,809,984 bytesをWritePixelsへ渡した。これはCPU側の書き込み量で、実際のGPU転送量の測定値ではない。背景が変化するときは小画像の合成・書き込みという新たなCPU処理が加わるため、通常運転でCPUとGPUの両方を確認する。各表示面の大きさやサンプル間隔で結果は変わる。

実行例:

```powershell
.\.tools\dotnet\dotnet.exe build windows/tests/DynamicPhotoWall.Tests/DynamicPhotoWall.Tests.csproj -c Release
.\.tools\dotnet\dotnet.exe windows/tests/DynamicPhotoWall.Tests/bin/Release/net10.0-windows10.0.19041.0/DynamicPhotoWall.Tests.dll artifacts/windows/rendering-four/targeted --scan-only --shared-rendering --shared-render-benchmark
```

結果は`artifacts/windows/rendering-four/`。`full/`、`network-core/`、`parity/`、`benchmark/shared-rendering-benchmark.json`、`benchmark-summary.json`とログ、計測DLLの`measured-assemblies.json`を保持する。

## 実機比較

変更前の稼働中`d563da0`（PID 43588）を追加で90サンプル観測し、GPU平均18.67%／p95 22.97%／最大23.68%、CPU平均1.46%を記録した。保存設定・GUIは変更していない。生データは`artifacts/windows/gpu-audit/20261020-084944/`。この区間の計測が終わってからビルド・テストを実行した。

候補版の実機GPU値は手動再起動後に測定する。通常再生の異なるシーン同士の比較から因果を確定せず、必要に応じて固定計画・解像度・提示頻度による比較へ進める。電力・GPU時間・フレーム提示間隔は未測定。PR #6はドラフト、Issue #2はopenとする。

候補`799d570`のRelease EXE・ZIP・SHA256SUMSを`release/windows/win-x64/`へ配置済み。製品バージョン、依存読み込み診断、ZIP内容・EXEハッシュ、作業ツリーclean、ルート生成物なしを確認した。配布検証は`artifacts/windows/rendering-four/release-update/20261020-090532/`へ保存。稼働中の旧PID 43588は保持し、適用はユーザーの手動再起動で行う。この段落を含む後続の記録用コミットはドキュメントのみで、配布バイナリは`799d570`。

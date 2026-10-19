# Windowsの背景生成と描画負荷 — Issue #2

## 変更した動作

ローカル表示の背景生成を、常時125ms周期から、前景の変更と実際の動作に応じた更新へ変更した。不変の静止Galleryでは初回生成後にタイマーも停止する。写真交換・再配置・Pan／Zoom・Scrolling Galleryの開始と終了は、既存の`TransitionController`が発行する通知で追跡する。シーン全体のフェードと背景自身の補間は、前景の生成要求に含めない。

動作中だけ最大8Hzで前景の幾何・画像参照・不透明度・clipを調べる。最大辺160pxの背景に対する約0.5pxの幾何変化と1/64の不透明度を区切りとし、同じ区画に留まる動きではbitmapの取得とぼかしを省く。開始・終了・明示的変更はこの判定を迂回し、正しい端点を取得する。時刻は既存の`AnimationScheduler`を使用する。短い動作の終了後や顔停止の保持区間では生成を続けない。

色追従を背景の生成から分離した。従来の0.8秒応答を、保持する2枚の画像とWPFの`ExponentialEase`による不透明度補間へ移した。5秒で最終色に収束させ、途中で新しい目標が来た場合は、その時点の表示色からつなぐ。タイマーで新しいbitmapを作らなくても色の補間は完了する。量子化前の最終色、透明な余白の延長、SkiaSharpのblur/clamp、彩度・明るさ補正は従来の処理を維持する。動作途中の出力が旧方式と全画素一致するという変更ではなく、応答を表示側へ移したものなので、実画面の知覚確認は別に行う。

pauseではタイマーと新規生成を止め、処理中の世代を無効にする。resumeは最新の構図を取り直す。変更が処理中に重なった場合は旧結果を公開せず、変更通知をまとめて最新の要求を処理する。破棄時は処理を取り消し、時計・アニメーションの購読も解除する。Gallery交換の終了・取消時に行う最終配置と子要素の確定も、通知をdispatcherへキューしてから取得する。

新しい前景の変更経路を追加する場合は、既存の`TransitionController`を通すか、その面の`GlassBackground.Invalidate()`を呼ぶ。直接プロパティを書き換えるだけで静止中の背景が再生成されるという前提にはしない。

## 既存描画とGPUの監査

| 経路 | 確認内容と今回の判断 |
|---|---|
| 背景の取得 | `VisualBrush` → `RenderTargetBitmap.Render` → `CopyPixels`。Microsoftの説明でもRenderTargetBitmapはソフトウェア描画の対象。取得回数を先に削減する |
| 背景の処理 | 最大辺160pxのpremultiplied BGRAをCPU側SkiaSharpでblurし、余白延長と色補正を行う。GPUへ移しても転送・読戻し・色補正の費用が残るため、今回の測定だけで置換はしない |
| 前景 | WPFの`TranslateTransform`／`ScaleTransform`とStoryboardを維持。顔保護、EXIF、角丸、スパンcrop、モード別画面表示を作り直さない |
| 表示側 | 固定した`DrawingImage`と保持画像の不透明度をWPFで補間する。Tier 2／Defaultを記録できても、各処理が実際にGPUで動いた証明やGPU時間の測定とは扱わない |
| 写真の読み込み | `ImageCache`はファイル更新時刻・寸法等を含むキー、256MiBのLRU予算、縮小decode、freeze済みbitmapを使用。背景更新ごとに原写真をdecodeする経路ではないため変更しない |
| 同期表示 | `WindowsAmbientBuilder`は事前に背景PNGを作り、`AmbientFrameVisual`で保持画像の不透明度を補間する。今回のローカルsamplerを使わない。PNG・wire時刻・共通時計・受信色補正は変更しない |

DirectX 12の全面描画は採用していない。小さな背景のGPU化だけで低負荷になるとは仮定せず、まず不要な取得・処理・割当を除く。次の検討ではWPF／CompositionとGPU処理の転送を含む全経路を測り、色管理・補間・余白・CPU／GPU・電力・メモリーを同条件で比較する。

根拠: [Microsoftの描画Tierとソフトウェア描画対象](https://learn.microsoft.com/en-us/dotnet/desktop/wpf/advanced/graphics-rendering-tiers)、[2D画像の性能指針](https://learn.microsoft.com/en-us/dotnet/desktop/wpf/advanced/optimizing-performance-2d-graphics-and-imaging)、[Easing Functions](https://learn.microsoft.com/en-us/dotnet/desktop/wpf/graphics-multimedia/easing-functions)。

## GUIなしの検証・再現手順

リポジトリ直下から実行する。ローカルSDKがない場合は`.tools/dotnet/dotnet.exe`を`dotnet`へ読み替える。

```powershell
.\.tools\dotnet\dotnet.exe build windows/tests/DynamicPhotoWall.Tests/DynamicPhotoWall.Tests.csproj -c Release --no-restore
.\.tools\dotnet\dotnet.exe windows/tests/DynamicPhotoWall.Tests/bin/Release/net10.0-windows10.0.19041.0/DynamicPhotoWall.Tests.dll artifacts/windows/issue-2/scheduling --scan-only --ambient-scheduling --ambient-transitions
.\windows\scripts\Measure-Ambient.ps1 -Seconds 4 -Repetitions 3 -NoBuild
```

`Measure-Ambient.ps1`はウィンドウを開かない合成fixtureを別プロセスで実行する。640×360の面に32×32の合成画像を拡大し、160×90の背景を取得する。1秒のwarm-up後、指定秒数の処理だけを測る。旧方式／新方式の順序をAB→BA→ABと入れ替える。静止、合成写真の差し替え、縦横Pan、Zoom、スクロール相当の移動、pause、2面、背景OFFの条件を分ける。

旧方式は`GlassBackground`の診断専用`continuousReference`で保持した125ms取得・CPU色フィルター・125ms線形fade。新旧とも共通の破棄・pause処理とレイアウト確定処理を使用する。同じバイナリ内の処理経路比較であり、過去の配布EXEとの全体比較ではない。背景OFFはsamplerを開始しない対照条件。写真差し替えは単一画像の交換であり、実Galleryの再配置は回帰テストで別途確認する。

結果は`artifacts/windows/issue-2/measurements/<日時>/`へ保存する。`environment.json`、各実行の`ambient-benchmark.json`とログ、全試行の`results.json`、集計`summary.json`を残す。CIMからハードウェア情報を取得できない場合も、取得不可の理由を記録して計測を続ける。CPUは`Process.TotalProcessorTime / wall time × 100`で、1論理コアを100%とする。タスクマネージャーの全コア正規化表示と同じ値ではない。最大working setはプロセス生涯の最大値で、測定区間の増分や保持テクスチャだけの使用量ではない。

回帰は以下を確認する。

- 静止時の生成・幾何poll・タイマーの停止。旧経路との初回画像の全画素一致、余白の不透明度と色補正。
- 縦横Pan／Zoom／scrollの動作中更新、0.5px未満の変化の蓄積、端点の取得、pause／resume。
- 連続変更のcoalesce、古い世代の非公開、生成途中のpause・取消・破棄、購読解除。
- 実際の`PhotoRenderer`のGallery交換・再配置・取消、画面別の更新分離、scrollの最終構造、シーン交代とclear。
- 色補間中の再目標化、WPFのeasingとCPU側の表示色計算の一致、同期背景の固定画像と不透明度補間。

## 2026-10-19の測定・回帰結果

Windows 11 x64（10.0.26300）、SDK 10.0.401、runtime 10.0.12、16論理コア、`AMD64 Family 25 Model 33 Stepping 2, AuthenticAMD`。WPFの記録値はTier 2／`ProcessRenderMode.Default`。CIMによるCPU名・GPU名／driver取得は制限環境で拒否され、推測で補っていない。

測定ディレクトリは`artifacts/windows/issue-2/measurements/20261019-231258/`。各条件はwarm-up 1秒＋測定4秒、各経路3回。次の値は3回の平均。2面は独立した同じ合成面を2つ動かす条件で、2台の実ディスプレイではない。

| 条件 | 取得回数 旧→新 / 4秒 | CPU 旧→新（1コア基準%） | managed割当 旧→新 / 4秒（MiB） |
|---|---:|---:|---:|
| 静止1面 | 32.00 → 0 | 24.74 → 0.26 | 6.12 → 0 |
| 写真1回差し替え | 32.33 → 1 | 24.82 → 9.47 | 6.19 → 0.31 |
| Horizontal Pan | 32.33 → 32.00 | 25.00 → 25.78 | 6.21 → 4.42 |
| Vertical Pan | 32.33 → 32.00 | 24.61 → 25.65 | 6.23 → 4.43 |
| Zoom | 32.00 → 32.00 | 25.78 → 26.17 | 6.20 → 4.48 |
| scroll相当の移動 | 32.00 → 31.67 | 24.61 → 24.08 | 6.17 → 4.37 |
| pause | 0 → 0 | 4.30 → 4.17 | 0.23 → 0.23 |
| 静止2面 | 63.67 → 0 | 31.77 → 0.13 | 11.90 → 0 |
| 背景OFFの対照 | 0 | 0.00 | 0 |

静止1面の取得時間＋worker処理時間は旧約64.22ms/4秒から新0ms、静止2面では旧約124.65msから新0ms。測定区間では初回生成を含まない。プロセス生涯最大working setの3回中最大は、静止1面85.61→65.87MiB、静止2面91.01→65.73MiB。Pan／Zoom／scrollは旧86.09〜86.36MiB、新84.52〜84.69MiB。この値は特定処理だけの常駐メモリー量ではない。

静止時と差し替え時の不要な仕事の削減はこの条件で確認できた。一方、動作中のCPUは同程度で、一部の平均は微増している。たとえばHorizontal Panの各試行は旧24.21〜25.78%、新23.83〜28.90%で、短い計測のばらつきもある。動作中のCPU改善や性能後退がないことを、この結果だけで断定しない。処理時間とmanaged割当は減っているが、表示側を含む残りのCPU、GPU・電力・フレームの確認は引き続き必要。pauseでも既存のWPF等の活動は残り、生成0回をアプリ全体のCPUゼロとは扱わない。

計測元は`86cd41f`に今回の未コミット差分を適用したビルド。`environment.json`に作業状態、`measured-assemblies.json`に計測時のDLLのSHA-256、`measured-production-sources.json`に製品コード5ファイルのSHA-256を記録し、計測後の製品ソースが一致することも確認した。今後のスクリプト実行ではDLLのハッシュも`environment.json`へ含める。

Releaseビルドは警告・エラー0。GUIを使わないWindows単体47ケース、ネットワーク26ケース／241 assertions（相互TLS・3ピア転送と復旧を含む）、従来fixture704 assertions、差分fixture472 assertions、Zoom構図5120 assertions、背景色12ケースが成功した。結果は`artifacts/windows/issue-2/full/`、`network-core/`と`build.log`へ保存。共通fixtureは既存のCLI verifierで照合し、共有Core・通信・色補正の実装は変更していない。PowerShellの構文確認も実施した。

## 2026-10-20のRelease起動・長時間表示の確認

ユーザーの依頼で`ca71363`のRelease単一EXE・ZIP・チェックサムを更新した。発行EXEの製品バージョンが同コミットを含むこと、ZIP内EXEとのハッシュ一致、依存読み込み診断を確認。旧配布物は`artifacts/windows/issue-2/release-update/20261019-232435/previous-release/`へ退避した。ユーザーが2026-10-19 23:25に起動し、起動直後に「今のところ問題なし」、翌日に「6時間ぐらい動かしてるけど違和感ない」と報告した。これはユーザーによる知覚確認であり、自動GUI試験ではない。

2026-10-20 07:50の読み取り専用確認でも同じPID 31496と`ca71363`の稼働を確認し、プロセス起動から約8.42時間だった。観測時の保存設定はオンラインモード・静止Gallery・背景ON。そのため、この報告はオンライン表示の連続稼働確認として扱い、今回変更したローカル`GlassBackground`の全モード・全画面条件の実機検証やCPU改善の証明にはしない。起動直後の30秒CPU観測も制御した旧／新比較ではない。

表示上の違和感は報告されていない一方、起動後の標準ログには共有計画検証の`Invalid ambient frame`による再試行が11件あった（2026-10-19 23:55:55〜2026-10-20 06:17:26）。このPRで変更していない`SharedScenePlan.Validate`／`SceneCoordinator.PumpAsync`の経路であり、ログだけでは時刻・PNGサイズなどのどの条件が原因か、表示への影響や今回の変更との因果は確定しない。無エラーの長時間試験とは扱わず、追跡事項として残す。通常設定や再生は操作していない。

## 2026-10-20の共有背景フレーム再試行の原因調査

`WindowsAmbientBuilder`のサンプル時刻が`duration * index / (count - 1)`で計算されていた。最終サンプルでいったん乗算してから除算すると、浮動小数点の丸めによって`duration`を1 ULP超えることがある。`SharedScenePlan.Validate`は`frame.At <= Duration`を厳密に検証するため、正常な予定の生成中に`Invalid ambient frame`となり、coordinatorがその候補を準備・commitする前に再試行へ戻る。

GUIなしの旧実装テストで、終了100.42374576461677秒に対して最終時刻100.42374576461678秒、差1.4210854715202004E-14秒、PNG 298 bytesで、実ログと同じ例外・検証箇所を再現した。さらに、運用時と同じ交換間隔5〜10秒・fade 1.2秒で、`GalleryTimeline`の256 seed中4つに同じ問題が起こる終了時刻があった。実際に生成された例は終了89.39626196492289秒に対し旧計算89.3962619649229秒。交換途中を避けて計画を区切るため、小数の終了時刻は通常運転でも発生する。

時刻は`(double)index / (count - 1) * duration`へ変更し、先に0〜1の比率を作る。最終サンプルでは比率が正確に1となり、時刻が終了値と一致する。Macの`PeerPlayback.swift`は既にこの順序であり、Swift側を変更する必要はない。タイムラインの長さ・交換予定・PNG容量制限・通信契約は変更しない。検証の許容誤差を広げる対応も行わない。

新規回帰は24／21／16サンプルになる1／3／4面と、小数・整数の終了値、実Gallery由来の終了値で2,416枚を生成し、各面の始点0・終点の完全一致・順序・JSON往復を検証した。1 ULPでも終了を超える受信時刻、NaN、負の時刻、容量超過PNGは引き続き拒否する。Windows単体48ケース、共有ネットワーク26ケース／241 assertionsが成功。Releaseビルドは警告・エラー0。旧実装の失敗と修正後の結果は`artifacts/windows/ambient-frame-timing/`へ保存した。

今後の例外には`at`・`duration`の往復可能な精度の数値と`pngBytes`を含める。過去の11件にはこれらの値がなく、各件がこの条件だったことまでは遡って証明できない。修正版へ切り替えた後の通常運転で、同じ再試行が消えることを確認する。

## 実画面の受け入れと残件

合成fixtureの結果を通常アプリのCPU改善率へ外挿しない。実写真・全画面・独立グループ・混在DPI・複数実モニター、Mac↔Windowsの同期表示、電力、GPU／DWM負荷、p50／p95の提示フレーム時間は別の確認とする。既存の通常設定・ユーザー写真・稼働中プロセスを計測用に変更しない。GUI操作を伴う自動試験は明示依頼がある場合だけ行う。

後続の実機比較では、専用設定と同じ写真・画面配置・解像度・更新周波数を使い、Releaseの旧版と候補版を同時に動かさず各条件60秒以上を3回測る。背景ON/OFF、静止と交換／再配置、Pan／顔停止、Zoom、scroll、pause／resume、シーン交代を分け、生成回数と処理時間にCPU sample、GPU／DWM、電力、割当／RSS、提示フレームを対応させる。短い合成計測だけでGPUや電力、滑らかさの改善を宣言しない。

オンライン表示のユーザーによる長時間確認は記録済み。共有背景フレームの丸め誤差は再現・修正済みだが、修正版での再試行消失とローカル背景の実機確認が残るため、PRはドラフトを維持し、Issue #2を自動closeする指定は付けない。

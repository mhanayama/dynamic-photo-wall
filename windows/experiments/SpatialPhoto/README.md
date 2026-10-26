# Spatial Photo — Windows native trial

**実験終了:** ユーザー評価で実用不合格。追加のモデル研究・実装は進めない。[最終handover](../../../docs/SPATIAL-PHOTO-HANDOVER-2026-10-26.md)を参照。以下は再現用の記録。

人物の側面を生成し、元写真を可視面へ投影する[Alpha 2](PORTRAIT-ALPHA.md)を追加した。テスト用EXEは`release/windows/win-x64/portrait-alpha/PortraitAlpha.exe`。[設計](../../../docs/PORTRAIT-3D-PIPELINE.md)を参照。以下は別の旧視差ワープ試作の手順。

[Issue #13](https://github.com/mhanayama/dynamic-photo-wall/issues/13)のWindows先行試作。**普通の写真 → AI深度生成 → キャッシュ → Direct3D 12で視差付き再生**を試せる独立したWindowsアプリ。UIはWPF、描画はC++／Direct3D 12、推論はC#／ONNX Runtime DirectML。ブラウザー・Pythonは使わない。Mac／Metalは今後実装する。

単眼写真からの2.5D表現であり、左右眼別のステレオ出力や真の3D復元ではない。本体の通常スライドショーへの統合は後続とし、独立した生成物・キャッシュを使用する。

## D&D用テストEXE

現在の強度調整版は `release/windows/win-x64/spatial-photo-test/SpatialPhotoTest.exe`。EXEをダブルクリックし、画像をウィンドウへドロップすると生成して再生する。EXEアイコンへの画像ドロップによる起動も受け付ける。再生中のD3D12描画面へ直接ドロップでき、生成中は最後に受け付けた1枚を次に処理する。JPEG／PNG／WebPを1枚ずつ使用する。更新時は試作アプリを終了してから、同じEXEを置き換える。

モデルは隣の`models/`へ同梱し、.NETと必要なネイティブDLL・Visual C++ランタイムはEXEへまとめる。コンソールウィンドウを表示しない。移動時はモデルやライセンスを含めて`spatial-photo-test/`フォルダー全体をコピーする。通常のDPWとは別の実験用配布物であり、GitHub Releaseへの公開は行わない。

```powershell
# 配布用EXEを作成し、配布用EXE自身でGUIなし検証
.\windows\experiments\SpatialPhoto\Package.ps1 -Test
```

`Package.ps1`は`artifacts/windows/spatial-photo/package/`へstagingを置き、検証成功後に専用の配布フォルダーへコピーする。README・モデル・依存ライブラリのライセンス・SHA256を含む。モデルとキャッシュの既定パスはカレントディレクトリに依存しない。リポジトリ外へコピーした場合のキャッシュは`%LOCALAPPDATA%/DynamicPhotoWall.SpatialPhotoTest/cache/`。

## ビルドと起動

Windows x64、.NET 10 SDK、Visual Studio 2022のC++開発ツール、Windows SDK、CMake 3.24以降が必要。GPUはDirect3D 12対応。リポジトリ直下で:

```powershell
# 初回: 依存パッケージと約99MBのモデルを取得し、GUIなしで検証
.\windows\experiments\SpatialPhoto\Build.ps1 -DownloadModel -Test

# 手動で試作画面を起動
.\windows\experiments\SpatialPhoto\Start.ps1
# 写真を指定して起動することも可能
.\windows\experiments\SpatialPhoto\Start.ps1 -Photo 'C:\Pictures\sample.jpg'
```

開発ビルドは `artifacts/windows/spatial-photo/app/SpatialPhoto.exe`。`Start.ps1`は配布用EXEを優先し、なければ開発ビルドを起動する。モデルとキャッシュの絶対パスを渡す。本体の個人設定は使用しない。ビルド／パッケージの`-Test`はウィンドウを作らず、`Start.ps1`が手動確認用の画面を開く。

1. 画像をウィンドウへドロップするか、「写真を選択して深度生成」でJPEG／PNG／WebPを選ぶ。EXIFなしでも動作。EXIFがある場合は向きを補正する。
2. 処理中は元の静止画を表示し、生成完了後に視差再生へ切り替わる。同じ画像は次回からキャッシュを使用する。
3. 片道／往復、初期方向、片道の時間、視差の強さ（0〜100%）、深度反転を変更する。自動再生は設定変更時に先頭へ戻る。片道は終点で保持する。強さの既定は50%、片道の既定は10秒。
4. 「深度 / 写真を切り替え」で生成結果を確認する。「深度を再生成」はキャッシュを使わず再推論する。
5. 差が見づらい場合は「左端」「右端」を切り替えるか、手動視点スライダーを動かす。手動確認では自動再生を止め、同じクロップのまま視点だけを切り替える。「視点を手動で確認」をOFFにすると自動再生に戻る。「最初から再開」でも手動・一時停止を解除する。

実験機能でありGPU負荷・消費電力・温度・ファン動作が増える可能性がある。ゲームなどとの同時利用は推奨しない。加速器は自動（DirectML優先／失敗時CPU）、DirectML、CPUを選べる。選択は次の生成時に適用。キャッシュ読み込みでは再推論せず、ステータスにそのキャッシュを生成したバックエンドを表示する。

## CLIで深度生成

```powershell
& .\artifacts\windows\spatial-photo\app\SpatialPhoto.exe `
  --generate 'C:\Pictures\sample.jpg' `
  --model '.tools\models\depth-anything-v2-small\model.onnx' `
  --output 'artifacts\windows\spatial-photo\cache' `
  --backend auto
```

`--backend`は`auto`／`directml`／`cpu`。`--force`で再生成。元画像は変更せず、写真・深度を外部へ送信しない。オンライン接続は初回のNuGetとモデル取得だけ。

キャッシュは画像内容のSHA256、モデルのSHA256、前処理バージョンから決定する。各エントリーは向き補正／縮小済み`photo.png`、白が近い相対深度の`depth.png`、ハッシュ・バックエンド・推論時間等を持つ`manifest.json`。画像編集・モデル／前処理変更で別エントリーになり、キャッシュの破損もハッシュで検出する。保持期限・容量表示・削除UIは未実装。試作終了後に不要なエントリーを上記キャッシュディレクトリから手動削除できる。

## 検証と結果

```powershell
# 実GPUで描画するがウィンドウは作らない
& .\artifacts\windows\spatial-photo\app\SpatialPhoto.exe --test `
  --model '.tools\models\depth-anything-v2-small\model.onnx' `
  --output 'artifacts\windows\spatial-photo\verification'

# 自分の写真で生成→キャッシュ→実GPU描画まで確認
& .\artifacts\windows\spatial-photo\app\SpatialPhoto.exe --test `
  --photo 'C:\Pictures\sample.jpg' `
  --model '.tools\models\depth-anything-v2-small\model.onnx' `
  --output 'artifacts\windows\spatial-photo\photo-verification'
```

`--test`は片道／往復・強度上限、EXIFの8方向、前処理／正規化／キー、D&Dファイルの判定、ネイティブのCF_HDROP読込、EXE基準のモデルパス、EXIFなしPNGの画素一致、実際のHLSLコンパイル・D3D12転送・描画・読み戻し・リサイズを検証する。近景／遠景のマーカーが逆方向へ十分動くことを実GPUで画素単位に測り、ネイティブ側で強度が古い上限へ丸められていないことも確認する。さらにモデルがあれば深度生成、ディスクキャッシュの再読込、生成深度による描画結果の変化を確認する。モデルなしでは9ケース、ありでは10ケース。結果JSONと画像は明示した出力先へ保存する。`--warp`はD3D12のソフトウェア描画検証用で、推論バックエンドは切り替えない。

2026-10-26、Windows／AMD Radeon RX 7900 XTXで6/6成功。EXIFなしの合成画像と、ローカル実写真1枚で生成から描画まで成功した。実写真の向き補正後1366×2048px、DirectML優先、モデルのセッション作成を含む推論区間は**2.18秒**。読み込み・正規化・保存・再生時間を含む総時間や一般的な性能値ではない。キャッシュ再読込で深度が一致し、視点の左右で描画結果が変化することを確認した。

ログ: `artifacts/windows/spatial-photo/native-tests.txt`、結果: `real-photo-verification/results.json`。GPU検証はオフスクリーンであり、WPFの実ウィンドウ操作・長時間再生・人物など複数種類での視覚品質評価は未実施。GUI自動操作は明示依頼がある場合だけ行う。

同日のD&D対応後、配布用WinExeを一時ディレクトリをカレントにして`--test`で起動し、**9/9成功**。モデルパスを指定せず隣のモデルを読み込み、バンドルされたD3D12ライブラリで推論後の描画まで成功した。結果は`artifacts/windows/spatial-photo/package-verification/results.json`、パッケージのログは`package-dd.txt`。D&Dのデータ形式と入力判定はウィンドウを作らず検証したが、Explorerから実際にドラッグする操作は未実施。

同日の「最大30°でも差が見えにくい」というユーザーの実機確認を受け、角度表記を廃止し、強度の係数上限を0.018から0.24へ拡大した。強度調整版のCLI検証は10/10成功。256px幅の2層合成図形で、左右端間の各マーカーの移動量は強度50%で約35px、100%で81px。実写真での知覚品質を保証する測定ではなく、変位が小さすぎる実装へ戻らないための回帰検証。生成モデルと前処理は変えていないため、既存の深度キャッシュをそのまま使える。実GUIの操作は未実施。

## 実装の境界

- 画像の向きを補正し、長辺2048pxまで縮小して生成と表示へ同じ画像を渡す。入力のデコード上限は6400万画素。
- モデルのRGB／ImageNet正規化と518px・14の倍数へのリサイズ規則を使用する。SkiaのMitchellによるリサイズはPIL bicubicとの完全一致を主張しない。前処理バージョンに含めてキャッシュを分離する。
- 深度の1〜99百分位を8bitへ正規化。モデルと描画は独立しており、D3D12側はRGBA画像とグレースケール深度だけを受け取る。推論はフレームごとに行わない。
- 視差は深度ワープ。UIは実際の角度ではなく0〜100%の強度。変位係数は強度100%で0.24、既定50%で0.12。中央基準の深度0〜1で片側最大12%（既定6%）の元画像幅に相当する変位を与える。一定クロップの片側余白は係数の半分とし、画像端を確保する。強くするほどクロップと輪郭の歪みは増える。深度境界での変位抑制を維持し、隠れた背景の復元は未実装。
- D3D12の子HWNDへ直接表示し、WPFのD3DImageやブラウザーは経由しない。D3DImageはD3D9相互運用のため、本体のVisualBrush／共有Drawing／フェードへそのまま挿入できるとは扱わない。
- 再生は30fpsを目標にWPFの時計で進める。試作ではGPU fenceを毎回待つ単純な実装。高度なフレーム並列化と実行時の性能に応じた品質変更は未実装。
- 最小化・OFF・深度表示・終了・GPUエラーでD3D12オブジェクトを解放し、元画像を保持する。一時停止・片道完了・強度0では再生tickを止める。リサイズ時は保持フレームを再描画する。Windowsのクライアント領域アニメーションが無効なら静止画を表示する。
- 専用設定画面を持つが、試作UIの設定の永続化、焦点距離戦略、キャッシュ保持方針、NPUの指定、本体スライド遷移／背景／複数画面／ネットワーク統合は後続。

## モデルと依存ライブラリ

- [Depth Anything V2 Small](https://huggingface.co/depth-anything/Depth-Anything-V2-Small)と[ONNX変換版](https://huggingface.co/onnx-community/depth-anything-v2-small): Apache-2.0。モデルrevision `64fe43eba7f8a384b02fe3fadaa26cbba35548d8`、`onnx/model.onnx`、SHA256 `afb6a5c28f3b6bf1618c6e43f02073ef9dfdc70e937502d51603e57b0a1df10c`を固定。`Get-Model.ps1`はハッシュを検証し、前処理設定と上流ライセンスを`.tools/models/depth-anything-v2-small/`へ取得する。重みはソースや通常Releaseに同梱しない。
- Microsoft.ML.OnnxRuntime.DirectML／Managed 1.24.4、Microsoft.AI.DirectML 1.15.4、SkiaSharp 3.119.4はNuGetで復元する。ONNX RuntimeはMIT、DirectML redistributableはMicrosoftの配布条件、SkiaSharpとSkiaはそれぞれのライセンスと第三者通知に従う。テスト用パッケージはモデル・ランタイム・依存ライブラリのライセンスと第三者通知を含む。Visual C++ランタイムはVisual Studioのx64リリース用redistから未変更のDLLを同梱し、[配布対象リスト](https://learn.microsoft.com/en-us/visualstudio/releases/2022/redistribution#visual-c-runtime-files)を通知に記載する。
- DirectMLの設定は[ONNX Runtime公式資料](https://onnxruntime.ai/docs/execution-providers/DirectML-ExecutionProvider.html)、D3D12の構成は[Microsoftの公式サンプル案内](https://learn.microsoft.com/en-us/windows/win32/direct3d12/working-samples)を参照。

Issue全体を完了とは扱わず、この試作で生成品質・変位量・負荷を確認してから本体へ統合する。

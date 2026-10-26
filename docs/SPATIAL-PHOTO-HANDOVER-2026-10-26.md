# Issue #13: 立体写真のWindows実験引き継ぎ

2026-10-26。ブランチ: `feature/spatial-photo-poc`。

## 結論と作業の区切り

**今回の方式は実用不合格。ユーザーの指示で実験をここで終了し、資料・ソースをcommit／pushして記録する。** これ以上の生成モデル調査・比較・改良はモデル研究になり、本来のDPW開発の目的から外れるため進めない。人物生成器の変更、GPU化、追加ビルド、本体統合、Mac移植を継続タスクとして扱わない。

深度ワープは移動を強くすると画像が壊れ、TripoSRによる人物3Dはテクスチャだけでなく立体形状の再現性も不足した。元写真を投影したAlpha 2でも実用に届かない。現行のTripoSR経路は採用しない。Issue #13全体を完了したとは扱わない。

## 要求と試した内容

要求はWindowsネイティブで画像をドロップし、生成から再生まで試すこと。上半身・全身の両方で人物の側面を生成して大きく回り込み、人物に隠れた背景を補完した1枚の平面と組み合わせる。DPWへの組み込み・配布に合う利用条件を優先し、Mac／Metalは将来の対象としていた。

| 実験 | 実装 | 評価 |
|---|---|---|
| 深度ワープ | Depth Anything V2 Small、ONNX Runtime DirectML／CPU、WPF＋C++ D3D12。強度を0〜100%へ拡大、手動視点・キャッシュ・D&Dを実装 | 小さい変位は差が見えにくく、強い変位は破綻。人物の側面生成を満たさない |
| Portrait Alpha 1 | BiRefNet liteで人物抽出、LaMaで背景補完、TripoSR CPUで頂点色メッシュを生成。人物と背景を同じD3D12カメラで±60°描画 | 顔・服などのテクスチャが粗く、実機評価で不合格 |
| Portrait Alpha 2 | 元写真の人物RGBAをメッシュへ投影。元視点の人物深度パスで隠面への誤投影を防止し、投影ON/OFF比較を追加 | 正面の細部は改善するが、人物の形状・側面・輪郭・継ぎ目の品質が不足。実用不可 |

SHARPはモデル規約が製品開発に適合しないため採用していない。TripoSRはWindows／AMD環境で経路を実行するために試した暫定生成器。MoGe用の取得スクリプトもあるが、Portrait Alphaの生成には使用していない。固定モデル・上流コードと利用条件は[設計](PORTRAIT-3D-PIPELINE.md)と[アルファ版記録](../windows/experiments/SpatialPhoto/PORTRAIT-ALPHA.md)を参照。

## ソースとローカル生成物

実験ソースは`windows/experiments/SpatialPhoto/`に隔離した。本体の通常再生・設定・ネットワークへ統合していない。

- `Native/Spatial.cpp`、`NativeRenderer.cs`: 深度ワープと人物メッシュ＋背景平面のD3D12描画。Alpha 2は元写真の投影と元視点の深度パスを追加。
- `PortraitWorker/`: CPUの人物抽出・背景補完・3D生成、モデル固定情報、Python依存物と背景範囲の単体検証。TripoSRのCUDA marching cubes拡張をscikit-imageのCPU実装へ置き換える。
- `Program.cs`、`PortraitAlphaWindow.cs`、`PhotoDrop.cs`: WPFの独立テストUI、D3D12子HWNDへのOLEドロップ、CLI入口。Alpha 2は正面静止から開始。
- `PortraitScene.cs`、`TrialPaths.cs`: ハッシュ検証、物理EXE基準のパス解決、生成ワーカーの起動・中止・キャッシュ読込。
- `Build.ps1`、`Package.ps1`、`Start*.ps1`、`Setup-PortraitAlpha.ps1`: 再現用のビルド・セットアップ・起動手順。通常のビルド手順へ自動追加していない。

| 種類 | ローカルの場所 |
|---|---|
| 旧視差テストEXE | `release/windows/win-x64/spatial-photo-test/SpatialPhotoTest.exe` |
| 最新の比較用Alpha 2 | `release/windows/win-x64/portrait-alpha/PortraitAlpha.exe` |
| Python・モデル・TripoSR上流コード | `.tools/portrait-alpha/` |
| 旧深度モデルなど | `.tools/models/` |
| 検証ログ・画像・キャッシュ | `artifacts/windows/spatial-photo/`、`artifacts/windows/portrait-alpha/` |

上記はすべてGit対象外。EXE・重み・入力写真・生成した人物・キャッシュはcommit／pushしない。Portrait Alphaはこのチェックアウト内のランタイムを参照するローカル実験用で、EXEだけをコピーして使える一般配布物ではない。生成結果のGLBは生成頂点色のままで、Alpha 2の写真投影を焼き込んだUVテクスチャ付きGLBではない。

## 確認済みの動作と未達

Windows／AMD Radeon RX 7900 XTXで、上半身・全身の実写真各1枚の生成と、正面・左右30°・左右60°のオフスクリーン描画を確認した。CPU生成は直接ワーカーで各約43秒、配布EXEから新しいキャッシュへの生成は約87秒。モデル検証・抽出・背景・メッシュ保存を含み、初回セットアップは除く。実用速度を満たしたという記録ではない。

- Alpha 2のCLIは両シーンで各6/6成功。遮蔽、リサイズ、異常メッシュ、ハッシュ、写真の細部保持、隠面への誤投影防止、投影切替、実生成シーンを検証。
- 既存の視差ワープ回帰は10/10、Pythonの背景範囲検証は2/2成功。
- 配布EXEでも一時ディレクトリをカレントにして検証。自己展開EXEの実GPUアクセスは実行環境の制約によりサンドボックス外で行った。
- ビルド成功。ネットワーク制約でNuGetの脆弱性情報取得はNU1900警告となった。
- GUI自動操作・Explorerからの実ドロップ・長時間再生の自動検証は未実施。ユーザーによる実機評価は実用不可。

Alpha 2の証跡は`artifacts/windows/portrait-alpha/texture-packaged-upper-views/`、`texture-packaged-full-views/`、`texture-legacy-verification/`、ビルドログは`texture-package-build.txt`。これらはローカルだけに残る。CLI成功は処理と描画の動作確認で、人物再現の品質合格ではない。

工程分割や保存形式は実験の記録として残す。モデルの追加調査を次の作業として自動的に再開せず、本来のDPW開発へ戻る。

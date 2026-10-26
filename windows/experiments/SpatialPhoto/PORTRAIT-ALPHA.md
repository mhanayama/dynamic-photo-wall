# Portrait 3D Alpha 2 — Windows用テスト

人物抽出 → 背景の人物除去・外周補完 → 側面を持つ人物3D生成 → Direct3D 12で再生する実験用EXE。上半身・全身とも対象。通常のDPWスライドショーへの統合は後続。

**評価結果: 人物の立体形状の再現性が低く、ユーザーの実機評価でAlpha 2も実用不可。現行のTripoSR経路は採用しない。** 写真投影で表面の細部は改善しても、生成形状の不一致は解消できない。EXEとCLI検証は実験の記録として残す。以下の成功件数は処理・描画の動作確認であり、人物品質を示すものではない。

## Alpha 2: 元写真の見た目を保つ投影

Alpha 1の人物は、TripoSRが生成した低密度の頂点色だけで描画していた。元写真のテクスチャを使っていなかったため、顔や服の細部が潰れ、ユーザーの実機評価でテクスチャ品質は不合格となった。

Alpha 2では、抽出済みの`person.png`を元カメラから人物メッシュへピクセル単位で投影する。元カメラから人物だけの深度マップを一度描き、隠れていた面へ顔や腕を重ねて貼ることを防ぐ。アルファマットと面の角度で、元写真が使える面と生成色を混ぜる。メッシュや推論モデルは変えていない。既存キャッシュをそのまま読み込める。

正面の顔・服の模様は改善したが、生成形状と写真の輪郭のずれ、顎・肩・髪の継ぎ目、斜めの面の引き伸ばしは残る。**写真にない側面の高品質な外観生成は未解決であり、この修正だけで人物品質を合格としない。** 「元写真を見えていた面へ投影」をOFFにすると、同じ形状・視点で旧版の生成色と比較できる。

投影はアプリのD3D12描画処理。保存済み`person.glb`は引き続き生成頂点色のメッシュであり、写真を焼き込んだUVテクスチャ付きGLBへのエクスポートは未実装。

## 起動と操作

このチェックアウトの`release/windows/win-x64/portrait-alpha/PortraitAlpha.exe`を開き、JPEG／PNG／WebPを1枚ドロップする。「写真を選択して生成」またはEXEアイコンへのドロップも利用できる。写真は変更・外部送信しない。生成時だけ別プロセスのPythonを使い、表示はWPF＋D3D12のネイティブ実装。

生成後は正面で静止する。左右の固定視点または「カメラを左右に自動移動」で回り込む。自動移動の既定範囲は左右30°、調整範囲は0〜60°、固定視点は正面・左右30°・左右60°。「元写真」「補完した背景」で比較できる。生成はCPU、再生はGPU。処理中の写真変更・終了・「生成を中止」で自分の生成ワーカーを停止する。

**このアルファ版はローカルチェックアウト用。EXE単体を別PCへコピーしても生成ランタイムは付属しない。** `.NET`と描画用DLLはEXEに含み、Python・重み・生成器はリポジトリの`.tools/portrait-alpha/`を参照する。既にセットアップ済みのこのPCでは追加操作は不要。再構築はリポジトリのルートから:

```powershell
.\windows\experiments\SpatialPhoto\Setup-PortraitAlpha.ps1
.\windows\experiments\SpatialPhoto\Package.ps1 -PortraitAlpha
.\windows\experiments\SpatialPhoto\Start-PortraitAlpha.ps1
```

初回セットアップだけネットワークを使用する。モデルは合計約2.1GB、CPU PyTorchなどの依存物は別途必要。生成中はHugging Face／Transformersをオフラインに固定する。出力は`artifacts/windows/portrait-alpha/cache/`へ保存。写真・モデル・ワーカーの変更で別キャッシュになり、再利用時は出力ハッシュを確認する。キャッシュに個人写真と生成人物が含まれるため、不要になったものはこのディレクトリから削除できる。

## 構成と既知の制限

- 人物抽出: BiRefNet lite ONNX（MIT）。主となる人物1人を想定。人物専用の検出器ではないため、複数人物・持ち物の選択は未対応。
- 背景: LaMa ONNX（Apache-2.0）。人物マスクを拡大して除去し、±60°のカメラ経路を覆う範囲を1枚の平面へ補完する。推論は512px、背景キャンバスは長辺1536px。広い外周は模様の繰り返し・ぼけが目立つ。
- 人物3D: [TripoSR](https://github.com/VAST-AI-Research/TripoSR)（コード・重みMIT）。CPU PyTorchとscikit-imageのmarching cubesで実際の立体メッシュを抽出する。モデル重みと上流コードの固定版は`PortraitWorker/models.json`に記録。CUDA拡張は使わない。
- 元画像は長辺1024pxに縮小。人物メッシュはMC128の頂点色で、GLBと描画用メッシュを保存する。再生時に元写真を投影し、見えていない面は生成色を使う。**人物の形状・側面・髪・指・足先の品質は不足している。** 人物専用モデル・姿勢補正は未実装。
- 人物は体積を持ち、背景と別の深度で描画する。角度は実際のカメラの回り込み。メートル単位の実距離ではなく、画角と人物bboxによる配置。背景が平面のため大きな視点移動で遠近感が不自然になり、画面端で切れた人物は断面が見える。側面は推定結果であり本人の実形状を保証しない。
- マット／背景／メッシュは別ファイルとして確認できるが、現在は同一ジョブで生成する。背景だけの再生成・ジョブキュー・キャッシュ容量管理・本体への統合・Mac／Metalは後続。

## CLI検証

GUIを開かずに生成とGPU描画を実行できる。`--output`には`artifacts/windows/`配下を指定する。

```powershell
& .\release\windows\win-x64\portrait-alpha\PortraitAlpha.exe `
  --portrait-generate 'C:\Pictures\portrait.jpg' --output 'artifacts/windows/portrait-alpha/cache'
# 生成されたmanifest.jsonを指定
& .\release\windows\win-x64\portrait-alpha\PortraitAlpha.exe `
  --portrait-test --scene 'artifacts/windows/portrait-alpha/cache/<key>/manifest.json' `
  --output 'artifacts/windows/portrait-alpha/verification'
# ビルド時に同じCLI検証を行う
.\windows\experiments\SpatialPhoto\Package.ps1 -PortraitAlpha -Test -SceneManifest '<manifest.jsonのパス>'
```

2026-10-26、Windows／AMD Radeon RX 7900 XTX、CPU推論で上半身・全身の実写真各1枚が生成成功。直接ワーカーを起動した計測は各約43秒、配布EXEから新しいキャッシュへ生成した計測は約87秒（モデル検証・抽出・背景・メッシュ保存を含む、初回セットアップは除く）。上半身10,764頂点／21,524面、全身4,427頂点／8,850面。各シーンの正面・左右30°・左右60°をウィンドウなしで描画し、元写真と比較した。本人らしさの品質合格とは扱わない。

描画CLIは各5/5（合成図形による遮蔽・リサイズ・視点、異常メッシュ拒否、ハッシュ検証、実生成シーン描画）。背景の経路計算はPython 2/2。既存の視差ワープ回帰検証も10/10。配布EXEでも一時ディレクトリをカレントにして新規生成、両シーンのGPU検証各5/5を確認した。自己展開EXEの実GPU検証は実行環境の制約によりサンドボックス外で行った。ログ・画像は`artifacts/windows/portrait-alpha/`（配布EXEの結果は`packaged-upper-views/`、`packaged-full-views/`、新規生成は`package-worker/`）。WPF操作・Explorerから実際にドロップするGUI自動テストは未実施。ビルドは成功したが、ネットワーク制約でNuGetの脆弱性情報取得はNU1900警告となった。

アプリ依存物のライセンス・通知と、別途取得したモデルのライセンスは`licenses/`に収録。ローカルの生成ランタイムの依存物は`.tools/portrait-alpha/python/Lib/site-packages/`に各ライセンスがある。このランタイムを含めた一般配布パッケージは未作成。

Alpha 2では同じ上半身・全身のキャッシュで投影ON/OFFの正面・左右30°・左右60°を描画して比較した。投影後のCLIは各6/6（上記に加え、細かいチェック模様の再現・隠面への誤投影防止・リサイズ・ON/OFF・写真なしのシーンへの切替）。既存の視差ワープ回帰も10/10。結果は`artifacts/windows/portrait-alpha/texture-upper-views/`、`texture-full-views/`、`texture-legacy-verification/`。実人物での目視確認では正面の細部が戻ったが、側面の境界と引き伸ばしが残り、品質不合格を解消したとは扱わない。GUI自動操作は行っていない。

# Issue #2: 描画経路の追加監査とネイティブ描画の候補

2026-10-20。`d563da0`の製品コードを静的に確認した結果。ここに挙げる効果は仮説であり、GPU時間・pass数・コピー回数の実測ではない。[通常再生の計測](GPU-AUDIT-2026-10-20.md)では候補によるGPU削減を確認できなかった。ユーザーの意向により、描画処理だけのDX12／ネイティブAPIへの置き換えも検討範囲とする。

今回計測したオンライン経路は、計画の準備時に作った背景PNGを`SharedSceneBuilder`で表示する。ローカルの`GlassBackground`が行うVisualBrush→RenderTargetBitmap→CPU blurの継続処理とは経路が異なる。ローカルblurだけをGPU化しても、今回観測したオンライン表示の負荷を解消する根拠にはならない。

## コードから確認できる追加候補

| 優先 | 該当箇所 | 現在の処理 | 変更候補と主な対象 |
|---|---|---|---|
| 1 | `Rendering/PhotoRenderer.cs`の`SetDisplayRegion`／`Sample`／`AddPresentation` | 最初の画面に元の描画ツリーを接続し、その上にも表示用Canvasを置く。各画面は`VisualBrush`で元ツリーまたは画面別の子ツリーをサンプルする。明示的なbrush cache指定はない。 | 表示用の再サンプリングをなくす出力構造、または静止部分のcacheを比較する。GPUの合成・中間面が対象。ツリーが二重に存在することからGPU処理時間も二倍だとは判断しない。WPFのクリップ／隠面処理や内部cacheの実測が必要。 |
| 2 | `Rendering/AmbientFrameVisual.cs`、`SharedSceneBuilder.cs` | 異なる背景サンプルは2枚の画面サイズImageで重ね、その上に暗くする半透明Borderを置く。Windowsが生成する背景は最大256側で、Imageで表示面まで拡大する。 | 2枚のsource-overと暗色overlayを1回の背景shaderで計算する。GPUの全画面描画pass・中間面が対象。半透明PNGも含め、既存のpremultiplied alphaと重なり順を再現する。 |
| 3 | `Networking/WindowsPlaybackOutput.cs:PrepareAsync` | デコード幅は写真の縦横比・キャッシュ予算・計画内の必要画像数で決まる。placementの表示幅・最大scale・出力DPIは入力に使わず、計画内で将来表示する画像も準備する。継続Gallery以外は現在の画像を保持して再利用する経路も使わない。 | 実際の最大表示寸法でデコード上限を決め、近い将来の画像だけ先読みする。CPUデコード、RAM、GPUへの転送・テクスチャ容量が対象。Pan／Zoomの必要な解像度、複数画面の同じ画像、端末間ready期限、原画像の向きを維持する。 |
| 4 | `Rendering/PhotoRenderer.Network.cs:PresentShared`、共有`SceneEvaluation.Evaluate` | 表示前・表示終了後も含め全placementを毎フレーム評価し、scale×2、位置×2、opacityを書き込む。Evaluateは参照型の`EvaluatedPlacement`を毎回生成する。 | 表示区間と動作区間でactive集合を作り、表示が変わる要素だけ評価する。主にCPU・GC・WPFプロパティ処理。WPFは同じ値の設定を内部で省略する場合があるため、setter呼出し数の削減をGPU削減量にはしない。巻き戻し、pause／resume、計画終端を保持する。 |
| 5 | `Networking/WindowsPlaybackOutput.cs:RenderFrame`、`DesktopIntegration/DesktopWindowHost.cs` | pause中もRendering購読は続き、同じelapsedの評価と各出力の`EnsureZOrder`を続ける。stop後も終了まで購読が残る。Z順は正常なら書き換えずWin32の検査だけをする。 | 描画が変わらない間は描画更新を休止し、予定されたcontrol／commit用の起床とShellの監視を分ける。主にCPU・wake-up。購読を単純に外すと将来のresume／commit／previewを処理できなくなるため、専用スケジュールが必要。 |

優先1〜3は継続描画のGPU負荷に結びつく可能性がある。4〜5は明確な仕事の削減候補だが、今回の3Dエンジン平均約18%を大きく下げる根拠にはまだならない。前回の同一PNG省略も、実再生中の適用率をまだ計測していない。

WPFの`VisualBrush`／`DrawingBrush`のcache指定と適正サイズでの画像デコードは[MicrosoftのWPF性能資料](https://learn.microsoft.com/en-us/dotnet/desktop/wpf/advanced/optimizing-performance-2d-graphics-and-imaging)にも説明されている。静止部分のcacheは候補になるが、Pan／scrollで内容自体が変わる面への一律cacheは、再生成や大きなテクスチャを増やす可能性がある。現行の写真Imageには既に`BitmapScalingMode.Linear`が設定されており、同じ設定を追加するだけの変更は候補としない。

## 描画部分だけをネイティブ化する境界

オンライン経路は既に、`SharedScenePlan`に写真の矩形・移動／scale・clip・角丸・表示区間・fade・背景PNGが入り、共有時計のelapsedから`SceneEvaluation`が状態を決めている。この入力と、asset IDに対応するデコード画像を新しいrendererへ渡す構成が取れる。設定UI、写真一覧・顔検出、構図計画、通信、同期時計は既存のまま維持できる。

差し替える範囲は`SharedSceneBuilder`／`PhotoRenderer.Network`の視覚要素生成・更新、画面への出力。`WindowsPlaybackOutput`のprepare／commit／controlは保持し、prepare済みGPU resourceと画面出力をrendererの責務へ分ける。WPFとネイティブを同じ計画・時計で比較できる入口を設ける。ローカルの`WallPlaybackSession`はWPF storyboardsと別の再生処理を使っており、オンライン描画を置き換えただけでは移行されない。

| 候補 | この用途で試す内容 | 留意点 |
|---|---|---|
| WPF継続 | 出力ツリーの再サンプリング、静止部分のcache、デコード寸法、active集合を整理 | 既存の表示互換性を使える。合成passやresource配置の制御範囲は限定される。 |
| D3D11＋DXGI＋DirectComposition（必要ならDirect2D） | 画像をGPU textureとして保持。出力ごとに可視矩形を描き、背景補間＋暗色を1 shaderへ統合。静止時は再描画を止める。 | 最初の比較用ネイティブrendererの有力候補。Direct2DとD3D11はDXGIで連携できる。 |
| D3D12＋DXGI＋DirectComposition | 同じ描画をD3D12で実装し、texture／upload／descriptor／commandを管理する。出力ごとの可視性判定、batch、背景shaderを組み合わせる。 | 正式な検討対象。CPUとGPUの同期、resource state、寿命をアプリで管理する実装が必要。API名の変更だけでGPU時間や描く画素数が減るとは評価しない。 |

[CreateSwapChainForComposition](https://learn.microsoft.com/en-us/windows/win32/api/dxgi1_2/nf-dxgi1_2-idxgifactory2-createswapchainforcomposition)はD3D11 deviceとD3D12 direct command queueの両方を受け取り、DirectComposition visualへswap chainを渡せる。[Direct2D／D3D連携](https://learn.microsoft.com/en-us/windows/win32/direct2d/direct2d-and-direct3d-interoperation-overview)と、[D3D12の同期・resource stateの責任](https://learn.microsoft.com/en-us/windows/win32/direct3d12/porting-from-direct3d-11-to-direct3d-12)を比較材料とする。DirectCompositionそのものは[描画済みbitmapを合成する仕組み](https://learn.microsoft.com/en-us/windows/win32/directcomp/bitmap-surfaces)であり、写真の画素生成には別の描画APIが必要。

現在の`DesktopWindowHost`はExplorerのProgman／WorkerWへ接続し、Windows 11のraised desktopでは不透明なlayered childを維持している。新rendererでは専用のnative出力hostを用意し、このShell接続・アイコンの背面・DPI・複数画面との互換性を先に検証する。通常の独立ウィンドウでswap chainを作れたことだけでは、壁紙として表示できると判定しない。WPFからnative surfaceを再び`VisualBrush`で配る構成では、候補1の表示経路が残る。

## 比較の進め方

まず固定の共有計画と合成fixtureで、WPF出力とnative出力の画素を照合する。角丸・透明margin・EXIFの向き・色補正・背景のsource-over・計画継続・巻き戻し・pause／resumeを含める。背景PNGのwire形式は維持し、受信端末の色補正は一度だけ行う。

GPUへの効果は同じ計画・同じ出力解像度・同じ提示頻度で比較する。静止／交換／Pan／scroll／fadeを分け、GPU時間・CPU・割当・転送量・VRAM・提示間隔と待機を記録する。offscreenではUI出力を含む効果を主張しない。実画面のGUI自動操作はリポジトリ規則に従い、明示依頼時だけ行う。現時点はコード監査と設計比較までで、native実装・新しい性能改善率・GUI互換性は未検証。

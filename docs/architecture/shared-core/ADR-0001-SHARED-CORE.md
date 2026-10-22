# ADR-0001: Rust計算Coreと既存Native RendererをC ABIで接続する

- 日付: 2026-10-22 JST
- 状態: **提案**。実装採用・性能合格・移行完了を意味しない。
- 対象: Windows x64 / macOS arm64の計算ロジック。Linuxの描画実装は対象外。
- 根拠commit: `8354c857f50d99287873f0669fe0b6e9fb67cf8c`

## 問題

Windowsの`DynamicPhotoWall.Core`とMacの`WallScenePlanner/WallMotionGeometry`および対応Swift部品には、選択・mode重み・Gallery・顔安全性・mirror・timelineの重複がある。表示品質を揃えるため、同じ仕様変更をC#/Swiftで実装しfixtureで照合している。今回の調査では8組だけでもWindows 550行＋Swift 532行の対応部品を確認したが、旧fixture用処理も含み、全行を削除できる見積りではない。

一方、WorkerW/WPFとNSWindow/SwiftUI/CALayer、WIC/SkiaSharpとImageIO/PhotoKit、FaceDetectorとVision、権限・bookmark・鍵の処理は合理的に分離されている。既存LANには具体的な`SharedScenePlan/PNScene`とPrepare/Ready/Commitがあり、これを捨てる必要はない。

DPWは常駐アプリで、低いアイドル負荷・描画の滑らかさ・長期安定性を優先する。重複削減のために画像コピー・毎frame FFI・helper常駐を追加しない。[現行分析](CURRENT-ARCHITECTURE.md)をコード根拠の正とする。

## 選択肢

| 案 | 評価 | 判断 |
|---|---|---|
| C#/Swiftを維持しfixtureを強化 | 新toolchain不要、最も小さい変更。仕様を2言語に移す保守費とRNG差が残る | 比較基準・No-Go時の代替として保持 |
| Rust cdylib＋C ABI、同一process | .NET P/InvokeとSwift C wrapperで接続し、既存native描画と分離可能。ABI・署名・load・unsafe境界が増える | **推奨**。段階採用し、S1で費用を実測 |
| Rust staticlib＋C ABI | Macではappにlink可能。Windows managed WPFではnative shim等が必要で、両OSのlink経路が分かれる | 初回は不採用。起動／配布の実益が確認できれば再評価 |
| Rust helper process＋IPC | crash隔離、raw pointer境界を小さくできる。起動・heap・IPC copy・wake・再接続・署名の費用 | 今回の純粋計算には不採用。隔離要件が出たら別ADR |
| C++共通library | 同様のC ABIで統合可能、共有C++基盤は現状なし。メモリ／所有権の検証負担 | Rustより合理的という根拠がなく不採用 |
| C#をMacへembed／WASM | 共通計算は可能だが新host runtime／binding／配布を要する | 現行Swift appを保つ目的に対し費用が大きく不採用 |

細部の10評価軸は[統合方式比較](PROPOSED-ARCHITECTURE.md#5-rust統合方式)。Rustのlink形態とC境界は[公式Linkage](https://doc.rust-lang.org/reference/linkage.html)と[FFI資料](https://doc.rust-lang.org/nomicon/ffi.html)に基づき、DPWの負荷比較は未実測の設計評価である。

## 推奨する決定

1. Rust Coreは写真metadata・設定・topology・明示時刻・stateから不変Render Planを生成する。共有対象は幾何から開始し、選択・履歴・local状態遷移へ順次広げる。
2. C ABIはopaque handle、UTF-8のversion付きbatch payload、明示releaseに限定する。画像・texture・path・callback・Rust内部型を境界へ出さない。catalogはrevision単位で一度登録し全groupで共有する。
3. Decode・画像LRU・GPU・背景生成・frame補間・display pacing・windowは既存Native Renderer、列挙・metadata/顔検出・設定保存・OS通知はPlatform Adapterに残す。ホストは既存classを使う。
4. 毎frameのRust呼出は行わない。Coreは次期限を返し、native時計・timer・display linkが実行する。LANの選出・時計補正・Ready障壁・暗号化cacheは今回共通化せず、既存plannerの中だけCoreを使う。
5. Render Planは物理px基準Q座標、正規化source crop/anchor、µs、明示z・curve・fade・version・seed・state digestを持つ。UTC開始は別Commit。初期は既存wire v1へ変換する。
6. 同じ正規化入力・state・event・versionに対するPlan/state byte一致を保証対象とする。seedだけの保証や、OS顔検出・画素／物理提示の完全一致は対象にしない。nativeの名前順はrank入力で維持する。
7. 旧動作を既定にShadow→機能単位採用→両OS受け入れ→旧計算縮退と進める。現行settings形式・OS差分・表示mode・native品質を維持し、互換差分の修正を別案件へ分ける。

## 判断根拠

- `FixedGalleryLayout`・`FaceMotionSafety`・`ModeSelection`等はOS I/Oを必要としないため、小さいheadless計算libraryに適している。
- Windows localの`PhotoRenderer.Build`にも幾何・乱数が残り、Mac localにも計算と表示stateが混在する。既存のLAN plan境界を参考に分離すればRenderer全体を作り直さず移せる。
- `PNPlanningCatalog`は全catalogをmainから外して再利用済み。Coreのsnapshot登録はこの設計を継承し、全写真変換を毎scene追加しない。
- C ABI dynamic libraryは既存WPF publishを維持でき、SwiftでもC header経由で接続可能。Macだけstatic化する分岐、helperのlifecycleより初期の統合面が小さいと判断する。
- メモリ・GPUの既存問題はnative画像・提示等にも関係するため、Rust導入を性能改善策の代用にしない。Coreの実益は保守の一本化と計算の再現性である。

## トレードオフと採用gate

同一processなのでCoreのabort/UBは本体を終了させ得る。C境界のbuffer所有権・panic・version検査、Rust toolchain、DLL/dylibの配布と署名が新しい維持費になる。metadataがhost/Coreで最低限二重化され、cold startも悪化する可能性がある。静的linkやIPCが常に遅い／重いとは断定しない。

S1で両targetのheadless/FFI・catalog費用、S2/S3で旧動作との比較、S7で実機と長時間・packageを確認する。[回帰gate](RISK-ASSESSMENT.md#2-性能メモリの測定gate案)を満たさなければ見送り、幾何だけの採用に限定することも認める。合意済みOS差を消すために無理な共通化をしない。

## 再検討する条件

- runtime負荷・配布負担・wrapper維持費が重複削減を上回る → 既存2言語＋fixture継続。
- 実際のcrash隔離要件が強い → helper IPC。
- Macのdylib load/署名が支配的でstaticの改善が実測できる → Mac static＋共通C ABI。
- LAN stateの二重実装が主な変更費になり、今回の境界では不足 → 純粋な選出／復旧stateだけ別ADRで評価。TLS・鍵・transportまで自動的に移さない。

## 今回の結果

5成果物を作成し、既存CLI fixture（704＋472 assertions、背景色12ケース、zoom framing 5,120 assertions）をWindows上で確認した。Rust prototype・製品変更・Mac build・GUI操作・配布更新は行っていない。これは設計提案で終了し、実装開始の作業は[Migration Roadmap](MIGRATION-ROADMAP.md)のS0から別途行う。

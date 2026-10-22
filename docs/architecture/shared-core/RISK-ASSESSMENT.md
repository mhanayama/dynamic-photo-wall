# Risk Assessment — 導入リスクと採用条件

2026-10-22 JST。状態: 設計提案。測定値のない改善は仮説。[現行調査](CURRENT-ARCHITECTURE.md)、[提案契約](PROPOSED-ARCHITECTURE.md)、[移行段階](MIGRATION-ROADMAP.md)を参照。

## 1. リスク一覧

高／中／低はDPWへの影響と現状の未確定度からの定性的評価。発生確率の実測ではない。

| リスク | 重大度 | コード上の根拠／発生条件 | 抑制策・検知・残る制約 |
|---|---|---|---|
| UI停止・切替遅延 | 高 | `WallScenePlanner`はMainActor。`PNPlanningCatalog`は全写真のID生成をactorへ移して再利用済み。FFIで毎回再変換すると再発 | immutable catalogを全groupで共有しworkerで登録。frameにはCoreを呼ばない。plan作成／serialize／parse／UI applyを別計測。Rust化そのものは停止解消の証拠ではない |
| アイドルCPUの増加 | 高 | local `GlassBackground`は前景変化時に更新し静止中timer停止、Mac同期はdisplay link | Coreはtimer/threadなし、deadlineイベントのみ。新しい60Hz Rust pollingを禁止。既存native frame driver自体の見直しは別案件 |
| GPU負荷増 | 高 | WPF共有描画・CALayer、visualの再利用・画面外drawingの取外しが既存最適化 | Plan変更だけでtexture/visualを再生成しない。背景採取やCPU→GPU uploadを増やさずframe counterで比較。幾何の共通化に直接のGPU削減根拠なし |
| metadataの重複保持 | 中〜高 | C#/Swift metadata、JSON buffer、Rust snapshotが同時に存在し得る。10万枚・複数groupで拡大 | chunk登録、共有catalog、serialize buffer即解放、revision単位で交換。Rust側にpathや元画像を複製しない。host索引を完全削除できるとは限らない |
| 画像・PNGの保持再発 | 高 | Windows `PeerSession`の過去計画と背景PNG保持の修正、ImageCache.ClearAsync、Mac owners別pin | CoreにPNG/Bitmap/CGImageを渡さず、current/outgoing/pendingとcatalogを別所有。完了・Next・stop・disconnectごとに参照数を検証。GPU driverの解放遅延も別観測 |
| 常駐メモリ改善への誤期待 | 高 | [既存Windows解析](../../../windows/docs/PROCESS-MEMORY-BREAKDOWN-2026-10-21.md)は生存managed約8.5〜11.7MiBに対しネイティブ領域が大きい | Rust導入の目的は保守と一致性。全体memory・native heap・GPUを別測定。既存の領域表と画像推定量は二重加算しない |
| RNG／順序差による挙動変化 | 高 | `.NET Random`とSwift独自RNG、OrdinalIgnoreCaseとlocalized compare、hash列挙 | algorithm/rng version固定、decision tape、rank入力、explicit tie。同じnative seedの列一致は主張しない。名前順の変更は別仕様合意が必要 |
| 数値branch・顔cropのずれ | 高 | `FixedGalleryLayout`のsafe interval、`FaceMotionSafety`の>20px、mirror半分閾値、末尾1 ULP修正 | Q/U/µs、basic演算順、threshold有理比較、両arch canonical一致。旧oracleの誤差だけで安全判定差を許容しない |
| 再生state二重管理 | 高 | local scene loopとLAN `SceneCoordinator`は別。Gallery先読みがselector履歴も進める | core/native/LANのstate所有権を表で固定。CoreのdeadlineとLAN障壁を二重実行しない。pause mask・prepare世代・同内容sequenceの冪等性を試験 |
| blank frame／window再生成 | 高 | 既存`PNPresentation/ShowShared`は旧visualを維持し継続境界のfadeを避ける | plan寿命とwindow寿命を分離、Readyまで旧表示、通常切替はwindow維持。rollbackもClear先行にしない。画面破棄・切断時の例外は残る |
| FFI allocator／use-after-free | 高 | 新たなunsafe境界、C#/SwiftがRust bufferを保持する場合 | handle＋世代、Rust releaseのみ、SafeHandle/deinit、入力借用は呼出内のみ、resultのnative値化後release。任意の不正pointerを安全に受理する保証はしない |
| panic／abortで本体終了 | 高 | cdylibは同一process。panic=abort、OOM、UBは本体へ波及 | panic=unwind＋境界catch、domain errorはResult、session poison。abort/UBは隔離不可。隔離の実要件が出ればIPCを再評価 |
| ABI／schema混在 | 高 | DLL自己展開とapp差替え、Swift dylib署名／rpath、古いconsumer | ABI major検査、schema/algorithm別version、immutable native package、BUILD-INFO hash。ロード時不一致ならlegacy。旧DLL単独の入替え禁止 |
| build・署名・配布失敗 | 高 | Windows single-file、Package allowlist、Mac signed bundle・archive一致 | native targetをOS別にbuild。package検証にnativeロード・hash・署名を追加。Rustなし開発のlegacy build経路も移行期間保持 |
| 依存・CI維持費 | 中 | Rust/Cargoを.NET＋Xcodeへ追加。調査時点でrepo内GitHub Actionsなし | toolchain/lock pin、依存最小、license更新、native CIを段階追加。非描画CoreのみLinux job可。build時間と管理工数の便益をS1/S7で再評価 |
| OSサービスの過剰移管 | 高 | PhotoKit/bookmark、FaceDetector/Vision、WorkerW/Spaces、secret storeは異なる | A/Rに残す。OS権限・画像pipeline・通信暗号化をCoreに入れない。Linuxはこの境界の新実装が別途必要 |
| LAN互換性の破壊 | 高 | scene JSON/Ready/commit、opaque ID、既存background PNGと色補正 | 既存wire変換、leaderだけ計画、receiver再抽選なし。new seed/layout情報は内部sidecar。新mode等wire意味変更は別ADR |
| 設定・ユーザーデータ破壊 | 高 | Windows settings.json、Mac snapshot＋bookmark、UI draft取消が別形式 | storage形式とmigrationを維持、共通値だけ検証。Core snapshotは通常保存しない。専用profileで旧版への復帰確認 |
| 新旧保守の長期化 | 中〜高 | Rust＋既存C#/Swiftが長期に3実装化 | 小PR、段階ごとに移行完了のcallsite一覧、S7削除条件、shadowは開発専用。費用が利益を上回るなら選択／LAN stateの移行を止める |

## 2. 性能・メモリの測定gate案

以下は**今回測定して得た値ではなく、実装開始時に基準を取得して適用する初期受け入れ案**。CPUやmemory改善を要求するのではなく、不要な回帰を検出する。特殊な遅いPCや巨大libraryでgateを満たせない場合は、理由を記録して設計を再検討し、測定後に都合よく閾値を緩めない。

### 条件

- 同じcommit相当のlegacy/shared切替ができるcandidate、shadow OFF、Release、同じ合成画像・向き補正済み顔・seed tape・topology・設定。
- ローカル／LAN、5モード、背景ON/OFF、1／3画面、1920×1080／4K、混在DPIを分離。10k/100k catalogと0/1/20写真のplanを含める。
- coldとwarm startを分け、AB→BA→ABを最低3対。連続指標はwarm-up後60秒以上、startup／prepareのp95は100回以上を目安に採取。単位・サンプル数・分布・OS/CPU/GPU/driver／refreshを記録する。
- CPUはprocess CPU時間/経過時間で1論理core=100%。タスクマネージャー全core正規化と混ぜない。GPUは同じengine・同じcounter・同じ露出／遮蔽条件。working set／private bytes／physical footprint／GPU allocationは別々。
- network I/O、PNG生成、decode、Core登録／apply、serialization、native plan apply、初回提示を分ける。Coreだけ速くてもend-to-endが悪ければ不合格。

### 初期gate

| 指標 | gate案 |
|---|---|
| フレーム経路 | Core FFI／catalog変換／JSON parseは0回/frame。新しい常駐thread・timerは0。画像・GPUの所有者は既存Rのみ |
| 無変化時 | 新Coreによる周期wake 0。静止／pause／stopのCPU増分は0.2 percentage point（1core基準）以内、または計器のnoise floor以内。既存native callbackを移行ついでに別方式へ変更しない |
| 通常CPU | legacy比+5%か+0.2 pointの大きい側を上限案にする。双方のabsolute値も報告。計画eventのCPU burstは別集計 |
| GPU時間／使用率 | 同engine・同場面で+5%か+0.2 pointの大きい側まで。upload bytes/count、surface rebuild countに原因不明の増加なし。提示hitchの新規発生なし |
| Core plan apply | catalog登録後、最大128画面／1024placementのevent計算p95<=10msを目標gate。ホストUI上でこの計算を行わない。100k catalog全走査が必要なら計測し、再利用／索引を検討 |
| UI apply | 60Hzで新しい4ms超のUI作業を加えないことを初期gate。高refreshはframe budgetに応じて厳しくする。既存のdecode／色変換の停止とは別に増分を確認 |
| 起動・復帰・scene準備 | end-to-end p95増分<=max(legacyの5%,20ms)。cold DLL展開／dylib load／catalog登録を含める。初回catalogが支配的なら段階移行のNo-Go |
| Core session memory | catalogを除く保持<=2MiB/groupを初期案。current/outgoing/pending、history上限、plan bufferを含む。最大local構成を制限する値にしない |
| 全process memory | 同じsteady stateでprivate bytes／footprint等の増分<=max(5%,16MiB)を初期gate。catalog登録の一時peakも記録。画像予算の削減で導入費を隠さない |
| catalog増分 | 10k/100kの両方でRust snapshot・host索引・一時bufferのbytesと構築時間を測る。1catalog/groupの複製がなく、差替え後に旧revisionが解放される |
| 長時間 | 24h→72hでcrash/hangなし、handle／plan／texture／PNG数が上限内。warm-up後の時系列で継続増加があれば原因を特定するまで既定化しない |

5%等の小差が計測noiseと分離できない場合は「改善／回帰なし」を断定せず、採取時間・回数を増やして区間推定と併記する。UIのhitchを単純平均CPUが低いことで許容しない。

[Macの既存測定](../../../macos/docs/SYNC-FRAME-PACING-MEASUREMENTS-2026-10-20.md)ではdisplay linkと16ms相対待機で差が出ている。Coreが同じ時刻を計算しても提示driverの品質は別なので、毎frame計算をRustへ集約する変更は避ける。

## 3. 抽象化の費用と便益

| 追加するもの | 回収できる保守負担 | 残す限界 |
|---|---|---|
| 純粋Core、共通fixture | 顔安全性・固定Gallery・mirror・mode抽選の2言語同時修正 | OS顔検出・codec・native描画は重複したまま |
| 小さいC ABI／schema／wrapper | hostとRustを局所的に変更し、input replayで再現 | allocator、ロード、ABI検証と2target buildの費用は増える |
| event state machine | localの次期限・pause・準備完了の意味を一致 | LAN選出・clock補正・Ready障壁は別のまま |
| catalog登録・revision | 全写真のID/metadata変換を毎scene繰り返さない | native I/O索引との最低限の二重metadataは残る |

FFIは高頻度処理・画像を扱わず、A/H/Rは既存classを使う。Rust導入で全体コード量が必ず減るとは見込まない。S1ではwrapperとschemaの行数・unsafe箇所、buildの追加分を記録し、S7では削除できた本番計算callsiteと、実際の仕様変更に要した工数を比較する。共通化が進んでも画像pipelineやLAN全体の統一を自動的に次の目標にしない。

## 4. 未確定事項・決定する段階

| 未確定 | 初期判断／確認方法 | 決定期限 |
|---|---|---|
| Rust libraryの実際の起動・heap費用 | cdylibを推奨するが測定なし。CLI consumer→native hostの順で比較 | S1 |
| Mac optional loader | C importだけではmissing dylibをruntime fallbackできない。dlopen wrapperまたはbundle単位rollbackを検証 | S1 |
| catalog chunk・総件数・顔上限 | 既存library規模と10万metadata benchmarkから上限を固定。超過時はlegacyへ | S1 |
| Q/U/µsの誤差とbranch一致 | 量子化だけで十分と仮定せず両arch比較。旧guardとの差はexact boolean gate | S1〜S2 |
| partial失敗の互換profile | C#/Swift呼出差を合成失敗で確定し、ユーザーUXを変えないprofileへ | S0、対象切替前 |
| local/LANのreflowサイズ補間 | Windows localはsize補間、Mac localとwire segmentは新sizeを先に適用。profileとwire変換を分ける | S3/S5前 |
| 共通RNG採用と旧再現性 | 旧seed列は保存しない。分布・history規則を保ち新versionで再現性を保証 | S4前 |
| OSを越えた同じローカル写真ID | pathとPhotoKit IDから自動一致はしない。LANの既存opaque ID／共通fixtureが基準 | 設計上の制約として維持 |
| Linux展開 | Coreはheadlessでbuild可能にする。desktop/wallpaper API・decode・権限は新R/Aが必要 | 別計画 |
| 実機性能・長時間受け入れ | CLI成功では代替不能。専用profileと明示的な実行依頼で確認 | S7前 |

## 5. 不採用・延期を判断する条件

S1でFFIとcatalogの費用が許容できず、native形態を変えない範囲で解消できない場合はRust導入を見送り、既存C#/Swiftと共通Goldenを継続する。S3までで幾何の共通化に実益があり、S4/S5の互換stateが過剰に複雑なら幾何だけの共有で止める。安全な段階停止は失敗ではなく、この設計の選択肢である。

IPCは実際のcrash隔離要件が出た場合、Mac staticはdylib配布／起動費が支配的と測定された場合に再評価する。どの方式でもCoreの導入を理由に既存のメモリ問題・GPU使用量が解決したとは扱わない。

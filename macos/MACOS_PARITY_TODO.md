# macOS版：Windows版との差分監査とTODO

監査日: 2026-10-14（日本時間）。基準はこのワークスペースの `windows/src/DynamicPhotoWall` / `windows/src/DynamicPhotoWall.Core` の実装。macOS側は `DynamicPhotoWall/*.swift` 全15ファイル、設定・単体/UIテスト・Xcodeプロジェクトを確認した。Windows側の関連実装・テスト・設計も照合した。

**結論:** 5モードの基本表示と設定画面はあるが、日常利用に必要な写真選択の接続、画面IDの保持、再生制御、監視・復旧、顔検出、動的背景、デコードキャッシュが不足している。既存TODOを現コードに合わせて更新した。今回の変更はドキュメントのみで、アプリの修正は行っていない。

## 判定と優先順位

- **実装あり**: コードの存在と呼出し経路を確認した。実機合格を意味しない。
- **部分実装／未接続**: クラスや設定は存在するが、実際の再生に反映されない、またはWindowsと動作が異なる。
- **未実装**: 対応する処理・状態を確認できない。
- **未検証**: OSの実動作を確認していない。実装不足とは分けて扱う。
- **P0**: 誤画面表示・設定喪失・再生破綻につながる修正。**P1**: 主要機能・性能の差分。**P2**: 常駐運用・診断・配布の整備。

以下のチェックは対応完了を表す。ソースに存在するだけでは完了にせず、自動検証と必要な実機確認を完了条件とする。比較対象にWindowsにも残る制約を含めない。

## 差分一覧

macOSのリンクは本ファイルからの相対パス。Windowsのリンクはリポジトリ直下の実装を指す。

| 領域 | macOSの現状 | Windowsとの主な差分／参照 |
|---|---|---|
| 設定UI | 実装あり／部分実装 | 5タブと多くの数値項目はある。顔設定・ログイン自動起動・一時停止がない。`exifOverlay` / `cacheMegabytes` はUIだけ。[ContentView](DynamicPhotoWall/ContentView.swift)、[Windows設定](../windows/src/DynamicPhotoWall/UI/SettingsWindow.xaml.cs) |
| 保存・適用 | 部分実装 | UserDefaultsにCodableデータを保存するが、破損退避・警告がない。編集値を直接モデルへ反映し、フォルダ変更は即保存。開始時は再走査せず古い写真一覧を使用。[AppModel](DynamicPhotoWall/AppModel.swift)、[SettingsManager](../windows/src/DynamicPhotoWall/Configuration/SettingsManager.cs) |
| 対象画面 | 部分実装／不具合 | 1画面用の背面ウィンドウはある。保存ID復元前に最初の画面IDを保存してしまう。未接続時も別画面へ選択を変更する。[AppModel](DynamicPhotoWall/AppModel.swift)、[Windows復旧](../windows/src/DynamicPhotoWall/WallController.cs) |
| 写真走査 | 部分実装 | 複数フォルダ・再帰ON/OFF・6拡張子・URL一致の重複排除はある。変更監視・定期照合・更新キー・永続メタデータがない。[PhotoLibrary](DynamicPhotoWall/PhotoLibrary.swift)、[PhotoScanner](../windows/src/DynamicPhotoWall/PhotoLibrary/PhotoScanner.cs) |
| EXIF | 部分実装／未検証 | 向き5〜8の寸法入替とImageIOの向き補正デコードはある。8方向の実画素検証・撮影日時保持がない。[PhotoLibrary](DynamicPhotoWall/PhotoLibrary.swift)、[PhotoImageView](DynamicPhotoWall/PhotoImageView.swift) |
| 写真選択 | 未接続 | `PhotoSelector` は直近除外・逐次選択・小規模緩和を実装し、単体テストもある。しかし本番のPlanner／Galleryから呼ばれていない。[PhotoSelector](DynamicPhotoWall/PhotoSelector.swift)、[WallScenePlanner](DynamicPhotoWall/WallScene.swift) |
| モード抽選 | 部分実装 | seed付き重み抽選はある。適格性判定より前にグループ重みを分割し、3連続抑制がなく、候補ゼロ時に無効なGalleryへフォールバックする。[WallScene](DynamicPhotoWall/WallScene.swift)、[CompositionEngine](../windows/src/DynamicPhotoWall.Core/CompositionEngine.cs) |
| Gallery | 部分実装 | 基本の共通高・中央配置はWindowsと同等。各スロットは時差付きで変更するが、履歴管理・先読み・全スロットの同時再配置アニメーションが不足。[WallSceneViews](DynamicPhotoWall/WallSceneViews.swift)、[PhotoRenderer](../windows/src/DynamicPhotoWall/Rendering/PhotoRenderer.cs) |
| 横Gallery | 部分実装 | 写真の実アスペクト比と初期ストリップ長は反映。有限ストリップが画面右外から通過するだけで、定速の流出・流入更新ではない。[WallSceneViews](DynamicPhotoWall/WallSceneViews.swift) |
| 縦横Pan / Zoom | 部分実装 | モード別時間、縦パン下端→上端、横パン端点、Zoom cover寸法は実装済み。Retina換算・顔位置・方向と中心のランダム化が不足。[WallScene](DynamicPhotoWall/WallScene.swift)、[MotionEngine](../windows/src/DynamicPhotoWall.Core/MotionEngine.cs) |
| クロスフェード | 部分実装 | 新旧両方のOpacityを変えるため暗くなる。次シーンはフェード中progress=0固定で、開始タイミングもWindowsと異なる。[DesktopWallView](DynamicPhotoWall/DesktopWallView.swift)、[PhotoRenderer.ShowAsync](../windows/src/DynamicPhotoWall/Rendering/PhotoRenderer.cs) |
| デコード・キャッシュ | 部分実装 | ファイル読込とデコードはUI外。キャッシュは元データのNSCache、固定256MiB。デコード画像のLRU・表示幅指定・設定予算・先読みはない。[PhotoImageView](DynamicPhotoWall/PhotoImageView.swift)、[ImageCache](../windows/src/DynamicPhotoWall/PhotoLibrary/ImageCache.cs) |
| 顔検出 | 未実装 | 顔データ・検出・キャッシュ・停止／フレーミング設定がない。[Windows FaceAnalyzer](../windows/src/DynamicPhotoWall/PhotoLibrary/FaceAnalyzer.cs) |
| 背景 | 部分実装 | 先頭の元写真を固定複製してぼかす。現在の切抜き・Gallery交換・流入写真に追従しない。[AmbientBackgroundView](DynamicPhotoWall/WallSceneViews.swift)、[GlassBackground](../windows/src/DynamicPhotoWall/Rendering/GlassBackground.cs) |
| 操作・時計 | 部分実装／不具合 | 開始・停止・次・終了メニューはある。一時停止がなく、手動Nextのindexと自動進行のindexが独立。時計はDate差分。[DesktopWindowController](DynamicPhotoWall/DesktopWindowController.swift)、[DesktopWallView](DynamicPhotoWall/DesktopWallView.swift) |
| OS統合・復旧 | 部分実装／未検証 | desktop level・マウス透過・全Spaces指定はある。画面変更・スリープ・遮蔽・健全性確認の購読処理がない。Dock/Menu Bar制御もない。[DesktopWindowController](DynamicPhotoWall/DesktopWindowController.swift)、[ExplorerRecovery](../windows/src/DynamicPhotoWall/DesktopIntegration/ExplorerRecovery.cs) |
| 運用 | 未実装／未検証 | ログ・専用検証プロファイル・ログイン起動・CLI検証相当がない。複数起動の明示的制御はなく、LaunchServices側の実際の動作も未検証。[DynamicPhotoWallApp](DynamicPhotoWall/DynamicPhotoWallApp.swift)、[Windows Program](../windows/src/DynamicPhotoWall/Program.cs) |

## P0：最初に直す不具合

- [ ] **M01 保存済み画面IDを正しく復元し、未接続でも保持する。** `AppModel.init` は `refreshScreens()` → `restoreSelection()` の順。前者が `selectedScreenID == nil` の状態で最初の画面を選びUserDefaultsを書き換えるため、後者は元の保存IDを読めない。保存値を先に読み、未接続時は選択IDを上書きせず待機する。完了条件: 2台目を選択→再起動して同じ画面、切断→別画面に表示しない、再接続→同じ画面へ復旧。Windows: `StartPlayback` / `RecoverAsync`。
- [ ] **M02 自動進行と「次の構成」の現在位置を一元管理する。** 自動進行は `WallPlaybackPosition.resolve` のローカルindex、手動Nextは `DesktopWindowController.sceneIndex += 1`。自動でscene 3まで進んでも最初のNextはscene 1から再作成する。ビューの再作成はseed／開始時刻もリセットする。完了条件: 長時間進行後のNextが現在の次へ進み、連打・フェード中・一時停止中も時計・選択履歴を維持する。
- [ ] **M03 写真走査の世代管理・キャンセル・適用操作を直列化する。** `reloadPhotos()` はTaskを保持せず、複数走査の古い完了が新しい結果を上書きできる。`start()` も走査中を自身では拒否せず、旧結果で開始できる。フォルダ解除時は走査終了前にsecurity scopeを解放する。完了条件: 連続保存・追加削除・停止→古いTaskが状態や再生を復活させない。`isScanning` が最新ジョブの状態を表し、scopeは使用中ジョブの終了まで有効。
- [ ] **M04 最後のフォルダ削除／写真ゼロで旧壁表示を停止し、要求状態を保持する。** 空フォルダ分岐は一覧を消すだけで `desktopWindowController.close()` を呼ばない。再走査が0枚でも `start()` のguardが戻るだけで旧ウィンドウと `isPlaying` が残る。完了条件: 旧写真は表示し続けず、待機状態を示し、監視で写真が戻れば再生要求がある場合だけ再開する。
- [ ] **M05 有効モードなし／適格写真なしを待機状態として扱う。** Plannerの候補ゼロ分岐は設定に関係なくGallery1枚を返す。保存前にも有効モード・正の重みを検証する。完了条件: 全無効・全重み0・適格写真0で勝手にGalleryへ切り替えず、理由を表示。写真・設定の変更で復帰する。Windows: `CompositionEngine.Next` のnullと `SettingsWindow.SaveAsync`。
- [ ] **M06 解決不能・一時的に不可読なブックマークを失わない。** `restoreFolderAccess()` は失敗項目を捨てた `folderURLs` から直ちに `saveBookmarks()` する。保存側の `compactMap(try?)` も失敗を黙って除外する。完了条件: 外付けドライブ未接続／権限失効で登録を消さず、未接続・再許可を表示。staleは更新し、明示的削除まで元の記録を保持する。macOS固有の運用品質項目。

## P1：写真選択とモード計画

- [ ] **M07 `PhotoSelector` を本番へ接続する。** シーン初期選択・Gallery交換・横Gallery流入で同じインスタンスと履歴を使う。現在のPlannerは連続配列切出し、Gallery交換は配列index計算で選ぶ。完了条件: `recentCount` と `randomOrder` が実際の表示へ反映される。7枚・ランダムOFFでも全写真をパス順で一巡し、末尾でラップする。
- [ ] **M08 表示中除外と縦写真優先を移植する。** 現シーン全画像を次シーンから除外し、構成を作れない時だけシーン間除外を緩和する。Gallery初期選択は縦写真を優先し、不足分を全候補から補う。同一シーン内の重複除外は緩めない。完了条件: 1〜5枚の小規模と大規模ライブラリ、フェード中・スロット交換で重複／繰り返し規則を検証。
- [ ] **M09 適格サブモード数で重みを分け、同一モード3連続を抑制する。** 現在はenabled数で先に割るため、横Panだけ不適格でも縦Panの重みが半分になる。Windowsと同じ順序で候補抽出→グループ重み分割→履歴抑制を行う。完了条件: 片方／両方のPan適格、横Gallery不適格、ウェイト0を検証。複数候補時は最大2連続、単一候補時は再生継続。乱数列のC#との完全一致は不要。
- [ ] **M10 毎フレームの全履歴再計算をなくす。** `TimelineView(.animation)` の中で `resolve` が開始indexから現在まで各シーンを再生成し、候補filterを繰り返す。完了条件: 現在／次の計画を保持し、描画時はその時刻評価だけを行う。8時間後も1フレームの処理量が過去シーン数に比例しない。大量写真でUI応答とCPUを測定する。

## P1：デコード・ライブラリ

- [ ] **M11 デコード済み画像のLRUと設定予算を実装する。** `PhotoDataCache` は圧縮元データをURLだけでキャッシュし、`cacheMegabytes` を読まない。キーをパス・サイズ・更新日時・デコード寸法にし、実画素のバイト数で64〜1024MiB予算を適用する。完了条件: 同じ写真の前景／背景で重複デコードを避け、同名上書き後は新内容へ更新、LRU予算内。表示中・先読み・GPUメモリは別計測とする。
- [ ] **M12 表示幅に応じた縮小デコード・直列実行・先読みを接続する。** 現在は長辺4096固定で、次シーンはフェード開始時に初めてビューを生成する。Windows相当の表示幅選択・元解像度を超えない縮小・約16MP上限を実装。次の構成1つと横Galleryの次流入写真を事前準備する。完了条件: フェード／流入時にProgressViewや空画像が出ず、巨大縦画像・小画像でもメモリが際限なく増えない。
- [ ] **M13 デコード失敗を再生制御へ通知する。** 現在はnilでreturnしてProgressViewが残る。破損・削除・コピー途中をスキップし、失敗集合は設定適用／ライブラリ更新まで再試行から除外する。完了条件: 有効な写真へ進み、全件失敗時は理由と待機を表示。停止時に保留中デコードがUIへ戻らない。
- [ ] **M14 変更監視と5分ごとの整合再走査を追加する。** 作成・削除・更新・名前変更を約1秒デバウンスし、再帰設定も反映する。表示画像削除は次構成へ、空からの復旧はM04の要求状態に従う。完了条件: 通知漏れ・監視失敗でも定期照合で復旧。フォルダ変更時に旧監視・Taskを解除する。Windows: `PhotoScanner` / `LibraryChanged`。
- [ ] **M15 メタデータと走査の堅牢性を補う。** パス・ファイル長・更新日時・撮影日時・向きを保持し、寸法5億画素超を除外。metadataキャッシュを永続化して更新時だけ再取得する。URL一致の重複排除は実装済みなので、追加は正規化・重複ルート／エイリアスの扱いを対象とする。不可読項目をログへ残して他の走査を継続。完了条件: 親子フォルダ登録、再帰OFF、不可読サブフォルダ、破損・巨大ヘッダーを検証。
- [ ] **M16 EXIFと実形式の回帰検証を追加する。** ImageIOの向き補正は既に有効。全8方向で寸法・四隅の実画素を検証し、JPEG撮影日時を取得。JPEG / PNG / WebP / HEIC / HEIFの本物の画像でデコードを確認する。現テストの `first.JPG` はPNGデータの改名なのでJPEG対応の証明にならない。OSコーデックの利用可否も結果に記録する。

## P1：モーションと表示

- [ ] **M17 Retinaのpoint／物理pixelを統一する。** `ScreenDescriptor` は物理解像度を持つが、実際の適格判定・動作時間・レイアウトへは `GeometryReader` のpoint寸法を渡している。Windowsのように物理座標で計画し、描画時にpointへ変換する。完了条件: 1x／2x／混在スケーリングで120px/s・40px/sの実速度、パン拡大率適格性、gap／角丸、デコード寸法が一致する。
- [ ] **M18 Galleryの交換を状態として保持し、旧写真上へフェードする。** 現在は経過割合から各スロットの写真を再導出する。Windowsの初回待ち `min + slot×3秒`、以後min〜maxの抽選間隔に揃え、履歴除外と準備済み画像を使う。完了条件: 交換対象以外の写真は維持し、全スロットの位置・寸法は同時アニメーション。変更途中でも同時表示重複や黒落ちがない。
- [ ] **M19 横Galleryを定速で流出・流入する方式へ変更する。** 初期配置をgap位置から画面＋先読みまで埋め、先頭退出→残りの座標補正→末尾へ新写真を追加する。現ビューは全stripの移動距離をscene進捗に掛けるため、設定の40px/sにならない。scene時間もWindowsの `max(120, galleryMaxSeconds×3)` と異なる。完了条件: scene継続中は有限配列が通過して終わることなく新写真が入り続け、速度・上下gap・実アスペクト比を維持する。
- [ ] **M20 横Pan／Zoomの方向・中心をWindows相当にする。** 横PanはURLのチェックサムで方向固定、Zoomは中心固定の拡大のみ。選択ごとに横Pan方向、Zoom拡大／縮小、顔なし時の中心0.35〜0.65を決定する。完了条件: cover寸法と縦横比を維持し、両方向・両ズームが出る。顔あり時はM24の位置を採用する。
- [ ] **M21 クロスフェードの合成と時刻を合わせる。** 旧シーンを不透明な土台にし、新シーンだけフェードイン。次シーンのモーション開始時刻を定義してWindowsと照合する。完了条件: 明るい単色画像の中間で暗くならず、フェード開始／終了／Next割込み／停止で黒画面やモーションの飛びがない。
- [ ] **M22 EXIFオーバーレイを実表示へ接続する。** `exifOverlay` は設定UI以外で使われていない。Windows同様にファイル名・向き適用後の解像度・取得可能な撮影日時を各モードへ表示する。完了条件: Gallery交換・流入でも現在の写真の内容に更新され、OFFなら表示しない。

## P1：顔検出と動的背景

- [ ] **M23 顔検出とキャッシュを追加する。** Vision等で向き適用済みの長辺640px画像から顔を検出し、上原点の正規化矩形へ統一。パス・長さ・更新日時キーでキャッシュし、保存件数は最大10,000。`StopAtFace` / `FaceAwareFraming` を設定モデル・UIへ追加。完了条件: 8方向・複数顔・検出ゼロ・失敗時を検証し、失敗時は通常のモーションへ戻る。
- [ ] **M24 顔位置を縦Pan／Zoomの幾何計算へ反映する。** Windows縦Panは最も上にある顔を基準に必要なら幅を縮め、顔全体＋余白が見える負のYで停止し3秒保持する。Zoomは最大面積の顔を基準にcover切抜きと中心を調整。完了条件: 顔近接・上端の顔・浮動小数点境界で顔の上下が欠けず、各設定OFFで通常動作に戻る。
- [ ] **M25 見えている前景から背景を更新する。** 元写真先頭の静的複製を、移動・クリップ・スロット交換・フェードを反映した前景採取へ置換する。背景自身・オーバーレイを採取に含めない。長辺160px、最大8fps、透明余白の最近傍色補完、Gaussian sigma=7、前回と50%混合を基準とする。完了条件: 赤青の上下分割写真のPan、左右色違いのscroll、Gallery1枚交換で背景色が実際の表示部分に追従する。
- [ ] **M26 背景処理の負荷と寿命を管理する。** UI外で画像処理し、実行中は後続ジョブを積まない。ユーザー一時停止・遮蔽・スリープで更新停止、scene破棄／終了でキャンセル。完了条件: 一時停止中と旧sceneの更新回数が増えず、全画面の高解像度blurを毎フレーム生成しない。失敗時は最後の背景または単色へ退避する。

## P1：常駐・デスクトップ統合

- [ ] **M27 一時停止と単調時計を導入する。** ユーザー停止理由・スリープ・遮蔽を独立状態で持ち、再生時間・Pan/Zoom・フェード・Gallery交換・背景を同時に凍結する。Date差分は時計変更やスリープで進捗が飛び得る。完了条件: メニュー／設定画面から停止と再開ができ、時計変更・スリープの経過を再生時間へ加算しない。Windows: `AnimationScheduler` / `TransitionController`。
- [ ] **M28 画面変更通知と健全性確認を追加する。** 保存IDに対応するNSScreenを再取得し、座標・解像度・倍率変更を反映。約15秒の確認でウィンドウ・背面順序を検証／復旧する。完了条件: 負座標・抜差し・同じ画面の再接続・倍率変更で別画面へ勝手に移らない。ウィンドウ消失と停止要求を区別する。
- [ ] **M29 スリープ／復帰・遮蔽を処理する。** OS通知を購読し、対象画面を覆う前景アプリで単体版の再生を休止。必要な権限と未許可時の扱いを明確にする。完了条件: 復帰時に画面とウィンドウを再検証し、他画面が覆われただけでは休止しない。複数ウィンドウ合計の遮蔽検出はWindowsにもないので必須にしない。
- [ ] **M30 Dock／Menu Barの扱いを実機で確定する。** Windowsの対象画面だけのタスクバー非表示をmacOSの同等仕様へ置換できるか、背面表示・通常アプリとの共存と併せて検証する。全画面化・アプリ全体設定の単純な流用で同等と見なさない。完了条件: 対象画面だけに限定できる範囲とOS制約を記録し、可能な制御は設定化、停止／スリープ／遮蔽／終了／異常終了時の復元を確認。対応できない範囲は明示した代替仕様にする。
- [ ] **M31 Spaces・Mission Control・デスクトップ表示を受け入れ確認する。** `.desktopWindow`、`.canJoinAllSpaces`、`.stationary`、`.ignoresCycle`、マウス透過は実装済み。完了条件: 実際の合成画面で写真が見え、デスクトップアイコン・クリック・通常アプリ・フルスクリーン・Spaces移動・Mission Control・「デスクトップを表示」と共存する。View内キャプチャだけで合格にしない。

## P2：設定・起動・診断・配布

- [ ] **M32 ドラフト・適用済み・保存済みの設定を分離する。** フォルダと画面も含め、保存／閉じる時の未保存値の扱いを揃える。再生中は停止→設定／一覧更新→再開を一連の操作にする。完了条件: 再帰設定変更後の「保存して表示開始」が新しい走査結果を使用。複数設定ウィンドウでドラフトが競合しない。Windows: `SettingsManager.Clone` / `ApplyAsync`。
- [ ] **M33 数値・色・スキーマを検証する。** 既存の範囲clampに加え、NaN／Infinity、無効背景色を扱う。Codable合成デコードはキー欠落で全設定の復元に失敗し得るため、追加項目は既定値で補完する。完了条件: 旧設定の欠落キー・不正値・型不一致で無言の全初期化にならず、保存前に具体的なエラーを表示。モード検証はM05と共通化する。
- [ ] **M34 永続化の破損復旧と移行を整える。** Windowsの原子的保存・破損コピー退避・警告を同等化する。Application Support内の `settings.json` に統一する場合は現UserDefaults・複数／旧単一ブックマークを一度だけ移行。ファイル形式の一致自体は機能パリティの条件にしない。完了条件: 書込み失敗・中断・破損で最後の有効設定とフォルダ権限を失わず、復旧内容をユーザーが確認できる。
- [ ] **M35 ログと診断状態を追加する。** 約2MBで1世代ローテーション。走査・デコード・設定・表示復旧の失敗を記録する。UI／メニューに現在モード・画面・写真数・一時停止理由・未接続・再試行を表示。完了条件: 無限spinner・再生中のまま無表示などが残らず、エラーの原因を追える。ログ出力失敗で再生を壊さない。
- [ ] **M36 ログイン起動と設定画面の表示規則を追加する。** macOSログイン項目として自動起動を設定し、OS側の登録状態も確認する。通常起動は設定を表示、登録済みのログイン起動はメニュー常駐、未設定の初回は設定を開く。完了条件: 自動起動ON/OFFと起動時再生ON/OFFを独立に検証。Windowsの初回はMonitorId未設定で自動再生しない点も再現する。
- [ ] **M37 重複起動・再表示・終了経路を検証／整備する。** 現状は明示的な単一起動／reopen処理がなく `WindowGroup` で設定画面を追加できる。完了条件: 2回目の通常起動で二重再生せず既存設定を表示し、ウィンドウを閉じてもメニューと再生を継続。通常終了・Dockからの終了・バックグラウンド処理失敗時もTask／scope／壁表示を解放する。Windowsは重複起動時に案内ダイアログを出すだけなので「前面へ出す」はmacOS側の改善要件。
- [ ] **M38 macOSのビルド・対応環境・配布手順を明文化する。** 現projectはmacOS 27.0、Swift 5モード、App Sandbox＋選択ファイルreadonly。対応OS／CPUを決めてReleaseビルド・権限・署名方法・起動手順をREADMEへ追加し、必要な実行／テストスクリプトを用意する。Metal描画は計画上の方針で、現実装はSwiftUI＋AppKit。Metal化をWindowsパリティの必須条件にはせず、性能計測と将来の同期要件で判断する。

## 回帰テストと受け入れ

- [ ] **T01 本番経路のテストを追加する。** 未接続のSelector単体テストだけでM07を完了にしない。M01〜M06の画面復元・Next・走査競合・空ライブラリ・無効モード・ブックマーク復旧を再現する。ユーザーのUserDefaults／写真／壁表示を使用しない検証プロファイルを用意する。
- [ ] **T02 Windowsの期待値を共通fixtureへまとめる。** `CompositionEngine` / `MotionEngine` / `PhotoSelector` の幾何・適格性・グループ重み・履歴・連続抑制をC#／Swiftで検証。固定seedで決定性を確認し、重み統計は連続抑制で名目割合から変わる点を許容する。5モードの位置・速度・時間・フェード・gallery差替え／流入をカバーする。
- [ ] **T03 画像・保存・監視・寿命を検証する。** 全EXIF方向の画素、形式別デコード、顔停止とZoom、キャッシュ更新／予算、破損・削除・巨大画像、設定欠落／破損、再帰・監視、pause中と破棄後の処理停止を確認。Windowsの実画像／ambient／retryテスト相当を含める。
- [ ] **T04 UIテストを実操作とassertionがある内容へ置換する。** 現在はテンプレートの起動と起動時間計測だけ。保存検証、ドラフト、開始／一時停止／次／停止、メニューから再表示、未接続・エラー状態を専用プロファイルで検証する。
- [ ] **T05 Swift concurrencyの警告を解消する。** 今回のテスト用ビルドで `PhotoAsset` のプロパティ／Equatable、`PhotoSelector` のactor隔離に関する警告を確認。UIのMainActorと純粋計画／Sendableデータの境界を整理し、テストの実行actorも明示。Swift 6モードでエラーになる警告を残さない。
- [ ] **T06 macOS実機で受け入れを行う。** 複数画面・負座標・Retina・超横長・実写真全件・顔・背景追従・画面抜差し・Spaces・スリープ・異常終了・8時間以上の連続運転を検証。CPU/GPU・キャッシュ・プロセスメモリ・描画の滑らかさを計測。Windows/macOS比較は同じ画像／物理viewport／設定／時刻の計画で行い、OS合成画面の確認と幾何fixture合格を区別する。

## 今回の検証結果

### ビルド

Xcode 27.0（27A266a）、macOS arm64で以下を実行し、**TEST BUILD SUCCEEDED** を確認した。Swift Testingの12ケースとUIテストのソースはコンパイル対象。テスト本体やアプリは起動しておらず、12ケースPASSとは判定していない。テスト内にactor隔離の警告が残る（T05）。

```sh
xcodebuild build-for-testing \
  -project macos/DynamicPhotoWall.xcodeproj \
  -scheme DynamicPhotoWall \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath artifacts/macos-audit/DerivedData \
  -skip-testing:DynamicPhotoWallUITests \
  CODE_SIGNING_ALLOWED=NO
```

最初の制限内ビルドはSwiftマクロの `sandbox_apply: Operation not permitted` で失敗した。同じコマンドを制限外で再実行して成功。これは製品のコンパイル不具合とは分けて扱う。実行ログはローカルの `artifacts/macos-audit/build.log` に保存（Git対象外）。

### アプリを起動しない計画処理の再現

実装の `PhotoAsset.swift` / `WallSettings.swift` / `WallScene.swift` をそのままSwift CLIへコンパイルし、1920×1080、seed=42で確認した。確認コードと出力は `artifacts/macos-audit/main.swift` / `planner-probe.txt`（Git対象外）。

| 入力／確認内容 | 観測結果 | 対応 |
|---|---|---|
| 全5モードOFF、横写真7枚 | Gallery1枚を返す | M05 |
| Zoomのみ、ランダムOFF、パス0.jpg〜6.jpgの7枚、index 0〜6 | 7回とも0.jpg。`index×7 mod 7` が常に0 | M07 |
| GalleryとZoomが適格、既定重み、横写真7枚、1000シーン | 同じモード3連続の窓が323か所 | M09 |
| 縦PanとZoomが適格、横PanはONだが不適格、Gallery群OFF、横写真7枚＋縦写真1枚、10000シーン | 縦Pan比率46.4%。候補抽選前の重みが35ではなく17.5になる。Windowsの連続抑制適用前の名目比率は35/55≒63.6% | M09 |
| Zoomのみ、elapsed=136秒（45秒×3＋1）→最初の手動Next相当のstartingIndex=1で再生成 | 現在scene 3 → scene 1へ戻る。実際のNextは加えてseedも変わる | M02 |

画面IDの上書き・走査競合・ブックマーク喪失・OS統合の指摘はソース経路からの判断であり、今回ユーザー設定を使った再現は行っていない。Windows WPF実行テストもmacOSでは実施していない。過去のWindows実機結果は [TEST-RESULTS](../windows/docs/TEST-RESULTS.md) を参照し、今回再実行済みとは扱わない。

## 既存TODOから修正した判断とパリティの境界

- 「全モードが `galleryMinSeconds` 固定」は現コードと一致しない。現在はPan距離÷速度、ZoomSeconds、Galleryの長寿命時間を使用する。不足は横Gallery速度・時間、顔保持、Retina、時計／切替である。
- 「縦Pan最短5秒」は現在のWindows実装とも異なる。Windowsも移動がある場合 `max(0.1, 距離/速度)`、移動ゼロの場合5秒。macOSの通常縦Panはこの基本式と一致しているため、この点を未実装としない。
- `PhotoSelector` の履歴・逐次・小規模緩和は実装と3テストがある。不足は本番経路への接続。EXIF寸法／ImageIO向き補正、URL一致の重複排除、モード別時間も一から作り直す項目ではない。
- WindowsのGalleryは固定の永久シーンではなく `max(90, maxSeconds×2)`、横Galleryも `max(120, maxSeconds×3)` で次構成へ進む。必要なのはそのscene継続中の独立交換と流入である。
- WindowsもZoom適格性には拡大上限を適用せず `Aspect >= 1` を使用する。この上限を新たに必須化しない。
- Windowsの `faces.json` は保存時のスナップショットを10,000件に制限する実装。メモリ内の厳密な上限とは区別する。
- Dock／Menu Barの対象画面限定制御はOS同等性の調査・受け入れが必要。「100%」と断定せず、可能な動作と制約を記録する。
- Windowsにも、ケーブル抜差し・混在DPI・実際のExplorer強制再起動・長時間稼働など未完了の手動確認がある。Windowsの存在するコードと実機検証済み範囲を混同しない。
- 2台3画面同期、LANペアリング、写真ID照合、配置ドラッグ、Windowsの複数画面表示、設定／履歴同期は両版の今後の機能であり、このTODOの不足には含めない。[クロスプラットフォーム計画](../docs/CROSS-PLATFORM-WALL-PLAN.md) の別フェーズで扱う。

推奨順序: **M01〜M06＋T01 → M07〜M17 → M18〜M31 → M32〜M38 → T02〜T06の受け入れ完了**。回帰テストは対応する実装と同時に追加する。

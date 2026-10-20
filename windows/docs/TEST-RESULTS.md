# 実施した検証

## 2026-10-20 — 共有描画の4項目をWPF内で置き換え

出力のVisualBrushを保持Drawingの直接描画へ、不透明背景2枚＋暗色層を低解像度での1枚合成へ置き換えた。写真デコード幅を表示寸法・最大倍率・出力サイズに合わせ、静止／非表示区間の写真評価を省く。透明背景のsource-overとローカル再生は維持する。Releaseビルド警告・エラー0、Windows単体51ケースとネットワーク26ケース／241 assertions成功。680出力のoffscreen比較は最大差2/255。PNG／WebP全8方向、出力要素を保持した描画更新とGallery継続も検証した。

100件中1件表示の600更新で、静止写真の評価60,000→0回、動作中は60,000→600回。背景のCPU合成・書き込みは増える。手動再起動した`799d570`を90サンプル×2区間観測し、アプリGPU平均18.67→5.14%、CPU平均1.46→0.92%を記録。ユーザーは表示の違和感なしと報告した。約11時間離れた固定シーンでない比較なので、確定した改善率や長時間のメモリー削減の証明とはしない。[条件・全結果・未測定事項](SHARED-RENDERING-TRIAL-2026-10-20.md)を参照。生データは`artifacts/windows/rendering-four/`と同資料記載のGPU計測ディレクトリ。今回の結果追記はドキュメントのみで、ビルド・テストの再実行や配布物の再発行は行っていない。

## 2026-10-20 — GPU観測と共有背景の同一サンプル省略

通常運転のReleaseをGUI操作・設定変更なしに90秒観測。アプリGPU平均17.68%／p95 23.19%／最大24.12%、DWM平均1.56%。同一PNGの凍結画像共有と、隣接する同一不透明画像の安定表示を候補実装した。GUIなしの262時点の旧表示比較は最大差1/255、半透明のみの反復は全画素一致。600更新の不透明度変更通知610→0、2面の同一PNG共有・色補正1回を確認。Windows単体49ケース成功、Releaseビルド警告・エラー0。タイマー停止と最終worker公開の間の既存テストの待機競合も修正した。[実測環境・生データ・候補と未測定事項](GPU-AUDIT-2026-10-20.md)を参照。

候補`d563da0`の配布EXE・ZIP・チェックサムを更新し、依存読み込み診断・ZIPハッシュ・製品バージョンを確認。ユーザーが手動で再起動したPID 43588を90サンプル×2区間観測し、GPU平均18.91%／18.57%、合計180サンプル平均18.74%を記録。通常再生全体のGPU低下は確認できなかった。保存設定・表示サイズは同一だがシーンとキャッシュ年齢は異なるため、性能後退の因果も未確定。PR #6はドラフト、Issue #2はopenを維持する。今回の追記はドキュメントのみで、計測後のビルド・単体テストの再実行は行っていない。

## 2026-10-20 — 共有背景の最終時刻の丸め誤差

`Invalid ambient frame`を旧実装のGUIなし回帰で再現。`duration * index / (count - 1)`の最終サンプルが終了時刻を1 ULP超え、共有計画の厳密な検証に落ちていた。交換間隔5〜10秒・fade 1.2秒の実`GalleryTimeline`でも256 seed中4つに該当する終了値を確認。Macと同じく比率を先に計算し、終端を終了値と完全一致させた。受信時刻やPNG容量の検証条件は維持し、例外には時刻・終了値・PNG bytesを追加した。

1／3／4面で2,416枚の背景フレームを生成し、端点・順序・JSON往復と、1 ULP超過・NaN・負の時刻・容量超過の拒否が成功。Windows単体48ケース、ネットワーク26ケース／241 assertions成功。ビルドは警告・エラー0。ログは`artifacts/windows/ambient-frame-timing/`、[原因と修正範囲](RENDERING-PERFORMANCE.md#2026-10-20の共有背景フレーム再試行の原因調査)を参照。過去ログには数値がなく11件すべての個別原因は未確定。稼働中の通常アプリでの修正版の再観測は別途行う。

## 2026-10-20 — Issue #2候補の長時間表示確認

ユーザーの依頼で`ca71363`のRelease EXE・ZIP・チェックサムを更新し、製品バージョン・ZIP内EXEの一致・依存読み込み診断を確認した。ユーザーは起動直後と約6時間の運転後に表示の違和感がないと報告。07:50にも同じPIDと候補版の起動から約8.42時間の稼働を確認した。観測時の保存設定はオンラインGallery・背景ONで、ローカル背景の最適化の全条件検証とは区別する。

起動後の標準ログには`Invalid ambient frame`による共有計画再試行が11件あり、無エラーとは扱わない。原因条件と影響は未確定。PRはドラフトのまま、GPU・電力・提示フレームなどの未計測事項も保持する。[詳細と検証範囲](RENDERING-PERFORMANCE.md#2026-10-20のrelease起動長時間表示の確認)を参照。GUI操作や設定変更は行っていない。

## 2026-10-19 — Issue #2: 前景の変更と動作に応じた背景生成

専用ブランチでローカル背景の継続生成を停止し、色追従を保持画像の不透明度補間へ分離。GUIなしのWindows単体47ケース、相互TLSを含むネットワーク26ケース／241 assertions、共通fixture704、差分fixture472、Zoom構図5120 assertionsと背景色12ケースが成功。Releaseビルドは警告・エラー0。静止・動作・pause/resume・取消・処理中の世代変更・画面別Gallery交換・scroll・破棄と、旧経路との初回画像の一致を確認した。

1秒準備＋4秒測定、旧／新各3回の合成fixtureで、静止1面の背景取得32→0回、静止2面63.67→0回、写真1回交換32.33→1回を確認。CPUは1コア基準で静止1面24.74→0.26%、2面31.77→0.13%。動作中は生成を維持し、CPU平均の一部は微増したため改善を断定していない。GPU・電力・提示フレーム・実画面・端末間同期は未計測。[環境・全条件の結果・再現手順](RENDERING-PERFORMANCE.md)を参照。ログは`artifacts/windows/issue-2/`。通常アプリと配布用EXEの置き換え、GUI操作、ユーザー設定の変更は行っていない。

## 2026-10-19 — Gallery全体の再表示をやめ、個別交換を継続

`919e4fd`の修正は90／120秒ごとに写真を選び直して別Galleryへ切り替えるため、ユーザーの期待する「同じGalleryのまま画像の差し替えを続ける」動作に訂正した。確定済み計画の終端の写真・位置・大きさを次の予定へ渡し、静止Galleryは更新済みフラグと次の交換までの残り時間、スクロールは列の位置と速度を引き継ぐ。静止Galleryの計画境界は交換途中を避け、全端末ready後のcommitを前計画の終端に合わせる。表示中のCanvas・残る画像要素・デコード済み画像を保持し、全体フェードを行わない。Next・設定変更・別モードの切替は通常の新構成を維持する。

GUIなし回帰テストを強化。静止／スクロール×スパン／画面別の4条件で各100計画・仮想時計で各2時間以上、境目の写真・位置・大きさの一致、Canvasと残る画像要素の同一性、全体不透明度1、設定どおりの交換間隔、pause/resumeで境界時刻をずらして継続すること、明示的Nextと設定変更では新構成となること、追加した省略可能なwire項目の往復を確認した。

ReleaseコンパイルとGUIなし43ケースが警告・エラー0で成功（`artifacts/windows/gallery-continuous-slots/full/test-results.json`）。相互TLSを含むネットワーク26ケース／241 assertionsも成功（`artifacts/windows/gallery-continuous-slots/network-core/test-results.json`）。Swift側も同じ計画継続と表示面・デコード済み画像の保持へ修正しテストを追加したが、Macでのコンパイル・実行確認は未実施。GUI操作・画面撮影・実端末間の長時間表示は未実施。

Windowsの配布用単一EXEを`artifacts/windows/gallery-continuous-slots/publish/`へ発行し、`release/windows/win-x64/DynamicPhotoWall.exe`へ反映。発行元とのSHA-256一致を確認し、旧EXEは同検証ディレクトリ内の`previous-*/`へ退避した。起動中のアプリは保持しており、修正の適用には再起動が必要。起動先の変更・ルート直下への生成物追加はない。

## 2026-10-19 — 同期Galleryが一定時間後に停止する問題

同期再生の有限タイムラインにも同種Galleryの再当選抑止を適用していたため、静止Galleryのみ有効なら既定90秒、Scrolling Galleryのみなら120秒の後に更新が止まっていた。ネットワークの計画生成に限って`allowGalleryRepeat`を有効にし、同じモードでも次の共有計画を準備する。ローカルの再当選スキップと写真交換、Pan・Zoomの連続回避と80／20の系統ウェイトは維持する。Swift側にも同じ修正と回帰テストを追加した。

実際の`WindowsScenePlanner`と`SceneCoordinator`を使ったGUIなし回帰テストを追加。静止／スクロール×スパン／画面別の4条件で各100計画、仮想時計で各2時間以上を進め、毎回の写真交換・移動、画面別ルーティング、全端末ready前のcommit抑止と前計画の期限前の引き継ぎを検証した。修正前は2計画目で失敗（`artifacts/windows/gallery-continuation/baseline/test-results.json`）、修正後は成功。既存のモード抽選テストでローカルのスキップとPan・Zoomの連続回避も確認した。

ReleaseコンパイルとGUIなし43ケースが警告・エラー0で成功（`artifacts/windows/gallery-continuation/full/test-results.json`）。ネットワークは26ケース／241 assertions成功（`artifacts/windows/gallery-continuation/network-core-unrestricted/test-results.json`）。通常の制限環境ではTLS証明書の秘密鍵インポートが失敗したが、制限外での追試で相互TLSを含め全件成功した。Mac上の追加Swiftコードのコンパイル・テスト、実端末間の長時間表示、GUI自動操作は未実施。

Windowsの単一EXEを`artifacts/windows/gallery-continuation/publish/`へ発行し、`release/windows/win-x64/DynamicPhotoWall.exe`へ反映した。旧EXEは同検証ディレクトリ内の`previous-*/`へ退避し、発行元と反映先のSHA-256一致を確認。起動中のアプリの終了・再起動は行っていないため、新動作には再起動が必要。配布先・起動先は維持し、Macの配布物は更新していない。

## 2026-10-19 — Mac版Zoom修正の取り込みとWindows配布ビルド

remoteをfetchし、`1ad7078`・`f69936e`・`38eac2e`をmainへfast-forwardで取り込んだ。`38eac2e`に含まれるWindowsの`FaceMotionSafety`は、写真の中央配置を基準に顔保護に必要な分だけ補正し、顔を画面中央へ強制移動しない。ローカル描画とネットワーク共有計画が同じ修正を使う。

`Build.ps1 -Test`へ`ParityVerifier --zoom-framing`を追加。縦Panの旧テストは初期値0.96の余白を前提にしていたため、現行の初期値1.0による全幅表示と、明示した0.96の中央配置を別々に確認するよう修正した。製品のPan動作は変更していない。

最終の`windows/scripts/Build.ps1 -Test`は警告・エラー0で成功。Windowsの42ケース、ネットワーク26ケース／241 assertions（相互TLSを含む）、Zoom構図5120 assertionsがすべて成功した。追加のCLI照合も共通fixture704 assertions、OS差分fixture472 assertions、背景色12ケースが成功。ログは`artifacts/windows/mac-zoom-integration/`、単体結果は`artifacts/windows/smoke-data/test-results.json`と`artifacts/windows/network-core/test-results.json`。初回の発行ではNU1900警告と起動中EXEの置換拒否があったが、旧EXEを退避した最終実行では解消した。

配布EXEは`release/windows/win-x64/DynamicPhotoWall.exe`（87,447,690 bytes、SHA-256 `4024BCE26009C2DE4B44CF8A992BCBACF4E3134A16365AC7C2FCD78FB28C98B5`）。旧EXEは`artifacts/windows/mac-zoom-integration/previous/`へ退避し、起動中のプロセスは停止していない。新動作の反映にはアプリの再起動が必要。起動先・ショートカットは従来の配布パスを維持し、既存ZIPは再作成していない。ルート直下への生成物追加なし。GUI操作を伴う自動テストと実画面での知覚確認は実施していない。

## 2026-10-19 — オンライン中の継続的な細かい点滅

オンライン再生と配置プレビューが毎フレーム呼ぶ`EnsureZOrder`は、正しい配置でも各出力をアイコンの直後へ`SetWindowPos`で挿入していた。複数出力があるとフレームごとに兄弟HWNDの順序を入れ替える。`DesktopZOrder`で「アイコンより後、壁紙より前」を確認し、その範囲にある間はネイティブの順序変更を行わない。範囲から外れた出力だけを戻し、Explorerやほかの写真ウィンドウの相対順序は維持する。

実HWNDを使わない兄弟順序モデルで、4出力とプレビューの600フレーム中の順序変更が0回であること、壁紙の後ろ／アイコンの前への移動は各1回の修復で安定すること、壁紙ハンドル欠落と修復失敗を検証した。修正の条件分岐を外して旧動作に戻すと新規テストだけが失敗し、回帰を検出できることも確認した（`artifacts/windows/online-flicker/baseline/`）。

ReleaseコンパイルとGUIなし9ケースが成功。既存のモード切替・遠隔ピア離脱時の表示面保持、Gallery終端、背景補間、ネットワーク通知の応答性も含む。結果は`artifacts/windows/online-flicker/test-results.json`。NuGet脆弱性情報へ接続できないNU1900の警告が3件あり、コンパイルエラーはない。GUI操作・画面撮影は実施せず、実画面での点滅解消の知覚確認は残す。

単一EXEを`release/windows/win-x64/DynamicPhotoWall.exe`へ反映し、発行元とのSHA-256一致を確認した（`C3D5A8667CA0B3770F0624387BED4684DAF589C5AB13100900A0A7597FDD6B86`）。旧EXEは`artifacts/windows/online-flicker/previous/`へ退避。起動中のアプリは終了しておらず、修正の反映にはアプリの再起動が必要。起動先の変更とルート直下への生成物追加はない。

## 2026-10-19 — ピアの手動解除とギャラリーの更新

**承認機能復旧後の追試:** 通常権限で失敗したTLS試験を含めて承認済み環境で再実行し、ネットワーク26ケース／241 assertionsがすべて成功した。最新結果は`artifacts/windows/gallery-peer-build/network-core-unrestricted/test-results.json`。以下の25ケース成功・TLS失敗は追試前の記録である。

ReleaseコンパイルとGUIなし17ケースが成功。各画面でのPan中央配置、Gallery列の中央寄せ、初期待機5〜10秒、写真とgapが収まる空きへの追加、既存写真を保持するWPFスロット追加、更新・選択フラグによる一巡、同種Gallery再当選のスキップを検証した。既存の表示継続・Zoom・背景補間・応答性・トレイコマンドも含む。結果は`artifacts/windows/gallery-peer-build/test-results.json`。

ネットワーク試験は25ケース／237 assertions成功。送信停止中の手動解除、自動再接続・着信の抑止、ソース選択の保持、手動再接続を確認した。初期inventory送信に失敗した仮接続の除去漏れも修正し、ハートビート期限を待たずに除去される回帰試験を追加した。相互TLSの1ケースはWindowsの秘密鍵インポートで実行環境の制限により失敗。結果は`artifacts/windows/gallery-peer-build/network-core/test-results.json`。GUI操作・画面撮影は実施していない。

NuGetの脆弱性情報に接続できないNU1900の警告が3件。コンパイルエラーはない。Macの追加分のビルドと実機間の同期表示は未確認。

## 2026-10-19 — Windows通知領域の右クリックで終了する問題

00:22のWindowsイベントログと保存済みダンプを解析。`NotifyIcon.ShowContextMenu` → `ContextMenuStrip`のウィンドウ作成中にWinFormsの例外ダイアログへ入り、その`PictureBox`初期化が`FileNotFoundException`で失敗してプロセスが終了していた。最初にメニュー作成を失敗させた例外の詳細はダンプから取得できていない。

通知領域アイコンは`NotifyIcon`を維持し、右クリックメニューをWPFの`ContextMenu`へ変更。右ボタンを離したイベントからWPF Dispatcherへ処理を渡し、WinFormsのドロップダウンと例外ダイアログの経路を使わない。所有ウィンドウのないメニューを前面化してフォーカスし、終了時に閉じる。開始・一時停止／再開・次へ・停止・設定・終了の機能は維持する。

Releaseビルドは警告・エラー0。ウィンドウや通知アイコンを作らない新規テストで全コマンド、非同期開始、一時停止／再開の表示を確認し、既存の描画・応答性・Gallery・背景等を含む18ケースが成功した。結果は`artifacts/windows/tray-menu/test-results.json`、ダンプ解析は同ディレクトリの`*-analysis.txt`。GUI操作による右クリック・フォーカス・画面外クリックの実機確認は行っていない。

単一EXEを発行し、ユーザー承認を受けて起動中のアプリを終了してから`release/windows/win-x64/DynamicPhotoWall.exe`へ反映し、`--tray`で再起動した。87,439,492 bytes、SHA-256は`255A5F51C1C76CD929DCCA60A7EC6998D3C6FA6AB45B74FA31467CCC04E61B45`。旧EXEは`artifacts/windows/tray-menu/previous/`へ退避。起動スクリプトとショートカットの参照先は同じ配布パス。ルート直下への生成物追加なし。

## 2026-10-19 — Galleryの固定サイズ・共通交換時計、顔サイズと背景のちらつき

Galleryは横長グループで高さ、縦長グループで幅を固定し、交換時は隣の写真を移動・退場させる。長辺だけがグループを超える単写真は外周を切り取る。ローカルも共有計画も、画面別表示を含むグループ全体で交換時計を1つにし、フェード完了後の10〜30秒ごとに1枚交換する。旧初期値30〜60秒は移行する。ネットワークplacementの独立した入場／退場フェードで、隣の写真の再フェードを防ぐ。

全顔の外接矩形を実ディスプレイ1枚へ収める`FaceMotionSafety`を追加した。Zoomは開始・終了倍率を同率で下げ、縦横Panは画像サイズと停止位置を調整する。20pxを超える移動が残らないPanは候補から除外する。背景は0.8秒を基準にした時間平滑化と125msのクロスフェード、共有サンプルの画像ソース固定で急変を抑える。定常時の色彩補正は維持する。

Windows部品17ケースが成功（警告・エラー0）。追加7ケースで、Zoomの両方向・縦横グループの全顔が101時点で収まること、縦横Panの縮小とスキップ、固定した短辺・隣写真の除外・巨大単写真、複数画面の単一交換時計、共有wireでの独立フェードの往復、変更しない写真の不透明度、WPFスロット交換中も高さが変わらないことを確認した。背景は8Hz／60Hzでの応答一致、色の急変の抑制・定常色の回復、フェード途中の再目標設定、共有サンプル境界の連続性を合成画素とオブジェクト状態で調べた。既存の20枚・応答性・ミラー・表示継続・Zoom・80／20抽選も成功。

結果は`artifacts/windows/gallery-face/test-results.json`。ネットワーク25ケース／224 assertions（同ディレクトリの`network-core/`）、共通fixture704 assertions・OS差分fixture472 assertionsも成功。歴史的fixtureのraw motion／Gallery計算を保持し、新しい安全処理と固定配置は別部品で検証する。

Releaseの単一EXEを発行し、`release/windows/win-x64/DynamicPhotoWall.exe`を2026-10-19 00:09 JST版へ置換した。87,439,233 bytes、SHA-256は`8482F4C3B4C80D7D4A3013AAE569FC3286B85519760B9A65923B019B078896CC`で発行元と一致する。旧EXEは`artifacts/windows/package/previous/`へ退避し、起動中のアプリは停止していない。反映には再起動が必要。

GUI表示・スクリーンショット・描画キャプチャは行っていない。実画面でのちらつき解消と知覚確認は未実施。Macの配置・交換時計・顔サイズのSwift実装と回帰テストは追加済みで、ビルド・実行未確認。Mac背景の平滑化・色彩補正の残差分はhandoverに記録する。

## 2026-10-18 — 縦パン表示幅の初期値を1.0へ変更

Windows・Swift・共有再生設定の`panWidthFraction`の初期値を0.96から1.0へ変更し、非有限値の補正とUI表記も揃えた。保存済みの幅と顔を収める処理は維持する。GUI撮影は行わない。Macのビルド確認は未実施。

WindowsのReleaseビルドと既存部品10ケースが成功。モード適性・自動ミラー・共有設定の往復・80／20抽選・表示継続・背景色の回帰を確認した。結果は`artifacts/windows/pan-width-default/test-results.json`。

## 2026-10-18 — ギャラリー80／パン・ズーム20の2系統抽選

系統を先に選び、選択済み系統の中からモードを抽選する`ModeSelection`を追加。Windowsの通常／共有計画とSwiftの単画面／グループ／ネットワーク計画を同じ2系統にした。連続回避は系統内だけとし、ギャラリーが静止だけでも80%を保つ。設定UIは2項目。旧初期値45／35／20は80／20へ移行し、旧カスタムPan・Zoomは合算する。

Windows部品10ケース成功。新規テストで80%の境界、系統内の連続回避、候補不足・ウェイト0、旧保存値／共有値の移行を確認した。静止・スクロール両有効と静止のみで各5万回抽選し、どちらもギャラリー79.97%・パン／ズーム20.03%。動き系の3モードに偏りがないことも確認した。結果は`artifacts/windows/mode-weights/test-results.json`。GUI撮影・ウィンドウ表示は行っていない。Swiftの同等テストは追加済みで実行未確認。

ネットワーク25ケース／224 assertions、共通fixture704 assertions、OS差分fixture472 assertionsも成功。WindowsのReleaseコンパイル・単一EXE発行を確認した。ネットワーク結果は`artifacts/windows/mode-weights/network-core/`。

## 2026-10-18 — 動きを知覚しやすいズーム設定

ユーザー指定により初期値を45秒・1.08倍から30秒・1.25倍へ変更し、倍率の上限を1.15から1.5へ広げた。Windows・Swiftのモデルと入力表示、.NETの共有設定の初期値を揃えた。拡大／縮小と滑らかな加減速・顔優先の計算は維持する。保存済み設定は自動上書きしない。

Windows部品9ケースが成功。新しい初期値・不正値の補正・上限1.5倍、旧保存値20秒／1.08倍の保持、共有設定の往復、拡大／縮小の25%の変化、スパン／自動ミラーで30秒の完走・15秒で1.125倍・開始5秒以内の変化を確認した。既存の表示継続・背景色・応答性・Galleryテストも成功。結果は`artifacts/windows/zoom-motion/test-results.json`。GUI撮影・実画面の目視確認は行っていない。Swiftの同等テストは追加済みで実行未確認。

ネットワーク25ケース／224 assertions、旧設定を明示した共通fixture704 assertions・OS差分fixture472 assertionsも成功。WindowsのReleaseビルド・単一EXEの発行を確認した。ネットワーク結果は`artifacts/windows/zoom-motion/network-core/`。

## 2026-10-18 — 同期切り替え・孤立時の表示継続と背景の色彩

同期表示が構成ごとにデスクトップウィンドウを生成・再接続していた処理を修正。先読みは`SharedSceneBuilder`による表示ツリーの準備だけにし、ローカル画面が同じなら同じ出力を使う。遠隔ピア離脱で共通キャンバスの原点・幅が変わる場合も旧・新それぞれの座標で切り出す。旧ツリーと表示ビューを取り外さずに新表示を重ね、フェード後に解放する。孤立中の繰り返しもこの経路にし、最終Gallery写真を新表示まで保持する。

アンビエント色はぼかし後の色差を最大1.6倍・輝度を最大1.12倍へ補い、RGB範囲で制限して無彩色・色相・アルファを保つ。ローカルは時間補間前、同期表示は背景PNGのデコード時に一度だけ適用し、他OSが生成した背景にも効かせる。転送PNGへ補正を焼き込まない。

ReleaseビルドとWindows部品8ケース成功。5モード間25通りのツリー保持、画面の再利用判定、遠隔ピア離脱／復帰時の座標、スパン／同一写真ミラー、準備失敗時の表示保持、Gallery内部フェードと終端保持、繰り返し先頭の被覆、5モードの背景色の補正を検証した。結果は`artifacts/windows/scene-transitions/test-results.json`。GUIを表示せず、スクリーンショットや描画キャプチャをせず、オブジェクト状態と合成画像の画素だけを調べた。実画面でのブラックアウト解消・切断時の知覚確認は未実施。今回の表示寿命と色彩の実装修正はWindowsが対象。

## 2026-10-18 — 低画素写真の3モード自動ミラーと背景の端色

横Pan・縦Pan・Zoomで、グループ長辺方向の写真画素数が半分未満なら同じ写真を各接続画面へミラーする。向き補正後の横画素数／縦画素数を使い、ちょうど半分はスパンを保つ。各画面でもパンの許容倍率を超える場合はそのモードの候補から外す。共通fixture8ケース、3モード×横長／縦長4画面グループのコア選択とネットワーク計画、半分ちょうど・短辺を参照しない境界、EXIF回転、過大な拡大の拒否を確認した。

背景はローカルとネットワークで透明な余白の延長を共用し、ネットワーク生成の暗い下地とぼかしの透明端を除去した。装飾グラデーションを除去し、暗幕を約18%へ弱めた。257×19pxの細い合成色帯の余白延長、全5モードの背景サンプルの四隅・中央が不透明な写真色を保持することを画素データで確認した。

Windows部品5ケース（今回2ケースと既存の応答性2ケース・Gallery20枚）、共通fixture704 assertions、OS差分fixture472 assertions、Releaseビルドが成功。結果は`artifacts/windows/mirror-ambient/test-results.json`。GUI撮影・実機の目視確認は行っていない。Swiftにも同じ判定・背景暗幕と部品テストを追加したが、Macビルド・実行は未確認。

## 2026-10-18 — 再接続・写真同期時のUI待機を解消する修正

コードから、キャッシュI/OのロックをUIの枚数表示も取得していたこと、同期開始元のUIコンテキストへ定期処理が戻り得たこと、受信データごとに通常優先度の画面更新と未取得写真のディスク検索を繰り返していたことを確認した。UI向け進捗をロック不要なスナップショットにし、同期開始・共有設定の適用をワーカーへ移した。通知は100ms・Background優先度で集約し、受信完了時にだけ次の写真を要求する。取得済みキャッシュと同一ソース設定を再利用し、設定・配置UIも差分だけ更新する。原データを使う時の認証とハッシュ検証は継続し、破損時は再取得する。

ネットワーク25ケース／224 assertions、Windows部品3ケース、Releaseビルドが成功。キャッシュ読込みを意図的に止めて転送ロックを保持しても進捗が読めること、10万件の通知が入力イベントを妨げないこと、再接続のカタログ反復で原データを復号しないこと、破損の検出・再要求、未取得検索1000回で追加I/OとUI通知が発生しないこと、既存のTLS・転送・切断・再接続を確認した。結果は`artifacts/windows/network-responsiveness/`。GUI撮影と実機の再接続中の手動操作確認は未実施。今回の修正対象はWindowsと共通.NET部品。

## 2026-10-18 — Galleryの最大枚数を20へ拡張

Windows・Macの入力表示と設定の上限を1〜20枚へ拡張し、共有再生設定の検証も揃えた。初期値5枚と既存の保存値は維持する。GUIを開かない追加部品テストで、1／5／12／20枚の選択・重複除外・画面内配置、写真不足、設定の往復、共有設定の往復と21枚の拒否、横4画面15360×1080で20枚を含む共有表示計画を確認した。Releaseビルド・部品テストが成功。結果は`artifacts/windows/gallery-capacity/`。GUI撮影は行っていない。Macにも同等テストを追加したが実行は未確認。

## 2026-10-18 — 保存済み画面と接続確認の区別

ネットワーク画面一覧・配置プレビューは接続確認できた画面だけを初期表示し、「未接続の画面も表示」と接続状態の列を追加した。保存済みの旧端末・旧モニター、LAN発見だけの候補を接続中としない。切断・再接続では保存済み配置を変更せず、オンライン終了時は一時表示をクリアする。開始時に見つかった新しいローカル画面も保持中の一覧へ追加する。ネットワーク・配置21ケース／177 assertionsとWindows Releaseビルドが成功。結果は`artifacts/windows/display-presence/network-core/`。GUI撮影・画像確認とMacのビルドは実施していない。

## 2026-10-18 — 画面配置のスナップ

ネットワーク配置へ隣接画面のスナップを追加し、通常配置も同じ純粋な幾何部品へ統一した。許容距離はプレビュー上12px。グループを問わない端・中央の整列、遠い行・列の除外、ドラッグ中の座標原点・縮尺維持を実装した。共通fixture15パターンと候補順の反転を含むネットワーク・配置20ケース／171 assertions、Windows Releaseビルドが成功。結果は`artifacts/windows/display-snapping/network-core/`。今回の検証ではGUIの撮影・画像確認は実施していない。Swiftの同じfixtureのテストは追加済みだがMac実行は未確認。

## 2026-10-18 — ディスプレイ名の共有表示

画面グルーピング・使用画面・配置プレビューを「ホスト名 / ディスプレイ名」で識別できるよう変更した。OSから取得した名前をinventoryと共有状態に含め、旧保存データに名前を補完する。ネットワーク19ケース／141 assertions、Windows既存22ケースと設定画面全8ページの描画確認が成功。結果は`artifacts/windows/display-names/`。3ピアの名前共有、進行役交代・再接続後の保持、名前がなくても内部IDを出さない表示、長すぎる名前の拒否を確認した。Swiftの同契約・部品テストを追加したがMacでの実行は未確認。

## 2026-10-18 — 分離したネットワーク基盤とWindowsアダプター

ネットワーク18ケース／131 assertionsとWindows22ケースが成功。TLS loopback、3ピアの設定・転送・交代・再接続、2壁の4ピアへの合流とpause引継ぎ、予約テスト表示、容量制限、DPAPI、5表示モードの計画と時刻からの描画・切出しを含む。共通fixture704 assertions・OS差分fixture472 assertionsも成功。結果は`artifacts/windows/network-core/`と`artifacts/windows/smoke-data/`。設定UI全8ページの描画結果は`artifacts/windows/settings-ui/`とsmoke-dataのPNG。Macのビルドと両OS実機の同期精度は未実施で、自動試験の合格には含めない。[構成と確認手順](../../docs/NETWORK-CORE.md)を参照。

## 2026-10-17 — 顔矩形キャッシュによるGalleryの余白改善

- 各写真の許容位置の共通範囲を求め、通常Gap・共通の高さと基準線を保った写真列を優先する。無理な場合は従来の写真別配置・必要時の縮小を維持する。顔の包含・非重複・写真全体の表示を保つ。
- ランダムのスパンGalleryで顔回避に伴う縮小・追加Gap・余白の偏りを評価し、キャッシュ済みの最大12候補から0.02以上改善する写真を採用する。開始時は最大2回、更新時は交換するslotだけ。試算はUIスレッド外で行い、候補を追加解析しない。
- コアで通常Gapと基準線、改善する矩形の選択、改善なし、未解析と顔なしの区別、同じパスの除外、12候補上限、取消、表示中除外・直近履歴・名前順を確認した。
- 合成写真3枚と保存済み顔キャッシュを用いた実2画面セッションで、名前順は元の選択、ランダム時は改善する選択となることを確認。開始後の定期交換・非重複・顔の包含・pause／Next／停止、サイズ／更新日時が変わったキャッシュの無効化も確認した。顔矩形は合成データで、検出器の精度検証とは分けている。
- 最終のコア20項目と統合5項目（余白改善、既存画面別描画、背景、復旧、自動ミラー／Gallery再配置）が成功。共通fixture704 assertionsも成功。Releaseビルド・単一EXE発行はエラー0、既知のNU1900情報取得警告あり。MacへのD09引き継ぎを更新した。

結果: `artifacts/windows/gallery-fill-final/test-results.json`、`gallery-fill-metrics.json`、`gallery-fill-{before,after}.png`。既存回帰は`artifacts/windows/gallery-fill-regression/test-results.json`。配置の比較PNGを確認した。候補不足・未解析が多い場合は従来配置へ戻るため、すべての写真で余白をなくせる保証はない。写真の切り取り、YOLO化、他部位検出、全件の事前解析は追加していない。実機のfps測定・混在DPI・ケーブル抜差し・長時間運転は未実施。

```powershell
.\.tools\dotnet\dotnet.exe windows/tests/DynamicPhotoWall.Tests/bin/Release/net10.0-windows10.0.19041.0/DynamicPhotoWall.Tests.dll artifacts/windows/gallery-fill-final --scan-only --gallery-fill
.\.tools\dotnet\dotnet.exe windows/tests/DynamicPhotoWall.Tests/bin/Release/net10.0-windows10.0.19041.0/DynamicPhotoWall.Tests.dll artifacts/windows/gallery-fill-regression --per-display-modes --mirror-gallery --ambient --retry-recovery
```

## 2026-10-17 — 小画像の縦Pan自動ミラーとGalleryの滑らかな再配置

- スパン幅への必要拡大率が上限を超え、同じ写真が全接続画面の縦Pan適性を満たす場合だけ、自動ミラーへ切り替える。画面別チェックや設定ファイルを書き換えない。大きな写真はスパン、手動の画面別表示は別々の写真という動作を維持する。
- コアで異なる画面寸法、拡大率の境界、EXIF補正後の幅、候補除外、単独画面、未接続領域、設定した表示幅の違いを検証した。
- 実際の2画面セッションで同じ写真と同じbitmapの共有、各画面の物理寸法、pause／Next、上限変更によるスパン復帰、手動個別表示、1台未接続、停止を確認した。写真は専用フォルダーへ生成し、設定・タスクバーを通常版と分離した。
- Galleryは安全な最終配置へ既存slotを移動・伸縮し、交換写真だけフェードする。アニメーション中の顔の境界通過を許容する。WPFで中間位置を通ること、slotを作り直さないこと、pause中の固定、完了と取消後の最終値確定・clock解除を検証した。前・途中・後のPNGも確認した。初回の統合試験はWPFのclock解除が反映される前の検査で失敗したため、反映を待つ検査へ修正して再実行した。
- 最終のコア19項目と、画面別モード・背景・復旧・自動ミラー／Gallery再配置の統合4項目が成功。共通fixtureの704 assertionsも成功。Releaseビルド・単一EXEの発行はエラー0、既知のNU1900情報取得警告あり。
- Macアプリ自体は変更・実行せず、D08の自動ミラーとD07の「Gallery移動中は境界通過可」をhandoverへ反映した。実機でのフレームレート測定・混在DPI・ケーブル抜差し・長時間運転は未実施。

結果: `artifacts/windows/mirror-gallery-final/test-results.json`、`gallery-{before,moving,after}.png`、`mirror-display-{0,1}.png`、`mirror-state.json`。既存回帰は`artifacts/windows/mirror-gallery-regression/test-results.json`。

```powershell
.\.tools\dotnet\dotnet.exe windows/tests/DynamicPhotoWall.Tests/bin/Release/net10.0-windows10.0.19041.0/DynamicPhotoWall.Tests.dll artifacts/windows/mirror-gallery-final --scan-only --mirror-gallery
.\.tools\dotnet\dotnet.exe windows/tests/DynamicPhotoWall.Tests/bin/Release/net10.0-windows10.0.19041.0/DynamicPhotoWall.Tests.dll artifacts/windows/mirror-gallery-regression --per-display-modes --ambient --retry-recovery
```

## 2026-10-17 — モード別の画面単位表示と、スパン中の顔境界回避

- 全5モードに「ディスプレイごとに表示」を追加。旧設定はスパンのまま、画面別モードは各画面の物理解像度で適性・写真・配置・背景を作り、モード・pause・Next・切替時刻をグループで共有する。
- 「スパン時に顔が画面の境目に重ならないよう配置」を初期値ONで追加。Gallery・縦Panは全検出顔を接続画面内へ寄せ、必要時だけ縮小。Galleryの再配置は安全な配置同士のフェードにする。横スクロール・横Pan・Zoomは従来の幾何を維持する。
- 5種類の画面配置（左右・上下・隙間・高さ違い・1画面未接続）、4種類の顔矩形、停止／方向のON/OFFによる縦Pan80通り、Gap3種類を含むGallery240通りで、顔の包含・移動中の境界回避・非重複を検証。位置調整でサイズを維持できる場合、巨大Gap、未検出、設定OFFも確認。
- 画面ごとの全5モードの画素、Gallery交換、scroll流入、背景pause／破棄、同じ配置座標でも画面IDで別の写真が出ること、スパンへの切替を確認。設定ウィンドウの5チェックと境界設定を保存・再読込し、1040×820と920×700をPNG確認。
- 実セッションで全モードを切り替え、各画面の寸法・モード・写真・共有pause／Next・停止と切断時の領域保持を確認。公開fixtureのastronaut.pngをWindows標準検出へ通し、他の顔設定をOFFにしたスパンGalleryでも顔を準備し、実際の配置が画面内へ収まることを確認。画面を1台切断した構成でも残った画面へ顔を配置する。
- 最終のコア18項目＋画面別描画／顔検出の統合1項目が成功。既存の背景・復旧・画面グループ・設定UI・テスト表示・グループ削除も成功。複数画面のタスクバー復元だけは起動中の通常版との干渉で最初に不一致となり、通常版を終了した単独試験では成功した。
- C#共通fixtureの704 assertionsは既存の期待値を維持して成功。Releaseの単一EXEを発行し、共通release先へ配置。NU1900の情報取得警告あり、コンパイルエラー0。Macアプリの変更・検証は行わず、D06/D07としてhandoverへ仕様を追加した。

結果: `artifacts/windows/span-face-complete/test-results.json`、`mode-routing-states.json`、`mode-checkboxes-{1040,920}.png`、`detected-face-spanning.png`。上下配置の短い縦Panで実際の描画位置も確認した追加統合は`artifacts/windows/span-face-vertical-frame/`。既存回帰は`artifacts/windows/span-face-final/`、タスクバーの単独再検証は`artifacts/windows/mode-routing-clean-multi/`。実機の提示検査は露出していたDISPLAY3の9/9点が成功し、DISPLAY1/2は他アプリに覆われていた。混在DPI・実ケーブル抜差し・長時間運転は従来どおり残る。顔未検出の写真まで保護する保証はない。

```powershell
.\.tools\dotnet\dotnet.exe windows/tests/DynamicPhotoWall.Tests/bin/Release/net10.0-windows10.0.19041.0/DynamicPhotoWall.Tests.dll artifacts/windows/span-face-complete --per-display-modes
```

## 2026-10-17 — 画面グループの削除

- 一覧カードごとに「削除」ボタンを追加。空／所属あり／最後のグループを削除でき、所属画面は未選択の画面も含め「独立して表示」へ戻す。画面の選択・配置・タスクバー設定は維持する。
- 再検出時は編集済みのグループ一覧を保持し、保存済みの削除前の名前を再追加しない。全削除後も再読込で「グループ1」を自動生成しない。
- 実際の削除ボタン・割り当て選択肢・一覧数・保存ボタンを操作し、ドラフトだけの変更、保存しない場合の元データ保持、保存・再読込、番号の再利用を確認した。
- Release発行とコア16項目が成功。最終の設定UI・既存テストパターン・グループ削除の統合3項目も成功。通常／最小サイズの設定ページ、全削除後の画面をPNGで確認。ビルドはエラー0、NU1900の情報取得警告あり。
- 最初のテストパターン統合試験は制限環境からExplorerのProgmanを取得できず失敗。対話デスクトップ側で再実行し、最終3項目はすべて成功した。削除試験自体は両環境で成功。

結果: `artifacts/windows/group-deletion-final/test-results.json`、`settings-page-3-{1040,920}.png`、`groups-deleted.png`。Mac移植にも同じ削除・再検出・保存の条件を[handover](../../macos/WINDOWS_DELTA_HANDOVER.md)へ追記した。

```powershell
.\.tools\dotnet\dotnet.exe windows/tests/DynamicPhotoWall.Tests/bin/Release/net10.0-windows10.0.19041.0/DynamicPhotoWall.Tests.dll artifacts/windows/group-deletion-final --scan-only --settings-ui --test-pattern-toggle --group-deletion
```

## 2026-10-17 — 両OSのreleaseディレクトリ統一

- Windows配布先を`release/windows/win-x64/`へ変更し、起動スクリプト・ショートカットを同じパスへ統一。ショートカットのターゲットと作業ディレクトリを実ファイルから確認。
- `Build.ps1 -Test`の発行とコア16項目が成功。検証結果は`artifacts/windows/smoke-data/`へ出力。エラー0、NuGetの脆弱性情報へ接続できないNU1900警告あり。
- ビルド前後でルート直下のファイルが増えないことを確認。既存のルートEXE・ショートカットは`artifacts/windows/legacy-root/`へ退避し、ルートは管理対象のドキュメント・設定ファイルだけになった。
- 診断`--probe`の既定レポートもデータディレクトリへ変更し、ルート直下の一時JSON生成を避ける。アプリのReleaseコンパイルで確認。
- Macは配布ZIP／DMGを`release/macos/arm64/`、archive・DerivedData・stagingを`artifacts/macos/package/`、検証結果を`artifacts/macos/verification/`へ分離。Git Bashの`bash -n`で両スクリプトの構文が成功。Mac実機での署名・archive・DMG生成は未実行で、handoverに確認条件を追加。

結果: `artifacts/windows/release-layout/result.json`。[共通規則](../../docs/GENERATED-FILES.md)と[Mac向け引き継ぎ](../../macos/WINDOWS_DELTA_HANDOVER.md)を参照。以下の過去記録の旧出力パスは当時の証跡として保持する。

## 2026-10-17 — 最新Mac版の取り込みと共通fixture互換性

- Mac側の`7508db8`までの更新を取り込み、Windowsの追加機能を統合。Macの既存実装・公開記録を保持した。
- 新設定`FaceAwarePanDirection`の既定値ONにより、旧共通fixtureは`HorizontalPan-4: field 2`で不一致となった。既存36ケースと生成器へ方向設定OFFを明示し、旧動作の期待座標を維持した。製品の既定値はONのまま。
- C# verifierは36 motion／eligibilityケース、Gallery配置9ケース、Selector2ケース、計704 assertionsが成功。Macアプリ・SwiftテストはWindows上では実行していない。方向ONのMac回帰追加は[引き継ぎ資料](../../macos/WINDOWS_DELTA_HANDOVER.md)で依頼する。

```powershell
.\.tools\dotnet\dotnet.exe run --project tests/ParityVerifier -- macos/DynamicPhotoWallTests/Fixtures/WindowsParity.json
```

## 2026-10-17 — 一般・タスクバー移動・グループ一覧・即時テスト表示

- 「表示設定」を「一般」へ改名し、タスクバー設定を使用ディスプレイへ移動。
- グループ一覧で総数・所属画面・未割り当てを表示。「グループを追加」の直後に一覧と数が更新され、未割り当てグループも保存・再読込できる。
- 上部のテストパターンボタンは「表示 → 表示停止 → 表示」と切り替わり、保存操作をせずにドラフトの配置で表示・停止する。写真未登録・通常再生中・一時停止中、独立した複数画面に対応する。
- プレビュー中に保存ファイルと通常設定を変更しないこと、終了後に以前の再生・一時停止状態を復元すること、未接続画面のプレビュー失敗時に写真再生を維持することを確認。通常の開始・停止によるプレビュー解除と、旧設定からテスト状態が自動復元されないことも確認。
- 通常・最小ウィンドウサイズの3ページ、および「表示停止」状態をPNGで確認。コア16項目、UI描画、ボタン操作の計18項目が成功。Releaseビルドはエラー0、NU1900の情報取得警告あり。

結果: `artifacts/settings-preview-final/test-results.json`、`settings-page-{1,2,3}-{1040,920}.png`、`test-pattern-button-visible.png`。再実行はテストランナーへ`--settings-ui --test-pattern-toggle`を指定する。テスト専用プロファイルを使用する。

## 2026-10-17 — 顔の反対側からパンを開始

- 縦パンは主な顔が上なら下から、下なら上から開始。横パンは左の顔なら右から、右の顔なら左から開始する。主な顔は面積が最大の検出領域とし、同面積では上・左の順で安定して選ぶ。
- 「動き」に方向選択のチェックボックスを追加し、初期値を有効にした。縦パンの顔位置停止・Zoomの顔フレーミングとは別に指定できる。横パンにも顔検出を追加。
- 上下・左右の顔、複数の顔、方向の乱数、停止設定の有効・無効を組み合わせて計算を確認。縦パンはどちらの向きでも距離÷速度で時間を決め、停止位置で顔全体が見えることを確認。未検出時・方向設定無効時は従来の動作を維持する。
- コア16項目が成功。実写真では3枚中3枚で顔を検出し、縦パンの顔位置停止、Zoom、動的背景、両Galleryの既存試験が成功。
- ライブラリー901枚の寸法・EXIF方向、2種類の顔領域、3画面比率、3モードの16,218通りで計算が成功。これは901枚すべての顔を検出したという意味ではない。
- Releaseビルドはエラー0。NuGetの脆弱性情報を取得できないNU1900警告あり。macOS側の実装は今回の変更対象外。

結果: `artifacts/face-pan-direction/test-results.json`、`artifacts/face-pan-real/feature-results.json`、`motion-library-results.json`。実写PNGはローカルのartifacts配下のみ。

## 2026-10-17 — 画面設定UIを3ページに分離

- 左メニューを「表示設定」「使用ディスプレイ」「画面グルーピング」に分離。表示設定は起動時の動作・画面別タスクバー・再生操作、使用ディスプレイは対象選択と再検出、グルーピングは連結・配置・テストパターンを担当する。
- グループ名の手入力を選択式へ変更し、「独立して表示」を明示。「＋ グループを追加」でグループを増やせる。既存のグループ名は選択肢へ引き継ぐ。
- 座標入力とWindows配置へのリセットを「配置を数値で調整」へ折りたたむ。保存・開始・閉じるは全ページ共通の下部へ配置。
- 3画面構成で3ページを1040×820と920×700の各サイズで描画し、6枚のPNGを確認。最小サイズで収まらない内容はページ内をスクロールでき、共通の保存ボタンは常に表示する。
- コア検証15項目と設定ページ描画が成功。Releaseビルドはエラー0。NuGetの脆弱性情報を取得できないNU1900警告は継続。

結果: `artifacts/settings-ui-split/settings-page-{1,2,3}-{1040,920}.png`。設定ページだけを再描画する場合はテストランナーへ`--scan-only --settings-ui`を指定する。描画試験は写真再生・タスクバー変更を行わない。

## 2026-10-17 — グループ指定と画面ごとのタスクバー設定

- 表示対象の選択とグループ指定を分離。同じグループ名の画面だけを連結し、空欄の画面はそれぞれ独立して再生する。カードの色・グループごとの寸法・テストパターンの画面番号で構成を確認できる。
- タスクバー非表示は各画面のチェックボックスへ移動。旧設定にGroupIdがなければ従来の連結を維持し、HideTaskbarがなければ従来の全体設定を引き継ぐ。新しい設定を保存すると画面ごとの値を保持する。
- グループの分割、独立画面の座標が別グループのキャンバスを広げないこと、旧JSONの移行と保存・再読込を確認。
- 3画面で「2画面を連結＋1画面を独立」と「3画面をすべて独立」を実行。グループ別の解像度・構成・再生、全グループへの一時停止・再開・次の構成を確認。
- 一部の画面だけにタスクバー非表示を設定し、ほかの画面を維持、停止時の復元を確認。
- 画面IDを未接続へ置き換えて、該当グループの領域保持と別グループの継続を確認。切断後の画面が前景アプリに覆われた場合は遮蔽状態が表示されるため、領域保持はステータス文言ではなく実際のViewportで検証する。
- 最終の18項目が成功。既存の全表示モードと設定画面のデスクトップ試験も別途成功。ビルドはエラー0、NuGetの脆弱性情報へ接続できないNU1900警告あり。

結果: `artifacts/display-groups-final/test-results.json`、`multi-taskbar-restore.json`、`display-groups-settings.png`、`display-groups-editor.png`。旧版が起動中の最初の検証ではタスクバー復元が1件不一致になり、単独の再検証と最終試験では成功した。複数プロセスから同じタスクバーを操作すると干渉する可能性があるため、通常起動は従来の単一起動制御を維持する。全画面を露出させた境界確認・混在DPI・長時間運転の未確認事項は従来どおり。

```powershell
.\.tools\dotnet\dotnet.exe windows/tests/DynamicPhotoWall.Tests/bin/Release/net10.0-windows10.0.19041.0/DynamicPhotoWall.Tests.dll artifacts/display-groups-final --multi-display --display-groups --retry-recovery
```

## 2026-10-17 — Windows内のマルチディスプレイ

- 複数画面の選択、ドラッグと端・中央スナップ、X/Yの数値入力、Windows配置へのリセット、設定保存、格子・斜線・円・画面番号を追加。
- 負座標、上下位置、40pxの隙間、異なる解像度から共通キャンバスと切り出し矩形を計算するテストが成功。従来のMonitorIdだけの設定も利用可能。
- 原点以外にある最初の画面とVisualBrushによる別画面を、全キャンバスの画像と全ピクセル比較。格子、および移動する写真と動的背景で、色成分の差1以内を確認。
- 実機の3画面（1920×1080が2台、3840×1100が1台、全体3851×2180）へ同時接続。設定画面のPNGを確認。
- 未接続IDへの差し替えと復帰をテストし、残った画面の表示と未接続領域の保持を確認。これはケーブルの実際の抜き差し試験ではない。
- 共通Zoomの再生、一時停止・再開・次の構成・全停止、対象画面ごとのタスクバー非表示と全タスクバーの復元が成功。
- Windowsが合成した実画面は、露出しているDISPLAY3でマゼンタ9/9点を確認。DISPLAY1/2は別アプリが9/9点を覆っており、この2画面の提示確認は未実施。両画面のWPF描画面とShell接続は確認済み。検査点のウィンドウ種別も記録し、覆われた点を描画失敗として扱わない。
- 既存モード・顔位置計算・EXIF・デコード・フォルダー監視・設定破損復旧・再試行復旧を含む17項目が成功。復元なしのReleaseビルドは警告0・エラー0。最終パッケージング時はNuGetの脆弱性情報へ接続できずNU1900警告2件が出たが、発行・テストは成功した。

結果: `artifacts/multi-display-final/test-results.json`、`multi-display-compositor.json`、`multi-display-settings.png`。3画面を同時に露出させた境界の目視確認、混在DPI、実ケーブル抜き差し、スリープ・Explorer再起動と長時間運転は手動確認が残る。PC間同期は対象外。

```powershell
# リポジトリ直下から、通常の対話デスクトップで実行
.\.tools\dotnet\dotnet.exe windows/tests/DynamicPhotoWall.Tests/bin/Release/net10.0-windows10.0.19041.0/DynamicPhotoWall.Tests.dll artifacts/multi-display-final --desktop --multi-display --retry-recovery
```

## 2026-10-14 — Windows v0.1.0 単一EXEリリース

- Release / win-x64 / self-contained / PublishSingleFileで発行。ネイティブライブラリも同梱し、シンボルはアプリに埋め込む。WPFのためトリミングは行わない。
- ルートの `DynamicPhotoWall.exe` をダブルクリックして起動する形へ変更。ショートカット・起動スクリプトも同じEXEを参照。
- 実行ファイル・設定画面・タスクトレイのアイコンを統一。「横スクロールGallery」の表示名を「Scrolling Gallery」に統一。
- 既存のコア検証と全モード・設定画面・常駐コントローラーの統合検証、合計13項目が成功。ビルドは警告0・エラー0。
- DLLを置かない別フォルダーへアプリと検証ランナーの単一EXEだけをコピーし、インストール済みランタイムの参照先を無効なパスにした状態で検証。
- 単一EXE環境で実デスクトップの色出力、顔検出、縦パン・Zoom・Gallery・Scrolling Gallery、動的背景、表示失敗後の自動復帰が成功。
- 単一EXE環境で対象画面のタスクバー非表示、通常復元、所有プロセスの強制終了後の復元が成功。
- EXEのみをさらに別フォルダーへ移動し、`Photo Wall.exe`へ改名した場合も復元用プロセスを起動し、異常終了時のタスクバー復元が成功。
- 写真・設定・キャッシュをEXEへ含めない。生成したEXEはGit対象外とし、GitHub Releasesのアセットとして配布する。

結果: `artifacts/smoke-data/test-results.json`、`artifacts/single-file-tests/test-results.json`、`artifacts/portable-rename-result.json`。単一EXEは初回起動時に必要なネイティブDLLをユーザーの一時領域へ展開する。別PC・長時間運転は従来どおり手動確認項目として残る。

## 2026-10-14 — 「画像表示を再試行中」で進まなくなる不具合

実行中のapp.logで `Math.Clamp` の下限が `4.547473508864641E-13`、上限が0となる例外を確認。全幅Zoomの顔位置調整で、拡大率の除算・乗算後に画像幅が画面幅を丸め誤差分だけ下回っていた。Buildが例外を投げる前の準備済み構成を保持していたため、同じ構成を2秒ごとに再試行し続けていた。

- Zoomの描画寸法を画面幅・高さ以上に補正し、位置の範囲が逆転することを防止。顔の目標位置も、実際にClampへ渡す上下限で検証する。
- Buildを呼ぶ前に準備済み構成を消費し、例外時は次の構成を選ぶ。
- 表示成功時に再生・一時停止状態を再表示し、再試行の表示を解除する。
- 298×200の画像と3840×1100の画面で、ログと同じ小数誤差を再現する回帰テストを追加。幅256〜4096、回転あり・なし、3画面比率でも検証。
- 現在のユーザー写真901枚の寸法を使い、大小の顔領域・3画面比率・3モードの計16,218通りの表示計算が成功。これは計算の検証であり、901枚すべての再デコード試験ではない。
- Galleryだけで起きる表示例外をテストで注入し、失敗後に有効なZoom構成へ進み「再生中」に復帰することを確認。
- 実写真で顔の縦パン終点、全幅Zoom、横スクロール、従来Galleryの表示も成功。ビルドは警告0・エラー0。

結果: `artifacts/retry-fix-core/test-results.json`、`motion-library-results.json`、`artifacts/retry-recovery-final/retry-recovery-results.json`。実写表示の結果は `artifacts/retry-fix-desktop/feature-results.json`。

## 2026-10-14 — 動的背景・横スクロールの高さ・フチ処理削除

[YouTube公式のアンビエントモード解説](https://blog.youtube/inside-youtube/youtube-ambient-color-mode-visual-language-redesign/)を調査し、小さなプレビューをぼかして背景に使う方針を参考にした。Photo Wallの更新周期や平滑化は独自の実装であり、YouTubeの内部実装を再現したものではない。

- 縦パンで青い下部から赤い上部へ移動すると、背景も青から赤へ変わることを確認。左右の空き領域も表示中の色を反映。
- 横スクロールで赤い写真が青い写真へ移動すると背景が追従。画面外の緑の写真は、画面内に入ってから背景へ反映される。
- 従来のGalleryで1枚を交換した場合にも背景が追従。従来のGalleryモードを維持。
- 一時停止で背景更新も停止。前の構成・終了したRendererのタイマーが残らないことを確認。
- 全写真とパン用フレームの4pxのOpacityMask処理を削除。
- 3840×1100で横スクロールの高さ1084px、上下の余白各8pxを確認。
- 実写真のWindows標準顔検出: サンプル3枚中3枚で検出。顔が収まる縦パンの終点、全幅Zoomでの顔位置調整、スクロールの新写真への交換を確認。
- 実デスクトップのピクセル検査: マゼンタ9/9、シアン9/9、フォーカス維持。
- コアを含む15項目が成功。ビルドは警告0・エラー0。

6秒の実写真パン計測（3840×1100 / 60Hz）:

| 項目 | 結果 |
|---|---|
| アニメーションの30fps上限 | なし |
| 毎フレームの写真レイアウト再計算 | 0回 |
| UI側で観測した移動更新間隔 | 中央値13.19ms、95%点15.18ms |
| 移動量 | 約720px（120px/秒） |
| 動的背景 | 初回を含め58回更新、プレビュー取得の最大3.48ms |

UI側のアニメーション更新計測であり、60Hz画面で75fpsが提示されたという意味ではない。OS・GPUの厳密な提示フレーム数や長時間の負荷はこの試験の対象外。

結果: `artifacts/ambient-final/test-results.json`、`ambient-results.json`、`pan-metrics.json`、`feature-results.json`。実写PNGはローカルのみ。

```powershell
dotnet windows/tests/DynamicPhotoWall.Tests/bin/Release/net10.0-windows10.0.19041.0/DynamicPhotoWall.Tests.dll artifacts/ambient-final --compositor --pan-metrics --features --ambient
```

## 2026-10-14 — タスクバーなしの全画面表示

- Displayに「対象画面のタスクバーを隠して全画面表示」を追加（初期値は有効）。
- 対象モニターのタスクバーだけが非表示になることを確認。
- ほかのモニターのタスクバーの表示状態が変わらないことを確認。
- 通常の停止・終了による復元を確認。
- テスト専用所有プロセスを強制終了し、独立したガードがタスクバーを復元することを確認。
- 結果: `artifacts/taskbar-fullscreen/taskbar-result.json`。実画面の色出力テストも同時に成功。

## 2026-10-14 — 「再生中だが写真が見えない」の修正

10月13日の実写PNGはWPF内での描画確認であり、Windowsが合成した実画面への表示を保証していなかった。ユーザー報告で未検出の不具合を確認した。

- 実際のShell階層は `SHELLDLL_DefView → 写真用HWND → WorkerW` で順序・領域は正しかった。
- ProgmanはWS_EX_NOREDIRECTIONBITMAP付きで、普通の非Layered子HWNDには合成対象の面がない。
- 写真用HWNDにWS_EX_LAYEREDとグローバルAlpha=255を設定。WPFがWM_STYLECHANGINGでLayeredフラグを除去する処理を、写真用HWNDのフックで抑制した。
- WPFのAllowsTransparency / PerPixelOpacityは有効にせず、不透明な通常描画を維持した。
- 実画面の9か所のピクセルを検査: マゼンタ9/9、背景色変更後のシアン9/9。フォーカス維持も確認。
- テスト結果: `artifacts/compositor-fix/compositor-result.json`。
- この検査は対象画面が他のアプリで覆われていない状態で実施する。モニター座標やWPF内の画像だけを成功条件にしない。

再実行コマンド:

```powershell
dotnet windows/tests/DynamicPhotoWall.Tests/bin/Release/net10.0-windows10.0.19041.0/DynamicPhotoWall.Tests.dll artifacts/compositor-fix --scan-only --compositor
```

実施日: 2026-10-13（日本時間）。環境: Windows 11 build 26300、x64、.NET SDK 10.0.401。

## Phase 1 — Windows統合

`artifacts/phase1-probe.json` に実機結果を保存。

- Progman / Windows 11 24H2形式の子ウィンドウ階層へ接続: 成功。
- 指定モニターの物理座標・寸法と接続後のウィンドウ矩形の一致: 成功。
- WS_CHILD、WS_EX_TOOLWINDOW、WS_EX_NOACTIVATE、WS_EX_TRANSPARENT: 確認。
- 検証終了後にアプリのHWNDが消失: 確認。ExplorerのHWNDは削除しない。

その後、ウルトラワイド3840×1100、座標(-11, 1080)、DPI 96で4モードの描画を検証。
他の2画面へアプリの描画ウィンドウを作成しない設計。壁紙変更APIは使用していない。

## Phase 2〜4 — 自動テストと統合テスト

最終ビルド: エラー0、警告0。テストランナーの検証は全件成功。

| 検証 | 結果 |
|---|---|
| 距離÷120px/秒のパン時間、上下・左右の終点 | PASS |
| ネイティブ解像度未満の写真の拡大許容と設定上限 | PASS |
| Galleryの画面内配置、比率保持、余白 | PASS |
| 同時表示の重複排除、直近写真の繰り返し抑制 | PASS |
| 2万回の重み抽選、Pan合計ウェイト、ウェイト0・全モード無効 | PASS |
| EXIF Orientation 1〜8の寸法・実ピクセルの回転/反転・撮影日時 | PASS |
| JPEG / PNG / WebPのデコード、破損・削除ファイルのスキップ | PASS |
| 設定の保存・復元、破損設定からの復旧 | PASS |
| フォルダー監視による追加・削除、重複フォルダーの排除 | PASS |
| 一時停止中の経過時間の凍結・復帰 | PASS |
| 負座標のウルトラワイドへの4モード描画 | PASS |
| Galleryの1枚だけの交換、他スロットの維持 | PASS |
| 設定画面の生成とレンダリング | PASS |
| 常駐コントローラーの開始・停止、個別更新、設定適用・再起動 | PASS |
| 一時停止中に次の構成を連続指定して復帰 | PASS |
| 未接続のモニターIDを指定した場合の安全な待機 | PASS |

抽選実測: Gallery 40.4%、Pan合計38.0%、Zoom 21.6%。設定45/35/20に対し、同じモードの3連続を抑制する効果が含まれる。
初期版のテストで小さいEXIF画像を不必要に拡大してデコードする問題を検出し、元の解像度を超えてデコードしないよう修正済み。
一時停止中に切替を中断した場合は新しいシーンを破棄し、前のシーンを保持する。

## 配置された実写ファイルでの検証

追加中に703枚→844枚と増加したため再走査し、**862枚**の時点で全件を検証した。
後から追加した画像は次回の走査対象になる。

- メタデータ読み取り: 862枚。
- デコード成功: **862 / 862枚**。失敗0枚。
- 全件デコード時間: **67.55秒**（テストは順次実行。常駐時は必要な写真のみ読み込む）。
- 縦写真747枚、横写真112枚、中間の比率3枚。幅270〜4096px、中央値1536px。
- 3840×1100に対し、縦パン候補は拡大上限2倍で183枚、4倍で662枚、6倍で736枚。
- 実写Gallery5枚: 270×450、1280×1920、1536×2048、1836×2448、3649×4096の写真を比率保持で同時表示。
- 実写Galleryの個別更新: 他の4枚を保持したまま1枚を交換、配置も再計算。
- 実写Vertical Pan: 1536×2048を3840px幅へ拡大。計算上の移動距離4020px、所要時間33.5秒。下側からの開始と描画・移動を確認。
- 実写Zoom: 4096×3463の写真で描画・拡大を確認。画面比率に合わせた上下の切り取りを伴う。
- 実写Horizontal Pan候補: 0枚。適性により抽選対象外になる。Horizontal Pan自体は4000×600の合成WebPで検証済み。
- 実写デコード試験のキャッシュ使用量: 62,441,472 bytes（設定64MiB以内）。プロセス全体のメモリ上限を意味しない。

詳細JSONと確認用PNGは `artifacts/actual-photos` に保存。写真と実写の確認画像は配布ZIPに含めない。
確認用PNGはWPFのレンダリング結果であり、OSが合成したデスクトップのスクリーンショットではない。

## 手動で残る確認

- Explorerの実際の強制終了・再起動後の復帰。
- モニターケーブルの抜き差し、解像度変更、96/144/192 DPIなどの混在と実際の変更。
- 実際のWindowsスリープ・復帰、仮想デスクトップ切替。
- 最大化・全画面アプリとの長時間の共存、Alt+Tabとマウスの通過を複数アプリで目視確認。
- 8〜24時間以上の連続運転におけるCPU/GPU/メモリの推移。
- Windows HEICコーデックの有無の両環境。

上記は実装済みの復旧経路を実機障害で検証したものではなく、未実施として区別する。

# Windows差分確認とMac build 10・11

## build 16: 同期描画の保持レイヤー化

build 15の再起動後もCPU負荷が残るという報告とユーザー提供sampleを受け、同期側の毎フレームのbitmap再描画をCore Animationの不変contentsと座標/不透明度の更新へ移した。`orderFrontRegardless`の反復呼出しも抑制した。共有PNG・色補正・wire時刻と16ms時計は維持する。

`bash macos/scripts/verify.sh`（GUI操作なし）が成功:

- Swift単体205件 / 31 suites。同期合成12件を追加し、静止/一時停止の属性・contents再設定なし、動作、同一PNG、透明な背景のsource-over、旧描画との画素比較、clip/角丸/スパンcrop、フェード、交換/再開/resize/破棄を検証。
- 共通fixture704＋472 assertions、背景色12ケース、Zoom構図5120 assertions。
- .NETネットワーク26ケース / 241 assertions。
- arm64 Releaseコンパイル。

204件時点の全検証ログは`artifacts/macos/issue-1-sync-final-verify.log`。縦境界の追加1件を含む全205件は`artifacts/macos/issue-1-sync-boundary-verify.log`で成功。本番背景の生成経路を使う合成画像を含め、旧描画と保持レイヤーの全画素差0を確認した。XcodeのCoreSimulatorバージョン警告とCore Imageの`MDB_MAP_FULL`ログは従来同様に出たが、対象の全単体試験とReleaseビルドは成功した。

`package.sh`により同じRelease archiveからAPP/ZIP/DMGを生成し、署名strict・arm64・ビルド番号16・LSMultipleInstancesProhibited・DMG・SHA-256を確認。3つのAPPの全6ファイルが一致し、ルート直下のエントリは不変。APPと実行ファイルは22:40:52（日本時間）。`artifacts/macos/package/build16-validation.json`、`build16-package.log`に保存した。旧配布物は`previous-release.91v0uU/`。稼働アプリの終了・再起動、`/Applications`の置換、GitHub公開は行っていない。

独立ウィンドウでの比較測定は[実測記録](RENDERING-MEASUREMENTS-2026-10-19.md)に分離する。実画面の色管理・滑らかさ・カーソル、複数実画面・Windows端末との同期、通常アプリのCPU再測定、電力/提示フレーム時間は未検証。

## build 15: ローカル配布物の更新

ユーザー許可で`package.sh`を実行し、Issue #1の修正とビルド番号15を含むarm64 Release archiveから`release/macos/arm64/`のAPP／ZIP／DMG／SHA256SUMSを更新。アドホック署名のstrict検証、arm64、LSMultipleInstancesProhibited、ZIP展開、DMG検証、SHA-256が成功。DMGを読み取り専用でマウントし、配布APP・ZIP内APP・DMG内APPの全6ファイルが一致した。APPと実行ファイルの更新時刻は22:15:50（日本時間）。検証結果は`artifacts/macos/package/build15-validation.json`、旧配布物は`artifacts/macos/package/previous-release.d22W4u/`。ルートのエントリに増減なし。製品ソースは前回193件の検証からビルド番号だけを変更しており、単体試験は再実行していない。通常アプリの置換・再起動とGitHub公開は含めない。[リリースノート](RELEASE-NOTES-v1.1.0-build15.md)を参照。

## Issue #1: CPU/GPU採取と同一fixtureによる比較

稼働build 14の平均CPUは30秒で35.07%。Time ProfilerとMetal System Traceを採取し、同期表示の16ms更新とCore Animation/Metal関連処理を確認した。同一fixtureの静止Galleryは変更前22.28%→PR版12.05%（各3回、準備5秒＋測定10秒）、背景生成80回→0回/10秒。同期側は5.65%→5.49%で同程度、10秒に約560回の再描画が続く。探索測定のPan/Zoom/scroll、一時停止、制約と生データの場所は[実測記録](RENDERING-MEASUREMENTS-2026-10-19.md)を参照。通常アプリは継続稼働し、個人設定・配布物は変更していない。電力・提示フレーム時間・実Windows同期の前後比較は未測定。

## Issue #1: 背景生成の抑制と描画計算のキャッシュ

専用ブランチで`verify.sh`（GUI操作なし）を実行。Swift単体193件/30 suites、共通fixture704＋472 assertions、色12ケース、Zoom構図5120 assertions、ネットワーク26ケース/241 assertionsとarm64 Releaseコンパイルが成功。静止Galleryの仮想60秒・3,600更新、共有グループの2タイルからの重複更新で背景生成1回を確認した。処理回数の検証であり、実アプリのCPU/GPU・電力の前後比較は未実施。変更理由・追加11回帰・実機残件は[描画負荷の監査](RENDERING-PERFORMANCE.md)を参照。通常アプリの置換、配布物の更新、GUI自動操作は行っていない。

2026-10-19（日本時間）。作業前は`855d899`で変更なし。`git pull --ff-only origin main`で`39bbdb9`（Galleryの配置・交換時計と顔を守る動き）を取得した。Windowsの追加実装・共通契約・Macへの移植を比較し、Macで残っていた背景処理とコンパイル・回帰検証を補った。

## 差分と対応

| 項目 | Macの対応 |
|---|---|
| Galleryの固定サイズ・交換 | 取得済みの`FixedGalleryLayout`と`GalleryTimeline`を使用。縦横の短辺を維持し、画面別表示もグループ全体の時計で1枚ずつ交換する部品・コントローラーテストに成功 |
| 顔のサイズと移動 | 取得済みの`FaceMotionSafety`を確認。Zoomは全区間で顔を実画面へ収め、移動が残らないPanは除外。旧raw geometryのfixtureと現在の安全処理の期待値を分けた |
| 抽選・既存設定 | ギャラリー80／パン・ズーム20の2段抽選と旧値の移行、Zoomの30秒・1.25倍、上限1.5倍を確認。保存済みZoom設定を保持 |
| 背景色の平滑化 | 50%の整数平均を0.8秒基準の浮動小数点フィルターへ変更。入力の周期に依存せず、静止時の色彩を弱めず収束する |
| 背景画像の更新 | 小画像2枚を保持して125msで補間。途中の更新は見えている混色から再開。通常の表示tickでは画像を生成せず不透明度だけを変える。pauseは再生時刻とともに保持 |
| 同期用背景・Galleryのfade | PNG生成時に計画上のサンプル時刻を渡す。PNGは未補正のまま送り、受信時に色を一度だけ補正。受信した個別の`fadeInSeconds`／`fadeOutSeconds`を既存の表示アダプターで上書きしないよう修正 |

取得したSwiftの`FaceMotionSafety`・`FixedGalleryLayout`・`GalleryFaceTests`には`CoreGraphics`の明示importが不足していたため追加した。古いテストでは、全顔を収めると移動できないPanを表示する期待値、旧顔停止時間、既定値変更で途中終了するScrolling Galleryの時間条件が残っていた。現在の安全処理の期待値へ更新し、Scrolling Galleryの準備待ち検証はシーンが終了しない明示設定で継続した。旧共通fixtureの期待値は再生成していない。

Dock／メニューバーをOS設定へ委ねる合意、Macの写真アプリ連携・起動時権限復旧・非対話Keychain・画面IDによるBinding・表示面保持を維持する。Windowsの描画クラス構造はそのまま移植せず、SwiftUIとAppKitの既存出力を使用する。

## 検証

```sh
bash macos/scripts/verify.sh --unit-only
bash macos/scripts/package.sh
```

| 検証 | 結果 |
|---|---|
| Swift単体 | 165件・26 suites成功 |
| Windows既存共通fixture | 704＋472 assertions成功 |
| 背景色fixture | Windows本体の色補正コードと12ケース一致 |
| .NETネットワーク基盤 | 25ケース・224 assertions・失敗0 |
| Mac Release | arm64コンパイル・archive成功 |
| ローカル配布物 | 1.1.0 build 10のAPP／ZIP／DMGを生成。署名・arm64・DMG・SHA256SUMSを確認 |
| 配置・内容 | 展開済みAPPとZIP内の全ファイルが一致。ルート直下のファイル一覧が作業前後で不変 |

新規の背景試験は合成画素で8Hz／60Hzの応答一致、pause、定常色への収束、交互色の変化幅、途中更新の紫色の混合、不透明な基底と画像参照の保持、サイズ変更を検証する。背景処理の既存試験も新しい時間依存の係数で確認した。ネットワーク出力の試験はfake surfaceで個別fadeと旧fadeへのフォールバック、不正なfadeの拒否を確認する。実ウィンドウの生成・表示・撮影・GUI操作は行っていない。

ログと生の照合結果は`artifacts/macos/remote-sync-2026-10-19/`の`baseline.log`、`verification.log`、`verification-final.log`、`package.log`、`release-verification.json`。配布物は`release/macos/arm64/`。置換前のbuild 9は`artifacts/macos/package/previous-release.15x7F1/`へ退避した。通常のユーザー設定・個人写真・OS権限を変更せず、`/Applications`の置換とGitHub Releaseへの公開も行っていない。

## 残る実機確認

実際のMac↔Windowsでの新Gallery計画の同期、顔保護後の構図、背景の追従と知覚的な自然さ、実ケーブル抜差し・スリープ・長時間再生は未確認。部品テストとビルド成功から、実画面でのブラックアウト・ちらつきがないと断定しない。GUI自動テストはユーザーから明示依頼がある場合だけ実施する。既存の[受け入れ残件](../MACOS_PARITY_TODO.md#release前に残す実機受け入れ)も維持する。

## build 11: Keychainへのアクセスを廃止

同日のユーザー報告で、Keychainの許可確認が連続することを受け、保存方式の選択を確認した。ユーザーは同一ユーザー権限の別プロセスに対する保護が弱くなる点を確認して、Keychainを使わない方式を選んだ。`PNKeychain`・対話許可・起動時のKeychain事前確認を削除し、`PNFileSecrets`を既定の保存先にした。[保存仕様](LOCAL-NETWORK-STORAGE.md)と[現在の権限フロー](PERMISSIONS.md)を参照。

旧`network/`と新`network/local-v2/`を区別し、旧通信データがある場合は明示的な新設定作成までオンライン化を保留する。旧Keychainと旧通信ファイルを読み出し・上書き・削除しない。新しい設定で他の端末へ接続し直し、写真ソース・共有側配置を再確認する。写真・共有設定の暗号化と相互TLSは維持する。新方式の鍵の破損・欠落時は鍵を再生成せず停止する。

`bash macos/scripts/verify.sh --unit-only`は単体167件・27 suites、共有fixture704＋472 assertions、背景色12ケース、.NETネットワーク25ケース・224 assertions、arm64 Releaseコンパイルが成功した。新規`FileSecretsTests`の5件で鍵・pinの再読込み、0700／0600とバックアップ除外、原子的更新、identity上書き拒否、リンク・権限不正・サイズ超過の拒否、破損・鍵欠落時の停止、旧データの不変を確認した。`NetworkAvailabilityTests`は秘密ストアの再利用とI/O失敗時の非接続へ変更し、OSのKeychain項目を使う試験は削除した。

`bash macos/scripts/verify-network-interop.sh`でもSwift／.NETの両方向の相互TLS・hello・length-prefixed JSON・ping/pongが成功した。Macのloopback上のCLI試験で、実Windows端末の受け入れやmulticast探索はこの更新では実行していない。GUI操作・画面撮影・通常アプリの起動・OS権限のリセットは行っていない。

最終コードの1.1.0 build 11をAPP／ZIP／DMGへ更新した。署名・arm64・DMG・SHA256SUMS・ZIP内の全ファイルと展開済みAPPの一致、ルート直下のファイル一覧が不変であることを確認した。実行ファイルの未定義シンボルに`SecItem*`／`SecKeychain*`の参照がなく、配布APPに秘密ファイルが含まれていないことも確認した。API参照の確認は、すべてのOSダイアログが出ないというGUI実機検証の代わりではない。

検証ログ・シンボル一覧・照合結果は`artifacts/macos/file-secrets-2026-10-19/`。置換前のbuild 10は`artifacts/macos/package/previous-release.YC6D0V/`へ退避した。`/Applications`の置換とGitHub Releaseへの公開は行っていない。実アプリの更新後の操作と、旧環境から新しい接続情報でのMac↔Windows再接続は手動確認の残件。

## build 12: 最新リモートの取り込みとGallery復旧

同日、変更のない`61033f3`から`origin/main`の`1ffc189`まで3コミットをfast-forwardで取り込んだ。写真ソースの接続表示・ピア解除、Panの中央配置、Galleryの空きへの追加、5〜10秒の交換待機、一巡フラグ、同種Gallery再当選の破棄はSwiftにも追加済みだった。Macでの未実行部分を検証し、次を修正した。

- 初期Galleryの構成時に写真を毎回先頭へ挿入していたため、選択順が逆転していた。構成時は選択順に末尾へ追加して収容可否を評価する。名前順と、先頭画面が原点以外でも正しい画像を切り出す動作を維持する。再生中の空きへの追加は既存の配置部品を使う。
- 同種Galleryを破棄した後の5秒待機とモード履歴が、写真の削除・更新・読込失敗後の復旧も阻んでいた。単画面・グループの表示写真が無効になったとき、および明示的な再試行で履歴と待ち時間を解除する。写真追加だけでは現在の表示と時計を維持する。
- 旧テストの「Nextで必ず新Galleryになる」「空きがあっても既存写真を交換する」という期待値を、新しい表示保持・追加フェードへ更新した。追加前の写真をすべて維持し、新規写真だけが入場することも確認する。
- 画面取得クロージャーのMainActor指定と、LAN許可コールバックの弱参照キャプチャーを明示し、Swiftの並行処理警告を解消した。

`bash macos/scripts/verify.sh --unit-only`の結果:

| 検証 | 結果 |
|---|---|
| Swift単体 | 174件・29 suites、失敗0 |
| Windows共通fixture | 704＋472 assertions、成功 |
| 背景色fixture | 12ケース一致 |
| .NETネットワーク基盤 | 相互TLSを含む26ケース・241 assertions、失敗0 |
| Mac Release | arm64コンパイル・build 12 archive成功 |
| ローカル配布物 | 1.1.0 build 12のAPP／ZIP／DMGを生成。署名・arm64・DMG・SHA256SUMS、APPとZIP内の全6ファイルの一致を確認 |

`GalleryBehaviorTests`の追加回帰では初期写真順、Gallery／Scrolling Galleryの単画面・画面別グループで、再当選後の待機中に写真を差し替えてもpauseを保持したまま復旧することを確認した。既存の削除・全読込失敗からの再試行・画面切り出し・Gallery追加・共有交換時計の回帰も成功。`NetworkDisconnectTests`で未接続ソースの非表示、保存済み選択の保持、手動切断後の再接続抑止と明示接続による再開を確認した。旧共通fixtureの期待値は変更していない。

ログは`artifacts/macos/verification/verify-complete.log`、各fixtureログと`artifacts/macos/network-core/test-results.json`。最初のsandbox内実行はXcodeのプロセス通知が拒否され停止したため、以降は通常権限で実行した。CoreSimulatorの版差、AppIntents未使用のメタデータ通知、XCTestホストのlinkd・描画キャッシュの`MDB_MAP_FULL`通知は出るが、最終の単体・ビルドは成功し、Swiftソースのコンパイル警告はない。

`bash macos/scripts/package.sh`で`release/macos/arm64/`のローカル候補を更新した。パッケージログは`artifacts/macos/verification/package-build12.log`、照合結果は`release-build12-check.json`。置換前のbuild 11は`artifacts/macos/package/previous-release.fjtxQc/`へ退避した。ルート直下のファイル一覧が作業前後で不変であることも確認した。`/Applications`の置換とGitHub Releaseへの公開は行っていない。

GUI自動操作、実ウィンドウの表示、スクリーンショット、通常の壁・個人設定・OS権限の変更は行っていない。単体の画面切り出しは既存のオフスクリーン描画で検証した。実Mac↔Windows間のLANと表示、顔を守った構図、ちらつき・背景追従の知覚確認、混在倍率・抜差し・長時間運転は引き続き実機の残件とする。

## Zoomの強制中央配置の修正

顔を必ず実画面中央に置いていた両OSの`FaceMotionSafety`を修正した。最小倍率で写真を中央配置した構図を基準にし、全顔を収めるために必要な分だけ移動する。顔をズームの支点にするため、拡大・縮小中の顔の表示位置は安定する。被覆と顔保護を両立できる場合は画像の端を画面内へ入れず、顔サイズの縮小と複数画面での顔保護は維持する。同倍率の候補画面は写真の中央配置からの移動量で選ぶ。

| 検証 | 結果 |
|---|---|
| Swift単体全体 | 178件・29 suites、失敗0。専用bundle ID・設定で実行 |
| C# Zoom位置補正 | `dotnet run --project tests/ParityVerifier -- --zoom-framing`で5120 assertions成功。Windows CoreをMac上のCLIで実行 |
| 旧Windows共通fixture | 704＋472 assertions成功。raw motionの期待値は変更なし |
| Mac Release | arm64コンパイル成功 |

追加回帰では左右上下の端にある顔、1.25／1.5倍、拡大／縮小、横長写真で切れていた顔の最小移動、顔サイズによる縮小、複数画面で元の構図を維持できる配置を確認した。各ズームを101時点で評価し、顔が収まり、被覆できるケースでは背景を露出しないことを検証する。C#側では顔なしの既存計画との一致、縦横スパンで全顔が実画面1枚へ収まることも確認した。C#の回帰コマンドを`verify.sh`へ追加した。

ログは`artifacts/macos/zoom-framing/`の`swift-tests.log`、`dotnet-tests.log`、`windows-parity.log`、`windows-delta.log`、`release-build.log`。最初のsandbox内のXcode実行は環境のプロセス通知制限で停止し、同じ単体テストを通常権限で再実行して成功した。Computer Use・GUI操作・UIテスト・画面撮影は行っていない。Windowsアプリの実行と実画面での構図確認は今回の検証には含めない。Windowsはユーザーが別端末で検証する。ルート直下のファイル一覧は作業前後で不変。

ユーザーのMacビルド依頼に従い、`bash macos/scripts/package.sh`で1.1.0 build 13のアドホック署名付きAPP／ZIP／DMGを`release/macos/arm64/`へ生成した。archive・署名・arm64・ZIP／DMG・SHA256SUMSと、APP／ZIP内の全6ファイルの一致を確認した。置換前のbuild 12は`artifacts/macos/package/previous-release.W9szkl/`へ退避した。パッケージ作成は自動承認レビューのモデル混雑で実行前に停止していたが、ユーザーが手動承認へ切り替えた後に同じコマンドで成功した。ログは同じ検証ディレクトリの`package-build13.log`、照合結果は`package-build13-check.json`。通常アプリの起動・`/Applications`の置換・GitHub Releaseへのアップロードは行っていない。

## build 14: 同期Galleryの継続とプレリリース更新

GitHub Release更新の依頼に従い、変更のない`d67fd1f`からbuild 14を作成した。公開済みbuild 12以降のZoom構図、同期Galleryの計画更新と写真・配置・交換時計の継続を含む。最初の隔離検証はSwift単体181件・29 suitesと全CLI試験、arm64 Releaseビルドが成功した。

公開準備中に、ユーザーからカーソルの一時停止とCPU約47%の報告があった。稼働中の`/Applications/DynamicPhotoWall.app`はbuild 13で、プロセス一覧ではアプリ45.5〜46.1%、WindowServer34.9〜45.6%だった。5秒間の読み取り専用`sample`で、メインスレッドの1,700サンプル中985が`PNSceneView.draw`を通り、そのうち788が`PNAssetKey.opaqueId`を通っていた。これはCPU全体に対する割合ではなく、採取した呼び出しスタックの内訳である。ユーザーへの確認ではカーソル停止のタイミングはまだ不明で、写真交換や計画更新との相関は確認できていない。

描画ループは表示時刻に関係なく全予定を調べ、写真IDのハッシュ・文字列変換と、画面IDの変換を繰り返していた。`PNPlayback.Frame`の準備時に、画面別の画像参照・配置・背景の整列・切り出し領域を確定するよう修正した。`PNSceneView.draw`は準備済み参照と時刻による位置・不透明度だけを使う。画面別の対象・重なり順・画像の再利用・継続時のフェード規則は保持する。

修正後に`bash macos/scripts/verify.sh --unit-only`を再実行した。

| 検証 | 結果 |
|---|---|
| Swift単体 | 182件・29 suites、失敗0。専用bundle ID・設定を使用 |
| 共通fixture | 704＋472 assertions成功 |
| Zoom構図 | Windows CoreをMacのCLIで実行し5,120 assertions成功 |
| 背景色 | 12ケース一致 |
| .NETネットワーク | 相互TLSを含む26ケース・241 assertions、失敗0 |
| Mac Release | arm64コンパイル成功 |

`sharedGalleriesRenewAcrossTwoHoursWithoutWindows`は静止／スクロール×スパン／画面別の4条件で各100計画・仮想時計2時間以上を検証し、境目の写真・位置・大きさ・交換間隔、readyと予定commitを確認した。`galleryContinuationKeepsTheSurfaceImagesAndFullOpacity`はfake surfaceと画像参照、不透明度1の保持を確認した。

新規`preparedDisplayContentMatchesLegacyLookupWithoutPerFrameIdentityWork`は64予定の画面別抽出・並び順・切り出し、画像参照の再利用、10時点の表示対象と不透明度を確認した。同じ対象を240回照合する比較は旧0.398824167秒／新0.003635541秒で、結果のチェックサムは一致した。デバッグ単体試験の照合部分の比較であり、アプリ全体のCPU使用率やカーソル応答の改善値ではない。時間の比率をテストの合否条件にしていない。

ログは`artifacts/macos/release-build14/verify.log`と修正後の`verify-performance.log`、プロファイルは`artifacts/macos/performance-2026-10-19/app-sample.txt`。GUI自動操作、画面撮影、通常アプリの置換・再起動、個人設定や写真の変更は行っていない。実画面での負荷とカーソル応答、実Mac↔Windows間のLAN・同期表示と長時間運転は未確認。配布は[build 14プレリリース](https://github.com/mhanayama/dynamic-photo-wall/releases/tag/macos-v1.1.0-build.14)とし、既存正式版とbuild 12は保持する。

修正後の`package.sh`も成功し、同じarm64 Release archiveからAPP／ZIP／DMGを生成した。アドホック署名、CPU構成、build番号、単一起動設定、ZIP／DMG、SHA256SUMS、APPとZIP内の全6ファイルの一致と、ルート直下のファイル一覧が不変であることを確認した。最初の公開候補は修正前なので使用せず、修正後の配布物を使用する。パッケージログは`artifacts/macos/release-build14/package-performance.log`、最終照合結果は`package-check.json`。配布先は`release/macos/arm64/`を維持する。

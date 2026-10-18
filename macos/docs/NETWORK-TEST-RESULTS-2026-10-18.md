# Macネットワーク実装の修正と検証

2026-10-18（日本時間）。`58f7f35`のMac実装を修正・検証し、追加の`347ae8c`（ホスト名による端末表示）を取り込んだ。環境はApple Silicon arm64、macOS 27.0.1、Xcode 27.1、.NET SDK 10.0.402。

## 修正

- `@Observable`の複数変数同時宣言、非同期クロージャーの暗黙の`self`を修正し、Macでコンパイルできるようにした。
- TLS identityを保護済みのデータから`SecIdentityCreate`でメモリ上に組み立てる。通常のlogin keychainへ永久鍵・証明書を追加登録する処理を除いた。秘密データの保存先は従来のKeychainアダプター。
- 初回の信頼情報の書込みが失敗した場合、メモリだけで登録済み扱いにしない。再起動・鍵の再利用・変更された証明書の拒否も検証する。
- 画面・グループ・ソース・表示計画のIDと座標、重複した配置IDを受信後に検証し、描画前に拒否する。
- 設定取消でネットワーク側の未保存ドラフトも読み直す。オンライン切替は独立した端末操作として維持する。
- TLS listenerとmulticast検出へ試験用のbind先／探索ポートを渡せるようにした。本番の既定の探索先は`239.255.77.87:47391`のまま。
- `347ae8c`の「このMac: ホスト名」、写真提供元・画面一覧・配置プレビューのホスト名表示を保持して競合を解消した。

## 自動検証

| 対象 | 結果・範囲 |
|---|---|
| Swift単体 | 118件・14 suites成功。既存の写真・設定・顔・マルチディスプレイの回帰を含む |
| ネットワーク共有データ | C#のJSON・ID・顔矩形・時刻評価・暗号文をSwiftで照合。原寸保持・改ざん拒否・14日期限・世代更新・切断復旧・Ready障壁を確認 |
| Keychain | UUIDで隔離した試験専用項目の追加・取得・更新に成功。試験後に同じ項目を削除。通常のネットワークidentityは参照しない |
| ネイティブTLS | メモリのみの合成identity同士で、実ソケットの相互TLSとフレーム交換に成功。listenerはloopbackへ限定 |
| Swift／.NET相互接続 | 双方からのTLS接続、hello、length-prefixed JSON、ping／pongの交換に成功 |
| Swift／.NET相互検出 | 実アプリの探索ポートと異なる一時ポートで、双方のmulticast広告を検出。TLS接続自体はloopbackへ限定 |
| OS非依存.NET | 18ケース・131 assertions・失敗0。3／4ピアの設定・転送・交代・合流・復旧はメモリ上のテスト用トランスポート |
| 既存共通fixture | 704 assertions、追加のOS差分fixtureは472 assertions成功 |
| Release | arm64 Releaseコンパイルと`LSMultipleInstancesProhibited`確認成功 |

Swift／.NETの相互接続もMac上で行った。実際のWindows OS・Schannel・別端末のファイアウォールを検証した結果ではない。interop probeは個人写真・通常設定・Keychain・デスクトップ出力を使わず、試験鍵・証明書はメモリにだけ保持する。

再現はリポジトリ直下から:

```sh
bash macos/scripts/verify.sh
bash macos/scripts/verify-network-interop.sh
bash macos/scripts/verify-network-interop.sh --with-discovery
```

`verify.sh`は既定でGUI操作なし。`--unit-only`も同じ動作。`--ui`はユーザーが明示的に依頼した場合だけ使用する。今回のホスト名追加後の確認もGUI操作なしで実施した。

ログは`artifacts/macos/network/after-hostname-pull.log`、基盤試験結果は`artifacts/macos/network-core/`、interopのログ・端点JSON・バイナリは`artifacts/macos/network-interop/`。DerivedDataと共通fixtureのログは`artifacts/macos/verification/`。

## 先行して実施したUI検証

ユーザーからGUI自動テストを無断実行しないよう指示される前に、既存UI5件と新規ネットワークUI1件を検証した。既存5件は成功。新規試験はmacOSのスイッチ値の取得方法を修正して単独再実行し成功した。合格した操作はネットワーク設定ページの表示・オフライン表示・取消であり、オンライン切替・写真公開・実端末接続は開始していない。スクリーンショットも目視確認した。

UI結果は`artifacts/macos/network/verification-final.log`（既存5件成功）、`network-ui-final.log`（新規1件成功）、キャプチャは`artifacts/macos/network/ui-final/`。ホスト名追加前の結果であり、追加後のUI操作は実行していない。今後もGUI操作を伴う自動検証は明示依頼がある場合に限ることを`AGENTS.md`に記録した。

## 実機確認として残す項目

- 実際のMac／Windowsの相互検出、確認操作なしの接続、ファイアウォール・ローカルネットワーク許可、通常アプリの再起動後のKeychain再利用。
- 実フォルダー・PhotoKit・iCloudからの原写真転送と、受信側のJPEG／PNG／WebP／HEICデコード。
- 共通の3画面配置、顔境界回避、5モード・画面単位表示・背景の接続、pause／Next／停止と提示時刻差。
- 進行役の停止、LAN切断、60秒の孤立動作、スタンドアロン・再接続、スリープ・実ケーブル抜差し、8時間運転。

本検証時点では配布用ZIP／DMGの更新・公開は行っていない。作業前後のルート直下ファイル一覧を比較し、生成物が増えていないことを確認した。

その後、同日のユーザー依頼で表示モードUIを変更し、ローカルのRelease候補をAPP／ZIP／DMGへ更新した。展開済みAPPも`release/macos/arm64/DynamicPhotoWall.app`に残す。署名・arm64構成・ZIP／DMG・チェックサムを検証した。GitHubへの公開は行っておらず、上記の実機残件は継続する。

## build 5: ネットワーク画面設定のクラッシュ修正

11:40のbuild 4のクラッシュ報告は、`NetworkDisplaySettingsView.binding`の配列範囲外アクセス。画面のコントロールが保持する添字と、更新後のドラフトの画面配列が一致しない経路があった。再読込みや適用ではドラフトが一時的にnilになる経路もあった。

行とBindingを`(peerId, displayId)`で識別し、アクセスのたびに現在のドラフトから対象を探すよう修正した。削除済みの行の読取りは行の旧値へ戻し、書込みは無視する。wall IDも照合し、別ウォールへの切替え後に古いコントロールで編集しない。グループ削除は現在の所属一覧へ適用し、配置ドラッグも元のwall IDを確認する。

`NetworkDraftBindingTests`の4件で、一覧の縮小・空配列、並べ替え・差替え、別ピアの同じ画面名、nilのドラフト、別ウォールへの切替え、未選択画面を含むグループ削除を確認した。Bindingの値を直接読み書きする単体試験であり、GUI操作は行わない。全単体は122件・15 suites成功。共有fixtureとネットワーク基盤のCLI試験も維持する。

ローカル候補のAPP／ZIP／DMGを1.1.0 build 5へ更新し、署名・DMG・チェックサムと、展開済みAPPとZIP内の全ファイルの一致を確認した。ログは`artifacts/macos/network-binding-fix/verification-final.log`と`package.log`。クラッシュ報告に含まれる端末情報や個人の設定はfixtureへコピーしない。

## build 6: 接続状態に応じた画面一覧とKeychain許可

保存済みsnapshotの遠隔画面が、接続前や切断後にも設定一覧へ表示されていた。画面一覧・配置プレビューを自端末と認証済み接続中の端末に限定した。探索候補は含めない。保存済みの所属・選択・座標は削除せず、再接続した画面で再利用する。オンライン解除・停止時にも接続中端末・候補・ソースの一時一覧をクリアする。

Keychainは既定で非対話アクセスとし、許可が必要ならアプリ内で理由と再試行ボタンを表示する。ユーザーがそのボタンを押した初期化時だけOSの確認を許可し、信頼情報のバックグラウンド保存では許可しない。平文保存や鍵の自動再生成へ切り替えない。現行のアドホック署名とfile-based Keychainに対応するため、非推奨APIの`SecKeychainGet/SetUserInteractionAllowed`を同期・排他・元値復帰付きで使う。コンパイル時の非推奨警告は残る。Data Protection Keychainへの移行には署名・provisioningの整備が必要で、本修正には含めない。

`NetworkAvailabilityTests`の4件で、接続前・接続中・切断後の画面の絞込みと配置保持、起動時の許可不足、明示操作時だけの対話許可、初期化後の非対話保存を確認した。Keychain拒否は注入したストアで再現し、通常のユーザー項目やOSの許可ダイアログを操作していない。全単体126件・16 suites、共有fixture、.NET基盤試験とarm64 Releaseコンパイルが成功。GUI操作・GUI自動テストは実施していない。実際の更新前後のKeychain許可操作は手動確認の残件。

ローカルのAPP／ZIP／DMGを1.1.0 build 6へ更新した。署名・arm64構成・DMG・SHA256SUMSと、展開済みAPPとZIP内の全ファイルの一致を確認した。ルート直下のファイルも増えていない。検証ログは`artifacts/macos/network-availability/verification.log`、更新ログは`package.log`、照合結果は`release-verification.json`。`/Applications`へのインストールとGitHubへの公開は行っていない。

## build 7: リモート機能差分の統合

リモートの`6d549ed`（画面グルーピング・Gallery容量）と`cae573a`（写真同期の応答性・低画素写真・背景）をfast-forwardで取得し、手元の未コミット修正を復元・統合した。画面Bindingの添字参照を戻さず、Keychainの非対話アクセスと明示的な再試行も維持する。

- ディスプレイ名と接続状態の表示、「未接続の画面も表示」の切替、未接続プレビューの薄い表示。現接続で受信したinventoryの画面だけを接続中とし、保存済み画面・探索候補・開始時にOSから消えているローカル画面を区別する。未接続の所属・座標・選択は保持する。
- ネットワーク配置の12pxスナップ。ドラッグ中の原点・縮尺とwall IDを保ち、現在の行IDで編集する。名前の変更で配置IDを変えない。
- Galleryの上限20枚、横Pan・縦Pan・Zoomの長辺基準のミラー、全5モードの18%暗幕。Macで未実行だった追加テストはCoreGraphicsのimportと型指定を補って実行した。
- MacのUI通知を100msごとに集約し、終了時に保留中の通知を破棄する。写真チャンクごとの画面更新・要求探索をやめ、暗号化保存完了時に進める。同一ソースの再適用では索引を再走査せず、取得済み写真のcatalog再受信でも原データを復号し直さない。実際の読取りで破損・消失した写真は取得済み一覧から外し、再取得へ戻す。キャッシュI/Oは既存の専用actorを維持する。

単体135件・19 suites、共有fixture704＋472 assertions、OS非依存.NETネットワーク25ケース・224 assertions、arm64 Releaseコンパイルに成功。通知1万件の集約と後続通知、旧セッション通知の取消、3チャンクで写真1枚分だけの完了通知、暗号化キャッシュの破損検出・再要求を追加検証した。画面一覧の試験も画面キー単位と未接続表示の切替に対応させ、抜かれたローカル画面を含めた。

Swift／.NETの双方向相互TLSと隔離ポートでのmulticast探索も再検証した。Mac上でのCLI検証であり、実Windows端末・実画面での受け入れやGUI自動テストは実施していない。現行Keychain互換APIの非推奨警告は残る。

ログは`artifacts/macos/remote-sync/verification-final.log`、`interop.log`。通信端点・詳細ログは`artifacts/macos/network-interop/`。

ローカル配布物のAPP／ZIP／DMGを1.1.0 build 7へ更新し、署名・arm64・DMG・チェックサム・ZIP内全ファイルと展開済みAPPの一致を確認した。ルート直下のファイル増加や未解消のGit競合はない。更新ログは`artifacts/macos/remote-sync/package.log`、照合結果は`release-verification.json`。`/Applications`へのインストールとGitHubへの公開は行っていない。

## build 8: 起動時のアクセス権限確認

Mac限定で起動時の権限確認と一括取得を追加した。写真・Keychain・通知・ローカルネットワーク・登録済みフォルダーを一つの画面にまとめ、明示操作から順番に要求する。ログイン起動でも不足があれば設定ウィンドウを開く。KeychainとLAN確認前のオンライン自動復帰と、ネットワーク開始時に別途出ていた通知許可要求を止め、取得後に保存済みの参加を再開する。拒否された権限は利用可能として扱わず、使えるローカル写真の再読込みは継続する。

フォルダーの再許可は同じIDのbookmarkだけを更新する。未保存の表示設定・アルバム選択を保存せず、取消時も再許可したbookmarkを維持する。Keychainの事前確認は既存identityと信頼情報を読み書きし、オンライン化や写真公開を伴わない。ローカルネットワークは現在の実行ファイルの署名hashに対応する取得フローの実施記録を使い、同じ版でも実際の探索で再確認する。保存値からOSの許可を推定しない。新しい実行ファイルでは説明画面から確認を行う。仕様・タイムアウト・署名の制約・Appleの根拠は[PERMISSIONS.md](PERMISSIONS.md)を参照。

全単体142件・20 suites、共有fixture704＋472 assertions、.NETネットワーク25ケース・224 assertions、arm64 Releaseコンパイルに成功。最終的な中止ガード追加後も権限関連11件・2 suitesを再実行して成功した。新規7件は、確認と対話要求の分離、逐次実行、拒否状態、中止と遅い応答、明示的なLAN再確認、フォルダーID／ドラフト保持、写真だけの復旧、ネットワークを起動しないKeychain事前確認を扱う。OS認可クライアントはfake、秘密ストアはメモリのみ。単体テストのホストでは実権限の確認・取得を開始しない。

さらに署名済み実行ファイルのCodeDirectory hashが、権限要求なしで読めて同一実行中に安定していることを実Security APIで1件追加検証した。追加後の`StartupPermissionsTests`全7件が成功（全体のテスト定義数は143件）。この実API確認もTCC・Keychainの認可状態を変更しない。結果は`artifacts/macos/startup-permissions/permissions-adapter.log`。

実OSの認可ダイアログ、APP置換後のTCC／Keychain、システム設定への遷移、実LAN未接続時、実フォルダーの再許可は手動受け入れとして残す。GUI操作・GUI自動テスト・ユーザーの権限リセットは行っていない。ログは`artifacts/macos/startup-permissions/verification-final.log`、最終の権限テストは`permissions-final.log`。

APP／ZIP／DMGを1.1.0 build 8へ更新した。署名・arm64・Bonjourと写真／LANの用途説明・DMG・SHA256SUMS・ZIP内の全ファイルと展開済みAPPの一致を検証し、ルート直下のファイルも増えていない。更新ログは`artifacts/macos/startup-permissions/package.log`、照合結果は`release-verification.json`。`/Applications`の置換とGitHub公開は行っていない。

## build 9: 表示の連続性と背景色彩

リモート`ac5057a`を取り込み、手元のbuild 8までの権限・通信・UI修正を復元した。Windowsのクラス構造をそのまま移植せず、Macの出力を画面キー単位で保持する`PNPlaybackSurface`と、表示の重なりを管理する`PNPresentation`へ分けた。計画先読みは画像と背景だけをデコードし、ウィンドウを作らない。実際のAppKit実装を使わないfake出力を注入できる。

新計画は現在の写真と背景へ重ね、不透明になるまで前の表示とデコード済み画像を保持する。遠隔画面が消えた時の切り出しも、旧・新それぞれの計画の原点と画面座標を使う。高速な連続切替では、その瞬間の不透明度の重なりを保持し、直前の写真を急に全不透明にしない。シーン全体をまとめてフェードし、写真ごと・背景ごとに旧表示へのシーンフェードを繰り返し適用しない。

孤立時はmoduloによる透明な先頭への巻戻しをやめ、終端表示に新しい周回を重ねる。Galleryの最終写真は後続の準備待ちで消さず、最初の写真のフェードとシーンフェードも重複させない。pause中は旧・新の時刻とフェードを保持する。グループ変更・60秒後の単体再生・再同期でも同じ画面の出力を保持し、明示的な停止・表示対象の解除・物理画面の消失で閉じる。共有表示への初回移行も新出力の実際の描画完了を待ち、未描画のウィンドウは透明なまま保持して旧ローカル表示を退けない。停止後や取り消された古い準備結果で表示を復活させず、再同期では保留中の単体用Commitも取り消す。

`AmbientColors`はWindowsと同じ最大1.6倍の色差・1.12倍の輝度補正をRGBAで実装し、RGB範囲・無彩色・アルファを保持する。ローカルはぼかし後・時間補間前、同期表示は受信PNGのデコード時に一度だけ補正する。進行役が生成するPNGは基底色のままとし、原写真には補正を掛けない。期待値はWindows本体の`AmbientPixels.cs`をGUI依存なしでリンクして生成した共通fixture12ケース。

単体154件・22 suites、既存fixture704＋472 assertions、新規の背景補正12ケース、.NETネットワーク25ケース・224 assertions、arm64 Releaseコンパイルが成功した。新規の表示試験は5モード間25通り、旧画像の参照・出力オブジェクトの維持、計画ごとの切り出し、連続スパン／ミラー／所属変更、失敗時の表示保持、孤立周回、Gallery終端、pause、単体準備・再同期、停止と物理画面消失、全出力の描画準備が整うまで旧ローカル表示を解放しないことを確認した。背景はWindowsとの数値一致、補間前の補正、転送PNGと元写真の非変更を確認した。画像の基準比較はmacOSの色管理を通した同じデコード経路で行う。

出力試験では実ウィンドウの生成・表示・描画・撮影を行わない。背景の画素試験も合成画像のメモリ上の処理だけで、画面キャプチャではない。ユーザーの追加指示どおり、Windowsと同じ実装にすることより表示の連続性を優先する。実画面でのブラックアウト・ちらつき・知覚的な自然さやOSの表示面破棄、実ケーブル抜差し・長時間運転は手動受け入れとして残し、部品テストの合格と区別する。

検証ログは`artifacts/macos/display-continuity/verification-final.log`。共通の背景fixtureは`tests/Fixtures/AmbientColors.v1.json`。

最終コードでAPP／ZIP／DMGを1.1.0 build 9へ更新した。署名・arm64・DMG・SHA256SUMS・ZIP内の全ファイルと展開済みAPPの一致を確認し、ルート直下のファイル増加とGitの未解消競合がないことも確認した。更新ログは`artifacts/macos/display-continuity/package-final.log`、照合結果は`release-verification.json`。`/Applications`へのインストールとGitHub公開は行っていない。

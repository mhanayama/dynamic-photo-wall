macOS v1.1.0（build 12）のApple Silicon専用プレリリースです。2026-10-19に作成した最新の配布物を掲載します。正式版のv1.1.0（build 4）は引き続き利用できます。

### 追加・改善

- Galleryは写真の大きさを保ち、空きがあれば追加、入らなければ交換します。グループ全体で5〜10秒の更新時計を共有し、一巡前の偏った再使用を抑えます。
- 初期Galleryの写真順が逆転する問題と、写真の削除・差し替え・読込失敗後に再生が復旧しない問題を修正しました。同種Galleryの再当選では表示を保持します。
- Pan／Zoomで全検出顔が実画面に収まるよう配置・倍率を調整します。背景色と背景画像を時間に沿って補間し、表示の切替時も直前の写真と背景を保持します。
- ギャラリー80／パン・ズーム20の抽選、Zoomの初期値30秒・1.25倍、縦Panの初期幅1.0に対応します。保存済みの独自設定は保持します。
- LAN上のピア検出、共有設定、写真転送、同期表示を試験用として含みます。写真ソースの接続状態表示と、この端末からのピア接続解除にも対応します。
- Keychainへのアクセスを廃止し、通信の鍵と信頼情報をsandbox内の専用ファイルへ保存します。相互TLSと写真・共有設定の暗号化は維持します。

### 対応環境・更新方法

- Apple Silicon（arm64）、macOS 27.0以降。
- 実行中の旧版を終了し、DMG内のアプリをApplicationsへコピーしてください。ZIPも同じアプリを含みます。
- アドホック署名です。Developer ID署名・公証は行っていません。
- 旧版の通信データがある場合は、ネットワーク設定で「新しい通信設定を作成」を選び、他の端末と接続し直してください。旧通信データとKeychain項目は自動移行・削除しません。単体用の写真・表示設定は保持します。
- 新方式の鍵ファイル自体は平文で、sandboxと0700／0600のファイル権限で保護します。同一ユーザー権限の別プロセスに対する保護はKeychainより弱くなります。[保存仕様](https://github.com/mhanayama/dynamic-photo-wall/blob/main/macos/docs/LOCAL-NETWORK-STORAGE.md)を参照してください。

### 検証状況

build 12ではSwift単体174件・29 suites、共通fixture 1,176 assertions、背景色12ケース、Mac上の.NETネットワーク26ケース・241 assertionsが成功しました。arm64 Releaseコンパイルとarchive、署名、ZIP／DMG、SHA256SUMS、展開済みAPPとZIP内のファイル一致も確認しています。今回の公開前に署名・CPU構成・ZIP／DMG・チェックサムを再確認しました。GUI自動操作は実施していません。

実際のMac↔Windows間のLAN・同期表示、実画面での顔の構図・ちらつき・背景追従、混在Retina、画面の抜差し、スリープ／復帰、Spaces、PhotoKitの実権限／iCloud、実ログイン起動、長時間運転は未確認です。ネットワーク機能を検証済み完成物として扱わず、実機確認用のプレリリースとして公開します。[build 12の検証記録](https://github.com/mhanayama/dynamic-photo-wall/blob/main/macos/docs/TEST-RESULTS-2026-10-19.md#build-12-最新リモートの取り込みとgallery復旧)と[実機受け入れの残件](https://github.com/mhanayama/dynamic-photo-wall/blob/main/macos/MACOS_PARITY_TODO.md#release前に残す実機受け入れ)を参照してください。

添付のSHA256SUMSでDMG／ZIPのチェックサムを確認できます。既存の正式版Releaseは保持します。

配布物のソース基準: `6ca7a10`（build 12の実装・検証記録）。その後の`1ad7078`までの変更はWindows専用コードとドキュメントのみで、macOSのソース・共通部品に差分はありません。既存のbuild 12配布物を再ビルドせず公開しています。

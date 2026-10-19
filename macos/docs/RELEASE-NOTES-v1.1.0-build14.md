macOS v1.1.0（build 14）のApple Silicon専用プレリリースです。2026-10-19の最新コードを再ビルドし、build 12以降のZoom構図・同期Galleryの継続修正と、同期描画のCPU負荷軽減を反映しました。

### build 12からの変更

- Zoomで顔を画面中央へ強制移動せず、写真の構図を基準に、全顔を収めるための必要最小限の位置補正を行います。顔を支点にした動きと顔サイズによる倍率調整を維持します。
- 同期Galleryが有限の表示計画の終端で止まる問題を修正しました。同じGalleryが続く場合は、表示中の写真・位置・大きさと交換時計を引き継ぎ、1枚ずつの交換を続けます。
- Scrolling Galleryも終端の位置と速度を引き継ぎます。表示面とデコード済み画像を再利用し、計画の継続だけでGallery全体をフェードし直しません。
- 同期描画で毎フレーム繰り返していた写真ID・画面IDのハッシュ計算と画像照合、背景の抽出・整列を準備時に移しました。実行中のbuild 13のスタック採取で、このID変換が主要な負荷源であることを確認しています。カーソルの一時停止が解消するかは実画面での確認が残ります。
- Next・設定変更・異なるモードへの移行は通常の切替を維持します。既存の写真・表示設定と、Keychainを使わない通信情報の保存方式も維持します。

### 対応環境・更新方法

- Apple Silicon（arm64）、macOS 27.0以降。
- 実行中の旧版を終了し、DMG内のアプリをApplicationsへコピーしてください。ZIPも同じアプリを含みます。
- アドホック署名です。Developer ID署名・公証は行っていません。
- 同期表示では、Windows側もGallery継続修正を含む`d67fd1f`以降のコードからビルドしてください。現在のWindows v0.1.0 Releaseには今回の修正は含まれません。
- build 10以前の通信データがある場合は、ネットワーク設定で「新しい通信設定を作成」を選び、他の端末と接続し直してください。旧通信データとKeychain項目は自動移行・削除しません。単体用の写真・表示設定は保持します。
- 通信の鍵ファイル自体は平文で、sandboxと0700／0600のファイル権限で保護します。同一ユーザー権限の別プロセスに対する保護はKeychainより弱くなります。[保存仕様](https://github.com/mhanayama/dynamic-photo-wall/blob/main/macos/docs/LOCAL-NETWORK-STORAGE.md)を参照してください。

### 検証状況

Swift単体182件・29 suites、共通fixture 1,176 assertions、背景色12ケース、C# Zoom構図5,120 assertions、Mac上の.NETネットワーク26ケース・241 assertionsが成功しました。arm64 Releaseコンパイルも成功しています。同期Galleryは静止／スクロール×スパン／画面別の4条件で各100計画・仮想時計2時間以上を検証し、計画の境目の写真・位置・大きさ・交換間隔と、ready後の予定時刻でのcommitを確認しました。fake surfaceの試験では表示面・画像参照・不透明度1の保持を確認しています。

描画対象64件・240回の照合を比較する単体試験では、旧方式約399msに対し準備済み方式約3.6msで、結果は一致しました。これは照合処理だけの比較で、アプリ全体のCPU使用率やカーソル応答の改善値ではありません。

実際のMac↔Windows間のLAN・同期表示、実画面での顔の構図・ちらつき・背景追従、混在Retina、画面の抜差し、スリープ／復帰、Spaces、PhotoKitの実権限／iCloud、実ログイン起動、実端末での長時間運転は未確認です。GUI自動操作は実施していません。ネットワーク機能は実機確認用として公開します。[build 14の検証記録](https://github.com/mhanayama/dynamic-photo-wall/blob/main/macos/docs/TEST-RESULTS-2026-10-19.md#build-14-同期galleryの継続とプレリリース更新)と[実機受け入れの残件](https://github.com/mhanayama/dynamic-photo-wall/blob/main/macos/MACOS_PARITY_TODO.md#release前に残す実機受け入れ)を参照してください。

添付のSHA256SUMSでDMG／ZIPのチェックサムを確認できます。正式版v1.1.0（build 4）と旧プレリリースbuild 12も保持します。

配布物は同じarm64 Release archiveから作成し、アドホック署名・DMG・ZIP・チェックサムと、展開済みAPP／ZIP内の全6ファイルの一致を確認しました。配布元のソースはこのReleaseの`macos-v1.1.0-build.14`タグです。

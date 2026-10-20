# Dynamic Photo Wall — Mac

Apple Silicon搭載Mac、macOS 27.0以降に対応する、写真がゆっくり動くデスクトップギャラリーです。

## 起動・更新

1. DMGを開き、`DynamicPhotoWall.app`をApplicationsへコピーします。ZIPにも同じアプリが入っています。
2. アプリを起動し、必要なアクセス権限を許可します。
3. 使用ディスプレイと、写真フォルダーまたは「写真」アプリのアルバムを選び、「保存して適用」を押します。
4. 設定・一時停止・終了はメニューバーから操作できます。

更新前にメニューから旧版を終了し、Applicationsのアプリを置き換えてください。
写真と保存済みの設定は引き継げます。配布物には写真・個人設定を含みません。
アプリはアドホック署名です。Appleによる公証は行っていません。
Dockとメニューバーの表示はmacOSの設定に従います。

## 写真の共有

試験用の「ネットワーク」では、LAN内の接続先へ選択した写真と顔データを転送します。
接続要求は受信側の確認なしで受け入れます。クラウドへの写真送信や利用状況の収集はありません。
build 10以前の通信設定がある場合は、「新しい通信設定を作成」を選び、接続し直してください。

同期再生のカクつき改善は手動確認済みです。複数端末の網羅的な同期、異なる表示倍率、
画面の抜き差し、スリープ復帰、長時間運転の確認は継続中です。

詳しい操作は[Macガイド](https://github.com/mhanayama/dynamic-photo-wall/blob/main/macos/README.md)、
今回の変更は[更新内容](https://github.com/mhanayama/dynamic-photo-wall/blob/main/macos/docs/RELEASE-NOTES-2026-10-20.md)を参照してください。
`BUILD-INFO.txt`にビルド元のコミット、`SHA256SUMS.txt`にDMG・ZIPのチェックサムを記載しています。

## ライセンス

本体はMITライセンスです。再配布時も`LICENSE`と`THIRD-PARTY-NOTICES.md`を一緒に保存してください。

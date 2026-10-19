# Dynamic Photo Wall — Windows

Windows 11 x64向けの、写真がゆっくり動くデスクトップギャラリーです。
.NETランタイムを同梱しているため、追加インストールは不要です。

## 起動・更新

1. ZIPを任意のフォルダーへ展開し、`DynamicPhotoWall.exe`を起動します。
2. 使用ディスプレイと写真フォルダーを選び、「保存して表示開始」を押します。
3. 設定・一時停止・終了はタスクトレイから操作できます。

更新前に旧版をタスクトレイから終了し、展開先のファイルを置き換えてください。
設定とキャッシュは`%LOCALAPPDATA%\DynamicPhotoWall`に保存されます。
EXEを移動した場合、ログオン時の自動起動は設定し直してください。
写真は配布物に含みません。同じ場所に`photos`フォルダーを作るか、設定で選択します。
本体は署名なし・インストーラーなしです。

## ネットワーク機能と検証範囲

オンラインモードでは、LAN内の接続ピアへ選択した写真と顔データを転送します。
接続要求は受信側の確認なしで受け入れます。クラウドへの写真アップロードや
テレメトリはありません。Mac↔Windowsの実機同期は未検証の試験用機能です。
混在DPI、画面の実ケーブル抜差し、長時間運転も実機受け入れが残っています。

詳しい操作・制約は[Windowsガイド](https://github.com/mhanayama/dynamic-photo-wall/blob/main/windows/README.md)、
今回の変更は[リリースノート](https://github.com/mhanayama/dynamic-photo-wall/blob/main/windows/docs/RELEASE-NOTES-2026-10-19.md)を参照してください。
`BUILD-INFO.txt`にはビルド元のコミットと依存バージョン、配布用の`SHA256SUMS.txt`にはEXEとZIPのSHA-256を記録します。

## ライセンス

本体はMITライセンスです。`LICENSE`と`THIRD-PARTY-NOTICES.md`、各依存ライブラリの
ライセンス・通知ファイルを、再配布時も一緒に保存してください。

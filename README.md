# Dynamic Photo Wall

お気に入りの写真がゆっくり動く、デスクトップ用のフォトギャラリーです。
WindowsとMacに対応し、複数の画面をつなげて表示することもできます。

## ダウンロード

| OS | ダウンロード | 対応環境 |
|---|---|---|
| Windows | [Windows版（10月20日更新）](https://github.com/mhanayama/dynamic-photo-wall/releases/tag/windows-v0.1.0) | Windows 11、x64 |
| Mac | [Mac版（10月20日更新）](https://github.com/mhanayama/dynamic-photo-wall/releases/tag/macos-v1.1.0) | Apple Silicon、macOS 27.0以降 |

**Windows:** ZIPを展開し、`DynamicPhotoWall.exe`を起動します。.NETのインストールは不要です。

**Mac:** DMGを開き、アプリをApplicationsへコピーします。Appleによる公証は行っていません。

起動したら、表示する画面と写真フォルダーを選んで保存すると再生が始まります。
Macでは「写真」アプリのアルバムも選べます。
更新するときは、旧版を終了してから置き換えてください。写真と保存済みの設定は引き継げます。

## できること

- 写真を並べる、横に流す、縦横に動かす、ゆっくり拡大する、5つの表示モード。
- 複数の画面をつなげた表示と、画面ごとの独立した再生。
- 顔が見えるように構図を調整し、写真の色に合わせて変わる背景。
- 一時停止、次の構成への切り替え、ログイン時の自動起動。

### 動作デモ

3台のモニターで再生している約11秒の動画です。音声はありません。人物写真はAIで生成した架空の人物です。

https://github.com/user-attachments/assets/83bbe258-322d-41b4-ae13-ecd4524e761b

## 写真とネットワーク機能

写真の表示と顔検出は端末内で処理します。クラウドへの写真送信や利用状況の収集はありません。

Windows版とMac版の試験用ネットワーク機能では、LAN内の端末間で写真を共有し、同期再生できます。
オンラインモードでは、選択した写真と顔データを接続先へ送ります。接続要求は受信側の確認なしで受け入れます。
端末間の同期、異なる表示倍率の画面、画面の抜き差し、長時間運転は引き続き確認中です。

## 使い方・開発

- [Windowsの使い方](windows/README.md) / [Macの使い方](macos/README.md)
- [Windowsの更新内容](windows/docs/RELEASE-NOTES-2026-10-20.md)
- [Macの更新内容](macos/docs/RELEASE-NOTES-2026-10-20.md)
- [ビルド・テストと開発資料](docs/DEVELOPMENT.md)

本体は[MITライセンス](LICENSE)です。[外部ライブラリの通知](THIRD-PARTY-NOTICES.md)も参照してください。

# Dynamic Photo Wall

写真がゆっくり動くデスクトップギャラリーです。WindowsとmacOSで、複数の画面をひとつのフォトウォールにしたり、グループごとに独立して再生したりできます。

## ダウンロード

| OS | 配布版 | 動作環境 |
|---|---|---|
| Windows | [Windows v0.1.0（2026-10-19更新）](https://github.com/mhanayama/dynamic-photo-wall/releases/tag/windows-v0.1.0) | Windows 11 x64。.NET同梱、インストール不要 |
| macOS | [v1.1.0 build 14 プレリリース](https://github.com/mhanayama/dynamic-photo-wall/releases/tag/macos-v1.1.0-build.14) / [v1.1.0 build 4 正式版](https://github.com/mhanayama/dynamic-photo-wall/releases/tag/macos-v1.1.0) | Apple Silicon（arm64）、macOS 27.0以降 |

WindowsはZIPを展開して`DynamicPhotoWall.exe`を起動し、使用ディスプレイと写真フォルダーを選んで「保存して表示開始」を押します。更新前に旧版をタスクトレイから終了してください。設定・キャッシュは`%LOCALAPPDATA%\DynamicPhotoWall`に保存されます。

macOSはZIPまたはDMGの`DynamicPhotoWall.app`をApplicationsへ移して起動します。配布物はad-hoc署名で、Appleの公証はありません。写真・フォルダー・通知・LANの権限はOSの確認に従ってください。

Windows最新版とmacOSプレリリースには試験用のネットワーク機能を含みます。Mac↔Windows間の実機同期の受け入れは継続中です。macOSの公開済み配布物はbuild 14、ローカル候補はbuild 17です。Zoomの構図と同期Galleryの継続、同期描画の負荷軽減に加え、画面更新周期と次計画準備による描画の停止を修正しました。Windows側もGallery継続修正を含む`d67fd1f`以降からビルドしてください。

詳しい操作と制約: [Windowsガイド](windows/README.md) / [macOSガイド](macos/README.md)。変更点: [Windows更新内容](windows/docs/RELEASE-NOTES-2026-10-19.md) / [macOS build 14](macos/docs/RELEASE-NOTES-v1.1.0-build14.md) / [macOS build 17のローカル候補](macos/docs/RELEASE-NOTES-v1.1.0-build17.md)。

## 動作デモ

3台のモニターに写真を並べて表示し、ゆっくりと動かす様子です。

https://github.com/user-attachments/assets/83bbe258-322d-41b4-ae13-ecd4524e761b

実際の稼働画面をスマートフォンで撮影した約11秒の動画です（音声なし）。動画内の人物写真は、AIで生成した架空の人物です。

## 主な機能

- Gallery、Scrolling Gallery、縦パン、横パン、Zoomの5モード。
- 複数画面をまたぐ表示、独立グループ、モードごとの画面単位表示。
- ローカルの顔検出による構図調整と画面境界の回避、小画像の自動ミラー。
- 写真の色を使った動的背景、滑らかな写真交換、再生・一時停止・次の構成。
- macOSはフォルダーに加え、写真アプリのアルバムにも対応。
- 試験用オンラインモードでは、LAN内の写真共有・暗号化転送・共通時計による同期再生に対応。

写真と顔検出は端末内で処理し、クラウドへの写真アップロードやテレメトリは行いません。オンラインモードを有効にしてピアを接続すると、選択した写真と顔データを接続端末へ転送します。接続要求は受信側の確認なしで受け入れる設計です。[通信仕様と検証範囲](docs/NETWORK-CORE.md)、[Macの鍵保存方式](macos/docs/LOCAL-NETWORK-STORAGE.md)を参照してください。

## ソースからビルド

### Windows

Windows 11 x64と.NET 10 SDKが必要です。初回の復元にはNuGet接続が必要です。リポジトリ直下で実行します。

```powershell
.\windows\scripts\Build.ps1 -Test
.\windows\Start-PhotoWall.ps1
# ZIPとSHA-256も作成する場合
.\windows\scripts\Package.ps1 -Test
```

配布先は`release/windows/win-x64/`。ランタイム同梱の単一EXEと、本体・依存ライブラリのライセンス、説明書、ビルド情報を生成します。Visual Studioでは`windows/DynamicPhotoWall.sln`を開きます。

### macOS

Apple SiliconのMacとXcode 27.0が必要です。

```sh
open macos/DynamicPhotoWall.xcodeproj
bash macos/scripts/verify.sh
bash macos/scripts/package.sh
```

配布先は`release/macos/arm64/`（APP / ZIP / DMG / SHA256SUMS）。WindowsからmacOS版はビルドできません。検証は既定でGUI操作なしです。実操作付きのテストは明示的に依頼された場合だけ行います。

## 開発資料

| 場所 | 内容 |
|---|---|
| `windows/` | WPFアプリ、OS非依存Core、テスト、ビルド・配布スクリプト |
| `macos/` | SwiftUI / AppKitアプリ、テスト、検証・配布スクリプト |
| `shared/DynamicPhotoWall.Networking/` | .NETのネットワーク基盤。Mac側は同じ通信契約をSwiftで実装 |
| `tests/` | OS共通fixture、描画計画の照合、通信試験 |
| `assets/` | 共通アイコン素材 |
| `docs/` | 共通仕様・計画・作業規則 |

- [生成物と作業ディレクトリの規則](docs/GENERATED-FILES.md): 完成物は`release/<OS>/`、ログ・診断・stagingは`artifacts/<OS>/`。いずれもGit対象外です。
- [Macへの差分引き継ぎ](macos/WINDOWS_DELTA_HANDOVER.md) / [Macの差分監査とTODO](macos/MACOS_PARITY_TODO.md)
- [ネットワーク実装・検証](docs/NETWORK-CORE.md) / [ピア間設計](docs/NETWORK-PEER-DESIGN.md) / [クロスプラットフォーム計画](docs/CROSS-PLATFORM-WALL-PLAN.md)

混在DPI、実ケーブル抜差し、長時間運転、実端末間の同期などの受け入れ確認は継続中です。単体テストの合格と実機確認は区別して記録します。

## ライセンス

本体コードは[MIT License](LICENSE)です。依存ライブラリとテスト画像はそれぞれのライセンスに従います。[外部コンポーネント](THIRD-PARTY-NOTICES.md)と[Windows配布物の通知](windows/THIRD-PARTY-NOTICES.md)を参照してください。写真・個人設定・鍵・キャッシュは配布物に含みません。

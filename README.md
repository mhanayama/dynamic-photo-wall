# Dynamic Photo Wall

写真がゆっくり動くデスクトップギャラリーです。Windows版とmacOS版を、このリポジトリで管理します。写真はローカルで処理します。

## 動作デモ

3台のモニターに写真を並べて表示し、ゆっくりと動かす様子です。デスク全体をひとつのフォトギャラリーにできます。

https://github.com/user-attachments/assets/83bbe258-322d-41b4-ae13-ecd4524e761b

実際の稼働中の画面をスマートフォンで撮影した約11秒の動画です（音声なし）。動画内の人物写真は、AIで生成した架空の人物です。

| プラットフォーム | 状態 | 開発・利用ガイド |
|---|---|---|
| Windows | WPF常駐アプリ。複数画面をつなぐ表示・配置設定、Gallery・横スクロール・パン・Zoom・顔検出・動的背景を実装 | [Windows版README](windows/README.md) |
| macOS | SwiftUI / AppKit版。複数画面・独立グループ・顔境界回避・画面単位モード・小画像ミラー・Gallery余白改善を実装。隔離自動テストと実機受け入れを継続 | [macOS版README](macos/README.md) / [差分監査とTODO](macos/MACOS_PARITY_TODO.md) |

## ディレクトリ構成

```text
dynamic-photo-wall/
├── windows/                         # Windows版
│   ├── DynamicPhotoWall.sln
│   ├── Directory.Build.props
│   ├── global.json
│   ├── src/                         # WPFアプリと.NET Coreロジック
│   ├── tests/
│   ├── scripts/                     # ビルド・ショートカット・診断
│   ├── assets/
│   ├── docs/                        # Windows設計・テスト結果
│   ├── Start-PhotoWall.ps1
│   ├── THIRD-PARTY-NOTICES.md
│   └── README.md
├── macos/                           # macOS版
│   ├── DynamicPhotoWall.xcodeproj
│   ├── DynamicPhotoWall/             # Swiftアプリ・アセット
│   ├── DynamicPhotoWallTests/
│   ├── DynamicPhotoWallUITests/
│   ├── MACOS_PARITY_TODO.md
│   └── README.md
├── docs/                            # プラットフォーム共通の計画・作業規則
├── release/                         # 両OSの配布物（Git対象外）
│   ├── windows/win-x64/
│   └── macos/arm64/
├── photos/                          # ローカル写真（Git対象外）
└── artifacts/                       # ビルド・検証結果（Git対象外）
```

`windows/src/DynamicPhotoWall.Core` は現在Windows側で利用するOS非依存の.NETロジックです。macOS版はSwift実装を持ちます。両OS共通の実装ができた場合に、独立した共通ディレクトリへ切り出します。

## Windows

ビルドにはWindows 11 x64と.NET 10 SDKが必要です。リポジトリ直下から実行します。作成したEXEの利用には.NETの別途インストールは不要です。

```powershell
.\windows\scripts\Build.ps1 -Test
.\windows\Start-PhotoWall.ps1
```

ビルド後は **`release/windows/win-x64/DynamicPhotoWall.exe`をダブルクリック**して起動できます。ランタイム同梱の単一EXEで、ドキュメント・ライセンス・ショートカットも同じディレクトリに置きます。Visual Studioでは `windows/DynamicPhotoWall.sln` を開きます。設定・操作・制約は [Windows版README](windows/README.md) を参照してください。

## macOS

Xcodeで `macos/DynamicPhotoWall.xcodeproj` を開き、`DynamicPhotoWall` スキームで起動します。Apple Silicon（arm64）専用で、対象OSはmacOS 27.0以降です。

```sh
open macos/DynamicPhotoWall.xcodeproj
```

隔離した自動検証は `bash macos/scripts/verify.sh`、ローカルRelease候補の作成は `bash macos/scripts/package.sh` を使用します。最新のmacOS v1.1.0（build 12）は[プレリリース](https://github.com/mhanayama/dynamic-photo-wall/releases/tag/macos-v1.1.0-build.12)からダウンロードできます。ネットワーク機能は実機確認用で、実際のMac↔Windows間の同期表示は未検証です。[正式版のbuild 4](https://github.com/mhanayama/dynamic-photo-wall/releases/tag/macos-v1.1.0)も保持しています。変更点と検証範囲は[リリースノート](macos/docs/RELEASE-NOTES-v1.1.0-build12.md)、実機受け入れの残件はTODOを参照してください。

ビルド・テスト手順は [macOS版README](macos/README.md)、不足機能と検証範囲は [差分監査とTODO](macos/MACOS_PARITY_TODO.md) を参照してください。

2026-10-17に追加したWindowsのマルチディスプレイ・グループ・設定UI・即時テスト表示・顔によるパン方向・モード別の画面単位描画・スパン中の顔境界回避・小画像の縦パン自動ミラーのMac移植は、[差分引き継ぎ資料](macos/WINDOWS_DELTA_HANDOVER.md)を基準に進めます。Galleryは滑らかに再配置し、顔の境界回避は最終配置へ適用します。

WindowsのGalleryは、写真列を詰める配置と、キャッシュ済みの顔位置による再抽選で、顔回避に伴う余白や縮小を抑えます。Macへの移植条件も同資料のD09へ記載します。

## 生成物の置き場所

配布物は両OS共通の `release/` 配下へ置きます。Windowsは `release/windows/win-x64/`、Macは `release/macos/arm64/`。MacはZIP／DMGに加え、直接起動できる`DynamicPhotoWall.app`も残します。ログ・検証画像・archive・DerivedData・staging等は `artifacts/<OS>/` へ置き、プロジェクトルート直下へ一時ファイルやEXE・ショートカットを出しません。[共通規則](docs/GENERATED-FILES.md)と[開発エージェント向け指示](AGENTS.md)を参照してください。

## 共通の計画

[Mac + Windows：3画面同期 Photo Wall 計画](docs/CROSS-PLATFORM-WALL-PLAN.md)と[ネットワーク実装・検証記録](docs/NETWORK-CORE.md)を参照してください。通信・統合画面設定・写真転送・同期表示を追加しました。Windowsに加え、Macのコンパイル・隔離テストとMac上のSwift／.NET間の相互TLS・multicast検出を確認しました。実際のMac↔Windows間のLAN・同期表示は実機確認が残ります。

[ピア間ネットワーク機能](docs/NETWORK-PEER-DESIGN.md)は、進行役の自動交代と任意ピアからの全体設定に対応する設計です。全ピアの画面を一つの一覧で扱い、画面ごとにピアをまたぐグループへの所属または単独表示を選びます。既に接続されたグループ同士の合流も扱います。

「オンラインモード」を有効にすると待受とLAN上のピア検出を開始し、接続候補から「接続」を選びます。受信側は確認操作なしで接続を受け入れる設計です。

同期再生は、各ピアが共通時刻を参照できる前提で、写真・表示計画を先読みし、予定時刻から既存の表示ロジックで描画位置や切替を決める設計です。

写真ソースの設定適用時に、提供ピアから利用ピアへのキャッシュ転送をバックグラウンドで開始します。原寸・元の画質を保ち、読み込み時に生成する顔メタデータも同期します。同じ提供ピアのソースを再選択・適用した場合は旧キャッシュを削除・更新し、有効期限は14日とします。写真と顔データは通信中・保存時とも暗号化し、復号鍵は各端末のOSの保護機能で管理する計画です。

切断時はOS通知を送り、残ったピア同士は同期を続けます。進行役が停止した場合は残存ピアから後任を自動選出します。孤立したピアは直前の表示モードを1分間繰り返し、その後スタンドアロンへ移ってもバックグラウンドで通信リトライを継続します。再接続時もOS通知を送り、準備後に共通時刻で表示同期へ戻る設計です。

ネットワーク基盤はWindows Coreから独立した`shared/DynamicPhotoWall.Networking`へ分離しました。Mac側は同じ通信契約と部品の責任分担をSwiftで実装し、共通fixtureで照合します。Macの検証手順は`bash macos/scripts/verify.sh --unit-only`、通信の相互検証は`bash macos/scripts/verify-network-interop.sh --with-discovery`です。[Mac検証記録](macos/docs/NETWORK-TEST-RESULTS-2026-10-18.md)を参照してください。新しいネットワーク機能は、両OSの実機相互接続が確認できるまで検証済み完成物として配布しません。

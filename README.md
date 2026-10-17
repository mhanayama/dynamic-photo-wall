# Dynamic Photo Wall

写真がゆっくり動くデスクトップギャラリーです。Windows版とmacOS版を、このリポジトリで管理します。写真はローカルで処理します。

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

隔離した自動検証は `bash macos/scripts/verify.sh`、ローカルRelease候補の作成は `bash macos/scripts/package.sh` を使用します。macOS v1.0.1（build 3）は[GitHub Release](https://github.com/mhanayama/dynamic-photo-wall/releases/tag/macos-v1.0.1)で公開済みです。実機受け入れの残件はTODOで継続管理します。

ビルド・テスト手順は [macOS版README](macos/README.md)、不足機能と検証範囲は [差分監査とTODO](macos/MACOS_PARITY_TODO.md) を参照してください。

2026-10-17に追加したWindowsのマルチディスプレイ・グループ・設定UI・即時テスト表示・顔によるパン方向・モード別の画面単位描画・スパン中の顔境界回避・小画像の縦パン自動ミラーのMac移植は、[差分引き継ぎ資料](macos/WINDOWS_DELTA_HANDOVER.md)を基準に進めます。Galleryは滑らかに再配置し、顔の境界回避は最終配置へ適用します。

WindowsのGalleryは、写真列を詰める配置と、キャッシュ済みの顔位置による再抽選で、顔回避に伴う余白や縮小を抑えます。Macへの移植条件も同資料のD09へ記載します。

## 生成物の置き場所

配布物は両OS共通の `release/` 配下へ置きます。Windowsは `release/windows/win-x64/`、Macは `release/macos/arm64/`。ログ・検証画像・archive・DerivedData・staging等は `artifacts/<OS>/` へ置き、プロジェクトルート直下へ一時ファイルやEXE・ショートカットを出しません。[共通規則](docs/GENERATED-FILES.md)と[開発エージェント向け指示](AGENTS.md)を参照してください。

## 共通の計画

[Mac + Windows：3画面同期 Photo Wall 計画](docs/CROSS-PLATFORM-WALL-PLAN.md)。Windows内の複数画面表示と配置設定を実装済み。MacとのPC間同期は今後の段階です。

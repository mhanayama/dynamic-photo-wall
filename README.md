# Dynamic Photo Wall

写真がゆっくり動くデスクトップギャラリーです。Windows版とmacOS版を、このリポジトリで管理します。写真はローカルで処理します。

| プラットフォーム | 状態 | 開発・利用ガイド |
|---|---|---|
| Windows | WPF常駐アプリ。Gallery・横スクロール・パン・Zoom・顔検出・動的背景を実装 | [Windows版README](windows/README.md) |
| macOS | SwiftUI / AppKit版を開発中。Windows版との差分対応が残る | [macOS版README](macos/README.md) / [差分監査とTODO](macos/MACOS_PARITY_TODO.md) |

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
├── docs/                            # プラットフォーム共通の計画
├── photos/                          # ローカル写真（Git対象外）
└── artifacts/                       # ビルド・検証結果（Git対象外）
```

`windows/src/DynamicPhotoWall.Core` は現在Windows側で利用するOS非依存の.NETロジックです。macOS版はSwift実装を持ちます。両OS共通の実装ができた場合に、独立した共通ディレクトリへ切り出します。

## Windows

リポジトリ直下から実行します。Windows 11 x64と.NET 10 SDKが必要です。

```powershell
.\windows\scripts\Build.ps1 -Test
.\windows\Start-PhotoWall.ps1
```

実行ファイルは `artifacts/win-x64`、ショートカットはリポジトリ直下に作成します。Visual Studioでは `windows/DynamicPhotoWall.sln` を開きます。設定・操作・制約は [Windows版README](windows/README.md) を参照してください。

## macOS

Xcodeで `macos/DynamicPhotoWall.xcodeproj` を開き、`DynamicPhotoWall` スキームで起動します。現在のプロジェクトの対象OSはmacOS 27.0以降です。

```sh
open macos/DynamicPhotoWall.xcodeproj
```

ビルド・テスト手順は [macOS版README](macos/README.md)、不足機能と検証範囲は [差分監査とTODO](macos/MACOS_PARITY_TODO.md) を参照してください。

## 共通の計画

[Mac + Windows：3画面同期 Photo Wall 計画](docs/CROSS-PLATFORM-WALL-PLAN.md)。macOS単体版の完成後に、Windowsの複数画面表示とPC間同期へ進む計画です。

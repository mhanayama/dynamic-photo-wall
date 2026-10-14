# Dynamic Photo Wall app icons

承認済みの「3枚の写真パネル」のデザインを共通にした、1024 × 1024 pxのPNGリソースです。

| 用途 | 完成画像 | Icon Composerの外観 |
| --- | --- | --- |
| Light | [PhotoWall-light.png](PhotoWall-light.png) | Default |
| Dark | [PhotoWall-dark.png](PhotoWall-dark.png) | Dark |
| Liquid Glass風 | [PhotoWall-liquid-glass.png](PhotoWall-liquid-glass.png) | Mono（クリア／tinted系） |

各画像は背景込みの正方形です。外側の角丸マスクは描き込んでいません。`*-source.png`は生成時の原寸で、完成画像とmacOS用サイズはそこから書き出しています。[生成プロンプト](PROMPTS.md)も保存しています。

## macOSアプリへの反映

現在のアプリアイコンは [PhotoWall.icon](../../macos/DynamicPhotoWall/PhotoWall.icon/icon.json) です。MacのIcon Composerで開き、3種類の完成PNGを別レイヤーとして設定し、Default / Dark / Monoの各外観で対応する1枚だけを表示します。元PNGは変更せず、`.icon/Assets`へ同梱しています。

XcodeのDebug／Releaseとも **Primary App Icon Set Name**（`ASSETCATALOG_COMPILER_APPICON_NAME`）を`PhotoWall`に指定しています。`.icon`はアプリの同期フォルダ内にあり、通常のビルド／archiveでコンパイルされます。Icon Composerで編集する場合は `macos/DynamicPhotoWall/PhotoWall.icon` を開いてください。

従来の`AppIcon` / `AppIconDark` / `AppIconGlass`の10スロット入り`.appiconset`は比較・再書き出し用に残しています。現在のアプリアイコンの外観切替は`.icon`側で管理します。

通常のSwiftUI画像リソースも同梱しています。

```swift
Image("PhotoWallIcon")       // ビューのLight / Darkに応じて画像が変わる
Image("PhotoWallIconGlass")  // Glass版の完成画像
```

このimagesetの切替はビュー用です。アプリアイコンの外観はOSが選択し、`PhotoWall.icon`内のDefault / Dark / Monoの設定が使われます。

## Icon Composerでの仕上げ

3種類とも背景込みの完成画像なので、画像レイヤーの追加glass効果とグループの透過・影を無効にし、用意されたデザインを維持しています。外側のマスクと各外観の出力はIcon Composer／Xcodeへ任せます。

`PhotoWall-liquid-glass.png`はMono用のガラス調アートワークです。3枚の写真パネルそれぞれが独立した屈折レイヤーになった構成ではありません。パネル単位の屈折や照明を後から調整する場合は、背景と各パネルを別素材として用意する必要があります。

Apple公式: [Icon Composer](https://developer.apple.com/icon-composer/) / [Xcodeへの組み込み](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer) / [アプリアイコン指針](https://developer.apple.com/design/human-interface-guidelines/app-icons/)

## 再書き出しと確認範囲

Windows版は[背景透過PNG](PhotoWall-windows-transparent.png)を使用します。Lightと同じ3枚のパネルを背景から切り抜いたWindows専用リソースで、Mac用の背景込み画像とは別に保存しています。`windows/assets/PhotoWall-apple-style.ico`は16 / 24 / 32 / 48 / 64 / 128 / 256 pxを収録し、EXE・設定画面・タスクトレイで共通利用します。元PNGのalphaを維持してICOのみを書き出します:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File windows/scripts/Export-AppIcon.ps1
```

WindowsのPowerShellで、リポジトリ直下から実行します。生成AIへの再リクエストは行わず、原寸画像のリサイズとアセットカタログの書き出しだけを行います。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File assets/app-icon/Export-AppIcons.ps1
```

PNGのサイズ、全30スロットの参照先、画像リソースの参照先をWindows上で確認しています。macOSではIcon Composerの3外観プレビュー、Release archive、`CFBundleIconName = PhotoWall`、コンパイル済みAssets.car内のAqua / DarkAqua / Tintableと対応するPNGレイヤーを確認済みです。アプリ起動・Dockでの外観切替確認は未実施です。

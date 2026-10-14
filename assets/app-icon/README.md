# Dynamic Photo Wall app icons

承認済みの「3枚の写真パネル」のデザインを共通にした、1024 × 1024 pxのPNGリソースです。

| 用途 | 完成画像 | macOSアプリアイコンセット |
| --- | --- | --- |
| Light | [PhotoWall-light.png](PhotoWall-light.png) | `AppIcon`（現在の既定） |
| Dark | [PhotoWall-dark.png](PhotoWall-dark.png) | `AppIconDark` |
| Liquid Glass風 | [PhotoWall-liquid-glass.png](PhotoWall-liquid-glass.png) | `AppIconGlass` |

各画像は背景込みの正方形です。外側の角丸マスクは描き込んでいません。`*-source.png`は生成時の原寸で、完成画像とmacOS用サイズはそこから書き出しています。[生成プロンプト](PROMPTS.md)も保存しています。

## macOSアプリへの反映

`macos/DynamicPhotoWall/Assets.xcassets`に3種類とも配置済みです。各`.appiconset`には16、32、128、256、512 ptの1x / 2x、計10スロットを収録しています。既存のApp Icon設定が`AppIcon`なので、次のビルドではLight版を使用します。

Dark版またはGlass版をアプリアイコンに固定する場合は、Xcodeの対象ターゲット → Build Settings → Asset Catalog Compiler - Options → **Primary App Icon Set Name**を`AppIconDark`または`AppIconGlass`に変更します。CLIでの確認例:

```sh
xcodebuild build \
  -project macos/DynamicPhotoWall.xcodeproj \
  -scheme DynamicPhotoWall \
  -destination 'platform=macOS' \
  -derivedDataPath artifacts/macos/DerivedData \
  ASSETCATALOG_COMPILER_APPICON_NAME=AppIconDark \
  CODE_SIGNING_ALLOWED=NO
```

通常のSwiftUI画像リソースも同梱しています。

```swift
Image("PhotoWallIcon")       // ビューのLight / Darkに応じて画像が変わる
Image("PhotoWallIconGlass")  // Glass版の完成画像
```

このimagesetの切替はビュー用です。Dockのアプリアイコンが外観に合わせて自動で切り替わる設定ではありません。

## ネイティブのLiquid Glassとの違い

`PhotoWall-liquid-glass.png`はガラス風の見た目を仕上げた静止画像です。壁紙に応じた屈折や照明の変化を持つ、Icon ComposerのネイティブなLiquid Glassアイコンではありません。透明な切抜きPNGや、独立したガラスレイヤーも今回の完成リソースには含めていません。

ネイティブ版を仕上げる場合は、MacのIcon Composerで3枚のパネルと風景を独立した透明PNG / SVGのレイヤーとして用意し、Default / Dark / Monoの外観を調整します。今回の3枚はその際の色・配置・質感のリファレンスに使えます。完成した`AppIcon.icon`をXcodeターゲットに追加し、App Icon名を`AppIcon`に設定します。平坦なPNGの上に効果を重ねるだけでは、パネルごとの屈折は再現できません。

Apple公式: [Icon Composer](https://developer.apple.com/icon-composer/) / [Xcodeへの組み込み](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer) / [アプリアイコン指針](https://developer.apple.com/design/human-interface-guidelines/app-icons/)

## 再書き出しと確認範囲

WindowsのPowerShellで、リポジトリ直下から実行します。生成AIへの再リクエストは行わず、原寸画像のリサイズとアセットカタログの書き出しだけを行います。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File assets/app-icon/Export-AppIcons.ps1
```

PNGのサイズ、全30スロットの参照先、画像リソースの参照先をWindows上で確認しています。Mac上のXcodeコンパイルとDockでの実表示は未確認です。

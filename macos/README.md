# Dynamic Photo Wall — macOS

SwiftUIで設定とシーンを構成し、AppKitで対象ディスプレイの背面ウィンドウと画像表示を制御するmacOS版です。Windows版との機能差分は [監査とTODO](MACOS_PARITY_TODO.md) に記載しています。

## 開発環境と起動

現在のプロジェクトはApple Silicon（arm64）搭載MacのmacOS 27.0以降を対象とし、Xcode 27.0でビルド確認しています。Debug／Releaseともarm64専用です。App Sandboxとユーザー選択フォルダの読取り権限を使用します。

リポジトリ直下から開きます。

```sh
open macos/DynamicPhotoWall.xcodeproj
```

`DynamicPhotoWall` スキーム、実行先 `My Mac` を選んでRunしてください。写真フォルダと対象画面を選び、表示を開始します。設定画面を閉じてもメニューバーから操作できます。

## ビルド

以下はすべてリポジトリ直下から実行します。生成物は `artifacts/macos` に保存します。

```sh
xcodebuild build \
  -project macos/DynamicPhotoWall.xcodeproj \
  -scheme DynamicPhotoWall \
  -destination 'platform=macOS' \
  -derivedDataPath artifacts/macos/DerivedData \
  CODE_SIGNING_ALLOWED=NO
```

これは署名なしのローカルコンパイル確認です。Xcodeからの実行や配布では、用途に合わせてSigning設定を使用してください。

## Releaseのパッケージ化

CLIでもReleaseのarchiveとZIPを作成できます。以下はローカル実行向けのアドホック署名を使用し、App Sandbox権限を保持する手順です。

```sh
mkdir -p artifacts/macos-release
xcodebuild archive \
  -project macos/DynamicPhotoWall.xcodeproj \
  -scheme DynamicPhotoWall \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath artifacts/macos-release/DerivedData \
  -archivePath artifacts/macos-release/DynamicPhotoWall.xcarchive \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES

ditto -c -k --sequesterRsrc --keepParent \
  artifacts/macos-release/DynamicPhotoWall.xcarchive/Products/Applications/DynamicPhotoWall.app \
  artifacts/macos-release/DynamicPhotoWall-macos-arm64.zip
```

プロジェクトの `ARCHS = arm64` を使用するため、Intel向けの実行ファイルは含みません。この手順ではDeveloper ID署名・公証は行いません。archiveとパッケージの生成だけでは、実行時の動作確認にはなりません。

## テスト

アプリを起動せず、単体／UIテストのコンパイルを確認する場合:

```sh
xcodebuild build-for-testing \
  -project macos/DynamicPhotoWall.xcodeproj \
  -scheme DynamicPhotoWall \
  -destination 'platform=macOS' \
  -derivedDataPath artifacts/macos/DerivedData \
  CODE_SIGNING_ALLOWED=NO
```

XcodeのProduct → Test、または次のコマンドで単体テストを実行できます。

```sh
xcodebuild test \
  -project macos/DynamicPhotoWall.xcodeproj \
  -scheme DynamicPhotoWall \
  -destination 'platform=macOS' \
  -derivedDataPath artifacts/macos/DerivedData \
  -only-testing:DynamicPhotoWallTests
```

単体テストはアプリをホストとして起動します。モデルの回帰テストは専用UserDefaultsとfake host／scannerを使用します。ホスト起動時もXCTest環境を検出して専用設定を使いますが、この隔離経路の実行確認はまだ行っていません。UIテストも起動と起動時間計測のテンプレート段階で、機能合格の判定には使えません。実行環境と検証範囲は [TODOの検証結果](MACOS_PARITY_TODO.md#実装進捗2026-10-14) を参照してください。

## 現在の実装進捗

P0の画面ID・再生位置・走査競合・空ライブラリ・無効モード・ブックマーク保持に対応し、写真選択、状態付き再生、一時停止、Retina用の物理座標計画、Gallery交換と横Galleryの流入更新を実装しています。実行テストと実画面の受け入れは未実施です。残件は [TODO](MACOS_PARITY_TODO.md) を参照してください。

ライブラリ更新時の表示保持、横Galleryの次画像準備待ち、全件読込み失敗後の待機／再試行、表示幅に合わせた寸法別デコードも実装済みです。[機能差レビュー](WINDOWS_PARITY_REVIEW.md) に修正範囲と残る確認を記載しています。

Releaseのpackagingは上記のCLI手順、またはXcodeのProduct → Archiveで行えます。

## 管理するファイル

アプリアイコンはIcon Composerの `DynamicPhotoWall/PhotoWall.icon` を使用し、DefaultにLight、DarkにDark、MonoにLiquid Glass版のPNGを割り当てています。Debug／ReleaseともApp Icon名は `PhotoWall` です。編集方法は [アイコンリソース](../assets/app-icon/README.md) を参照してください。

アプリ・テスト・アセット・Xcodeプロジェクト・共有スキーム・ドキュメントを親のGitリポジトリで管理します。`xcuserdata`、DerivedData、コンパイルキャッシュは個人環境の状態として除外します。

[プロジェクト全体](../README.md) / [Windows版](../windows/README.md) / [クロスプラットフォーム計画](../docs/CROSS-PLATFORM-WALL-PLAN.md)

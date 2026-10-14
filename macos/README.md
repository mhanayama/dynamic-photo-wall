# Dynamic Photo Wall — macOS

SwiftUIで設定とシーンを構成し、AppKitで対象ディスプレイの背面ウィンドウと画像表示を制御するmacOS版です。Windows版との機能差分は [監査とTODO](MACOS_PARITY_TODO.md) に記載しています。

## 開発環境と起動

現在のプロジェクトはmacOS 27.0以降を対象とし、Xcode 27.0でビルド確認しています。App Sandboxとユーザー選択フォルダの読取り権限を使用します。

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

単体テストはアプリをホストとして起動します。ユーザー設定と独立した検証プロファイルは未整備です。UIテストも起動と起動時間計測のテンプレート段階で、機能合格の判定には使えません。実行環境と検証範囲は [TODOの検証結果](MACOS_PARITY_TODO.md#今回の検証結果) を参照してください。

## 管理するファイル

アプリ・テスト・アセット・Xcodeプロジェクト・共有スキーム・ドキュメントを親のGitリポジトリで管理します。`xcuserdata`、DerivedData、コンパイルキャッシュは個人環境の状態として除外します。

[プロジェクト全体](../README.md) / [Windows版](../windows/README.md) / [クロスプラットフォーム計画](../docs/CROSS-PLATFORM-WALL-PLAN.md)

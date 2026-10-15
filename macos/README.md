# Dynamic Photo Wall — macOS

Apple Silicon搭載Mac、macOS 27.0以降、Xcode 27.0向けです。SwiftUI＋AppKitで写真を対象ディスプレイの背面へ表示します。App Sandboxと、ユーザーが選択したフォルダーへの読取り権限を使用します。

## 起動と設定

```sh
open macos/DynamicPhotoWall.xcodeproj
```

`DynamicPhotoWall` スキームでRunし、写真フォルダーと対象画面を選んで「保存して表示開始」を押します。JPEG／PNG／WebP／HEIC／HEIFを扱います。

フォルダーは行のゴミ箱、または複数選択して「選択を削除」で解除できます。画面・フォルダー・各設定は「保存して適用」までドラフトです。「変更を取り消す」または設定ウィンドウを閉じると、未保存の変更を破棄します。メニューからの開始は適用済みの設定を使います。

設定を閉じても再生とメニューは継続します。メニューバーから開始／停止／一時停止／次／設定再表示／終了を操作できます。通常起動は設定画面を表示し、設定済みのログイン起動はメニューへ常駐します。ログイン起動と、アプリ起動時に再生する設定は独立しています。ログイン項目が承認待ちの場合は、システム設定で許可します。

Dock／メニューバーの表示はmacOS側の設定に従います。これはWindowsの対象画面限定タスクバー非表示との、ユーザー合意済みのOS差分です。

## 機能と保存

5モード、重み・履歴・逐次選択、次構成の先読み、Gallery独立交換、連続スクロール、顔を考慮したPan／Zoom、表示中の切抜きに追従する小画像背景を実装しています。画像準備や再走査中も旧ビットマップを保持します。写真変更はイベント監視で約1秒後に反映し、5分ごとの照合も行います。対象画面が前面アプリに覆われると休止し、ユーザーpause・スリープと独立して復帰します。

本番データはsandbox内のApplication Supportの `DynamicPhotoWall/` に保存します。

- `settings.json`: 画面・設定・フォルダーブックマークの原子的保存。直前の保存は `.previous`、破損原本は `.invalid-UUID` へ退避。
- `metadata.json`／`faces.json`: ファイル更新情報に基づくキャッシュ。顔キャッシュは最大10,000件。
- `app.log`／`app.log.1`: 約2MBで1世代のログ。写真のパスやエラーを含むローカル診断情報。

従来のUserDefaults・単一／複数ブックマークは、初回の保存時に新形式へ移行します。解決不能なフォルダー登録は、明示的に削除するまで保持します。

## CLIビルドと隔離テスト

リポジトリ直下で実行します。テスト実行にはXcodeと.NET 10 SDKが必要です。

```sh
bash macos/scripts/verify.sh
```

単体テスト、実操作付きUIテスト、Windows Coreの共通fixture照合、arm64 Releaseコンパイルを実行します。追加の単体検証だけなら `--unit-only` を指定します。ログ・DerivedDataは `artifacts/macos-verification/`（Git対象外）です。

テスト用アプリIDは `asia.dix.mhanayama.DynamicPhotoWall.Regression`。通常アプリと別のsandbox／UserDefaultsを使います。UIテストにはfake画面・写真一覧・ログイン登録・デスクトップhostを渡すため、ユーザーの写真や表示中の壁、ログイン項目を変更しません。実画像テストは公開fixtureと一時ディレクトリを使います。

アプリを起動せずコンパイルだけ確認する場合:

```sh
xcodebuild build-for-testing \
  -project macos/DynamicPhotoWall.xcodeproj -scheme DynamicPhotoWall \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath artifacts/macos-compile/DerivedData CODE_SIGNING_ALLOWED=NO
```

## Release候補のパッケージ化

```sh
bash macos/scripts/package.sh
```

`artifacts/macos-release/candidate/` にarm64専用archive、アドホック署名付きZIP／DMG、SHA256SUMSを生成します。署名とCPU構成も検査します。Developer ID署名・公証・GitHubへの公開は含みません。XcodeのProduct → Archiveも利用できます。

公開済み `macos-v1.0.0` は以前の実装です。修正候補v1.0.1（build 3）は正式Releaseしていません。コード・自動テストの合格に加えて、[Release前の実機受け入れ](MACOS_PARITY_TODO.md#release前に残す実機受け入れ)を完了してから公開します。Spaces、実ログイン、画面抜差し、8時間運転の確認は自動テストの合格に含みません。

## アイコンと管理ファイル

Icon Composerの `DynamicPhotoWall/PhotoWall.icon` を使用し、DefaultにLight、DarkにDark、MonoにLiquid Glass用PNGを割り当てています。Debug／ReleaseともApp Icon名は `PhotoWall` です。[アイコンリソース](../assets/app-icon/README.md)を参照してください。

アプリ・テスト・アセット・プロジェクト・スクリプトは親Gitリポジトリで管理します。`xcuserdata`、DerivedData、生成物は除外します。

[機能差と全TODO](MACOS_PARITY_TODO.md) / [レビュー記録](WINDOWS_PARITY_REVIEW.md) / [プロジェクト全体](../README.md) / [Windows版](../windows/README.md)

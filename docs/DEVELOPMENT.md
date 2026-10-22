# ビルドと開発資料

各コマンドはリポジトリ直下で実行します。完成した配布物は`release/`、ログ・検証結果・作業ファイルは`artifacts/`へ出力します。
どちらもGit対象外です。[生成物の規則](GENERATED-FILES.md)に従ってください。

## Windows

Windows 11 x64と.NET 10 SDKが必要です。初回はNuGetへの接続が必要です。

```powershell
.\windows\scripts\Build.ps1 -Test
.\windows\Start-PhotoWall.ps1
# 配布ZIPとチェックサムを作る
.\windows\scripts\Package.ps1 -Test
```

完成物は`release/windows/win-x64/`です。起動スクリプトと、配布先のショートカットも、このEXEを起動します。
ZIPには本体、説明書、ライセンス、ビルド元のコミットを記録した`BUILD-INFO.txt`を含みます。
写真・個人設定・ローカルのショートカットは含めません。

## Mac

Apple SiliconのMac、Xcode 27.0、.NET 10 SDKが必要です。

```sh
bash macos/scripts/verify.sh
bash macos/scripts/package.sh
```

完成物は`release/macos/arm64/`のAPP・ZIP・DMG・SHA256SUMS.txtです。
ZIP／DMGにはREADME・ライセンス・ビルド元のコミットと実行ファイルのハッシュを記録した`BUILD-INFO.txt`も含みます。
動作確認済みAPPを再ビルドせずに再梱包する場合は`bash macos/scripts/package.sh --reuse-app <ビルド元commit>`を使います。
指定commitと現在のMac本体・プロジェクトに差分がある場合は再利用を中止します。
WindowsではMac版をビルドできません。パッケージ作成とGitHubへの公開は別の操作です。

## 検証

上記のテストコマンドはGUI操作なしで実行します。GUIを操作するテストは、ユーザーから明示的な実行指示がある場合だけ行います。
単体テストの成功と、実機での表示・長時間運転の確認は分けて記録します。

## 資料の入口

| 調べたいこと | 資料 |
|---|---|
| 詳しい設定と動作 | [Windows](../windows/REFERENCE.md) / [Mac](../macos/REFERENCE.md) |
| Windowsの設計 | [アーキテクチャ](../windows/docs/ARCHITECTURE.md) |
| Shared Core / Native Rendererの設計提案 | [現行分析](architecture/shared-core/CURRENT-ARCHITECTURE.md) / [全体設計・Render Plan](architecture/shared-core/PROPOSED-ARCHITECTURE.md) / [移行と検証](architecture/shared-core/MIGRATION-ROADMAP.md) / [リスク](architecture/shared-core/RISK-ASSESSMENT.md) / [ADR](architecture/shared-core/ADR-0001-SHARED-CORE.md) |
| 今回のWindows描画改善と測定 | [検証・測定記録](../windows/docs/SHARED-RENDERING-TRIAL-2026-10-20.md) |
| Macの同期描画改善 | [build 17](../macos/docs/RELEASE-NOTES-v1.1.0-build17.md) |
| ネットワークの仕様と検証 | [通信基盤](NETWORK-CORE.md) / [ピア間設計](NETWORK-PEER-DESIGN.md) |
| OSごとの違いと引き継ぎ | [Macへの引き継ぎ](../macos/WINDOWS_DELTA_HANDOVER.md) / [Macの残件](../macos/MACOS_PARITY_TODO.md) |

## Releaseの更新

公開一覧にはWindowsとMacの現行版をそれぞれ1件掲載します。ネットワーク機能は両OSとも試験用です。
置き換え済みのMac旧Releaseは下書きも含めて削除し、ソースのタグは残します。
削除前に本文・配布物を`artifacts/macos/`へ退避します。旧Releaseのダウンロードリンクは利用できなくなります。

Release本文は「変更点・使い方・注意点」に絞り、テスト件数や実装・測定の詳細は資料へリンクします。
既存タグの配布物を更新する場合は、実際のビルド元コミットを本文と`BUILD-INFO.txt`へ記録します。

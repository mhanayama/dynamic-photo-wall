# Windows配布検証 — 2026-10-19

対象: `windows-v0.1.0`の2026-10-19差し替え版。実装は`d67fd1f`までのGallery継続修正を含む。文書と配布スクリプトの整備後のコミットは、最終EXEの製品情報とZIP内`BUILD-INFO.txt`に記録する。

## 実行環境と結果

Windows x64、ローカル.NET SDK 10.0.401、.NET / Windows Desktop runtime 10.0.12、SkiaSharp 3.119.4。通常設定・ユーザー写真を使わず、`artifacts/windows/`配下の専用データで実行した。

| 検証 | 結果 |
|---|---|
| `windows/scripts/Package.ps1 -Test` | Release単一EXEの発行、ZIP作成・内容検証に成功 |
| Windows単体試験 | 43ケース、失敗0 |
| OS非依存ネットワーク試験 | 26ケース、241 assertions、失敗0。TLS・3ピア間転送／交代／再参加を含む |
| Zoom構図検証 | 5,120 assertions、成功 |
| 共通fixture | 従来基準704 assertions、Windows差分472 assertions、背景色12ケース、すべて成功 |
| ZIP | 明示した11ファイルのみ。内部EXEと配布EXEのSHA-256一致 |
| ライセンス | 本体MIT、復元済みの.NET・Windows Desktop・SkiaSharp各パッケージの原文を同梱 |
| スクリプト | PowerShell構文確認、Mac `package.sh`の`bash -n`が成功 |
| 発行EXEの依存読み込み | 隔離コピーを起動後に差し替え、`Accessibility`読込・WPF popup bridgeのJIT・物理ファイルの展開をGUIなしで確認 |

ログは`artifacts/windows/release-2026-10-19/`、各試験の結果は`artifacts/windows/smoke-data/`と`artifacts/windows/network-core/`。完成物は`release/windows/win-x64/`。プロジェクトルートの実ファイル一覧も比較する。

NuGetの脆弱性データ取得に`NU1900`警告が出たため、今回のビルドを脆弱性監査の成功とは扱わない。パッケージ復元・コンパイル・テストは成功した。

## トレイの右クリック失敗

実行中アプリのログに`FileNotFoundException: Accessibility, Version=4.0.0.0`と`PopupSecurityHelper.ForceMsaaToUiaBridge`を確認した。WPF側にも[同じ例外の報告](https://github.com/dotnet/wpf/issues/7751)がある。今回の隔離試験では、マネージドライブラリを展開しない旧方式でホストEXEを起動後に置き換えると、後から必要なランタイム依存を読み込めず診断プロセスが失敗した。`IncludeAllContentForSelfExtract=true`へ変更すると同じ試験が成功し、物理的な展開先も確認できた。

`Verify-PublishedRuntime.ps1`はこの試験を今後のパッケージ作成にも含める。`--check-runtime`はmutex・通常設定・`Application`作成より前に分岐し、GUIを開かない。トレイメニュー表示の例外はトレイ側で捕捉し、全体のUI例外処理によって再生を止めない。実際のトレイ操作の確認はこのCLI検証に含めない。

## 実施していない確認

GUI操作を伴う自動テストは実行していない。実端末のMac↔Windows LAN同期、混在DPI、実ケーブル抜差し、長時間運転、実画面のちらつきと提示時刻差は受け入れ残件。今回のWindows環境ではmacOSのビルド・パッケージ実行を確認しておらず、Mac側はシェル構文確認のみ。公開済みMac build 12は変更しない。

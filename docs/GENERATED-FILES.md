# 生成物と作業ディレクトリ

2026-10-17制定。Windows・macOS共通のリポジトリ規則。配布物はプロジェクトルート配下の`release/`、開発・検証の生成物は`artifacts/`へ分ける。OS環境によって作られる一時ファイルをルート直下へ置かない。

| 種類 | Windows | macOS |
|---|---|---|
| 配布用完成物 | `release/windows/win-x64/` | `release/macos/arm64/` |
| 内容 | 単一EXE、README・ライセンス・関連資料、起動ショートカット | ZIP、DMG、SHA256SUMS |
| パッケージ作業 | 必要な作業ファイルは`artifacts/windows/` | `artifacts/macos/package/`にarchive・DerivedData・ログ。DMG stagingはOS標準一時領域 |
| 検証・診断 | `artifacts/windows/<検証名>/` | `artifacts/macos/verification/`など |
| その他の一時ファイル | `artifacts/windows/tmp/`またはOS標準一時領域 | `artifacts/macos/tmp/`またはOS標準一時領域 |

`.NET`の既定のプロジェクト内`bin/`・`obj/`、ローカルSDK／パッケージ用`.tools/`は引き続き利用できる。Xcodeは`-derivedDataPath`と`-archivePath`で出力先を明示する。ログ・キャプチャ・fixture生成・コマンドのリダイレクトも、実行時のカレントディレクトリ任せにせず出力先を指定する。

ルート直下にEXE・APP・ZIP・DMG・ショートカット・ログ・一時JSON・クラッシュダンプを生成／コピーしない。`release/`と`artifacts/`はGit対象外で、写真や個人設定もコミットしない。`.DS_Store`・`Thumbs.db`・`Desktop.ini`などはignoreで防御するが、ignoreだけで散在を許容する規則ではない。OS管理の一時ファイルは標準一時領域を使ってよい。

アプリの通常設定・キャッシュ・ログは従来どおりユーザー領域へ置く（WindowsのLocalAppData、Macのsandbox内Application Support）。検証は専用プロファイルを使う。`--data-dir`や診断の`--output`で変更する場合も、ルート直下を指定しない。Windowsの`--probe`既定レポートはデータディレクトリの`probe-result.json`。

## 実行方法

リポジトリ直下から:

```powershell
.\windows\scripts\Build.ps1 -Test
.\windows\Start-PhotoWall.ps1
```

Windowsは`release/windows/win-x64/DynamicPhotoWall.exe`または同じディレクトリのショートカットからも起動できる。配布先の`photos/`は初期写真フォルダーとして利用できる。写真は設定から別フォルダーを選んでもよい。旧ルートEXEから移動した場合、ログオン自動起動を使用していれば新しいEXEから設定し直す。

```sh
bash macos/scripts/verify.sh
bash macos/scripts/package.sh
```

Macは検証結果を`artifacts/macos/verification/`、配布用ZIP／DMGを`release/macos/arm64/`へ出力する。archiveは`artifacts/macos/package/`に残し、完成した配布物へ混ぜない。DMG stagingはOS標準一時領域に作成し、終了時に削除する。GitHub Releaseへのアップロードは別操作。

## 変更・移行時の確認

- スクリプト、起動先、ショートカット、README、handoverを同じパスへ揃える。
- ビルド／検証／パッケージ化の前後でルート直下のファイル一覧を比較し、生成物が増えていないことを確認する。
- `git status --short --untracked-files=all`だけではignore済みの散在を検出できないため、実ファイル一覧も確認する。
- 既存のルート生成物を移す場合は対象を個別に確認し、ソースやユーザーファイルを一括削除しない。過去の検証記録にある旧パスは当時の証跡として残してよい。今後の手順には新パスを使う。

規則はルートの[AGENTS.md](../AGENTS.md)からも参照する。Mac移植時の確認事項は[handover](../macos/WINDOWS_DELTA_HANDOVER.md)を参照。

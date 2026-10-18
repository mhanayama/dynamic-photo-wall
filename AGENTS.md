# リポジトリ共通の作業規則

Windows・macOSのどちらで作業する場合も、[生成物と作業ディレクトリの規則](docs/GENERATED-FILES.md)に従う。

- 配布用の完成物はルートの`release/`へ置く。Windowsは`release/windows/win-x64/`、Macは`release/macos/arm64/`。
- ログ・スクリーンショット・診断結果・archive・DerivedData・パッケージ用staging・その他の一時生成物は`artifacts/windows/`または`artifacts/macos/`へ置く。OS標準の一時ディレクトリも使用できる。
- プロジェクトルート直下へEXE・APP・ZIP・DMG・ショートカット・ログ・一時ファイルを生成／コピーしない。コマンドの出力先を明示する。
- `release/`と`artifacts/`はGit対象外。コード・スクリプト・ドキュメント・共有テストfixtureをコミットする。
- ビルド／配布先を変えたら起動スクリプト・ショートカット・README・handoverも揃え、ルートへ生成物が増えていないことを確認する。
- GUI操作を伴う自動テストは、ユーザーから明示的な実行指示がある場合だけ行う。通常の検証は単体・CLI・ビルドを使う。Macの`verify.sh`は既定でGUI操作なし。`--ui`は明示依頼がある場合だけ指定する。

Macの差分実装は[引き継ぎ資料](macos/WINDOWS_DELTA_HANDOVER.md)を参照。既存のOS差分の合意と専用設定による隔離検証を維持する。

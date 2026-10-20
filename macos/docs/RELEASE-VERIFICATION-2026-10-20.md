# Mac配布検証 — 2026-10-20

## 配布物

ユーザーがカクつき改善を確認したv1.1.0 build 17のAPPを公開する。
本体のソースは`0159a24e02813b889ec438b8c218ca49405c1b82`。現在のMac本体・プロジェクトと差分はない。
APPを再ビルドせず、署名済みの全6ファイルを保持してREADME・ビルド情報・ライセンスを同梱し、ZIP／DMGを作り直した。

| 確認 | 結果 |
|---|---|
| Swift単体試験 | build 17作成時に209件 / 31 suites成功、GUI操作なし |
| 共通fixture・Zoom構図 | 704＋472 assertions、Zoom 5,120 assertions、背景色12ケース成功 |
| 共有ネットワーク試験 | 26ケース / 241 assertions成功 |
| Release本体 | build 17、arm64、署名・単一起動設定を確認。ユーザーが同期表示のカクつき改善を手動確認 |
| APPの保持 | 再梱包前・配布APP・ZIP内APP・DMG内APPの全6ファイルのSHA-256が一致 |
| ZIP／DMG | 同じAPPとREADME・BUILD-INFO.txt・LICENSE・THIRD-PARTY-NOTICES.mdを含む。署名・ZIP／DMG・SHA256SUMS.txt成功 |
| ビルド情報 | ソースcommit・バージョン・arm64・署名方式・実行ファイルのSHA-256を記録 |
| 個人データ | 写真・設定・鍵・キャッシュを含まない |
| Windows | 本体・配布物・Releaseの更新操作なし |

実行ファイルのSHA-256は`d8eab70d38bdf6733d4182ba5fca0b1afbb0af87b4b10bb9ecc9259a06c23a5b`。
テストとReleaseコンパイルは[build 17作成時の記録](RELEASE-NOTES-v1.1.0-build17.md)、測定は[原因調査](SYNC-FRAME-PACING-MEASUREMENTS-2026-10-20.md)を参照。
今回は本体ソースの変更・再ビルド・再起動・GUI自動操作を行っていない。

## 公開と保管

Windowsと同じく、初回公開時の`macos-v1.1.0`タグを保持して配布物を更新する。
実際のAPPのソースはRelease本文と同梱の`BUILD-INFO.txt`を参照する。
独立した旧Mac Release（build 14・build 12・v1.0.1・v1.0.0）は当初下書きで保管したが、ユーザーの追加指示により4件とも削除した。ソースタグは保持し、Releaseは現行Mac版とWindows版の各1件のみ。削除前に本文・添付ファイルを`artifacts/macos/github-release-20261020/deleted-release-backups/`へ保存し、GitHubのSHA-256との一致を確認した。

更新前のv1.1.0公開版（build 4）の本文・添付ファイルと、公開前後のRelease一覧・検証結果は`artifacts/macos/github-release-20261020/`へ保存する。
ローカルの再梱包前配布物は`artifacts/macos/package/previous-release.s0wPW8/`、完成物は`release/macos/arm64/`。
Appleによる公証とDeveloper ID署名は行っていない。ネットワーク機能は試験用で、網羅的な端末間同期・異なる表示倍率・画面の抜き差し・スリープ復帰・長時間運転の確認は継続中。

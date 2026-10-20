# Mac同期表示のカクつき — 引き継ぎ（2026-10-20）

## 最新状態：build 17のカクつき改善をユーザー確認済み

ユーザーの修正・Release APP置換指示により、display linkの周期修正に加え、全候補写真のID・URL・顔情報・参照表生成を専用の`PNPlanningCatalog` actorへ移した。同じ写真metadataと順序では不変snapshotを再利用する。準備中のNext・停止・進行役変更で古い計画を確定しないようにし、取消・顔情報更新・写真削除／並び替えも追加回帰で確認した。

Swift単体209件 / 31 suites、共通fixture・背景色・Zoom構図、ネットワーク26件 / 241 assertions、arm64 Releaseが成功。build 17の署名付きAPP／ZIP／DMGとSHA256SUMSを`release/macos/arm64/`へ置き換えた。release・archive・ZIP・DMGのAPP全6ファイルが一致し、ライセンス同梱も確認。旧配布物は`artifacts/macos/package/previous-release.IUtGFf/`。稼働build 16は終了・再起動していない。ユーザーが手動で起動し直して同期表示を確認する。[build 17のノート](RELEASE-NOTES-v1.1.0-build17.md)を参照。

配布後の手動テストで、ユーザーが「カクつかなくなった」と確認し、commit・push・PR作成とmainへのマージを指示した。初回画像表示時のCore Animation色変換・コピー等は未変更。長時間運転・複数画面・スリープ復帰の網羅的な確認や、通常アプリの定量再測定は残す。以下は調査・引き継ぎ時点の記録として保持する。

## 依頼と現在の状態

作業ブランチは `fix/macos-synchronized-frame-pacing`。ユーザーはWindowsとMacを同期再生し、比較する画面は双方1920×1080。Mac側の縦Panが速く見え、終端の差も大きいが、次のモードへの切替は同時に見えるとの報告があった。その後、Mac側のカクつきが報告された。

**最新の指示は、カクつきの原因調査と修正を優先し、速度差はその後に再観測された場合に調べること。** このブランチは、Macで検証・調査を継続するための修正候補である。Windows上での作成時はSwiftのコンパイル、新規テストの実行、実機での改善確認が未実施だった。下記のMac引き継ぎでコンパイルと自動回帰を確認したが、実機での改善確認は残る。配布APP・ZIP・DMGや通常稼働アプリは更新していない。

## Macでの引き継ぎ結果（2026-10-20）

`c509f6f`の差分を確認し、Xcode 27.1 / arm64 / .NET 10.0.402で `bash macos/scripts/verify.sh --unit-only` を実行した。製品コードの追加修正なしで以下が成功した。

- Swift単体206件 / 31 suites。新規の `displayTicksUseSharedTimeAcrossMissedFramesPauseAndHandoff` を含む。
- 従来fixture704 assertions、delta fixture472 assertions、背景色12ケース、Zoom構図5120 assertions。
- .NETネットワーク26ケース / 241 assertions / 0 failures。Windowsのsandboxで未完了だった相互TLSも含む。
- arm64 Releaseコンパイルと `LSMultipleInstancesProhibited=true` の確認。

最初のsandbox内実行はSwift macroとXcodeテスト通知の制限で停止したため、通常権限で再実行した。成功した実行ではSwiftソースのコンパイル警告なし。CoreSimulatorのバージョン通知、Core Imageの `MDB_MAP_FULL`、AppIntents未使用のメタデータ通知が出たが、全試験とReleaseビルドは成功した。

ログは `artifacts/macos/sync-frame-pacing/verify.log` と `artifacts/macos/verification/`、ネットワーク結果は `artifacts/macos/network-core/`。ルート直下の実ファイル一覧は検証前後で一致した。GUI自動操作、描画計測ハーネス、通常アプリの置換・再起動、配布物の更新は行っていない。

その後、ユーザーから原因調査の依頼を受け、本体の`PNPlayback`を通す専用ハーネスでdriverだけを切り替え、1920×1080・60Hz・120px/秒の縦Panを各3回測定した。旧方式は約57.5更新/秒で画面更新通知の4.223%に状態の据え置きがあり、display linkは60更新/秒で据え置き0%。render処理時間は両方式ともp95約0.44msで、相対待機による周期のずれが滑らかさを損ねる要因であることを再現した。[測定条件・結果・限界](SYNC-FRAME-PACING-MEASUREMENTS-2026-10-20.md)を参照。通常アプリと配布物は未更新で、報告された症状の唯一の原因・実提示の欠落率・実機での解消確認とは区別する。

さらに稼働build 16の`Animation Hitches`を20秒採取し、次計画作成の`PNScenePlanner.prepare`がMainActorを116ms・72ms占有し、同時刻にフレーム更新も止まることを確認した。全写真の参照表生成と`opaqueId`反復計算が中心。初回画像表示の色変換・コピー等でも約48msの占有があった。display linkへの置換だけではこれらを解消しないため、次の修正対象は計画の参照表・ID生成の退避／再利用と、初回表示準備の検証。これらは未修正。既存の描画CPUハーネスは独自の16ms driverで`PNPlayback`全体を通らないため、周期の比較には今回追加した`FramePacingBenchmark.swift`を使用する。実描画計測やGUI自動操作は明示依頼のある範囲で行い、自動回帰の成功をカクつき解消の証拠にしない。

## 調査結果と変更

`PNPlayback.startTimer()` は `render()` 完了後に `Task.sleep(16ms)` を行っていた。そのため、実際の呼出し間隔は16msに描画処理時間とスケジューリング遅延が加わる。60Hzの16.67ms周期とも位相が揃わず、更新の抜けや間隔の揺れにつながり得る。Windows上ではソースからの要因候補だったが、Macの隔離比較でこの更新周期の問題を再現した。報告された実機症状の主因・唯一の原因かどうかは、実際の同期条件で候補を確認するまで区別する。

次の差分を用意した。

- `PeerDisplayFrameDriver.swift`：選択したローカル画面の `NSScreen.displayLink(target:selector:)` から更新通知を受け、メインRunLoopのcommon modeで描画する。画面構成変更時に接続先を選び直し、終了時にinvalidateする。weak targetを介して参照循環を避ける。
- `PeerPlaybackOutput.swift`：16msの相対待機ループを上記driverへ置き換えた。再生位置は従来どおり共有時計から求め、コールバック回数やdisplay linkのローカル時刻を再生時計にしない。`automaticRendering: false` の隔離検証を維持し、driverも注入可能にした。
- `NetworkPresentationTests.swift`：偽driverと偽surfaceだけで、不規則な更新・更新の欠落・pause/resume・終端・予約された次モードへの切替・停止後のcallback解除を確認するテストを追加した。デスクトップウィンドウを生成・操作しない。

画面更新通知の仕様はAppleの [NSScreen.displayLink](https://developer.apple.com/documentation/appkit/nsscreen/displaylink(target:selector:)) と [CADisplayLink](https://developer.apple.com/documentation/quartzcore/cadisplaylink) を参照。複数ローカル画面の場合は選択された画面IDの先頭を更新の基準にする。異なるリフレッシュレートの画面すべてへ個別の垂直同期を保証する実装ではない。

## Macでの検証手順

```sh
git fetch origin
git switch fix/macos-synchronized-frame-pacing
git pull --ff-only
bash macos/scripts/verify.sh --unit-only
```

Swiftの型・actor isolation・AppKit APIと全単体テスト、arm64 Releaseコンパイルを確認する。新規テストは `NetworkPresentationTests.displayTicksUseSharedTimeAcrossMissedFramesPauseAndHandoff`。WindowsではAppKit SDKとSwiftが利用できず未実施だったが、Mac引き継ぎ時に成功した。

GUI操作を伴う自動テストは今回も許可されていない。`--ui` は指定しない。生成物は `artifacts/macos/`、完成した配布物は `release/macos/arm64/` に置く。検証は専用プロファイルを使い、通常設定や写真を変更しない。

ビルドと単体テストが通った後、隔離した同じ同期計画・画像・画面条件で旧版と修正版を比較する。MainActorの`PNPlayback.render()`処理時間、実更新間隔の分布、画面更新を逃した回数、CPUを測定し、16ms待機による揺れが消えるか確認する。display linkへの置換だけで改善しない場合は、ネットワーク受信処理・デコード・ログ・画面列挙などがMainActorを長時間占有していないか調べる。今回の差分で改善したと決めつけない。

手動で表示確認する際は、縦Pan中の滑らかさに加え、pause/resume、Next、Galleryの継続、モード切替時のフェード、画面構成変更、スリープ復帰を確認する。速度差は再観測時に別途計測する。配布更新・再起動を行う前に検証結果を記録する。

## Windows側で確認済みの範囲

- 保存済み共有レイアウトを読み取り、比較対象の共有寸法1920×1080、Windowsが追従側、共有Pan速度120px/秒、縦Panの画面別表示OFFを確認した。設定の書換えは行っていない。
- 既存の共通fixtureは704＋472 assertions成功。ただし、これは今回のSwift差分の実行検証ではない。
- 既存のネットワークCLI試験は26件中25件成功、237 assertions。相互TLSの1件はsandbox内のX509秘密鍵インポートで `CryptographicException` が発生した。今回のMac差分とは独立しており、成功扱いにしない。
- 診断用CLIで同期時計の±0.5%補正を確認した。120px/秒なら30秒で約18pxの差に相当するため、ユーザー報告の数十〜数百pxをそれだけで説明したとは扱わない。稼働中の両端末の時計を計測した値ではない。
- `git diff --check` 成功。ルート直下に生成物が増えていないことも確認した。Windows本体・共有wire・写真・設定・配布先の変更はない。速度差の診断ログ追加も、最新の優先順位に従い見送った。

作業用CLIと結果はGit対象外の `artifacts/windows/sync-pan-investigation/` にある。メモリダンプは写真・復号済みデータ・秘密情報を含み得るとして自動承認審査で拒否され、採取していない。今後の計測は処理時間や座標など必要な項目に限定する。

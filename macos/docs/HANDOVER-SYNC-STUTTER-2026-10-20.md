# Mac同期表示のカクつき — 引き継ぎ（2026-10-20）

## 依頼と現在の状態

作業ブランチは `fix/macos-synchronized-frame-pacing`。ユーザーはWindowsとMacを同期再生し、比較する画面は双方1920×1080。Mac側の縦Panが速く見え、終端の差も大きいが、次のモードへの切替は同時に見えるとの報告があった。その後、Mac側のカクつきが報告された。

**最新の指示は、カクつきの原因調査と修正を優先し、速度差はその後に再観測された場合に調べること。** このブランチは、Macで検証・調査を継続するための修正候補である。Windows上で作成しており、Swiftのコンパイル、新規テストの実行、実機での改善確認は未実施。配布APP・ZIP・DMGや通常稼働アプリは更新していない。

## 調査結果と変更

`PNPlayback.startTimer()` は `render()` 完了後に `Task.sleep(16ms)` を行っていた。そのため、実際の呼出し間隔は16msに描画処理時間とスケジューリング遅延が加わる。60Hzの16.67ms周期とも位相が揃わず、更新の抜けや間隔の揺れにつながり得る。これはソースから確認したカクつきの要因候補であり、今回の実機症状の主因と実測で確定したものではない。

次の差分を用意した。

- `PeerDisplayFrameDriver.swift`：選択したローカル画面の `NSScreen.displayLink(target:selector:)` から更新通知を受け、メインRunLoopのcommon modeで描画する。画面構成変更時に接続先を選び直し、終了時にinvalidateする。weak targetを介して参照循環を避ける。
- `PeerPlaybackOutput.swift`：16msの相対待機ループを上記driverへ置き換えた。再生位置は従来どおり共有時計から求め、コールバック回数やdisplay linkのローカル時刻を再生時計にしない。`automaticRendering: false` の隔離検証を維持し、driverも注入可能にした。
- `NetworkPresentationTests.swift`：偽driverと偽surfaceだけで、不規則な更新・更新の欠落・pause/resume・終端・予約された次モードへの切替・停止後のcallback解除を確認するテストを追加した。デスクトップウィンドウを生成・操作しない。

画面更新通知の仕様はAppleの [NSScreen.displayLink](https://developer.apple.com/documentation/appkit/nsscreen/displaylink(target:selector:)) と [CADisplayLink](https://developer.apple.com/documentation/quartzcore/cadisplaylink) を参照。複数ローカル画面の場合は選択された画面IDの先頭を更新の基準にする。異なるリフレッシュレートの画面すべてへ個別の垂直同期を保証する実装ではない。

## Macで最初に行うこと

```sh
git fetch origin
git switch fix/macos-synchronized-frame-pacing
git pull --ff-only
bash macos/scripts/verify.sh --unit-only
```

まずSwiftの型・actor isolation・AppKit APIと全単体テスト、arm64 Releaseコンパイルを確認する。新規テストは `NetworkPresentationTests.displayTicksUseSharedTimeAcrossMissedFramesPauseAndHandoff`。WindowsではAppKit SDKとSwiftが利用できず、ここは検証できていない。

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

# macOS v1.1.0 build 17 — 同期再生の更新周期と計画準備の停止を修正

2026-10-20。Macの同期再生のカクつきについて、[更新間隔の比較と稼働中build 16のトレース](SYNC-FRAME-PACING-MEASUREMENTS-2026-10-20.md)から確認した2つの要因に対応したApple Silicon用ローカル候補です。GitHub Releaseには未公開です。

## 変更

- 同期再生の「描画完了後に16ms待機」を、選択画面のdisplay linkへ変更しました。再生位置・速度・pause/resumeは従来どおり共有時計から求めます。
- 全候補写真のID・URL・顔情報・参照表の生成を、MainActorから専用actorへ移しました。同じ写真情報と順序の間は1つの不変snapshotを再利用し、写真の追加・削除・顔解析結果・寸法等の更新で作り直します。写真ごとのIDは生成時に1回だけ計算します。
- 準備中のNext・停止・進行役変更で古い計画を確定しないようにしました。Galleryの継続、写真の順序、顔保護、通信形式と暗号化キャッシュのIDは維持します。

## 更新と手動確認

`release/macos/arm64/DynamicPhotoWall.app`をbuild 17へ更新しました。旧配布物は`artifacts/macos/package/previous-release.IUtGFf/`へ退避し、APP・ZIP・DMGを同じReleaseから作りました。arm64、macOS 27.0以降、アドホック署名です。release・archive・ZIP・DMGのAPP全6ファイル一致、署名、arm64、ライセンス同梱、ZIP／DMG、SHA-256を確認しました。

稼働中のアプリは自動で切り替わりません。アプリのメニューから終了し、`release/macos/arm64/DynamicPhotoWall.app`を起動し直してください。`/Applications`へのコピーと自動再起動は行いません。

Mac↔Windowsを従来と同じ設定で同期させ、縦Panの周期的な引っかかり、次の表示を準備するときの停止、モード切替、pause/resume、Next、Galleryの連続交換を確認してください。初回画像表示時のCore Animationの色変換・コピーで約48msを要した別の経路は今回変更していません。残る引っかかりは発生場面を分けて確認します。

## 検証

GUI操作なしの隔離検証でSwift単体209件 / 31 suites、共通fixture704＋472 assertions、背景色12ケース、Zoom構図5120 assertions、ネットワーク26ケース / 241 assertions、arm64 Releaseコンパイルが成功しました。追加回帰では顔情報・寸法・写真の所属と順序の更新、取消された写真準備、計画準備／画像準備中のNext・停止・進行役変更を確認しました。

display linkと旧方式の隔離比較は、同じ1920×1080・60Hzの縦Panで約57.5更新/秒から60更新/秒、画面更新通知時の状態の据え置き率4.223%から0%でした。

配布後の手動テストで、ユーザーが「カクつかなくなった」と確認し、commit・push・PR作成とmainへのマージを指示しました。これは今回の同期表示のカクつきについての受け入れで、長時間運転・複数画面・スリープ復帰の網羅的な検証や、通常アプリでの停止時間・CPUの再測定とは区別します。

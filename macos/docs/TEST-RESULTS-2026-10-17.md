# Windows先行機能のMac移植・検証記録

2026-10-17（日本時間）。作業開始時の`0f31687`から`git pull --ff-only`で`2f140ce`まで取り込み、作業中に追加された`d1044b6`もautostashで差分を保持して取り込んだ。[handover](../WINDOWS_DELTA_HANDOVER.md)のD01〜D09をMacへ反映。Mac mini / arm64、macOS 27.0.1、Xcode 27.0で検証した。製品候補は1.0.1 build 4。GitHub Releaseへは公開していない。

## 実装と自動検証

| 対象 | 実装・確認した内容 |
|---|---|
| D01 | 複数画面選択、物理pxの独自配置、グループごとの正規化。負座標・隙間・上下ずれ・遠い別グループ・異常寸法の拒否。Retinaと非RetinaのOS配置リセットは各画面寸法で隣接を変換 |
| D02 | 独立グループの再生・復旧、共通キャンバスの切り出し、グループ単位の遮蔽。1グループに1つのPlannerと履歴、共通の開始時刻・pause・最長時間・フェード。画像キャッシュの所有者ごとのpinと必要幅の集約 |
| D03 | 一般／使用ディスプレイ／画面グルーピング／写真／表示モード／動き／見た目。空グループの追加・保存・削除、最後のグループの非復活、未選択画面の所属解除、取消。ドラッグとスナップ、折りたたみ内の数値／OS配置リセット |
| D04 | 写真なし・未保存配置での一時テスト表示。保存内容の不変、設定の取消・閉じる・再表示、適用中のプレビュー保持、通常再生／手動pauseへの復元、接続失敗時の保持と出力作成失敗からの復帰、通常開始／全停止、切断・再接続 |
| D05 | 最大面積→Y→Xの顔選択、縦横Panの開始側、方向と停止の独立、定速と3秒保持。顔解析・先読みへ接続。既存EXIF全8方向の実画像検出も維持 |
| D06 | 5モードの画面単位チェック、旧設定のスパン維持、保存・復元、全接続画面の適性判定、画面ID対応、座標重複の分離。短いモーションの終点保持、スパン／画面単位のフェード、全体pause／Next |
| D07 | Windowsと同じGallery／縦Panの全顔外接矩形による配置。左右／上下／隙間／未接続タイル、方向と停止ON/OFF。Gallery交換時の既存スロットの中間位置・pause、前景と背景で共通の幾何 |
| D08 | 小画像だけ同一写真を画面ごとにミラー。拡大率の厳密境界、全画面への適性、同一bitmap、手動個別表示との分離、大画像のスパン維持、未接続画面の除外 |

既存のフォルダーブックマーク・PhotoKitアルバム・ログイン設定・原子的保存とschemaVersion 1を維持。単一画面の`screenID`から移行し、未接続IDを保持する。Dock／メニューバーは合意済みのmacOS設定に従い、LAN／PC間同期は追加していない。

## D09追加分

作業中に追加された`d1044b6`の余白改善も移植。通常Gap・高さ・基準線を保てる列全体の平行移動を優先し、最大128の区間を保持する。ランダムのスパンGalleryだけ、現行資産の顔矩形が既知の候補を最大12枚比較し、初回は最大2回、交換は対象slotだけ変更する。顔未解析と検出済み顔なしを区別し、試算は履歴を消費せず採用だけ記録。候補を一括デコードせず、採用候補だけ読み込み、失敗なら元の写真を使う。試算と最終配置はactorで計算する。

名前順・個別表示・設定OFFの非再抽選、ファイル／PhotoKit更新時のキャッシュ失効、候補上限、履歴、初回／定期交換、読込失敗、取消と停止を回帰で確認。WindowsDeltaの52 motionは完全に同じ期待値を保持し、4 Galleryのうち2ケースだけ、新仕様の共通基準線と最大高さ探索に伴う期待値を変更した。従来WindowsParityの36ケースは変更していない。

## 実行結果

- 最終の`bash macos/scripts/verify.sh`: 単体109件、UI 5件、C#共通fixture、arm64 Releaseコンパイルが成功。UIでは画面選択、空グループの追加・削除・保存・再起動、一時表示・設定閉じる／再表示、5モードの設定、従来のフォルダー／アルバム／再生操作を確認。
- 通常開始時の画像失敗の再試行、D09の初回構成と対象slotだけの定期交換、履歴・キャッシュ・失敗／取消も上記の単体に含む。
- C#共通fixture: 従来の36 motion・9 Gallery・2 selectorケースは704 assertions成功。旧期待値は変更していない。
- 追加の共通fixture: 52 motion・4顔保護Galleryレイアウト・4 Gallery余白改善ケース、472 assertions成功。Swiftでも同じ期待座標・時間・`frameTop`を照合。
- 実際の`GroupDesktopWallView`を非表示のNSHostingViewで描画して画素を比較。先頭画面が原点以外にあるスパンの切り出しと、座標が重複する個別表示の写真分離が成功。
- 共有背景の生成・pause／破棄、共有キャッシュのpinと必要幅、待機時の旧表示保持、モード間フェードを隔離テストで確認。
- 設定Windowは最小900×680 point。UI添付画像はタイトルバー込み900×712pxで、全7ページ・保存／開始操作が表示され、本文をスクロールできることを目視確認。
- `bash macos/scripts/package.sh`: arm64 archive、アドホック署名の検証、ZIP、DMG、SHA256SUMSを生成。
- 実行前後のルート実ファイル一覧で追加ファイル0件。新設されたルートディレクトリは規定の`release/`のみ。作業ファイルは`artifacts/macos/`、完成物は`release/macos/arm64/`。

Swiftコンパイルの警告なし。XcodeのCoreSimulatorバージョン通知、XCTestホストのlinkd接続通知、未使用AppIntentsのmetadata通知、hdiutilの非推奨通知は、Macターゲットのテスト／archive成功と分けて扱う。

## 証跡と再現

リポジトリ直下から実行:

```sh
bash macos/scripts/verify.sh
bash macos/scripts/package.sh
```

- `artifacts/macos/verification/`: tests.log、windows-core-fixtures.log、windows-delta-fixtures.log、release-build.log、xcresult、UI添付PNG、ルート一覧とgenerated-file-audit.json。
- 最終の単体109件・UI5件が成功したxcresult: `DerivedData/Logs/Test/Test-DynamicPhotoWall-2026.10.17_20-30-52-+0900.xcresult`。集計は`test-summary-final.json`、確認画像は`ui-attachments-final/`。
- `artifacts/macos/package/`: archive、DerivedData、archive.log。
- `release/macos/arm64/`: DynamicPhotoWall-macos-arm64.zip、DynamicPhotoWall-macos-arm64.dmg、SHA256SUMS。

テストは専用アプリID・設定・fake host／画面／写真ソースを使う。上記の画像描画テストもデスクトップWindowを表示しない。通常の写真・壁表示・ログイン項目は変更しない。

## 実機で未確認の条件

実ケーブル抜差し、異なるRetina倍率の実パネルをまたぐ継ぎ目・速度、実ウィンドウによるグループ遮蔽、スリープ／復帰、Spaces／Mission Control、PhotoKitの実権限／iCloud、ログイン起動、8時間以上の運転は未確認。fake画面・時間を進めるテスト・非表示の画像描画を、これらの合格へ読み替えない。[継続TODO](../MACOS_PARITY_TODO.md#release前に残す実機受け入れ)を維持する。

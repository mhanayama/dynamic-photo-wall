# 実施した検証

## 2026-10-17 — 小画像の縦Pan自動ミラーとGalleryの滑らかな再配置

- スパン幅への必要拡大率が上限を超え、同じ写真が全接続画面の縦Pan適性を満たす場合だけ、自動ミラーへ切り替える。画面別チェックや設定ファイルを書き換えない。大きな写真はスパン、手動の画面別表示は別々の写真という動作を維持する。
- コアで異なる画面寸法、拡大率の境界、EXIF補正後の幅、候補除外、単独画面、未接続領域、設定した表示幅の違いを検証した。
- 実際の2画面セッションで同じ写真と同じbitmapの共有、各画面の物理寸法、pause／Next、上限変更によるスパン復帰、手動個別表示、1台未接続、停止を確認した。写真は専用フォルダーへ生成し、設定・タスクバーを通常版と分離した。
- Galleryは安全な最終配置へ既存slotを移動・伸縮し、交換写真だけフェードする。アニメーション中の顔の境界通過を許容する。WPFで中間位置を通ること、slotを作り直さないこと、pause中の固定、完了と取消後の最終値確定・clock解除を検証した。前・途中・後のPNGも確認した。初回の統合試験はWPFのclock解除が反映される前の検査で失敗したため、反映を待つ検査へ修正して再実行した。
- 最終のコア19項目と、画面別モード・背景・復旧・自動ミラー／Gallery再配置の統合4項目が成功。共通fixtureの704 assertionsも成功。Releaseビルド・単一EXEの発行はエラー0、既知のNU1900情報取得警告あり。
- Macアプリ自体は変更・実行せず、D08の自動ミラーとD07の「Gallery移動中は境界通過可」をhandoverへ反映した。実機でのフレームレート測定・混在DPI・ケーブル抜差し・長時間運転は未実施。

結果: `artifacts/windows/mirror-gallery-final/test-results.json`、`gallery-{before,moving,after}.png`、`mirror-display-{0,1}.png`、`mirror-state.json`。既存回帰は`artifacts/windows/mirror-gallery-regression/test-results.json`。

```powershell
.\.tools\dotnet\dotnet.exe windows/tests/DynamicPhotoWall.Tests/bin/Release/net10.0-windows10.0.19041.0/DynamicPhotoWall.Tests.dll artifacts/windows/mirror-gallery-final --scan-only --mirror-gallery
.\.tools\dotnet\dotnet.exe windows/tests/DynamicPhotoWall.Tests/bin/Release/net10.0-windows10.0.19041.0/DynamicPhotoWall.Tests.dll artifacts/windows/mirror-gallery-regression --per-display-modes --ambient --retry-recovery
```

## 2026-10-17 — モード別の画面単位表示と、スパン中の顔境界回避

- 全5モードに「ディスプレイごとに表示」を追加。旧設定はスパンのまま、画面別モードは各画面の物理解像度で適性・写真・配置・背景を作り、モード・pause・Next・切替時刻をグループで共有する。
- 「スパン時に顔が画面の境目に重ならないよう配置」を初期値ONで追加。Gallery・縦Panは全検出顔を接続画面内へ寄せ、必要時だけ縮小。Galleryの再配置は安全な配置同士のフェードにする。横スクロール・横Pan・Zoomは従来の幾何を維持する。
- 5種類の画面配置（左右・上下・隙間・高さ違い・1画面未接続）、4種類の顔矩形、停止／方向のON/OFFによる縦Pan80通り、Gap3種類を含むGallery240通りで、顔の包含・移動中の境界回避・非重複を検証。位置調整でサイズを維持できる場合、巨大Gap、未検出、設定OFFも確認。
- 画面ごとの全5モードの画素、Gallery交換、scroll流入、背景pause／破棄、同じ配置座標でも画面IDで別の写真が出ること、スパンへの切替を確認。設定ウィンドウの5チェックと境界設定を保存・再読込し、1040×820と920×700をPNG確認。
- 実セッションで全モードを切り替え、各画面の寸法・モード・写真・共有pause／Next・停止と切断時の領域保持を確認。公開fixtureのastronaut.pngをWindows標準検出へ通し、他の顔設定をOFFにしたスパンGalleryでも顔を準備し、実際の配置が画面内へ収まることを確認。画面を1台切断した構成でも残った画面へ顔を配置する。
- 最終のコア18項目＋画面別描画／顔検出の統合1項目が成功。既存の背景・復旧・画面グループ・設定UI・テスト表示・グループ削除も成功。複数画面のタスクバー復元だけは起動中の通常版との干渉で最初に不一致となり、通常版を終了した単独試験では成功した。
- C#共通fixtureの704 assertionsは既存の期待値を維持して成功。Releaseの単一EXEを発行し、共通release先へ配置。NU1900の情報取得警告あり、コンパイルエラー0。Macアプリの変更・検証は行わず、D06/D07としてhandoverへ仕様を追加した。

結果: `artifacts/windows/span-face-complete/test-results.json`、`mode-routing-states.json`、`mode-checkboxes-{1040,920}.png`、`detected-face-spanning.png`。上下配置の短い縦Panで実際の描画位置も確認した追加統合は`artifacts/windows/span-face-vertical-frame/`。既存回帰は`artifacts/windows/span-face-final/`、タスクバーの単独再検証は`artifacts/windows/mode-routing-clean-multi/`。実機の提示検査は露出していたDISPLAY3の9/9点が成功し、DISPLAY1/2は他アプリに覆われていた。混在DPI・実ケーブル抜差し・長時間運転は従来どおり残る。顔未検出の写真まで保護する保証はない。

```powershell
.\.tools\dotnet\dotnet.exe windows/tests/DynamicPhotoWall.Tests/bin/Release/net10.0-windows10.0.19041.0/DynamicPhotoWall.Tests.dll artifacts/windows/span-face-complete --per-display-modes
```

## 2026-10-17 — 画面グループの削除

- 一覧カードごとに「削除」ボタンを追加。空／所属あり／最後のグループを削除でき、所属画面は未選択の画面も含め「独立して表示」へ戻す。画面の選択・配置・タスクバー設定は維持する。
- 再検出時は編集済みのグループ一覧を保持し、保存済みの削除前の名前を再追加しない。全削除後も再読込で「グループ1」を自動生成しない。
- 実際の削除ボタン・割り当て選択肢・一覧数・保存ボタンを操作し、ドラフトだけの変更、保存しない場合の元データ保持、保存・再読込、番号の再利用を確認した。
- Release発行とコア16項目が成功。最終の設定UI・既存テストパターン・グループ削除の統合3項目も成功。通常／最小サイズの設定ページ、全削除後の画面をPNGで確認。ビルドはエラー0、NU1900の情報取得警告あり。
- 最初のテストパターン統合試験は制限環境からExplorerのProgmanを取得できず失敗。対話デスクトップ側で再実行し、最終3項目はすべて成功した。削除試験自体は両環境で成功。

結果: `artifacts/windows/group-deletion-final/test-results.json`、`settings-page-3-{1040,920}.png`、`groups-deleted.png`。Mac移植にも同じ削除・再検出・保存の条件を[handover](../../macos/WINDOWS_DELTA_HANDOVER.md)へ追記した。

```powershell
.\.tools\dotnet\dotnet.exe windows/tests/DynamicPhotoWall.Tests/bin/Release/net10.0-windows10.0.19041.0/DynamicPhotoWall.Tests.dll artifacts/windows/group-deletion-final --scan-only --settings-ui --test-pattern-toggle --group-deletion
```

## 2026-10-17 — 両OSのreleaseディレクトリ統一

- Windows配布先を`release/windows/win-x64/`へ変更し、起動スクリプト・ショートカットを同じパスへ統一。ショートカットのターゲットと作業ディレクトリを実ファイルから確認。
- `Build.ps1 -Test`の発行とコア16項目が成功。検証結果は`artifacts/windows/smoke-data/`へ出力。エラー0、NuGetの脆弱性情報へ接続できないNU1900警告あり。
- ビルド前後でルート直下のファイルが増えないことを確認。既存のルートEXE・ショートカットは`artifacts/windows/legacy-root/`へ退避し、ルートは管理対象のドキュメント・設定ファイルだけになった。
- 診断`--probe`の既定レポートもデータディレクトリへ変更し、ルート直下の一時JSON生成を避ける。アプリのReleaseコンパイルで確認。
- Macは配布ZIP／DMGを`release/macos/arm64/`、archive・DerivedData・stagingを`artifacts/macos/package/`、検証結果を`artifacts/macos/verification/`へ分離。Git Bashの`bash -n`で両スクリプトの構文が成功。Mac実機での署名・archive・DMG生成は未実行で、handoverに確認条件を追加。

結果: `artifacts/windows/release-layout/result.json`。[共通規則](../../docs/GENERATED-FILES.md)と[Mac向け引き継ぎ](../../macos/WINDOWS_DELTA_HANDOVER.md)を参照。以下の過去記録の旧出力パスは当時の証跡として保持する。

## 2026-10-17 — 最新Mac版の取り込みと共通fixture互換性

- Mac側の`7508db8`までの更新を取り込み、Windowsの追加機能を統合。Macの既存実装・公開記録を保持した。
- 新設定`FaceAwarePanDirection`の既定値ONにより、旧共通fixtureは`HorizontalPan-4: field 2`で不一致となった。既存36ケースと生成器へ方向設定OFFを明示し、旧動作の期待座標を維持した。製品の既定値はONのまま。
- C# verifierは36 motion／eligibilityケース、Gallery配置9ケース、Selector2ケース、計704 assertionsが成功。Macアプリ・SwiftテストはWindows上では実行していない。方向ONのMac回帰追加は[引き継ぎ資料](../../macos/WINDOWS_DELTA_HANDOVER.md)で依頼する。

```powershell
.\.tools\dotnet\dotnet.exe run --project tests/ParityVerifier -- macos/DynamicPhotoWallTests/Fixtures/WindowsParity.json
```

## 2026-10-17 — 一般・タスクバー移動・グループ一覧・即時テスト表示

- 「表示設定」を「一般」へ改名し、タスクバー設定を使用ディスプレイへ移動。
- グループ一覧で総数・所属画面・未割り当てを表示。「グループを追加」の直後に一覧と数が更新され、未割り当てグループも保存・再読込できる。
- 上部のテストパターンボタンは「表示 → 表示停止 → 表示」と切り替わり、保存操作をせずにドラフトの配置で表示・停止する。写真未登録・通常再生中・一時停止中、独立した複数画面に対応する。
- プレビュー中に保存ファイルと通常設定を変更しないこと、終了後に以前の再生・一時停止状態を復元すること、未接続画面のプレビュー失敗時に写真再生を維持することを確認。通常の開始・停止によるプレビュー解除と、旧設定からテスト状態が自動復元されないことも確認。
- 通常・最小ウィンドウサイズの3ページ、および「表示停止」状態をPNGで確認。コア16項目、UI描画、ボタン操作の計18項目が成功。Releaseビルドはエラー0、NU1900の情報取得警告あり。

結果: `artifacts/settings-preview-final/test-results.json`、`settings-page-{1,2,3}-{1040,920}.png`、`test-pattern-button-visible.png`。再実行はテストランナーへ`--settings-ui --test-pattern-toggle`を指定する。テスト専用プロファイルを使用する。

## 2026-10-17 — 顔の反対側からパンを開始

- 縦パンは主な顔が上なら下から、下なら上から開始。横パンは左の顔なら右から、右の顔なら左から開始する。主な顔は面積が最大の検出領域とし、同面積では上・左の順で安定して選ぶ。
- 「動き」に方向選択のチェックボックスを追加し、初期値を有効にした。縦パンの顔位置停止・Zoomの顔フレーミングとは別に指定できる。横パンにも顔検出を追加。
- 上下・左右の顔、複数の顔、方向の乱数、停止設定の有効・無効を組み合わせて計算を確認。縦パンはどちらの向きでも距離÷速度で時間を決め、停止位置で顔全体が見えることを確認。未検出時・方向設定無効時は従来の動作を維持する。
- コア16項目が成功。実写真では3枚中3枚で顔を検出し、縦パンの顔位置停止、Zoom、動的背景、両Galleryの既存試験が成功。
- ライブラリー901枚の寸法・EXIF方向、2種類の顔領域、3画面比率、3モードの16,218通りで計算が成功。これは901枚すべての顔を検出したという意味ではない。
- Releaseビルドはエラー0。NuGetの脆弱性情報を取得できないNU1900警告あり。macOS側の実装は今回の変更対象外。

結果: `artifacts/face-pan-direction/test-results.json`、`artifacts/face-pan-real/feature-results.json`、`motion-library-results.json`。実写PNGはローカルのartifacts配下のみ。

## 2026-10-17 — 画面設定UIを3ページに分離

- 左メニューを「表示設定」「使用ディスプレイ」「画面グルーピング」に分離。表示設定は起動時の動作・画面別タスクバー・再生操作、使用ディスプレイは対象選択と再検出、グルーピングは連結・配置・テストパターンを担当する。
- グループ名の手入力を選択式へ変更し、「独立して表示」を明示。「＋ グループを追加」でグループを増やせる。既存のグループ名は選択肢へ引き継ぐ。
- 座標入力とWindows配置へのリセットを「配置を数値で調整」へ折りたたむ。保存・開始・閉じるは全ページ共通の下部へ配置。
- 3画面構成で3ページを1040×820と920×700の各サイズで描画し、6枚のPNGを確認。最小サイズで収まらない内容はページ内をスクロールでき、共通の保存ボタンは常に表示する。
- コア検証15項目と設定ページ描画が成功。Releaseビルドはエラー0。NuGetの脆弱性情報を取得できないNU1900警告は継続。

結果: `artifacts/settings-ui-split/settings-page-{1,2,3}-{1040,920}.png`。設定ページだけを再描画する場合はテストランナーへ`--scan-only --settings-ui`を指定する。描画試験は写真再生・タスクバー変更を行わない。

## 2026-10-17 — グループ指定と画面ごとのタスクバー設定

- 表示対象の選択とグループ指定を分離。同じグループ名の画面だけを連結し、空欄の画面はそれぞれ独立して再生する。カードの色・グループごとの寸法・テストパターンの画面番号で構成を確認できる。
- タスクバー非表示は各画面のチェックボックスへ移動。旧設定にGroupIdがなければ従来の連結を維持し、HideTaskbarがなければ従来の全体設定を引き継ぐ。新しい設定を保存すると画面ごとの値を保持する。
- グループの分割、独立画面の座標が別グループのキャンバスを広げないこと、旧JSONの移行と保存・再読込を確認。
- 3画面で「2画面を連結＋1画面を独立」と「3画面をすべて独立」を実行。グループ別の解像度・構成・再生、全グループへの一時停止・再開・次の構成を確認。
- 一部の画面だけにタスクバー非表示を設定し、ほかの画面を維持、停止時の復元を確認。
- 画面IDを未接続へ置き換えて、該当グループの領域保持と別グループの継続を確認。切断後の画面が前景アプリに覆われた場合は遮蔽状態が表示されるため、領域保持はステータス文言ではなく実際のViewportで検証する。
- 最終の18項目が成功。既存の全表示モードと設定画面のデスクトップ試験も別途成功。ビルドはエラー0、NuGetの脆弱性情報へ接続できないNU1900警告あり。

結果: `artifacts/display-groups-final/test-results.json`、`multi-taskbar-restore.json`、`display-groups-settings.png`、`display-groups-editor.png`。旧版が起動中の最初の検証ではタスクバー復元が1件不一致になり、単独の再検証と最終試験では成功した。複数プロセスから同じタスクバーを操作すると干渉する可能性があるため、通常起動は従来の単一起動制御を維持する。全画面を露出させた境界確認・混在DPI・長時間運転の未確認事項は従来どおり。

```powershell
.\.tools\dotnet\dotnet.exe windows/tests/DynamicPhotoWall.Tests/bin/Release/net10.0-windows10.0.19041.0/DynamicPhotoWall.Tests.dll artifacts/display-groups-final --multi-display --display-groups --retry-recovery
```

## 2026-10-17 — Windows内のマルチディスプレイ

- 複数画面の選択、ドラッグと端・中央スナップ、X/Yの数値入力、Windows配置へのリセット、設定保存、格子・斜線・円・画面番号を追加。
- 負座標、上下位置、40pxの隙間、異なる解像度から共通キャンバスと切り出し矩形を計算するテストが成功。従来のMonitorIdだけの設定も利用可能。
- 原点以外にある最初の画面とVisualBrushによる別画面を、全キャンバスの画像と全ピクセル比較。格子、および移動する写真と動的背景で、色成分の差1以内を確認。
- 実機の3画面（1920×1080が2台、3840×1100が1台、全体3851×2180）へ同時接続。設定画面のPNGを確認。
- 未接続IDへの差し替えと復帰をテストし、残った画面の表示と未接続領域の保持を確認。これはケーブルの実際の抜き差し試験ではない。
- 共通Zoomの再生、一時停止・再開・次の構成・全停止、対象画面ごとのタスクバー非表示と全タスクバーの復元が成功。
- Windowsが合成した実画面は、露出しているDISPLAY3でマゼンタ9/9点を確認。DISPLAY1/2は別アプリが9/9点を覆っており、この2画面の提示確認は未実施。両画面のWPF描画面とShell接続は確認済み。検査点のウィンドウ種別も記録し、覆われた点を描画失敗として扱わない。
- 既存モード・顔位置計算・EXIF・デコード・フォルダー監視・設定破損復旧・再試行復旧を含む17項目が成功。復元なしのReleaseビルドは警告0・エラー0。最終パッケージング時はNuGetの脆弱性情報へ接続できずNU1900警告2件が出たが、発行・テストは成功した。

結果: `artifacts/multi-display-final/test-results.json`、`multi-display-compositor.json`、`multi-display-settings.png`。3画面を同時に露出させた境界の目視確認、混在DPI、実ケーブル抜き差し、スリープ・Explorer再起動と長時間運転は手動確認が残る。PC間同期は対象外。

```powershell
# リポジトリ直下から、通常の対話デスクトップで実行
.\.tools\dotnet\dotnet.exe windows/tests/DynamicPhotoWall.Tests/bin/Release/net10.0-windows10.0.19041.0/DynamicPhotoWall.Tests.dll artifacts/multi-display-final --desktop --multi-display --retry-recovery
```

## 2026-10-14 — Windows v0.1.0 単一EXEリリース

- Release / win-x64 / self-contained / PublishSingleFileで発行。ネイティブライブラリも同梱し、シンボルはアプリに埋め込む。WPFのためトリミングは行わない。
- ルートの `DynamicPhotoWall.exe` をダブルクリックして起動する形へ変更。ショートカット・起動スクリプトも同じEXEを参照。
- 実行ファイル・設定画面・タスクトレイのアイコンを統一。「横スクロールGallery」の表示名を「Scrolling Gallery」に統一。
- 既存のコア検証と全モード・設定画面・常駐コントローラーの統合検証、合計13項目が成功。ビルドは警告0・エラー0。
- DLLを置かない別フォルダーへアプリと検証ランナーの単一EXEだけをコピーし、インストール済みランタイムの参照先を無効なパスにした状態で検証。
- 単一EXE環境で実デスクトップの色出力、顔検出、縦パン・Zoom・Gallery・Scrolling Gallery、動的背景、表示失敗後の自動復帰が成功。
- 単一EXE環境で対象画面のタスクバー非表示、通常復元、所有プロセスの強制終了後の復元が成功。
- EXEのみをさらに別フォルダーへ移動し、`Photo Wall.exe`へ改名した場合も復元用プロセスを起動し、異常終了時のタスクバー復元が成功。
- 写真・設定・キャッシュをEXEへ含めない。生成したEXEはGit対象外とし、GitHub Releasesのアセットとして配布する。

結果: `artifacts/smoke-data/test-results.json`、`artifacts/single-file-tests/test-results.json`、`artifacts/portable-rename-result.json`。単一EXEは初回起動時に必要なネイティブDLLをユーザーの一時領域へ展開する。別PC・長時間運転は従来どおり手動確認項目として残る。

## 2026-10-14 — 「画像表示を再試行中」で進まなくなる不具合

実行中のapp.logで `Math.Clamp` の下限が `4.547473508864641E-13`、上限が0となる例外を確認。全幅Zoomの顔位置調整で、拡大率の除算・乗算後に画像幅が画面幅を丸め誤差分だけ下回っていた。Buildが例外を投げる前の準備済み構成を保持していたため、同じ構成を2秒ごとに再試行し続けていた。

- Zoomの描画寸法を画面幅・高さ以上に補正し、位置の範囲が逆転することを防止。顔の目標位置も、実際にClampへ渡す上下限で検証する。
- Buildを呼ぶ前に準備済み構成を消費し、例外時は次の構成を選ぶ。
- 表示成功時に再生・一時停止状態を再表示し、再試行の表示を解除する。
- 298×200の画像と3840×1100の画面で、ログと同じ小数誤差を再現する回帰テストを追加。幅256〜4096、回転あり・なし、3画面比率でも検証。
- 現在のユーザー写真901枚の寸法を使い、大小の顔領域・3画面比率・3モードの計16,218通りの表示計算が成功。これは計算の検証であり、901枚すべての再デコード試験ではない。
- Galleryだけで起きる表示例外をテストで注入し、失敗後に有効なZoom構成へ進み「再生中」に復帰することを確認。
- 実写真で顔の縦パン終点、全幅Zoom、横スクロール、従来Galleryの表示も成功。ビルドは警告0・エラー0。

結果: `artifacts/retry-fix-core/test-results.json`、`motion-library-results.json`、`artifacts/retry-recovery-final/retry-recovery-results.json`。実写表示の結果は `artifacts/retry-fix-desktop/feature-results.json`。

## 2026-10-14 — 動的背景・横スクロールの高さ・フチ処理削除

[YouTube公式のアンビエントモード解説](https://blog.youtube/inside-youtube/youtube-ambient-color-mode-visual-language-redesign/)を調査し、小さなプレビューをぼかして背景に使う方針を参考にした。Photo Wallの更新周期や平滑化は独自の実装であり、YouTubeの内部実装を再現したものではない。

- 縦パンで青い下部から赤い上部へ移動すると、背景も青から赤へ変わることを確認。左右の空き領域も表示中の色を反映。
- 横スクロールで赤い写真が青い写真へ移動すると背景が追従。画面外の緑の写真は、画面内に入ってから背景へ反映される。
- 従来のGalleryで1枚を交換した場合にも背景が追従。従来のGalleryモードを維持。
- 一時停止で背景更新も停止。前の構成・終了したRendererのタイマーが残らないことを確認。
- 全写真とパン用フレームの4pxのOpacityMask処理を削除。
- 3840×1100で横スクロールの高さ1084px、上下の余白各8pxを確認。
- 実写真のWindows標準顔検出: サンプル3枚中3枚で検出。顔が収まる縦パンの終点、全幅Zoomでの顔位置調整、スクロールの新写真への交換を確認。
- 実デスクトップのピクセル検査: マゼンタ9/9、シアン9/9、フォーカス維持。
- コアを含む15項目が成功。ビルドは警告0・エラー0。

6秒の実写真パン計測（3840×1100 / 60Hz）:

| 項目 | 結果 |
|---|---|
| アニメーションの30fps上限 | なし |
| 毎フレームの写真レイアウト再計算 | 0回 |
| UI側で観測した移動更新間隔 | 中央値13.19ms、95%点15.18ms |
| 移動量 | 約720px（120px/秒） |
| 動的背景 | 初回を含め58回更新、プレビュー取得の最大3.48ms |

UI側のアニメーション更新計測であり、60Hz画面で75fpsが提示されたという意味ではない。OS・GPUの厳密な提示フレーム数や長時間の負荷はこの試験の対象外。

結果: `artifacts/ambient-final/test-results.json`、`ambient-results.json`、`pan-metrics.json`、`feature-results.json`。実写PNGはローカルのみ。

```powershell
dotnet windows/tests/DynamicPhotoWall.Tests/bin/Release/net10.0-windows10.0.19041.0/DynamicPhotoWall.Tests.dll artifacts/ambient-final --compositor --pan-metrics --features --ambient
```

## 2026-10-14 — タスクバーなしの全画面表示

- Displayに「対象画面のタスクバーを隠して全画面表示」を追加（初期値は有効）。
- 対象モニターのタスクバーだけが非表示になることを確認。
- ほかのモニターのタスクバーの表示状態が変わらないことを確認。
- 通常の停止・終了による復元を確認。
- テスト専用所有プロセスを強制終了し、独立したガードがタスクバーを復元することを確認。
- 結果: `artifacts/taskbar-fullscreen/taskbar-result.json`。実画面の色出力テストも同時に成功。

## 2026-10-14 — 「再生中だが写真が見えない」の修正

10月13日の実写PNGはWPF内での描画確認であり、Windowsが合成した実画面への表示を保証していなかった。ユーザー報告で未検出の不具合を確認した。

- 実際のShell階層は `SHELLDLL_DefView → 写真用HWND → WorkerW` で順序・領域は正しかった。
- ProgmanはWS_EX_NOREDIRECTIONBITMAP付きで、普通の非Layered子HWNDには合成対象の面がない。
- 写真用HWNDにWS_EX_LAYEREDとグローバルAlpha=255を設定。WPFがWM_STYLECHANGINGでLayeredフラグを除去する処理を、写真用HWNDのフックで抑制した。
- WPFのAllowsTransparency / PerPixelOpacityは有効にせず、不透明な通常描画を維持した。
- 実画面の9か所のピクセルを検査: マゼンタ9/9、背景色変更後のシアン9/9。フォーカス維持も確認。
- テスト結果: `artifacts/compositor-fix/compositor-result.json`。
- この検査は対象画面が他のアプリで覆われていない状態で実施する。モニター座標やWPF内の画像だけを成功条件にしない。

再実行コマンド:

```powershell
dotnet windows/tests/DynamicPhotoWall.Tests/bin/Release/net10.0-windows10.0.19041.0/DynamicPhotoWall.Tests.dll artifacts/compositor-fix --scan-only --compositor
```

実施日: 2026-10-13（日本時間）。環境: Windows 11 build 26300、x64、.NET SDK 10.0.401。

## Phase 1 — Windows統合

`artifacts/phase1-probe.json` に実機結果を保存。

- Progman / Windows 11 24H2形式の子ウィンドウ階層へ接続: 成功。
- 指定モニターの物理座標・寸法と接続後のウィンドウ矩形の一致: 成功。
- WS_CHILD、WS_EX_TOOLWINDOW、WS_EX_NOACTIVATE、WS_EX_TRANSPARENT: 確認。
- 検証終了後にアプリのHWNDが消失: 確認。ExplorerのHWNDは削除しない。

その後、ウルトラワイド3840×1100、座標(-11, 1080)、DPI 96で4モードの描画を検証。
他の2画面へアプリの描画ウィンドウを作成しない設計。壁紙変更APIは使用していない。

## Phase 2〜4 — 自動テストと統合テスト

最終ビルド: エラー0、警告0。テストランナーの検証は全件成功。

| 検証 | 結果 |
|---|---|
| 距離÷120px/秒のパン時間、上下・左右の終点 | PASS |
| ネイティブ解像度未満の写真の拡大許容と設定上限 | PASS |
| Galleryの画面内配置、比率保持、余白 | PASS |
| 同時表示の重複排除、直近写真の繰り返し抑制 | PASS |
| 2万回の重み抽選、Pan合計ウェイト、ウェイト0・全モード無効 | PASS |
| EXIF Orientation 1〜8の寸法・実ピクセルの回転/反転・撮影日時 | PASS |
| JPEG / PNG / WebPのデコード、破損・削除ファイルのスキップ | PASS |
| 設定の保存・復元、破損設定からの復旧 | PASS |
| フォルダー監視による追加・削除、重複フォルダーの排除 | PASS |
| 一時停止中の経過時間の凍結・復帰 | PASS |
| 負座標のウルトラワイドへの4モード描画 | PASS |
| Galleryの1枚だけの交換、他スロットの維持 | PASS |
| 設定画面の生成とレンダリング | PASS |
| 常駐コントローラーの開始・停止、個別更新、設定適用・再起動 | PASS |
| 一時停止中に次の構成を連続指定して復帰 | PASS |
| 未接続のモニターIDを指定した場合の安全な待機 | PASS |

抽選実測: Gallery 40.4%、Pan合計38.0%、Zoom 21.6%。設定45/35/20に対し、同じモードの3連続を抑制する効果が含まれる。
初期版のテストで小さいEXIF画像を不必要に拡大してデコードする問題を検出し、元の解像度を超えてデコードしないよう修正済み。
一時停止中に切替を中断した場合は新しいシーンを破棄し、前のシーンを保持する。

## 配置された実写ファイルでの検証

追加中に703枚→844枚と増加したため再走査し、**862枚**の時点で全件を検証した。
後から追加した画像は次回の走査対象になる。

- メタデータ読み取り: 862枚。
- デコード成功: **862 / 862枚**。失敗0枚。
- 全件デコード時間: **67.55秒**（テストは順次実行。常駐時は必要な写真のみ読み込む）。
- 縦写真747枚、横写真112枚、中間の比率3枚。幅270〜4096px、中央値1536px。
- 3840×1100に対し、縦パン候補は拡大上限2倍で183枚、4倍で662枚、6倍で736枚。
- 実写Gallery5枚: 270×450、1280×1920、1536×2048、1836×2448、3649×4096の写真を比率保持で同時表示。
- 実写Galleryの個別更新: 他の4枚を保持したまま1枚を交換、配置も再計算。
- 実写Vertical Pan: 1536×2048を3840px幅へ拡大。計算上の移動距離4020px、所要時間33.5秒。下側からの開始と描画・移動を確認。
- 実写Zoom: 4096×3463の写真で描画・拡大を確認。画面比率に合わせた上下の切り取りを伴う。
- 実写Horizontal Pan候補: 0枚。適性により抽選対象外になる。Horizontal Pan自体は4000×600の合成WebPで検証済み。
- 実写デコード試験のキャッシュ使用量: 62,441,472 bytes（設定64MiB以内）。プロセス全体のメモリ上限を意味しない。

詳細JSONと確認用PNGは `artifacts/actual-photos` に保存。写真と実写の確認画像は配布ZIPに含めない。
確認用PNGはWPFのレンダリング結果であり、OSが合成したデスクトップのスクリーンショットではない。

## 手動で残る確認

- Explorerの実際の強制終了・再起動後の復帰。
- モニターケーブルの抜き差し、解像度変更、96/144/192 DPIなどの混在と実際の変更。
- 実際のWindowsスリープ・復帰、仮想デスクトップ切替。
- 最大化・全画面アプリとの長時間の共存、Alt+Tabとマウスの通過を複数アプリで目視確認。
- 8〜24時間以上の連続運転におけるCPU/GPU/メモリの推移。
- Windows HEICコーデックの有無の両環境。

上記は実装済みの復旧経路を実機障害で検証したものではなく、未実施として区別する。

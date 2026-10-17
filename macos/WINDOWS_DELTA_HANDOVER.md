# Mac実装への引き継ぎ — 2026-10-17のWindows追加分

作成日: 2026-10-17（日本時間）。Windowsの実装基準は `f20e05c`、Macの比較基準は `7508db8`（v1.0.1 build 3の記録）。この資料と同じコミットに含めた共通fixtureの互換性修正も取り込んでから作業する。

## 今回実装する差分

オンライン化より先に、Mac単体のマルチディスプレイ対応を進める。Windows側で追加した以下の動作をMacへ移植する。LAN通信・ペアリング・PC間の時計同期・写真転送は今回の範囲外。

| ID | 差分 | Macの現状 | 完成時の動作 |
|---|---|---|---|
| D01 | 使用画面の複数選択・配置 | `selectedScreenID`による1画面選択 | 使用する画面を個別選択し、アプリ独自の座標で配置できる |
| D02 | グルーピング・独立再生 | 1個の`WallPlaybackController`と背面Window | 同じグループは共通キャンバス・共通再生、別グループと独立画面は別再生 |
| D03 | 設定UIの整理・グループ一覧 | Displayタブに画面・起動・再生操作が混在 | 「一般」「使用ディスプレイ」「画面グルーピング」を分離し、空グループも一覧・保存する |
| D04 | 即時テストパターン | 未実装 | グルーピング画面の「表示」で即表示、「表示停止」で終了。保存や写真登録は不要 |
| D05 | 顔の反対側からパン開始 | 検出・顔停止・Zoomは実装済み。縦Panは下から固定、横Panは乱数 | 最大の顔の反対側から縦横Panを開始。独立した設定を追加、初期値ON |

**Dock／メニューバーはmacOS側の設定に従う。** 2026-10-15にユーザー合意済みのOS差分を維持する。Windowsの画面ごとのタスクバー非表示は使用ディスプレイへ移動したが、Macへ動かないチェックボックスをコピーしたり、システム全体のDock設定を変更したりしない。詳細は[既存TODO](MACOS_PARITY_TODO.md#許容するos差分ユーザー合意済み)。

Macでは既にVision顔検出・顔キャッシュ、顔停止／Zoom、前景からの動的背景、次構成の先読み、FSEvents、原子的設定保存・完全なドラフト、ログイン起動・遮蔽休止・単一起動を実装している。旧レビュー中の「未実装」「コンパイルのみ」は当時の記録で、今回それらを作り直す必要はない。

## 参照するコード

| 内容 | Windowsの実装・テスト | Macの主な変更候補 |
|---|---|---|
| データ・グループ分割・座標 | [Models.cs](../windows/src/DynamicPhotoWall.Core/Models.cs)、[WallLayout.cs](../windows/src/DynamicPhotoWall.Core/WallLayout.cs) | [WallSettings.swift](DynamicPhotoWall/WallSettings.swift)、[SettingsRepository.swift](DynamicPhotoWall/SettingsRepository.swift)、[ScreenDescriptor.swift](DynamicPhotoWall/ScreenDescriptor.swift) |
| 再生全体・一時プレビュー | [WallController.cs](../windows/src/DynamicPhotoWall/WallController.cs) | [AppModel.swift](DynamicPhotoWall/AppModel.swift) |
| グループ単位の再生と復旧 | [WallPlaybackSession.cs](../windows/src/DynamicPhotoWall/WallPlaybackSession.cs) | [WallPlaybackController.swift](DynamicPhotoWall/WallPlaybackController.swift)、[DesktopWindowController.swift](DynamicPhotoWall/DesktopWindowController.swift)、[WindowOcclusion.swift](DynamicPhotoWall/WindowOcclusion.swift) |
| 共通キャンバスの切り出し | [PhotoRenderer.cs](../windows/src/DynamicPhotoWall/Rendering/PhotoRenderer.cs) | [DesktopWallView.swift](DynamicPhotoWall/DesktopWallView.swift)、[WallSceneViews.swift](DynamicPhotoWall/WallSceneViews.swift)、[AmbientBackground.swift](DynamicPhotoWall/AmbientBackground.swift) |
| UI・配置エディター | [SettingsWindow.xaml](../windows/src/DynamicPhotoWall/UI/SettingsWindow.xaml)、[SettingsWindow.xaml.cs](../windows/src/DynamicPhotoWall/UI/SettingsWindow.xaml.cs)、[DisplayLayoutEditor.cs](../windows/src/DynamicPhotoWall/UI/DisplayLayoutEditor.cs) | [ContentView.swift](DynamicPhotoWall/ContentView.swift) |
| 顔方向・停止位置・時間 | [MotionEngine.cs](../windows/src/DynamicPhotoWall.Core/MotionEngine.cs) | [WallScene.swift](DynamicPhotoWall/WallScene.swift)、`WallPlaybackController.needsFaces` |
| 回帰検証 | [Windowsテストランナー](../windows/tests/DynamicPhotoWall.Tests/Program.cs)の`RunAsync`内の顔方向ケースと`TestPatternToggleAsync` | [SharedParityTests.swift](DynamicPhotoWallTests/SharedParityTests.swift)、[FullParityRegressionTests.swift](DynamicPhotoWallTests/FullParityRegressionTests.swift)、既存モデル・UIテスト |

クラス名や描画方式までWPFと同じにする必要はない。以下のデータと動作を正本とする。

## D01 / D02: データと再生の単位

Windowsの追加データは次のとおり。Swiftでは既存の命名規則へ合わせる。

| 項目 | 意味・互換性 |
|---|---|
| `Displays[]` | 使用する画面の`Id, X, Y, Width, Height, GroupId, HideTaskbar`。座標と寸法は共通キャンバス上の物理px |
| `GroupId` | 同じ非空名の画面だけ連結。前後の空白を除去。空／nullはその画面だけ独立し、空の画面同士を結合しない |
| `DisplayGroupNames[]` | グループの定義一覧。使用中の所属名も取り込み、空名・重複を除去。所属画面ゼロのグループも残す |
| `MonitorId` | Windows旧単一画面設定のフォールバック。Macでは既存`SettingsSnapshot.screenID`の移行に相当 |
| `HideTaskbar` | Windowsだけの画面別設定。欠落時は旧グローバル値を継承。Macは既存のOS側設定に従う仕様を維持 |

Windowsは`GroupId`フィールドが欠落した旧複数画面設定を「グループ1」として扱い、以前の一枚壁を維持する。明示的なnullは独立を意味する。Macの既存単一画面設定は、保存済みIDの1画面へ移行する。新フィールド欠落で既存の設定・フォルダーブックマーク・ログイン起動設定を失わない。現在`SettingsRepository`はschemaVersion=1以外を拒否するため、版を上げる場合は読取り・書込み・旧版移行を一緒に扱う。

`DisplayGroups.Create`はグループ名を大文字小文字も区別して比較する。名前付きグループと、偶然同じ文字列の独立画面IDも別物として扱う。実際の再生セッションは所属画面があるグループだけ作り、空グループはUI・保存用に残す。

レイアウトはグループごとに左端／上端の最小値を引いて正規化する。幅は`max(X + Width) - min(X)`、高さは同様。負座標・上下ずれ・隙間を保持する。別グループの座標でキャンバスを広げない。Windowsは幅・高さ32768px以内、各画面の幅・高さが正、計算途中は広い整数型で検証する。

Macの`NSScreen.frame`はpointで、縦軸の向きも壁の上原点と異なる。OS上のWindow配置とアプリ内の物理px配置を分離し、Retina／混在倍率でpoint座標に一律2倍を掛けて連結しない。各画面の物理解像度と編集座標を保存し、切り出した領域の最終描画だけその画面のpointへ変換する。

1グループにつきSelector・Planner・時計・現在／次scene・フェード・背景を1組持ち、各画面は共通キャンバスの担当矩形を切り出す。同じ写真を画面別に抽選・レイアウトしたり、背景のblurを画面別に作ったりしない。独立グループの写真・時計・待機・復旧は分け、開始／停止／一時停止／再開／Nextのユーザー操作は全グループへ送る。同じ画像が偶然別グループに出ることは許容する。

現在のMacは`AppModel.playback`、`host`、`appliedScreenID`と`DesktopWindowController.window`が単一。グループ単位のセッションと画面単位の出力へ分ける際、既存のメニュー・状態表示・終了処理・テスト用fake hostも対応させる。走査・sandboxアクセス・顔解析／デコードキャッシュの共通資源は所有者を明確にする。

特に`PhotoImageStore.setDisplayedAssets`は現在、pin集合と必要幅を呼ぶたびに置換する。複数セッションから共有インスタンスへそのまま呼ぶと別グループの表示画像を解放し得る。所有者ごとのpin／必要幅を集約するか、全体のキャッシュ予算を守れる別の構造へ変更する。グループ数だけ256MiBを無制限に増やさない。

画面切断時は保存済み／最後に接続した寸法と担当領域を保持する。残った画面へ内容を詰めたり、未選択画面へ移したりしない。全所属画面が切れたグループだけ待機し、他グループは続行。接続・解像度変更・復旧で該当グループを再構成する。グループ全体の遮蔽休止は、そのグループの接続中画面すべてが同じ前面ウィンドウに覆われたとき。複数の別ウィンドウによる合算遮蔽は今回の必須条件にしない。

Windowsの描画は先頭画面に共通Canvasを接続し、他画面へVisualBrushで切り出す。先頭画面が原点以外にある場合も正しく切り出す。Canvasそのものを移動するとVisualBrush原点がずれるため、位置調整は外側のラッパーへ行っている。Macでも原点以外の最初の画面・共通背景の境界を回帰検証する。画面の物理走査タイミングまでの同期は保証していない。

## D03: 最終的な設定UI

最終のページ名は **一般 / 使用ディスプレイ / 画面グルーピング / 写真 / 表示モード / 動き / 見た目**。「表示設定」は「一般」へ改名済み。

- **一般**: ログイン起動、アプリ起動時再生、全体の再生操作。
- **使用ディスプレイ**: 写真を出す画面のチェック一覧・再検出。Windowsではここに画面別タスクバー設定を配置。MacではDock／メニューバーがOS設定に従う説明を維持する。
- **画面グルーピング**: グループ一覧、グループ追加、画面の所属選択、配置プレビュー、テストパターン。

グループ一覧は総数と、各グループの所属台数・画面名を表示する。所属ゼロは「画面未割り当て」と出す。「グループを追加」の直後に一覧と数を更新し、最小の未使用番号で「グループN」を作る。保存・再起動後も空グループを保持する。画面の所属は「独立して表示」または定義済みグループの選択式にする。

配置はドラッグ可能にし、同グループ内の端・中央へスナップする。X/Y入力・OS配置へのリセットは「配置を数値で調整」に折りたたむ。画面選択と所属指定は同じドラフトを参照し、チェック変更を一覧・配置へ即反映する。保存・開始・取消等はページ共通の位置に置く。Macの既存ドラフト取消・ウィンドウを閉じたときの破棄を維持する。

Windowsの通常1040×820／最小920×700は確認済み。Macの寸法はネイティブUIに合わせてよいが、最小サイズでも保存操作が隠れず、長い画面名やグループ増加時は適切にスクロールする。

## D04: テストパターンは一時的な表示操作

グルーピング画面に「テストパターン」と **表示** ボタンを置く。押したら現在の画面・グループ・配置ドラフトで即表示し、同じボタンを **表示停止** に変える。再クリックで終了し **表示** に戻す。「保存して表示開始」を押す必要はない。

一時表示の契約:

1. 表示前に選択・寸法・グループ・接続画面を検証。全画面未接続などで失敗した場合、動いていた写真を止めない。
2. 一時表示専用のドラフトコピーを持ち、保存済み／通常再生の設定を上書きしない。settings.json、ブックマーク、フォルダー登録、ログイン項目を変更しない。写真ゼロ・未登録・停止中でも使える。
3. テスト表示中だけ写真セッションを置き換える。終了時は通常再生が要求されていた場合だけ適用済み設定で写真セッションを再作成し、ユーザーpauseを維持する。開始前に停止していた場合は停止のまま。
4. 通常の開始は一時表示を解除し、写真を開始してpauseを解除。全体の停止は一時表示も解除する。途中の出力作成失敗は前の通常状態／一時表示への復帰を試みる。
5. 設定画面を閉じても一時表示は継続し、開き直したボタンも「表示停止」。設定ドラフトの取消・破棄とは寿命を分ける。通常設定を保存して適用しただけでは写真開始へ切り替えず、一時表示開始時の配置を維持する。
6. アプリ再起動でテスト状態を復元しない。Windowsに残る`DisplayTestPattern`は内部・互換用途で、LoadとUI保存はfalseへ戻す。Macでは一時状態の永続化自体が不要。

格子120px、斜線、円、選択画面全体での画面番号、グループ名、物理解像度、正規化後の座標を出し、継ぎ目・隙間・上下ずれを確認できるようにする。画面番号はグループごとに1から振り直さない。切断・再接続の復旧は写真停止中の一時表示でも動作する。

復元は写真セッションの再作成であり、前の写真の同じ時刻へ厳密に戻す仕様ではない。

## D05: 顔の反対側からパン開始

`faceAwarePanDirection: Bool = true`を`WallSettings`と欠落キーのデコードへ追加し、「動き」に **顔の反対側からパンを開始する** を置く。`stopAtFace`と`faceAwareFraming`とは独立した設定。表示モードの説明も **Vertical Pan — 縦写真を上下に見せる** へ更新し、下から固定という古い案内を残さない。

主な顔は正規化矩形の **面積が最大 → 同面積ならYが小さい → Xが小さい** の順で選ぶ。座標は向き補正済み画像の左上原点。Macの`PhotoFaceAnalyzer`は既にVisionの下原点を`y = 1 - box.maxY`へ変換しているため、再度上下反転しない。

| 顔中心とモード | 開始位置 → 進む側 |
|---|---|
| 縦: centerY ≤ 0.5 | 写真下部（Y=-overflow）→ 上部（Y=0） |
| 縦: centerY > 0.5 | 写真上部（Y=0）→ 下部（Y=-overflow） |
| 横: centerX < 0.5 | 写真右部（X=-overflow）→ 左部（X=0） |
| 横: centerX ≥ 0.5 | 写真左部（X=0）→ 右部（X=-overflow） |

方向ONで顔があれば横Panの乱数reverseより優先する。顔なし／設定OFFは旧動作（縦は下から上、横は選択ごとの乱数）へ戻す。Scrolling Galleryの方向、横Panの全幅移動・高さ、Zoomの既存動作は維持する。

`WallPlaybackController.needsFaces`を縦／横Panかつ方向ONでもtrueにする。既存のprepare・先読み・facesReady・assetWithFaces経路で顔を用意し、準備後に方向と時間を確定する。顔なしや検出失敗で待ち続けない。

縦Panで`stopAtFace`もONなら、方向に使った同じ最大顔で幅縮小と停止位置を決める。方向OFFの場合だけ従来どおり最も上の顔で停止する。顔の高さがviewportの92%以内になる幅を上限とし、上下4%余白の範囲内で顔中心を高さ30%へ寄せ、終点を`[-overflow, 0]`へclamp。移動時間は`abs(end-start)/speed`（移動ありは最低0.1秒、移動なし5秒）、停止後3秒保持。横Panは顔位置で途中停止せず、時間は従来の`max(5, overflow/speed)`。

現在のMacでは`WallMotionGeometry.duration(for:)`と`ForegroundGeometry.placements`（AmbientBackground.swift内）のmotion progress計算が分かれている。顔停止の3秒を移動時間に混ぜたり、新方向で負のdurationを作ったりしないよう、前景・背景と切替の両経路を確認する。

幾何の小さな期待値（viewport=1000×600、panWidthFraction=1、speed=120、方向ON、stopAtFace=OFF、顔矩形は左上原点）:

| モード・写真寸法 | 顔矩形(x,y,w,h) | from → to | 移動秒数 |
|---|---|---|---|
| 縦1000×2000 | (0.4,0.05,0.2,0.1) | Y=-1400 → 0 | 11.6666667 |
| 縦1000×2000 | (0.4,0.85,0.2,0.1) | Y=0 → -1400 | 11.6666667 |
| 横3000×600 | (0.05,0.3,0.1,0.2) | X=-2000 → 0 | 16.6666667 |
| 横3000×600 | (0.85,0.3,0.1,0.2) | X=0 → -2000 | 16.6666667 |

最初の縦ケースでstopAtFace=ONなら終点Y=-20、移動11.5秒＋停止3秒。複数顔・中心ちょうど0.5・方向OFF・停止OFF・顔なし・大きな顔・EXIF全8方向も確認する。

## 共通fixtureの扱い

取り込んだMac版には[WindowsParity.json](DynamicPhotoWallTests/Fixtures/WindowsParity.json)と[C# verifier](../tests/ParityVerifier/Program.cs)があり、SwiftとWindows Coreの同じ期待値を比較する。従来fixtureの36 motionケースには方向設定がなかったため、新しいWindows既定値ONにより`HorizontalPan-4: field 2`で不一致になった。

この引き継ぎコミットでは既存36ケースと生成器へ **faceAwarePanDirection=falseを明示** し、v1.0.1の従来動作の比較を維持した。期待座標を変更したり、製品の既定値をOFFへ戻したりしていない。Swiftは未知のJSONキーを無視できる。

Mac移植時はこの既存suiteを残し、方向ONの上下左右・複数顔・停止有無・reverse組合せを追加する。共通fixtureを追加するなら`SharedParityTests`の`cases.count == 36`、生成器、C#・Swift両方の読取りと期待値も更新する。旧期待値の一括再生成だけで合格にしない。

## 実装順序と受け入れ条件

推奨順: D05の純粋計算・回帰 → D01/D02のデータ移行とグループ再生 → D03のUI → D04の一時表示 → Mac実機受け入れ。各段階で既存の隔離テストを維持する。

- [ ] 旧単一画面設定の移行、未接続ID、フォルダー権限・ログイン設定の保持、保存失敗／取消。
- [ ] 2画面連結＋1独立、3独立、空グループの追加・保存・再読込、未選択画面へ表示しない。
- [ ] 負座標・上下ずれ・隙間・先頭画面が原点以外・別グループの遠い座標で、viewportと切り出しが正しい。
- [ ] 同グループの写真／動き／フェード／背景が境界でつながり、別グループのNext／待機／復旧が干渉しない。全体pause／停止・終了で全出力を解放。
- [ ] 共有キャッシュのpinと必要幅が別グループから消されず、全体予算・先読み・停止後の非同期結果を管理できる。
- [ ] 写真未登録で「表示 → 表示停止 → 表示」、未保存配置の反映、保存ファイルの不変、通常再生／pauseの復元、接続不能時の既存表示保持。
- [ ] 通常開始／全停止、設定の保存・取消・閉じる・再表示、アプリ再起動でも一時表示とボタン状態が一貫する。
- [ ] 縦横の顔方向・最大顔の選択・停止の有無・従来動作・定速・3秒保持が一致し、横Panへ顔停止を追加しない。
- [ ] Retina／混在倍率、実ケーブル抜差し、グループ遮蔽、スリープ、Spaces／Mission Control、長時間運転を実画面で確認。

## 検証状況と再現

WindowsはRelease発行・コア16項目が成功。最終UI／ボタン統合を含む18項目も成功。グループ別再生・画面別タスクバー、未接続IDの差し替え、共通キャンバスの画素比較を検証済み。実画面の提示確認は露出していたDISPLAY3のみで、他2画面は前景アプリに覆われていた。混在DPI・全画面を露出した境界・実ケーブル抜差し・Explorer再起動／スリープ・長時間運転は残る。[Windows検証記録](../windows/docs/TEST-RESULTS.md)を参照。

Mac基準版の記録は2026-10-15の **単体74件・UI3件、C#704 assertions成功、arm64 Releaseコンパイル成功**。2026-10-17にはWindows上で互換性修正後のC#共通fixture **704 assertions成功** を再確認した。今回Macアプリ・Swiftテストは実行していない。Mac実機受け入れの残件は[既存TODO](MACOS_PARITY_TODO.md#release前に残す実機受け入れ)を維持する。

Windowsの再現（リポジトリ直下、通常の対話デスクトップ）:

```powershell
.\windows\scripts\Build.ps1 -Test
.\.tools\dotnet\dotnet.exe windows/tests/DynamicPhotoWall.Tests/bin/Release/net10.0-windows10.0.19041.0/DynamicPhotoWall.Tests.dll artifacts/handover-settings --settings-ui --test-pattern-toggle
```

`.tools`がなければインストール済み`dotnet`を使用する。実写真・スクリーンショット・ログ・EXE・artifactsはGit対象外で、Macへpullしても付いてこない。コミットしたテストコード・fixtureと[検証記録](../windows/docs/TEST-RESULTS.md)で再現する。

Macの再現（Xcode 27／arm64・.NET 10、リポジトリ直下）:

```sh
bash macos/scripts/verify.sh --unit-only
bash macos/scripts/verify.sh
```

前者は単体・C#fixture・Releaseコンパイル、後者はUIも含む。既存スクリプトは専用アプリID・専用設定とfake hostを使用する。複数画面用fake host／screenProviderとUIプロファイルを拡張し、通常の壁表示・個人写真・ログイン項目を自動試験で変更しない。署名・配布手順は[Mac README](README.md)を参照。今回の引き継ぎは実装・検証用で、GitHub Releaseの更新は含めない。

## Mac側への作業依頼文

> mainの最新を取り込み、macos/WINDOWS_DELTA_HANDOVER.mdを基準にD01〜D05を実装してください。既存Mac v1.0.1の顔検出・背景・監視・設定保存・隔離テストを維持し、マルチディスプレイ、独立グループ、一般／使用ディスプレイ／画面グルーピングのUI、空グループ一覧、保存不要のテスト表示、顔の反対側からのパンを追加します。Dock／メニューバーは合意済みのOS設定に従う仕様を維持。PC間同期は後回しです。共通fixtureの従来ケースは方向OFFを明示してあり、方向ONの回帰を追加してください。自動検証と実機未確認を区別して記録してください。

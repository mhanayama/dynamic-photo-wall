# Mac実装への引き継ぎ — 2026-10-17のWindows追加分

**Macの公開配布更新（2026-10-20）:** Windows側の説明・配布構成へ合わせ、動作確認済みbuild 17の署名済みAPPを再ビルドせず、README・BUILD-INFO.txt・ライセンスを添えたZIP／DMGとSHA256SUMS.txtへ再梱包した。APP全6ファイルは受け入れ済みAPPと一致。公開先は既存の`macos-v1.1.0`、初回公開時のタグを保持し、実際のAPPソースは`0159a24`として本文・BUILD-INFOへ記録する。旧Mac独立Releaseはタグと配布物を保持した下書きで保管し、公開一覧は現行Mac版1件へまとめる。Windows本体・配布物・Releaseは更新しない。[配布検証](docs/RELEASE-VERIFICATION-2026-10-20.md)と[利用者向け更新内容](docs/RELEASE-NOTES-2026-10-20.md)を参照。以下は各作業時点の記録。

**build 17のユーザー受け入れ（2026-10-20）:** 配布後の手動テストでユーザーが「カクつかなくなった」と確認し、commit・push・PR作成とmainへのマージを指示した。今回の同期表示のカクつき改善として記録し、長時間運転・複数画面・スリープ復帰の網羅的な確認や通常アプリの定量再測定まで完了とは扱わない。以下の手動確認待ちは当時の記録。

**Mac同期カクつき修正のローカルbuild 17（2026-10-20）:** ユーザーの「両方を修正してRelease APPを置き換え、手動テストする」という指示により、display linkによる周期修正と、全写真のID・URL・顔情報・参照表の生成を専用actorへ移す修正を反映した。同じ写真metadataと順序の間は1つの不変snapshotを再利用し、Next・停止・進行役変更で古い準備結果を確定しない。Swift単体209件 / 31 suites、共通fixture・色・Zoom、ネットワーク26件 / 241 assertions、arm64 Release成功。署名付きAPP／ZIP／DMGとSHA256SUMSを`release/macos/arm64/`へ更新し、archiveも含むAPP全6ファイル一致を確認。旧配布物は`artifacts/macos/package/previous-release.IUtGFf/`。稼働build 16の終了・再起動、`/Applications`へのコピー、GitHub公開は行っていない。実機での改善はユーザーの手動確認待ち。初回画像表示の色変換・コピー等の別経路は未変更。[build 17のノート](docs/RELEASE-NOTES-v1.1.0-build17.md)を参照。以下の未修正という記述は調査時点の記録。

**稼働Macの長い停止を特定（2026-10-20）:** build 16へ20秒の`Animation Hitches`をattachし、`PNScenePlanner.prepare`の全候補写真からの参照表・ID生成がMainActorを116ms・72ms占有し、同時刻の更新の空白と一致することを確認した。初回画像表示のCore Animation色変換・コピー等も約48ms占有。display link修正だけではこれらは解消しない。次の対象は計画作成時の全写真のID・参照表生成をMainActorから外す／安全に再利用することと初回表示準備の検証。今回は原因調査で製品の追加修正・配布更新は行っていない。[時刻別のスタックと更新間隔](docs/SYNC-FRAME-PACING-MEASUREMENTS-2026-10-20.md#稼働中build-16の確認)を参照。

**同期フレーム周期の実測（2026-10-20）:** ユーザーの原因調査依頼により、同じ本体の`PNPlayback`と合成縦Panでdriverだけを切り替え、1920×1080・60Hzで各3回比較した。旧16ms相対待機は約57.5更新/秒・画面更新通知での据え置き4.223%、display linkは60更新/秒・据え置き0%。render処理は両方式ともp95約0.44msで、相対待機が滑らかさを損ねる要因であることを再現した。通常アプリ・配布物は未更新で、実同期条件の解消と他の停止要因は未確定。[測定条件と限界](docs/SYNC-FRAME-PACING-MEASUREMENTS-2026-10-20.md)を参照。

**Mac同期表示のカクつきの引き継ぎ（2026-10-20）:** ユーザー指示により、速度差よりカクつきの原因調査・修正を優先する。`fix/macos-synchronized-frame-pacing`に、描画後16ms待機を選択画面のdisplay linkへ置き換える修正候補と、偽driverによる共有時刻・pause/resume・切替のテストを追加した。Mac引き継ぎ後、Swift単体206件 / 31 suites、共通fixture・背景色・Zoom構図、ネットワーク26件 / 241 assertions、arm64 Releaseコンパイルが成功。実更新間隔・CPUの比較と実機での改善確認は残る。通常アプリ・配布物は未更新。[調査結果とMacでの検証手順](docs/HANDOVER-SYNC-STUTTER-2026-10-20.md)から引き継ぐ。速度差は改善後に再観測された場合に調べる。

**共有背景の終端時刻の修正（2026-10-20）:** Windowsの`duration * index / (count - 1)`が1 ULPだけ終了値を超え、`Invalid ambient frame`となる条件を再現。実Galleryの小数の終端でも発生する。Macと同じ比率先行の計算へ揃えた。通信の範囲検証は厳密なまま、例外に時刻・終了値・PNG bytesを追加。2,416背景フレームとWindows単体48件、共有ネットワーク26件／241 assertions成功。Swiftは既に安全な計算順序のため変更なし。[調査記録](../windows/docs/RENDERING-PERFORMANCE.md)を参照。修正版の実運転での再試行消失は未確認。

**Windows候補の長時間表示確認（2026-10-20）:** `ca71363`のRelease EXEを更新し、ユーザーは起動後約6時間に違和感なしと報告。同じプロセスの稼働も確認した。観測設定はオンラインGalleryのためローカル背景最適化の実機検証とは区別する。共有計画検証の`Invalid ambient frame`再試行が11件あり、原因・影響は未確定。PR #4はドラフトを維持する。[Windowsの記録](../windows/docs/RENDERING-PERFORMANCE.md)を参照。

**Windows Issue #2の背景生成（2026-10-19）:** ローカル背景を前景の変更と動作区間に応じて更新し、静止時は生成タイマーも停止する。0.8秒の色応答は保持画像の不透明度補間へ分離。動作中は最大8Hzの幾何照合で約0.5背景px未満の変化をまとめ、開始／終了と写真交換・再配置の確定を取得する。pauseと世代取消、画面別の購読解除を扱う。Windowsの同期PNG／wire時刻／受信補正、Mac側コードと配布物は変更しない。[Windowsの監査・回帰・計測手順](../windows/docs/RENDERING-PERFORMANCE.md)を参照。専用ブランチで検証し、実画面・GPU・電力・端末間表示の受け入れは別に残す。

**README・ライセンスと配布整備（2026-10-19）:** 本体はルート`LICENSE`のMITライセンス。依存通知はルートとWindows側の`THIRD-PARTY-NOTICES.md`へ分けた。Windowsは`Package.ps1 -Test`で最新EXE・配布README・実際の依存パッケージのライセンス・ビルド情報をZIP化し、SHA-256を確認する。Macの`package.sh`は次回作成時から、署名を維持したAPPの外側にMITと共通通知を置き、ZIP／DMGにも含める。出力先は引き続き`release/macos/arm64/`。この同梱差分のMac実行確認は残っており、今回のWindows作業ではMacの公開済みbuild 14を更新していない。

**build 16の受け入れ確認とmainへの統合（2026-10-19）:** ユーザーが通常表示について「綺麗に反映されてるし動作も軽くなった」と確認し、機能後退がなければIssue #1を関連付けたPRをmainへマージすることを許可した。PR #3の差分と回帰結果を再確認し、既知の機能後退・未解決レビュー・競合はない。通常アプリの定量CPU、GPU/電力/提示フレーム、複数実画面・Windows端末での網羅的な確認は未測定事項として残す。

**Macローカル配布build 16（2026-10-19 22:40）:** build 15再起動後のPID 81849のsampleでも`PNSceneView.draw`とCore Animationのbacking texture準備が残ったため、同期写真・背景を保持レイヤーへ移した。静止時は同じ属性を再設定せず、動作時は従来時刻の位置・倍率・不透明度を更新する。背景の色補正・PNG・wire時刻、clip/角丸/スパンcrop、写真と場面のフェードを維持。前面化は表示開始/非表示からの復帰時に限る。16ms時計と画面検出は維持した。Swift単体205件/31 suites、既存fixture・ネットワーク・arm64 Releaseが成功し、APP/ZIP/DMGの全6ファイル一致・署名・チェックサムを確認。配布物は22:40:52へ更新、旧build 15は`artifacts/macos/package/previous-release.91v0uU/`。稼働アプリの終了・再起動と`/Applications`へのコピーは行っていない。[build 16のノート](docs/RELEASE-NOTES-v1.1.0-build16.md)、[測定記録](docs/RENDERING-MEASUREMENTS-2026-10-19.md)を参照。同一合成fixtureの各3回平均CPUは静止5.55%→1.92%、背景補間16.78%→2.20%、Zoom17.51%→2.59%。最大RSSは増え、実画面/色管理/電力/実Windows同期は未確認。計測用の縦の色段差は旧描画にもあり、本番背景生成経路を通す合成画像で旧/新全画素差0を確認した。以下のbuild 15/14の記述は各作業時点の記録。

**Macローカル配布build 15（2026-10-19 22:15）:** ユーザーの配布用ビルド置き換え許可により、Issue #1の修正を含むAPP／ZIP／DMGとSHA256SUMSを`release/macos/arm64/`へ更新した。署名・arm64・ZIP/DMG・チェックサムと3つのAPPの全6ファイル一致を確認。旧配布物は`artifacts/macos/package/previous-release.d22W4u/`へ退避。`/Applications`と稼働中build 14は変更しておらず、GitHub Releaseも未公開。[build 15のノート](docs/RELEASE-NOTES-v1.1.0-build15.md)を参照。

**Mac Issue #1の実測（2026-10-19）:** 稼働build 14のCPU平均35.07%、同期描画とCore Animation/Metal関連のスタックを確認。固定fixtureの静止Galleryは変更前22.28%→PR版12.05%、背景生成80→0回/10秒。同期fixtureでは差がなく、静止/一時停止相当でも再描画が続く。次の対象は`PNWindowSurface.present`の無条件再描画と16ms進行処理。数値は通常アプリの同条件前後比較ではない。[実測と制約](docs/RENDERING-MEASUREMENTS-2026-10-19.md)を参照。

**Mac Issue #1の背景生成改善（2026-10-19）:** 静止構成の8Hz再生成をやめ、写真/配置/画像準備の変更と動作区間のサンプリングへ分離。ローカルの色追従は表示側の0.8秒応答へ移した。前景の顔保護計画・Gallery配置をキャッシュし、同一NSImageへの再描画要求も抑える。共有PNG・wire時刻・受信色補正は維持する。Swift単体193件・既存fixture・ネットワーク試験とarm64 Releaseビルドが成功。実CPU/GPU/電力・実画面の滑らかさ・Mac↔Windows表示は未確認。通常アプリ・配布物は更新していない。[監査と計測手順](docs/RENDERING-PERFORMANCE.md)を参照。

**Mac build 14の公開用検証（2026-10-19）:** `d67fd1f`までのGallery継続修正をMacで検証し、build 14へ更新した。さらに、ユーザー報告のCPU約47%・カーソルの一時停止を調べ、稼働中build 13の5秒間のスタック採取で`PNSceneView.draw`からの`PNAssetKey.opaqueId`の反復計算が主要な負荷源と分かった。写真IDと画面IDの照合、画像参照、背景の抽出・整列、画面の切り出しを計画の準備時に確定し、毎フレームの描画から除いた。Swift単体182件・29 suites、共通fixture704＋472 assertions、Zoom構図5120 assertions、色12ケース、.NETネットワーク26ケース・241 assertionsとarm64 Releaseコンパイルが成功。GUI操作なしの64予定×240回の照合比較は旧約399ms／新約3.6msで結果が一致した。実アプリのCPU低下やカーソル停止の解消は未検証。通常アプリの置換・再起動は行っていない。[検証記録](docs/TEST-RESULTS-2026-10-19.md#build-14-同期galleryの継続とプレリリース更新)と[リリースノート](docs/RELEASE-NOTES-v1.1.0-build14.md)を参照。以下のMac未実行という記述は取り込み前の記録として保持する。

**Gallery全体を再表示しない継続へ訂正（2026-10-19）:** `919e4fd`は有限計画ごとに別Galleryへ切り替えていた。ユーザーの期待は表示中のGalleryのまま1枚ずつの交換が続くこと。今回、plannerへ直前の確定済み計画を渡し、同じGalleryの当選は終端の写真・位置・大きさと交換時計・更新済みフラグを引き継ぐ予定の追加に変更した。Scrolling Galleryも終端位置と速度を維持する。`continuationOf`／`gallerySchedule`は省略可能なwire項目で、静止Galleryの交換途中には計画を区切らず、ready後のcommitを前計画の終端へ合わせる。WindowsはCanvasと残る画像要素を保持し、Macは同じ表示面とデコード済み画像を保持して全体フェードを行わない。Macの`PNPlaybackLayer`も、時刻0から始まる個別交換の明示的なfadeInSecondsを尊重する。Next・設定変更・異なるモードへの移行は通常の切替を維持する。Windowsは4条件×100計画・各2時間以上の仮想時計で、境目の写真・位置・大きさ・画像要素・不透明度1・交換間隔・pause/resumeとNextを確認し、GUIなし43ケースとネットワーク26ケース／241 assertionsが成功。Macの`NetworkModuleTests`と`NetworkPresentationTests.galleryContinuationKeepsTheSurfaceImagesAndFullOpacity`にも追加したが、Macでのコンパイル・実行・配布物更新は未実施。隔離設定で`verify.sh --unit-only`を実行する。実端末間表示とGUI自動操作は未実施。下の継続修正の記録は訂正前の経緯として保持する。

**同期Galleryの長時間停止を修正（2026-10-19）:** 共有計画は静止Galleryで既定90秒、Scrolling Galleryで120秒の有限タイムラインだが、同種Galleryの再当選抑止で次の計画が作られず停止していた。両OSでネットワークの計画生成だけ`allowGalleryRepeat`を有効にし、同じモードでも予定を更新する。ローカルの5秒後再抽選・写真交換の継続と、Pan／Zoomの連続回避・系統ウェイトは維持する。Windowsの新規回帰は実際のplannerとcoordinatorへ仮想時計を渡し、静止／スクロール×スパン／画面別で各100計画・2時間以上、ready前のcommit抑止と期限前の引き継ぎを確認した。修正前は2計画目で失敗、修正後はGUIなし43ケースとネットワーク26ケース／241 assertionsが成功。Swiftの`NetworkModuleTests.sharedGalleriesRenewAcrossTwoHoursWithoutWindows`と`ModeWeightTests.onlyFiniteSharedTimelinesAllowRepeatedGalleryDraws`を追加したが、Windows上のためこの追加分のMacコンパイル・テスト・配布物更新は未実施。Macでは従来どおり隔離設定の`verify.sh --unit-only`で確認する。実端末間の長時間表示・GUI操作は未実施。

**WindowsでZoom修正を検証（2026-10-19）:** `38eac2e`までを取り込み、`Build.ps1 -Test`にZoom構図のCLI検証を追加した。Windows Release発行、GUIなし42ケース、ネットワーク26ケース／241 assertions（相互TLSを含む）、Zoom構図5120 assertions、既存fixture704＋472 assertions、背景色12ケースが成功。縦Panの旧テストは現行初期値1.0と明示値0.96を区別するよう修正し、製品動作は変更していない。配布先は`release/windows/win-x64/`、旧EXEは`artifacts/windows/mac-zoom-integration/previous/`。起動中のアプリを保持したため新EXEの反映には再起動が必要。GUI操作・実端末間表示は未実施。[Windows検証記録](../windows/docs/TEST-RESULTS.md)を参照。

**Zoomの強制中央配置を修正（2026-10-19）:** 両OSの`FaceMotionSafety`で、顔を実画面中央へ置き直す処理を廃止。最小倍率で写真を中央配置する構図から、全顔を収めるための最小限の移動だけを行う。顔を支点にするズーム・倍率の同率縮小・実画面1枚への顔保護は維持する。画面の被覆と顔保護を両立できる場合は背景を露出させず、候補画面の同率時も写真の構図からの移動量で選ぶ。`ZoomMotionTests`とMacでも実行できるC#の`ParityVerifier --zoom-framing`で確認し、後者を`verify.sh`へ追加した。旧raw motionのfixtureは変更しない。Swift単体178件、C#の位置補正5120 assertions、既存fixture704＋472 assertions、Mac Releaseコンパイルが成功。1.1.0 build 13のローカルAPP／ZIP／DMGを更新し、署名・arm64・チェックサム・APP／ZIPの一致を確認した。[Mac検証記録](docs/TEST-RESULTS-2026-10-19.md#zoomの強制中央配置の修正)を参照。GUI操作・Computer Useは実施していない。

Windowsアプリの検証はユーザーが別端末で実施する。pull後に`dotnet run --project tests/ParityVerifier -- --zoom-framing`で新しい位置補正をCLI検証できる。Windowsのビルド・既存試験は`.\windows\scripts\Build.ps1 -Test`を使用する。GUI操作を伴う検証は、この引き継ぎだけを実行許可とみなさない。

**Mac build 12の公開（2026-10-19）:** 既存の1.1.0 build 12配布物を[プレリリース](https://github.com/mhanayama/dynamic-photo-wall/releases/tag/macos-v1.1.0-build.12)へ掲載した。ZIP／DMG／SHA256SUMSを添付し、署名・arm64・ZIP／DMG・チェックサム、APPとZIP内の全6ファイルの一致を再確認した。GitHub側の3添付のサイズとSHA-256もローカルと一致。正式版build 4は保持し、ネットワークは実機確認用と明記した。配布物のソース基準は`6ca7a10`で、`1ad7078`までmacOSソース・共通部品の変更はない。再ビルド・GUI自動操作・通常アプリの置換は行っていない。[リリースノート](docs/RELEASE-NOTES-v1.1.0-build12.md)を参照。

**Mac build 12の確認（2026-10-19）:** `1ffc189`までを取り込み、写真ソースの接続表示・ピア解除・Pan中央配置・Galleryの空きへの追加、一巡フラグと再当選スキップをMacで検証した。初期Galleryの写真順の逆転と、写真削除・差し替え・読込失敗後の再試行まで同種モード抑止が働く不具合をSwift側で修正した。通常の再当選は5秒待ち、表示中の写真が無効になった場合と明示的な再試行はモード履歴と待ち時間を解除する。単体174件・29 suites、共通fixture704＋472 assertions、色12ケース、.NETネットワーク26ケース・241 assertionsが成功。[検証記録](docs/TEST-RESULTS-2026-10-19.md#build-12-最新リモートの取り込みとgallery復旧)を参照。以下のMac未実行という記述は取り込み前の記録として保持する。実端末間の表示・GUI自動操作は今回の検証に含めない。

**最新のWindows追試（2026-10-19）:** 承認機能の復旧後、TLSを含むネットワーク26ケース／241 assertionsがすべて成功。以下の追加調整のTLS失敗は通常権限での追試前の記録である。Mac build 11のKeychain非使用・背景改善も取り込み済みだが、今回追加したSwiftコードとテストのMac実行確認は未実施。

**Mac build 11: Keychain非使用への変更（2026-10-19）:** ユーザーが連続するOS確認を避ける方式を選択した。`PNKeychain`と対話許可の経路を削除し、sandbox内の専用ファイルへ端末ID・鍵・信頼情報を保存する。0700／0600、原子的更新、identity上書き禁止、リンク・破損・鍵欠落時の停止を実装する。鍵ファイル自体は平文であり、同じユーザー権限の別プロセスに対する保護はKeychainより弱いという合意を含む。旧データがあれば明示的な新設定作成まで接続を保留し、旧Keychainと旧通信ファイルを変更しない。新しい端末IDで接続し直す。写真・設定の暗号化とTLSは維持する。[保存仕様](docs/LOCAL-NETWORK-STORAGE.md)を参照。以下のbuild 8のKeychain記述は当時の記録であり、現行の権限一覧には含まれない。

**2026-10-19の追加調整:** Panの各画面中央配置、Gallery列の中央寄せ、初期待機5〜10秒、選択済み・更新済みフラグ、同種Gallery再当選の破棄と5秒後再抽選、空きへの写真追加を両OSへ実装した。過去の10〜30秒などの記録は当時の結果。保留解除後、WindowsのReleaseコンパイルとGUIなし17ケースは成功。ネットワークは25ケース／237 assertions成功、TLSの1ケースは実行環境の秘密鍵保存制限で失敗した。接続直後の送信失敗時に仮接続が残るWindows側の問題も修正した。Swiftのattachは従来から初期送信を後処理の対象にしている。Macのこの追加分はビルド／実行未確認。[最新仕様と検証範囲](../docs/NETWORK-CORE.md)を参照。

**2026-10-19の写真ソース・ピア切断:** 両OSで未接続の写真ソースを既定で隠し、表示切替から保存済み選択を確認・解除できるようにした。編集中も接続状態だけを更新し、非表示によって選択・世代・キャッシュを消さない。接続済み一覧にこの端末との接続解除を追加。解除した側が明示接続するかオンラインモードを終了するまで、自動再試行と相手からの着信を拒否する。他の端末同士の接続には作用しない。inventoryで初めて知った候補にも失効時刻を付け、切断後に候補が残り続ける問題を修正した。Windowsの26ケース／240 assertionsとReleaseコンパイルは成功。Swiftの`NetworkDisconnectTests`を追加したがMacでは未実行。隔離設定の`verify.sh --unit-only`で確認し、GUI操作は明示依頼時だけ行う。[動作と検証記録](../docs/NETWORK-CORE.md)を参照。

**2026-10-19のGallery・顔サイズ:** `FixedGalleryLayout`で横長は高さ／縦長は幅をグループ短辺いっぱいに固定し、交換時の縮小を廃止。隣の写真を移動・退場させる。通常写真は全体、長辺がグループより長い単写真は外周を切り取り、顔保護がONなら顔を収められる位置を選ぶ。旧D09の縮小損失による最適化は現在の再生経路では使わず、過去fixture用の純粋な部品は保持する。`GalleryTimeline`が画面別表示を含むグループ全体の1本の交換時計を生成する。初期値10〜30秒、前のフェード完了後から次を数える。コントローラーも単独とグループで同じ規則へ変更。共有placementには省略可能な`fadeInSeconds`／`fadeOutSeconds`を加え、隣の写真は位置だけ動かして再フェードしない。

`FaceMotionSafety`は全顔の外接矩形を実ディスプレイへ収める。Zoomは開始・終了倍率を同率で下げ、Panは画像サイズと停止位置を補正し、移動が20px以下なら候補から除外する。既存のraw motion／Gallery計算は過去fixtureの基準として保持し、実際の表示部と共有計画は新部品を使う。`GalleryFaceTests`と既存の交換・準備待ちテストを更新した。2026-10-19にMacでimport不足を修正し、追加分を含む単体165件とReleaseコンパイルを確認した。[結果](docs/TEST-RESULTS-2026-10-19.md)を参照。

**背景の差分反映（Mac build 10）:** Windowsの`AmbientTransition`に相当する0.8秒基準の浮動小数点の色平滑化と、125msの表示補間を追加した。Macの`AmbientTextureTransition`は途中からの再目標設定で現在の混色を基底へ固定し、通常の表示tickでは保持した2枚の小画像の不透明度だけを変える。再生時刻を用いてpause中の色と補間を保持する。同期用PNGの生成にも各サンプルの時刻を渡し、色彩補正は受信時だけに維持する。ネットワークのMac表示は従来から準備済みサンプル間を連続補間する。色の追従・途中切替・不透明な基底の保持は部品テストで検証し、実画面での知覚確認は残す。

新規テストをGUI撮影なしで確認する場合は、隔離bundle IDと`artifacts/macos/verification/DerivedData`を指定し、`xcodebuild test`の`-only-testing:DynamicPhotoWallTests/GalleryFaceTests`、`ModeWeightTests`、`ZoomMotionTests`を対象にする。verifyは既定でGUI操作なし。GUI操作の自動テスト（`--ui`）や画面撮影は明示依頼がある場合だけ実行する。実機では縦横グループの短辺固定、交換が重ならないこと、顔が収まる動き、Windows進行役・Mac進行役双方の共有計画を確認する。
**2026-10-18の縦Pan幅:** ユーザー指定で`panWidthFraction`の初期値と非有限値の補正を0.96から1.0へ変更。Windows・Swift・共有再生の初期値とUI表記を統一する。保存済みの0.96等は上書きしない。顔を画面へ収める縮小は維持する。2026-10-19にMacでReleaseコンパイルを確認した。

**2026-10-18の抽選ウェイト統合:** ギャラリー（静止・スクロール）80／パン・ズーム（縦・横・拡大縮小）20の2段抽選へ変更。Swiftの`ModeSelection`を単画面の`next`とグループの`chooseGroupMode`から利用する。連続回避は同じ系統内だけにし、1モードしかなくても系統の割合を変えない。設定UIは`galleryWeight`と計算プロパティ`motionWeight`の2項目。永続化・wireでは`panWeight`を合算した動きの重みにし、`zoomWeight`は旧値の読込み専用として0で保存する。旧初期値45／35／20は80／20へ移行、旧カスタム値はPanとZoomを合算。2026-10-19に`ModeWeightTests`と既存のウェイト0のテストをMacで確認した。異なる抽選規則の旧ピアを混在させない。

**2026-10-18のZoom調整:** ユーザー指定で「パンと同様にはっきり動く」方向にし、初期値を30秒・1.25倍、倍率上限を1.5倍へ変更した。Windows／Swiftの設定モデル・入力表示と.NET共有設定を揃えた。保存済み設定・受信した共有設定を勝手に新値へ書き換えず、既存ウォールでは設定から適用する。2026-10-19にSwiftの`ZoomMotionTests`をMacで確認した。共通fixtureの旧設定は既存仕様の回帰検証として維持する。

**2026-10-18の表示品質原則:** ユーザー指定により、視覚的・知覚的に自然な連続表示を最優先とする。[共通原則と受け入れ基準](../docs/CROSS-PLATFORM-WALL-PLAN.md#最優先の設計原則視覚知覚の自然さ)に従い、通常のモード・通信状態・60秒フォールバック・再同期のために出力ウィンドウを開き直さない。次の写真と背景の準備・フェード完了まで直前の表示面を維持する。Windowsでは表示ツリー準備をウィンドウ所有から分離し、遠隔ピア離脱時の論理キャンバス変更でもローカル出力を保持するよう修正した。Macもbuild 9で画面キー単位の表示面保持と、旧・新の計画ごとの切り出しを実装した。Macでは重なった表示の不透明度も保持し、連続切替時の飛びを防ぐ。実ウィンドウを作らない回帰テストで確認し、実画面での知覚確認は残す。

**背景色彩の追加引き継ぎ:** Windowsはぼかし後の色差を最大1.6倍、輝度を最大1.12倍へ補う`AmbientPixels.EnhanceColors`を追加。RGBの余裕で補正量を制限し、無彩色・色相・アルファを保つ。ローカルはぼかし後・時間補間前、ネットワークは受信PNGのデコード時に一度だけ補正する。転送PNGは基底色のままにする。Swiftもbuild 9で`AmbientColors`を追加し、ローカルはぼかし後・時間補間前、同期表示は受信PNGデコード後に一度だけ適用した。進行役の`AmbientProcessor`は転送PNGを未補正で生成する。共通fixture12ケースをWindows本体のコードとSwiftで照合する。Windowsの背景生成側へ補正を加えて二重に掛けない。

**Mac限定の権限復旧（build 8）:** 起動時のアクセス権限一覧と一括取得を追加した。写真・Keychain・通知・LAN・登録済みフォルダーを扱い、保存済みのオンライン復帰は必要な確認後に進める。フォルダーの再許可で共有設定や未保存ドラフトを上書きしない。[仕様と署名の制約](docs/PERMISSIONS.md)を参照。GUI操作を伴う検証は実施しない。

**2026-10-18のD08改定:** 横Pan・縦Pan・Zoomで、グループ長辺方向の写真画素数が長辺の半分未満なら同一写真を各画面へミラーする。横長（正方形を含む）は向き補正後の横画素数、縦長は縦画素数を比較し、ちょうど半分は除外する。全接続画面でモード適性を満たす必要があり、各画面でも許容倍率を超えるパン写真をスパンへ戻さない。この規則は下記の旧D08の倍率による判定に優先する。Swiftの`MirrorPolicy`と`WallGroupPlayback`、共通fixture8ケースと`MirrorAmbientTests`へ反映し、Macで共通fixtureを含む単体テストとReleaseコンパイルを確認した。実画面での見え方の確認は残る。全5モードの背景暗幕も18%へ弱め、既存の端色の延長とクランプぼかしを維持する。Windowsはネットワーク背景生成にも同じ余白延長を適用し、装飾グラデーションを除去した。

**2026-10-18のネットワーク追加:** 以下のD01〜D09は既存単体機能の引き継ぎ記録として維持する。通信のSwift実装をMacで修正し、隔離テスト・Mac上のSwift／.NET相互TLSとmulticast検出を検証した。実際のWindows端末とのLAN・同期表示は未検証。[Macの結果](docs/NETWORK-TEST-RESULTS-2026-10-18.md)、今の作業範囲・検証コマンド・実機確認項目は[NETWORK-CORE.md](../docs/NETWORK-CORE.md)を参照。今回の作業ではネットワークを開発対象へ進めており、末尾の旧依頼文の「PC間同期は後回し」は当時の優先順位である。

作成日: 2026-10-17（日本時間）。Windowsの実装基準は `f20e05c`、Macの比較基準は `7508db8`（v1.0.1 build 3の記録）。この資料と同じコミットに含めた共通fixtureの互換性修正も取り込んでから作業する。

**Mac反映状況（2026-10-17）:** `d1044b6`まで取り込み、D01〜D09のMac実装と隔離回帰テストを追加。以下は移植元の仕様・当時の比較表として保持する。現在の操作は[Mac README](README.md)、実行結果と実機残件の区別は[Mac検証記録](docs/TEST-RESULTS-2026-10-17.md)を参照。

D06/D07追加時にはMacの`0f31687`も統合済み。写真アプリのアルバム連携・選択時の自動スキャン・通常の適用時再生開始を保持する。設定移行で`SettingsSnapshot.photoAlbums`やPhotoKitの写真識別子を失わず、権限・ドラフト・再検索・既存テストも維持する。D04の一時テスト表示は写真ソースの走査や保存と独立した経路にする。

## 追加引き継ぎ: 配布物とOS別の一時ファイル

両OS共通の[生成物の規則](../docs/GENERATED-FILES.md)とルートの[AGENTS.md](../AGENTS.md)を守る。配布物はルート配下の **release/** へ統一し、Windowsは`release/windows/win-x64/`、Macは`release/macos/arm64/`。今回Windowsのビルド／起動／ショートカットとMacのpackage／verifyスクリプトを新パスへ変更した。

Mac側は展開済みの`DynamicPhotoWall.app`・ZIP・DMG・SHA256SUMSを`release/macos/arm64/`へ置く。2026-10-18のユーザー指定で、APPも直接起動できる状態で残す。archive・DerivedData・archive.logと置換前のローカル配布物は`artifacts/macos/package/`、検証ログは`artifacts/macos/verification/`へ置く。DMG stagingはOS標準一時領域に作成し、終了時に削除する。その他の一時ファイル・キャプチャ・診断結果は`artifacts/macos/<作業名>/`またはOS標準一時領域へ出す。OS差分で出るファイルを含め、ルート直下へAPP・ZIP・DMG・ショートカット・ログ・一時ファイルを生成／コピーしない。

- [x] Mac実機で変更後の`verify.sh`／`package.sh`を実行し、完成物と作業ファイルが上記の場所へ分かれることを確認する。
- [x] 実行前後のルート直下ファイル一覧を比較する。ignore済みのファイルも確認し、ルートへ生成物が増えていないことを記録する。
- [x] 新規スクリプトやリダイレクトも出力先を明示し、配布先変更時はREADME・handover・起動手順を同時に更新する。

Windows上ではMacスクリプトの構文と出力パスを確認する。署名・archive・DMGの実生成はMac側で検証する。過去の検証記録の旧パスは証跡として残してよいが、これからの作業は新パスを使う。

## 今回実装する差分

オンライン化より先に、Mac単体のマルチディスプレイ対応を進める。Windows側で追加した以下の動作をMacへ移植する。LAN通信・ペアリング・PC間の時計同期・写真転送は今回の範囲外。

| ID | 差分 | Macの現状 | 完成時の動作 |
|---|---|---|---|
| D01 | 使用画面の複数選択・配置 | `selectedScreenID`による1画面選択 | 使用する画面を個別選択し、アプリ独自の座標で配置できる |
| D02 | グルーピング・独立再生 | 1個の`WallPlaybackController`と背面Window | 同じグループは共通キャンバス・共通再生、別グループと独立画面は別再生 |
| D03 | 設定UIの整理・グループ一覧 | Displayタブに画面・起動・再生操作が混在 | 「一般」「使用ディスプレイ」「画面グルーピング」を分離し、空グループも一覧・保存する |
| D04 | 即時テストパターン | 未実装 | グルーピング画面の「表示」で即表示、「表示停止」で終了。保存や写真登録は不要 |
| D05 | 顔の反対側からパン開始 | 検出・顔停止・Zoomは実装済み。縦Panは下から固定、横Panは乱数 | 最大の顔の反対側から縦横Panを開始。独立した設定を追加、初期値ON |
| D06 | モードごとの画面別描画 | 未実装 | 各モードに「ディスプレイごとに表示」。OFFはグループ全体へスパン、ONは画面ごとの写真・配置・背景 |
| D07 | スパンを維持した顔の境界回避 | 未実装 | Galleryと縦Panで検出顔を画面境界から避け、グループ全体の構成を維持 |
| D08 | 小画像の縦Pan自動ミラー | 未実装 | スパンへの拡大率が上限を超えても各画面で適性がある写真は、同じ写真を各画面へ表示 |
| D09 | Galleryの顔回避による余白改善 | 未実装 | 写真列を詰め、必要時に顔矩形がキャッシュ済みの候補から再抽選する |

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

## D06 / D07: モード別の画面単位描画とスパン中の顔保護

ユーザーの主目的は「顔がディスプレイの境界に来るのを避けること」。このためだけに全モードを独立表示へ切り替えると、グルーピングの意味がなくなる。**スパンの顔優先配置を主な対策にし、モード別の画面単位表示は独立した選択肢として提供する。**

追加設定:

| Windows名（SwiftはcamelCaseへ） | 初期値 | UI |
|---|---|---|
| `GalleryPerDisplay` | false | Gallery行の「ディスプレイごとに表示」 |
| `GalleryScrollPerDisplay` | false | Scrolling Gallery行の同チェック |
| `VerticalPanPerDisplay` | false | Vertical Pan行の同チェック |
| `HorizontalPanPerDisplay` | false | Horizontal Pan行の同チェック |
| `ZoomPerDisplay` | false | Cinematic Zoom行の同チェック |
| `AvoidFaceDisplayBoundaries` | true | 「スパン時に顔が画面の境目に重ならないよう配置」 |

旧設定は各モードのスパンを維持する。例: Galleryだけ画面単位、Scrolling Galleryはスパン。グループ内のモード抽選・時計・フェード・pause・Nextは共有し、画面単位のときだけ各画面の物理寸法で写真・構成・背景を作る。全接続画面に候補があるモードを選び、各画面の適性で写真を選ぶ。履歴・キャッシュはグループ／アプリ内で共有し、写真不足時は別画面での再使用を許容する。短いモーションは終点を保持し、最長の時間で次の構成へ移る。Gallery交換とscroll流入も画面ローカルの寸法を使う。未接続画面の領域は残すが、画面単位のシーンは接続中の画面だけ作る。

Windowsでは`CompositionEngine.Next(...displayViewports)` / `ForMode`、`WallPlaybackSession.PreparedGroup`、`PhotoRenderer.BuildPerDisplay`が実装。`SceneVisual.Surfaces`で現在の写真・背景・交換処理を集約する。**画面単位の出力は画面IDへ対応させる**。設定座標が重なっていても各画面の写真が混ざらないようにし、旧スパン→画面単位、画面単位→スパンのフェードも扱う。WPFは描画元Canvasを最初のWindowへ接続したまま表示用Canvasから参照し、サンプリング元自身ではなく外側のラッパーを配置する。

スパン中の顔保護は[FaceSafeLayout.cs](../windows/src/DynamicPhotoWall.Core/FaceSafeLayout.cs)を正本とする。複数画面グループで、写真ごとの**全検出顔の外接矩形**を接続中の画面内へ収める。1台が切れて接続画面が1台だけになっても、保存済みキャンバスの未接続領域へ顔を配置しない（`RequiresProtection`）。画面内側の余白は`min(24px, 短辺*0.03)`。既存のVision検出・EXIF補正・顔キャッシュを再利用し、Galleryの準備・交換にも顔解析を追加する。顔がない写真は従来配置へ戻す。

- **Gallery**: 最初に従来と同じ高さで配置可能か調べ、写真の順序・全体表示・非重複・間隔を維持しながら位置を調整する。無理な場合のみ高さを下げ、実現可能な最大の高さを探索する。最終配置で各写真の全検出顔を1つの接続画面内へ収める。交換時は既存slotの位置とサイズを滑らかに補間し、交換写真だけフェードする。**再配置アニメーション中に顔が境界を通過してよい**（2026-10-17のユーザー指定）。旧／新レイアウト全体をフェードするだけの切替へ戻さない。WPFはSineEaseを使い、pauseとNext／停止時のclock解除・最終値確定も扱う。
- **Vertical Pan**: まずXを寄せる。写真の顔以外が壁の外周で切れることは許容し、不必要な縮小を避ける。顔の広がりが大きければ幅を縮小。顔停止ONは全顔が見える安全なYへ終点を補正し、方向選択と距離÷速度を維持。内部の上下境界がある場合はパンの移動範囲も制限する。写真が壁より低いときの配置YはWindowsの`MotionPlan.FrameTop`相当で保持する。
- **Scrolling Gallery / Horizontal Pan / Zoom**: この配置調整の対象外。横方向に移動する2モードは境界を通過してよい。必要ならD06の画面別表示を使う。

必要な回帰: 全5モードのチェック・旧設定・保存、異なる解像度のモード適性、スパンと画面単位の切替、画面IDと座標重複、背景の寿命、共有pause／Next／停止、Gallery交換・scroll、切断復帰。顔は左右／上下配置・隙間・複数顔・大きな顔・停止と方向ON/OFF・未検出・設定OFF・交換中の再配置を検証する。Windowsの`--per-display-modes`とコアの`FaceBoundaryGeometry`を参照し、共通fixtureへも境界を渡すケースを追加する。従来の境界なしfixtureは期待値を維持する。

## D09: 顔の矩形キャッシュを利用したGalleryの余白改善

2026-10-17の追加指定。YOLO化・バスト／ヒップ等の部位検出・スキャン後の全件バックグラウンド解析は後日検討とし、既存の顔キャッシュでGalleryの配置を改善する。新しい設定項目は不要。写真全体とスパンを維持し、トリミングは行わない。

1. `FaceSafeLayout.Gallery`で、各写真の顔が許されるX/Y区間を列の原点へ変換して交差を求める。写真順序・同じ高さ・基準線・通常Gapのまま列全体を移動できるなら優先する。中央に近い区間候補を各段階で128件まで保持する。無理なら従来の写真別配置・必要時の高さ縮小へ戻る。
2. ランダムのスパンGallery・顔境界回避ONの場合、開始時の構成と写真交換時に、顔位置の既知候補で改善を試す。Windowsの[GalleryComposition.cs](../windows/src/DynamicPhotoWall.Core/GalleryComposition.cs)を正本とし、評価値は`2*max(0, 1-safeHeight/originalHeight) + (追加Gap合計 + abs(列中心X-壁幅/2))/壁幅`。写真本来の縦横比による自然な外余白は除き、顔保護で増えた隙間・縮小・偏りを評価する。0.02以上改善する場合だけ採用する。
3. キャッシュ参照はファイル／PhotoKit資産の現行識別子・サイズ・更新日時に対応させ、未解析と検出済み顔なしを区別する。候補は最大12枚、初回構成で最大2回、更新は交換する1slotだけ。現在表示中の写真と同一構成内の重複を除外し、直近履歴も尊重する。試算は履歴を消費せず、採用写真だけ記録する。計算は表示のUIスレッド外で行い、取消を反映する。
4. 試算候補を一括デコード・顔検出しない。既知の矩形から配置を計算し、採用時だけデコードする。未解析写真は通常抽選で選ばれた時の既存の顔解析でキャッシュを増やす。候補なし・改善なし・読込失敗は元の写真で継続する。名前順、画面別Gallery、顔境界回避OFFは再抽選しない。

Gallery交換の滑らかな位置／サイズ補間と、移動中の顔の境界通過許容はD07のまま。Macでは既存の`PhotoFaceAnalyzer`actorにキャッシュだけを参照する経路を追加し、解析結果の座標原点とPhotoKit識別子を保持する。PhotoKitのドラフト・自動スキャン・適用時開始を変更しない。Windowsの`--gallery-fill`は既存キャッシュに矩形を用意した専用写真で、名前順との違い、開始・定期交換・Next・pause・停止、ファイル変更時の無効化、通常Gapと画像全体の維持を確認する。

## D08: 幅が小さい縦写真の自動ミラー

D06の縦Panの画面別チェックがOFFでも、写真ごとに次の条件でミラーへ切り替える。設定のチェックや保存ファイルを書き換えず、グループも分割しない。

- `wall.width * panWidthFraction / photo.orientedWidth > maxPanUpscale`で、接続中に壁より横幅の狭い画面がある。
- **同じ写真**が接続中の全画面の縦Pan適性を満たす（縦横比<0.95、各画面への拡大率が上限以内、表示高が画面高+20pxを超える）。別の写真が適合しても代用しない。
- 境界値ちょうどはスパンのまま。EXIF補正後の幅を使う。顔未検出でも動作し、顔の境界回避設定から独立する。

例: 横800pxの縦写真、壁3840px、左右各1920px、幅割合0.96、許容上限4倍では、壁への4.608倍は不可、各画面への2.304倍は可なのでミラー。大きな写真はスパンを維持する。各画面でも上限を超える小画像は縦Pan候補にしない。単独画面や上下配置で壁幅と各画面幅が同じ場合、ミラーへ切り替えても拡大率は改善しないため対象外。

Windowsは`CompositionPlan.MirrorPerDisplay`で抽選段階から候補を扱い、最大の接続画面幅に合わせてデコード・顔解析を1回行って、同じ写真とbitmapを全出力へ配る。各画面の物理寸法でモーションを作り、共通時計・pause・Next・フェード・最長時間を維持する。短いモーションは終点で待つ。未接続画面には描画せず、保存した壁領域は保持する。D06を手動ONにした場合は従来どおり画面ごとに別写真を選び、自動ミラーにしない。

Windowsテストの`--mirror-gallery`は同一写真・同一bitmap・各画面寸法・pause／Next・スパン復帰・手動個別表示・未接続画面を実セッションで確認する。同じテスト内でGalleryが既存slotの中間位置を通ること、pause中の停止、完了／取消後の安全な最終配置も確認する。コアの小画像ケースは異なる解像度・拡大率境界・EXIF・候補除外・単独画面を含む。Macでは同等の隔離テストを追加する。

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

1グループにつきSelector・Planner・時計・現在／次scene・フェードを1組持つ。D06がOFFのモードは通常は共通キャンバスと背景を作り、各画面へ担当矩形を切り出す。D06がONのモードではモード抽選と時計を共有したまま画面別の写真・レイアウト・背景を作る。D08の自動ミラーは同じ写真から画面別シーンを作る例外。独立グループの写真・時計・待機・復旧は分け、開始／停止／一時停止／再開／Nextのユーザー操作は全グループへ送る。同じ画像が偶然別グループに出ることは許容する。

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

**追加修正: 各グループの一覧カードに「削除」を必ず設ける。** 空グループ・所属画面があるグループの両方を削除できる。削除したグループの全画面（現在未選択の画面も含む）は「独立して表示」へ戻し、選択・配置・画面別設定を維持する。削除はドラフトだけを更新し、保存で反映、保存せず閉じれば元の設定を維持する。再検出時に保存済みグループ名をドラフトへ再追加して復活させない。最後のグループも削除でき、保存・再読込後に既定の「グループ1」を勝手に再作成しない。再び追加した場合は最小の未使用番号を使う。Windowsの回帰は`--group-deletion`で実行できる。

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

推奨順: D05の純粋計算・回帰 → D01/D02のデータ移行とグループ再生 → D06/D07/D08/D09の画面単位モード・スパン顔保護・自動ミラー・Gallery余白改善 → D03のUI → D04の一時表示 → Mac実機受け入れ。各段階で既存の隔離テストを維持する。

- [ ] 旧単一画面設定の移行、未接続ID、フォルダー権限・ログイン設定の保持、保存失敗／取消。
- [ ] 2画面連結＋1独立、3独立、空グループの追加・保存・再読込、未選択画面へ表示しない。
- [ ] 空／所属あり／最後のグループの削除、未選択画面の所属解除、再検出での非復活、保存・再読込・未保存で閉じたときの保持を確認する。
- [ ] 負座標・上下ずれ・隙間・先頭画面が原点以外・別グループの遠い座標で、viewportと切り出しが正しい。
- [ ] 同グループの写真／動き／フェード／背景が境界でつながり、別グループのNext／待機／復旧が干渉しない。全体pause／停止・終了で全出力を解放。
- [ ] 共有キャッシュのpinと必要幅が別グループから消されず、全体予算・先読み・停止後の非同期結果を管理できる。
- [ ] 写真未登録で「表示 → 表示停止 → 表示」、未保存配置の反映、保存ファイルの不変、通常再生／pauseの復元、接続不能時の既存表示保持。
- [ ] 通常開始／全停止、設定の保存・取消・閉じる・再表示、アプリ再起動でも一時表示とボタン状態が一貫する。
- [ ] 縦横の顔方向・最大顔の選択・停止の有無・従来動作・定速・3秒保持が一致し、横Panへ顔停止を追加しない。
- [ ] 全5モードの画面単位チェックとスパンへの切り替え、各画面の適性・背景・画像交換、全体pause／Nextを確認する。
- [ ] 個別表示へ逃がさず、スパンGallery・縦Panで検出顔を境界から避ける。左右／上下配置・隙間・複数顔・Gallery交換中・未接続画面も検証する。
- [ ] Galleryの詰めた列、矩形キャッシュによる再抽選、未解析／検出なしの区別、名前順の維持、候補不足・読込失敗・取消時の継続を確認する。
- [ ] Retina／混在倍率、実ケーブル抜差し、グループ遮蔽、スリープ、Spaces／Mission Control、長時間運転を実画面で確認。

## 検証状況と再現

D09追加後はWindowsのコア20項目と、余白改善・画面別描画・背景・復旧・自動ミラー／Gallery再配置の統合5項目が成功。共通fixture704 assertionsも成功。余白改善は合成写真と保存済みの顔矩形を用い、検出器の精度とは分けて検証した。これはWindows側の引き継ぎ時の記録で、Macの移植・実行結果は[Mac検証記録](docs/TEST-RESULTS-2026-10-17.md)を参照。

WindowsはRelease発行・コア19項目が成功。モード別の画素・UI・実再生、実顔検出とスパン境界回避、既存のグループ・プレビュー・削除・背景・復旧の統合も成功。D08追加時には自動ミラーとGallery再配置の統合も成功し、同一写真／bitmap・中間位置・pause・取消後の最終配置を確認した。未接続IDの差し替え、共通キャンバスの画素比較を検証済み。タスクバー復元は通常版との干渉を除いた再検証で成功。実画面の提示確認は露出していたDISPLAY3のみで、他2画面は前景アプリに覆われていた。フレームレート測定・混在DPI・全画面を露出した境界・実ケーブル抜差し・Explorer再起動／スリープ・長時間運転は残る。[Windows検証記録](../windows/docs/TEST-RESULTS.md)を参照。

Mac基準版の記録は2026-10-15の **単体74件・UI3件、C#704 assertions成功、arm64 Releaseコンパイル成功**。2026-10-17にはWindows上で互換性修正後のC#共通fixture **704 assertions成功** を再確認した。この段落はWindows側引き継ぎ作成時の記録。Mac移植後の単体・UI・追加fixture・パッケージ検証は[2026-10-17のMac検証記録](docs/TEST-RESULTS-2026-10-17.md)を参照。Mac実機受け入れの残件は[既存TODO](MACOS_PARITY_TODO.md#release前に残す実機受け入れ)を維持する。

Windowsの再現（リポジトリ直下、通常の対話デスクトップ）:

```powershell
.\windows\scripts\Build.ps1 -Test
.\.tools\dotnet\dotnet.exe windows/tests/DynamicPhotoWall.Tests/bin/Release/net10.0-windows10.0.19041.0/DynamicPhotoWall.Tests.dll artifacts/windows/handover-settings --settings-ui --test-pattern-toggle
```

`.tools`がなければインストール済み`dotnet`を使用する。実写真・スクリーンショット・ログ・release・artifactsはGit対象外で、Macへpullしても付いてこない。コミットしたテストコード・fixtureと[検証記録](../windows/docs/TEST-RESULTS.md)で再現する。

Macの再現（Xcode 27／arm64・.NET 10、リポジトリ直下）:

```sh
bash macos/scripts/verify.sh --unit-only
bash macos/scripts/verify.sh
```

現在は両コマンドともGUI操作なしの単体・C#fixture・ネットワーク基盤・Releaseコンパイル。UI操作はユーザーから明示的な依頼がある場合だけ`--ui`で実行する。既存スクリプトは専用アプリID・専用設定とfake hostを使用する。複数画面用fake host／screenProviderとUIプロファイルを拡張し、通常の壁表示・個人写真・ログイン項目を自動試験で変更しない。署名・配布手順は[Mac README](README.md)を参照。今回の引き継ぎは実装・検証用で、GitHub Releaseの更新は含めない。

## Mac側への作業依頼文

> mainの最新を取り込み、macos/WINDOWS_DELTA_HANDOVER.mdを基準にD01〜D09を実装してください。既存Mac v1.0.1とPhotoKitアルバム連携の顔検出・背景・監視・設定保存・隔離テストを維持し、マルチディスプレイ、独立グループ、設定UI、グループ追加／削除、保存不要のテスト表示、顔の反対側からのパン、モード別の画面単位表示を追加します。主目的の顔境界対策は、スパンGallery・縦Panで顔を避ける配置として実装してください。Galleryは滑らかに再配置し、移動中の顔の境界通過を許容します。D09の詰めた列と顔矩形キャッシュからの再抽選で余白を減らし、名前順と写真全体を維持してください。YOLO・他部位検出・全件解析は後日検討です。幅の小さい縦写真だけはD08の拡大率判定で同じ写真の自動ミラーへ切り替え、手動の別写真表示と区別してください。Dock／メニューバーは合意済みのOS設定に従い、PC間同期は後回しです。既存fixtureを維持し、新しい方向・境界・画面別描画・自動ミラー・Gallery余白改善の回帰を追加してください。AGENTS.mdとdocs/GENERATED-FILES.mdに従い、配布物はrelease/macos/arm64、作業生成物はartifacts/macos配下へ分け、ルート直下へ一時ファイルを出さないことも確認してください。自動検証と実機未確認を区別して記録してください。

# ピア間ネットワークの実装と検証

更新: 2026-10-18。[基本設計](NETWORK-PEER-DESIGN.md)に沿って、通信から設定UI・同期表示まで接続した。Windowsのビルドと自動検証は実施済み。Swiftのネイティブ実装と部品テストも追加したが、このWindows環境にはXcodeがないため、**Macのビルド・Mac↔Windowsの実機相互接続は未検証**。完成・配布の判定には後述のMac検証を残す。

## モジュールと責任境界

Windowsの通常再生Coreからネットワーク基盤を独立させ、[shared/DynamicPhotoWall.Networking](../shared/DynamicPhotoWall.Networking)を`net10.0`のライブラリーにした。WPF・Win32・PhotoKit・既存のWindows Coreを参照しない。Macへ.NETを埋め込まず、同じ契約とポートをSwiftで実装する。

| 責任 | OS非依存.NET | ネイティブSwift |
|---|---|---|
| データ契約・検証 | `PeerContracts.cs`、`Session/SessionContracts.cs` | `PeerContracts.swift` |
| 依存の入口 | `Session/Ports.cs` | `PNPeerLink`、`PNTransport`、`PNDiscovery`、`PNClock`、`PNPhotoProviding`、`PNScenePlanning`、`PNPlaybackOutput`、`PNNotifications` |
| 共有設定・進行役 | `Session/Leadership.cs` | `PNPeerSession`の設定確定処理、`PeerWallMerge.swift` |
| メンバー管理・メッセージ振分け | `Session/PeerSession.cs`、`PeerSession.Merge.cs` | `PeerSession.swift` |
| TLS・メッセージ境界 | `Transport/` | `PeerTransport.swift`のTLSアダプター |
| LAN広告 | `Discovery/LanPeerDiscovery.cs` | `PNLanDiscovery` |
| 写真取得・転送ジョブ | `Photos/PhotoTransferService.cs` | `PeerPhotos.swift` |
| 暗号化保存 | `EncryptedPhotoCache.cs`、`Persistence/` | `PeerStorage.swift` |
| 共通時計・切断状態 | `SharedClock.cs`、`PeerPlaybackRecovery.cs` | `PNSharedClock`、`PNRecovery` |
| Prepare／Ready／予約Commit | `Playback/SceneCoordinator.cs` | `PNSceneCoordinator` |
| 表示計画の時刻評価 | `Playback/SharedScenePlan.cs`、`GroupTimeline.cs` | `PNPlacement.evaluate` |

Windows固有の接続点は[Networking/](../windows/src/DynamicPhotoWall/Networking)に置く。`WindowsNetworkHost`が部品を組み立て、`WindowsSecretStore`だけがDPAPI、`WindowsPhotoProvider`が既存写真走査と顔検出、`WindowsPlaybackOutput`がWPF／デスクトップ出力を扱う。設定画面はドラフトを編集し、セッションへ要求する。

写真保存は`IPhotoCache`を介して転送状態から分離する。UIはロック不要な`PhotoTransferService.Progress`だけを枚数表示に使う。キャッシュI/O中に`Available`や`Catalog`をUIから列挙しない。`CoalescedAction`が通知を一つにまとめ、Windowsの`DispatcherUpdateQueue`が100msごと・Background優先度で画面へ反映する。写真データの受信ごとにUI処理を積まず、写真1枚の完了時に進捗と次の取得要求を更新する。配置プレビュー・接続候補・設定のバインドは内容が変わった時だけ更新する。

同期開始と共有設定の適用はワーカー上で行い、開始元のUI同期コンテキストを定期処理へ引き継がない。同じソース設定の再適用ではディスク索引を再走査せず、有効なキャッシュの再通知では原データを復号し直さない。原データの認証・ハッシュ検証は実際の読込み時に行い、破損・消失を検出したら未取得へ戻して再取得する。Windows写真提供側も、起動後に原データのハッシュがキャッシュと一致すれば既存の顔metadataを再利用する。

Mac側は[Networking/](../macos/DynamicPhotoWall/Networking)に、Keychain／Network.framework／PhotoKit／Vision／AppKitのアダプターを置く。`NetworkModel`が組立てとUI、`PeerSettingsAdapter`が既存の設定モデルとの変換を担当する。データ契約へフォルダー権限・PhotoKit識別子・AppModelを持ち込まない。

## 接続・設定・進行役

設定画面には自端末のホスト名を表示する（Windowsは「このPC」、Macは「このMac」）。接続候補、写真ソースの提供元、画面一覧・配置プレビューの端末名もホスト名を使う。写真ソースは「ソース名（ホスト名）」の形式。端末IDは内部の接続・キャッシュ管理に維持し、表示名には短縮IDを使わない。未接続で名前が分からない端末は「未接続の端末」と表示する。

画面一覧と配置プレビューは「ホスト名 / ディスプレイ名」で表示する。`PeerDisplay.name`はOSから取得した名前をinventory・共有状態・表示計画に含め、接続時に既存の画面名も更新する。Windowsは`MonitorDescriptor.Name`、Macは`WallDisplay.name`を送信する。配置・所属の識別には引き続き`(peerId, displayId)`を使う。名前のない旧保存データも読み込め、まだ名前を取得できない画面は「ディスプレイ」と表示する。両端末にこの契約を含む版を導入して検証する。

保存済みの画面一覧は現在の接続状態を意味しない。通常の一覧・配置プレビューは確認済み画面だけに絞り、「未接続の画面も表示」で保持中の画面を確認・編集できる。接続状態の列と薄いプレビューで区別する。遠隔画面は現在の認証済み接続で受け取ったinventoryに存在するものだけを接続中とし、発見候補や過去の共有状態からは推定しない。開始時のローカルinventoryにも、その時点でOSが列挙した画面だけを含める。切断や一覧の絞込みでは配置・選択・グループを削除せず、再接続で一覧へ戻す。オンラインモード終了時は画面・ソース等の一時表示状態をクリアする。

配置プレビューのドラッグは、表示上12px以内に近づいた隣接画面へスナップする。上下左右の接続、同じ端の整列、中央揃えに対応し、ネットワーク配置では端末やグループを問わず選択済み画面を対象とする。遠い行・列の画面は対象外。ドラッグ中の縮尺・座標原点を保ち、スナップはドラフトだけに反映する。Windowsの通常配置も同じ純粋な`DisplaySnapping`部品を使い、Swiftは`DisplayLayout.snapped`で同じ共通fixtureを検証する。

1. 「ネットワーク」のオンラインモードで待受と広告を開始する。候補の「接続」を押すまで新規接続しない。受信側には承認画面を出さない。
2. 初回接続は自己署名証明書を端末IDへ固定するTOFU方式。以後の証明書変更を拒否する。既知ピアへの再接続と接続群の内部接続は自動で行う。
3. 全画面を`(peerId, displayId)`で識別し、一つの画面一覧でグループ／単独表示を管理する。同じグループ名だけで勝手に結合しない。未接続画面の配置も保持する。
4. どのピアからも、読込み時のrevisionと要求IDを付けて変更できる。進行役が検証・暗号化保存してから確定する。同時編集は拒否し、未保存の編集を保持する。適用済み要求IDの履歴も複製し、交代後の再送を二重適用しない。
5. 生存中の進行役を維持する。離脱後は残存IDの辞書順で後任を選び、termとsessionを更新する。旧進行役が復帰しても古いtermでは設定を取り戻さない。分断中は各接続群が継続でき、合流時はtermとIDで収束する。
6. 接続済みの二つの壁を明示的に接続した場合も、旧側の全画面・グループ・ソースを合流させる。接続先側の進行役と共通表示設定を採用し、旧側の他ピアへ移行を伝える。合流履歴を保存し、後から戻る旧ピアも追従できるようにする。

LAN発見には当初候補のmDNSではなく、両OSで同じ小さなUDP multicast広告を実装した。`239.255.77.87:47391`へ2秒ごとに`photowall-v1`、名前、端末ID、版、TCPポートを広告する。写真・顔・元のパス・鍵を広告しない。候補は8秒で期限切れになる。TLSのTCPポートはOSが選ぶ。OSのローカルネットワーク許可とファイアウォールのアプリ許可は必要。別セグメントやmulticast遮断環境の探索は対象外。

JSONはcamelCase、UUID、文字列の列挙値、base64画像チャンクを使う。フレームは`uint32 big-endian length | JSON`、上限4MiB。`PeerPacket { type, body }`をTLS 1.2／1.3で双方向に送る。64KiBの写真チャンクは別ジョブから送信を直列化し、制御メッセージとの書込み混線を防ぐ。送信・ハンドシェイクに期限を設ける。

## 原寸写真と暗号化キャッシュ

ソース適用時に提供ピアが原データを読み、向き補正後の寸法と正規化顔矩形を生成する。受信側は顔を再検出しない。通常ファイルとPhotoKitの原写真リソースを、そのままのバイト列で転送する。PhotoKitの編集後レンダリングへ変換する処理は加えていない。HEIC等の表示可否はWindows側のコーデックにも依存し、低画質への変換で代替しない。

同一提供ピアのソースを選択し直した場合、または「写真キャッシュを更新」で新世代を発行する。旧世代の写真・顔を削除し、遅れて到着した旧ジョブを拒否する。ソース解除・起動中断後に残った不要ファイルも整理する。再接続や表示モードだけの変更では世代を変えない。変更のないローカル写真を再デコードし続けたり、長い取込みを定期処理で毎分中断したりしない。

キャッシュは生成・検証から14日で期限切れとし、読取り・再接続では延長しない。定期処理で期限切れを削除し、ソースが利用可能なら再取得する。索引も暗号化ヘッダーから復元し、平文の顔一覧や元のパスを別ファイルへ保存しない。原データのディスク予算は既定10GiB、1画像256MiB、同時受信2件。容量不足は未取得枚数を表示して待機し、即座の再取得ループにしない。デコード用メモリ予算は原寸の保存品質と分ける。

```text
magic:       ASCII "DPWCAC01" (8 bytes)
salt:        32 random bytes
block 0:     encrypted PhotoCacheHeader JSON (photo + faces + cachedAt + expiresAt)
block 1..N:  encrypted original chunks, at most 65,536 bytes
each block:  int32 little-endian length | ciphertext | 16-byte GCM tag
file key:    HKDF-SHA256(device key, salt, info="DynamicPhotoWall/photo-cache/v1", 32 bytes)
nonce:       four zero bytes | uint64 big-endian block number
AAD:         UTF-8 "DPWCAC01:{opaqueId}:{blockNumber}:{plaintextLength}"
opaqueId:    lowercase SHA-256("{provider:N}:{source:N}:{generation:N}:{imageId}")
```

保存はAES-256-GCM。WindowsはDPAPI、MacはKeychainで端末の鍵とIDを保護する。保存鍵は他ピアへ送らない。途中の`.tmp`も暗号文。完了時に原データのSHA-256、ヘッダー、チャンク認証と順序を確認してから公開する。改ざんや不完全なデータを再生へ渡さない。画像・顔・元の名前はログに出さない。

## 同期表示・切断

共通再生設定の`galleryMax`は1〜20枚（初期値5枚）。Windows・Macの設定正規化と共有契約も同じ範囲とする。静止Galleryの実枚数は共通キャンバスの縦横比と利用可能な写真数に応じて決まり、設定値を上限とする。

既存の抽選・モード判定・Gallery配置・顔配置・Motionの計算をOS側の計画アダプターから呼ぶ。進行役だけが具体的な写真、始点・終点、拡大率、継続時間、クリップ、画面別指定を決め、縮小背景の先読みサンプルも送る。5モードと画面単位／スパンを扱う。

横Pan・縦Pan・Zoomの写真は、グループ長辺方向の画素数が長辺の半分未満なら同じ写真を各画面へミラーする。横長（正方形を含む）は向き補正後の横画素数、縦長は縦画素数を比較し、半分ちょうどはスパンを保つ。全接続画面で既存のモード適性を満たす必要があり、パンの許容倍率を超えた写真を強制的にスパンしない。表示計画の既存の画面別指定で転送するため、追加のプロトコル項目は不要。

全5モードの背景生成は、透明な余白を写真色で埋めてから端色をクランプしてぼかす。ローカル背景とネットワーク背景で同じ処理を使い、暗幕は約18%へ統一する。装飾グラデーションを除去し、画面端の人工的な黒帯を防ぐ。

各表示部が画像をデコードしてReadyを返した後、2秒先の共通時刻でCommitする。描画は`sharedNow - startAt - pausedDuration`から位置を評価し、メッセージ到着を開始の起点にしない。遅れたフレームも同じ時刻の位置へ追従する。時計はOS時刻が一致する前提を維持し、4時刻の往復計測で小さな補正を滑らかに反映する。物理的な画面の提示差・フレーム同期精度は実機で測定する。

heartbeatは1秒、無応答6秒で切断、登録済み接続の再試行は5秒間隔。切断／再接続はOS通知へ渡す。残存ピアは同期を続け、孤立側は最後の表示計画を60秒繰り返し、その後ローカルキャッシュによる単体計画へ移る。再試行は続け、準備後の予約Commitで同期へ戻る。ユーザーのpause／停止を接続復旧だけで解除しない。

配置ドラフトはドラッグと数値で編集できる。格子・円・斜線のテスト表示は別の出力経路で予約し、設定の保存や写真の再生時計・pause／停止を変更しない。

## 実施した検証

- OS非依存ネットワーク・配置: 25ケース、224 assertions成功。実際の相互TLS loopback、3ピアの別端末設定・原寸転送・進行役離脱・60秒フォールバック・再接続、2壁から4ピアへの合流とpause引継ぎ、revision競合と再送、予約テスト表示、暗号化・期限・容量制限、ディスプレイ名の転送・旧データからの名前補完、15パターンの配置スナップ、保存済み画面と現接続の区別を含む。追加の応答性テストではI/Oを止めた状態での進捗取得、通知の集中、再接続時のキャッシュ再利用、UI同期コンテキストを引き継がない開始・設定反映を確認した。
- Windows: 既存20ケースと新規2ケース成功。5モード×スパン／画面単位の計画・背景・時刻評価・切出し、DPAPIの隔離保存を確認。WPFの切出し画像は最大2/255の端の丸め差を許容し、平均画素差も制限した。
- Windowsの設定画面全8ページを1040／920pxで描画して確認。ネットワークページの追加後も既存ページの順番を維持する。
- 応答性修正ではウィンドウを開かず、Windows部品3ケース（10万件の通知より入力を優先、キャッシュからの顔解析再利用、Gallery20枚）を確認した。結果は`artifacts/windows/network-responsiveness/`。この修正時のGUI撮影・実端末を再接続しながらの手動操作確認は行っていない。
- 低画素写真・背景修正ではWindows部品5ケースが成功。共通の長辺判定8ケース、3モード×横長／縦長グループの同一写真の画面別計画、全5モードの背景の端色を合成データで確認した。結果は`artifacts/windows/mirror-ambient/test-results.json`。GUI撮影は行っていない。Swiftの同じfixtureと部品テストは追加済みで実行未確認。
- 既存の共通fixtureは704 assertions、OS差分fixtureは472 assertions成功。
- Windows Releaseコンパイル成功。Swift側はテストコードを追加した段階で、ここでは実行していない。

結果は`artifacts/windows/network-core/`、`artifacts/windows/smoke-data/`へ保存する。試験は合成写真・専用設定・一時秘密鍵を使用し、個人写真や通常の壁を変更しない。

3／4ピアの試験はテスト用トランスポートによる同一プロセス内の検証で、TLS loopbackは実ソケットを使う。実際の3台・異なるOSの提示タイミングを確認した結果とは区別する。

```powershell
$env:NUGET_PACKAGES = Join-Path $PWD '.tools/packages'
.\.tools\dotnet\dotnet.exe run --project tests/NetworkCore.Tests -c Release -- artifacts/windows/network-core
.\.tools\dotnet\dotnet.exe run --project windows/tests/DynamicPhotoWall.Tests -c Release -- artifacts/windows/smoke-data
```

[NetworkWire.v1.json](../tests/Fixtures/NetworkWire.v1.json)はC#が生成した合成データの共通fixture。原データ、試験用鍵、暗号化ファイル、共有設定、表示計画、opaque IDを含み、Swift側でも復号・値の一致・Ready障壁を検証する。実際の鍵・証明書・写真は含めない。

## 手元のMacでの確認

ユーザーの手元のMacで実施する。まず同じコミットを取り込み、通常の壁や個人設定を触らない単体検証を行う。

```sh
bash macos/scripts/verify.sh --unit-only
```

新規の`NetworkModuleTests`は共通fixture、C#暗号文のSwift復号、原寸保持、改ざん拒否、14日期限、切断状態、予約Commitを対象にする。既存のPhotoKit・グループ・表示・権限・設定テストも維持する。出力は`artifacts/macos/verification/`。

その後は合成写真フォルダー等を使い、次を確認する。**実行前にMac側のコンパイルエラー・警告を解消し、成功ログを残す。**

1. 両OSでオンラインを有効にし、相互に候補が出る。片側の「接続」で確認画面なしに接続し、証明書と鍵が各OSの保護領域で再利用される。
2. Macのテスト用アルバム／フォルダーを選んで適用する。Windowsへ原寸が届き、顔データも一致する。JPEG／PNG／WebPに加え、手元のHEICのデコード可否を確認する。
3. 両OSのいずれからでも全画面の所属と座標を編集でき、格子の境界が実画面でつながる。モード5種類、画面単位、pause／再開／Next／停止を確認する。
4. 進行役を終了し、残存側の同期継続・自動交代を確認する。孤立側は60秒後に単体動作となり、再接続で予約時刻の同期へ戻る。通知の重複、pause／停止の解除がないことも確認する。
5. 写真ソースの再適用と解除、容量上限、スリープ復帰、再起動、長い取込み中の設定変更、ネットワークの再断を確認する。

Macの結果と両OS間の提示時刻差・長時間運転の結果が揃うまで、ネットワーク機能を検証済み完成物として配布しない。今回の作業はソース実装とWindows検証であり、既存の公開済みMacリリースの更新・公開は含めない。

# ピア間ネットワークの実装と検証

更新: 2026-10-19。[基本設計](NETWORK-PEER-DESIGN.md)に沿って、通信から設定UI・同期表示まで接続した。Windowsのビルドと自動検証に加え、Macでコンパイル修正・隔離テストとSwift／.NETの通信検証を実施した。**Mac上の相互TLS・multicast検出と、実際のMac↔Windows間のLAN・画面表示は別の検証**。[Macの結果](../macos/docs/NETWORK-TEST-RESULTS-2026-10-18.md)と後述の実機確認項目を参照。

## 表示・ギャラリーの追加調整（2026-10-19）

**最新の検証:** 承認機能の復旧後、TLSを含むネットワーク26ケース／241 assertionsがすべて成功した。結果は`artifacts/windows/gallery-peer-build/network-core-unrestricted/test-results.json`。WindowsのGUIなし17ケースも成功済み。以下のTLS失敗の記述は通常権限による追試前の記録である。Mac build 11の保存方式・背景改善を取り込んだが、今回追加したSwift部分のMacでの実行確認は引き続き未実施。

写真ソース・ピア解除の検証後に追加された依頼をソースへ反映した。縦Panは各表示面の写真全体を中央へ置き、顔の収容に必要な分だけ横へ補正する。ミラーも各画面のviewportで計算する。Galleryは顔が収まる複数の画面区間を保持して列全体の中央に最も近い位置を選び、先頭の画面への偏りを避ける。

Galleryの初期待機を5〜10秒に変更し、旧初期値30〜60秒・10〜30秒だけを移行する。独自の設定値は維持する。空きに写真とgapが収まる場合は、最大枚数内で既存写真を退場・縮小せず追加する。追加できない場合は従来の固定サイズで交換する。グループ全体の更新済みフラグで、追加・交換直後の写真が残った古い写真より先に再交換されないようにする。写真選択にも履歴と独立した一巡フラグを持つ。

Gallery→Gallery、Scrolling Gallery→Scrolling Galleryの当選は破棄し、表示を保持して5秒後に再抽選する。異なるGallery同士の切替は可能。ローカルの更新処理は待機中も続け、共有計画は次の採用計画を準備するまで直前の表示を保持する。80／20は破棄分を含む抽選の割合で、採用された切替の比率ではない。設定revisionの変更時はモード履歴をリセットし、同じモードでも新設定を適用できるようにする。

ビルド保留の解除後、Windows本体・テストのReleaseコンパイルとGUIを開かない17ケースが成功した。結果は`artifacts/windows/gallery-peer-build/test-results.json`。ネットワーク試験では接続直後の送信失敗時に仮接続が残る問題を見つけ、初期inventory送信も受信ループと同じ後処理で接続解除するよう修正した。この回帰試験を含む25ケース／237 assertionsは成功。相互TLSの1ケースは実行環境の証明書秘密鍵インポートで失敗し、通常権限では未検証。結果は`artifacts/windows/gallery-peer-build/network-core/test-results.json`。NuGetの脆弱性情報へ接続できない警告NU1900があるが、コンパイルエラーはない。Macの追加分はビルド・実行未確認。以下の26ケース／240 assertionsの成功記録は、この追加調整より前に承認済み環境で実行した写真ソース・ピア解除修正の結果である。

## 写真ソースの接続状態と手動解除（2026-10-19）

写真ソースは現在の接続と受信したソース一覧で有効性を判定し、未接続・提供終了のソースは既定で隠す。「未接続の写真ソースも表示」で保存済みの選択を確認・解除できる。接続状態の更新は設定の編集中も反映するが、選択・世代ID・暗号化キャッシュは表示フィルターだけでは変更しない。接続時のinventoryからだけ追加された候補にも8秒の失効を適用し、切断後の一覧残留を防ぐ。

接続済みピアの一覧から、この端末と選択したピアとの接続を即時解除できる。Windowsではソケットを先に閉じ、通信処理の待ち合わせが詰まっていても解除を進める。オンラインモードを終了するか、この端末の接続候補から明示的に接続し直すまで、当該ピアへの自動再試行と相手からの着信を抑止する。他のピアとの接続、保存済みの画面配置・ソース選択・キャッシュは保持する。別の端末同士の接続を解除する機能ではない。wire契約は変更していない。

WindowsのReleaseコンパイルとOS非依存ネットワーク26ケース／240 assertionsが成功。3ピアでの切断・提供ソース変更・他ピア経由の再試行・手動再接続、送信停止中の強制解除とキャッシュ保持を検証した。結果は`artifacts/windows/source-presence-unrestricted/test-results.json`。GUI操作・画面撮影は実施していない。Swiftにも同じ変更と`NetworkDisconnectTests`を追加したが、今回のMacコンパイル・テスト実行は未確認。

## Gallery・顔サイズ・背景の表示部品（2026-10-19）

固定サイズの配置は.NET Coreの`FixedGalleryLayout`とSwiftの同名部品、グループ全体の交換予定は`GalleryTimeline`で計算する。UI・ファイルI/O・通信から独立し、縦横のグループと複数の画面別表示を部品単位で検証する。Galleryは短辺をほぼいっぱいに固定し、隣の写真の移動・退場で交換を収める。待ち時間は前の交換のフェード完了後から次を数える。初期値の最新変更とビルド保留の状態は上の追加調整を参照。

共通placementへ省略可能な`fadeInSeconds`／`fadeOutSeconds`を追加した。未指定は従来の`fadeSeconds`へフォールバックし、旧wire fixtureの直列化は変えない。新Galleryでは写真の入場・退場と隣の写真の位置移動を分け、動かすだけの写真を再フェードさせない。すべての接続ピアをこの契約に対応した版へ揃える。

`FaceMotionSafety`は既存の動き計算の結果を受け、全顔の外接矩形が実ディスプレイへ収まるようZoomの開始・終了倍率、Panの画像サイズと停止位置を補正する。20pxを超える移動が残らないPanは候補から除外する。共有計画に確定した位置・寸法・倍率を載せ、受信側で顔検出をやり直さない。

Windowsの背景は`AmbientTransition`で経過時間による色平滑化、`AmbientTexturePresenter`で125msの表示補間を行う。共有背景は`AmbientFrameVisual`に全サンプルを固定して載せ、更新は不透明度だけにする。Mac build 10は`AmbientTransition`と`AmbientTextureTransition`で同等の時間依存処理を行い、同期用PNGにも計画中のサンプル時刻を使う。受信側は準備時に保持した背景画像を連続補間する。[handover](../macos/WINDOWS_DELTA_HANDOVER.md)を参照。

Windowsの対象部品17ケース、ネットワーク25ケース／224 assertions、既存fixture1,176 assertionsが成功。結果は`artifacts/windows/gallery-face/`。GUIの撮影・表示・描画キャプチャは行っていない。Macでも追加分を含む単体165件、共有fixture1,176 assertionsと背景色12ケース、ネットワーク25ケース／224 assertions、arm64 Releaseコンパイルが成功した。[Macの2026-10-19の結果](../macos/docs/TEST-RESULTS-2026-10-19.md)を参照。実機同期・知覚確認は未検証。
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

Windowsの計画先読みは`SharedSceneBuilder`で画像・背景・表示ツリーだけを準備し、ウィンドウを生成しない。`PlaybackSurfaceLayout`がローカル出力の再利用を判断し、`WindowsPlaybackOutput`は既存の出力を保持して計画を交換する。遠隔ピアが消えて共通キャンバスの原点・幅が変わっても、ローカルの画面が同じなら再生成しない。旧・新のツリーは各計画に属する切り出し座標を持つ。`PhotoRenderer`は旧ツリーと表示ビューを残して新表示を重ね、フェード完了後に旧表示を解放する。孤立時の繰り返しも同じ切り替えとし、Galleryの最終写真は新表示が覆うまで保持する。

Macの`PNPlayback`はデコード済みの計画と物理出力を分離する。出力は`PNDisplayKey`で保持し、準備ではウィンドウを作らない。新表示を重ねて不透明になった後に前表示を解放し、連続切替では実際に見えている重なりを維持する。旧表示は旧計画の座標で切り出す。孤立時も同じ重ね替えを使い、Galleryの終端写真を準備待ちの間に消さない。単体移行・再同期・グループ変更だけでは出力を閉じず、停止・明示的な表示対象解除・物理画面の消失で閉じる。最初の共有表示も、未描画の出力は透明なままとし、全出力の実際の描画完了を待って旧ローカル表示を退ける。

写真保存は`IPhotoCache`を介して転送状態から分離する。UIはロック不要な`PhotoTransferService.Progress`だけを枚数表示に使う。キャッシュI/O中に`Available`や`Catalog`をUIから列挙しない。`CoalescedAction`が通知を一つにまとめ、Windowsの`DispatcherUpdateQueue`が100msごと・Background優先度で画面へ反映する。写真データの受信ごとにUI処理を積まず、写真1枚の完了時に進捗と次の取得要求を更新する。配置プレビュー・接続候補・設定のバインドは内容が変わった時だけ更新する。

同期開始と共有設定の適用はワーカー上で行い、開始元のUI同期コンテキストを定期処理へ引き継がない。同じソース設定の再適用ではディスク索引を再走査せず、有効なキャッシュの再通知では原データを復号し直さない。原データの認証・ハッシュ検証は実際の読込み時に行い、破損・消失を検出したら未取得へ戻して再取得する。Windows写真提供側も、起動後に原データのハッシュがキャッシュと一致すれば既存の顔metadataを再利用する。

Mac側は[Networking/](../macos/DynamicPhotoWall/Networking)に、専用ファイル保存／Network.framework／PhotoKit／Vision／AppKitのアダプターを置く。`NetworkModel`が組立てとUI、`PeerSettingsAdapter`が既存の設定モデルとの変換を担当する。データ契約へフォルダー権限・PhotoKit識別子・AppModelを持ち込まない。

MacのキャッシュI/Oは専用actor、写真の読込み・解析はバックグラウンド処理を使う。`PNViewUpdates`は画面への通知を100msごとに集約し、セッション終了時に保留中の更新を破棄する。受信チャンクごとの画面更新と次要求の探索を避け、写真の暗号化保存完了時に進める。同一ソースの設定再適用では索引を再走査せず、取得済み写真の再通知でも原データを復号し直さない。実際の転送・表示・背景生成で破損や消失を検出した写真は取得済み一覧から外し、再取得の対象へ戻す。

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

写真・共有設定の保存はAES-256-GCM。WindowsはDPAPI、Mac build 11はユーザーの明示選択により、sandbox内の所有者のみ読書きできる専用ファイルで端末の鍵とIDを保持する。Macの鍵ファイル自体は平文であり、同じユーザー権限の別プロセスに対する保護はKeychainより弱い。TLS identityは`SecIdentityCreate`でメモリ上に組み立て、Keychainへ登録しない。信頼情報の書込みに失敗した場合も、メモリ上だけで登録済み扱いにしない。保存鍵は他ピアへ送らない。写真キャッシュの途中の`.tmp`も暗号文。完了時に原データのSHA-256、ヘッダー、チャンク認証と順序を確認してから公開する。改ざんや不完全なデータを再生へ渡さない。画像・顔・元の名前はログに出さない。

Mac build 11は起動・権限確認・オンライン化・信頼情報保存・旧版からの切替でKeychainへアクセスしない。`PNFileSecrets`が0700の専用ディレクトリと0600の秘密ファイルを使い、リンク・別所有者・不正な権限を拒否する。旧通信データがあるのに新方式の鍵がない場合はオンライン化を保留し、ネットワーク設定の「新しい通信設定を作成」を明示的に選んだ後に別領域で開始する。旧Keychainと旧通信データは読み出し・削除・上書きしない。新方式の鍵が破損・消失した場合も別identityを自動生成しない。[Macの保存仕様](../macos/docs/LOCAL-NETWORK-STORAGE.md)と[権限取得フロー](../macos/docs/PERMISSIONS.md)を参照。

## 同期表示・切断

表示モードの抽選は`ModeSelection`で、ギャラリー（静止・スクロール）80／パン・ズーム（縦・横・拡大縮小）20の2系統を先に選び、その系統の適性を満たす有効モードを均等に選ぶ。同じGalleryの再当選はスキップし、パン・ズームの3連続回避は系統内で行う。候補不足時は利用可能な系統へ配分する。Swiftの同名部品を単画面・グループ・ネットワーク進行役から利用する。

共有契約の`galleryWeight`はギャラリー系、`panWeight`はパン・ズーム系を表す。旧`zoomWeight`は読込み互換用に残し、保存時は0とする。旧初期値45／35／20は80／20へ移行し、それ以外の旧設定はPanとZoomを合算する。ネイティブUIは2項目で編集し、部品内でも旧既定値を解決するため、旧共有状態を受信しても新しい系統の割合で抽選する。同じウォールの両OSはこの新規則を実装した版に揃える。

表示の最優先要件は視覚的・知覚的な自然さ。出力ウィンドウは画面の表示先を所有し、表示計画は写真・動き・背景だけを所有する。計画の先読みではウィンドウを生成しない。通常のモード切り替えと切断・再接続・単体再生への移行では表示先を維持し、次の表示が準備できるまで直前の有効な表示を残す。明示的な停止・物理的な画面構成の変更・OSによる表示面破棄を除き、計画更新からウィンドウを閉じない。この規則は[共通設計原則](CROSS-PLATFORM-WALL-PLAN.md#最優先の設計原則視覚知覚の自然さ)に従う。

共通再生設定の`galleryMax`は1〜20枚（初期値5枚）。Windows・Macの設定正規化と共有契約も同じ範囲とする。静止Galleryの実枚数は共通キャンバスの縦横比と利用可能な写真数に応じて決まり、設定値を上限とする。

既存の抽選・モード判定・Gallery配置・顔配置・Motionの計算をOS側の計画アダプターから呼ぶ。進行役だけが具体的な写真、始点・終点、拡大率、継続時間、クリップ、画面別指定を決め、縮小背景の先読みサンプルも送る。5モードと画面単位／スパンを扱う。

横Pan・縦Pan・Zoomの写真は、グループ長辺方向の画素数が長辺の半分未満なら同じ写真を各画面へミラーする。横長（正方形を含む）は向き補正後の横画素数、縦長は縦画素数を比較し、半分ちょうどはスパンを保つ。全接続画面で既存のモード適性を満たす必要があり、パンの許容倍率を超えた写真を強制的にスパンしない。表示計画の既存の画面別指定で転送するため、追加のプロトコル項目は不要。

全5モードの背景生成は、透明な余白を写真色で埋めてから端色をクランプしてぼかす。ローカル背景とネットワーク背景で同じ処理を使い、暗幕は約18%へ統一する。装飾グラデーションを除去し、画面端の人工的な黒帯を防ぐ。

Windowsの`AmbientPixels.EnhanceColors`は背景の色差を最大1.6倍、輝度を最大1.12倍へ補う。RGB範囲の余裕で補正量を抑え、無彩色・色相・アルファを保つ。ローカルはぼかし後・時間補間前、同期表示は`SharedSceneBuilder`による受信PNGのデコード時に一度だけ処理する。提供元や進行役がMacでもWindowsで補正が効き、送受信の二重補正を避ける。Swiftの`AmbientColors`も同じ補正を実装し、ローカルは`AmbientProcessor`のぼかし後・時間補間前、同期表示は受信PNGデコード後に一度だけ適用する。Macの進行役が作る転送PNGは未補正で、送受信で二重補正しない。両OSの本体コードを共通fixture12ケースで照合する。

各表示部が画像をデコードしてReadyを返した後、2秒先の共通時刻でCommitする。描画は`sharedNow - startAt - pausedDuration`から位置を評価し、メッセージ到着を開始の起点にしない。遅れたフレームも同じ時刻の位置へ追従する。時計はOS時刻が一致する前提を維持し、4時刻の往復計測で小さな補正を滑らかに反映する。物理的な画面の提示差・フレーム同期精度は実機で測定する。

heartbeatは1秒、無応答6秒で切断、登録済み接続の再試行は5秒間隔。切断／再接続はOS通知へ渡す。残存ピアは同期を続け、孤立側は最後の表示計画を60秒繰り返し、その後ローカルキャッシュによる単体計画へ移る。再試行は続け、準備後の予約Commitで同期へ戻る。ユーザーのpause／停止を接続復旧だけで解除しない。

配置ドラフトはドラッグと数値で編集できる。格子・円・斜線のテスト表示は別の出力経路で予約し、設定の保存や写真の再生時計・pause／停止を変更しない。

## 実施した検証

- OS非依存ネットワーク・配置: 25ケース、224 assertions成功。実際の相互TLS loopback、3ピアの別端末設定・原寸転送・進行役離脱・60秒フォールバック・再接続、2壁から4ピアへの合流とpause引継ぎ、revision競合と再送、予約テスト表示、暗号化・期限・容量制限、ディスプレイ名の転送・旧データからの名前補完、15パターンの配置スナップ、保存済み画面と現接続の区別を含む。追加の応答性テストではI/Oを止めた状態での進捗取得、通知の集中、再接続時のキャッシュ再利用、UI同期コンテキストを引き継がない開始・設定反映を確認した。
- Windows: 既存20ケースと新規2ケース成功。5モード×スパン／画面単位の計画・背景・時刻評価・切出し、DPAPIの隔離保存を確認。WPFの切出し画像は最大2/255の端の丸め差を許容し、平均画素差も制限した。
- Windowsの設定画面全8ページを1040／920pxで描画して確認。ネットワークページの追加後も既存ページの順番を維持する。
- 応答性修正ではウィンドウを開かず、Windows部品3ケース（10万件の通知より入力を優先、キャッシュからの顔解析再利用、Gallery20枚）を確認した。結果は`artifacts/windows/network-responsiveness/`。この修正時のGUI撮影・実端末を再接続しながらの手動操作確認は行っていない。
- 低画素写真・背景修正ではWindows部品5ケースが成功。共通の長辺判定8ケース、3モード×横長／縦長グループの同一写真の画面別計画、全5モードの背景の端色を合成データで確認した。結果は`artifacts/windows/mirror-ambient/test-results.json`。GUI撮影は行っていない。Swiftの同じfixtureと部品テストは追加済みで実行未確認。
- 表示の連続性・背景色彩の修正ではWindows部品8ケースが成功。5モード間25通り、旧表示ツリーとビューの保持、遠隔ピア離脱によるキャンバスの縮小と復帰、スパン／画面別表示、Galleryの最終表示保持・孤立時の繰り返し、色差・明るさの補正と無彩色・アルファ保持を確認した。結果は`artifacts/windows/scene-transitions/test-results.json`。テストは合成画像・オブジェクトの状態のみを調べ、ウィンドウの表示・GUI撮影・描画キャプチャを行っていない。実機での切断中の知覚確認は未実施。
- 既存の共通fixtureは704 assertions、OS差分fixtureは472 assertions成功。
- Windows Releaseコンパイル成功。これはWindows側での記録。Swift側は[Mac検証記録](../macos/docs/NETWORK-TEST-RESULTS-2026-10-18.md)へ分ける。

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

`NetworkTransportTests`はメモリ上のidentity再生成、信頼情報の書込み失敗、ネイティブ相互TLSを検証する。`FileSecretsTests`は専用一時領域で鍵・pinの保持、ファイル権限、リンク・破損・消失の拒否、旧データの保持を検証する。Keychain項目を読み書きするテストは廃止した。アプリと同じSwiftコードと.NETモジュールの通信を別プロセスで確認する場合:

```sh
bash macos/scripts/verify-network-interop.sh
bash macos/scripts/verify-network-interop.sh --with-discovery
```

TLSはloopbackだけで実行する。後者は47391番と異なる一時ポートで実際のmulticast相互検出も行う。鍵・ID・信頼情報はメモリ上のみで、通常のKeychain・設定・写真・壁を使わない。ログとバイナリは`artifacts/macos/network-interop/`。実際のWindows OS・別マシンのファイアウォールや3画面の同期精度を確認した結果には含めない。

その後は合成写真フォルダー等を使い、次を確認する。**実行前にMac側のコンパイルエラー・警告を解消し、成功ログを残す。**

1. 両OSでオンラインを有効にし、相互に候補が出る。片側の「接続」で確認画面なしに接続し、証明書と鍵が各OSの保護領域で再利用される。
2. Macのテスト用アルバム／フォルダーを選んで適用する。Windowsへ原寸が届き、顔データも一致する。JPEG／PNG／WebPに加え、手元のHEICのデコード可否を確認する。
3. 両OSのいずれからでも全画面の所属と座標を編集でき、格子の境界が実画面でつながる。モード5種類、画面単位、pause／再開／Next／停止を確認する。
4. 進行役を終了し、残存側の同期継続・自動交代を確認する。孤立側は60秒後に単体動作となり、再接続で予約時刻の同期へ戻る。通知の重複、pause／停止の解除がないことも確認する。
5. 写真ソースの再適用と解除、容量上限、スリープ復帰、再起動、長い取込み中の設定変更、ネットワークの再断を確認する。

Macの自動検証と両OS間の提示時刻差・長時間運転は区別する。実機間の結果が揃うまで、ネットワーク機能を検証済み完成物として配布しない。既存の公開済みMacリリースの更新・公開は今回に含めない。

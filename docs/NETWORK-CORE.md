# ネットワーク基盤の実装 — 第1段階

2026-10-18。[基本設計](NETWORK-PEER-DESIGN.md)を `fd8cbc8` で確定し、Windows側のOS非依存Coreに最初の基盤を実装した。アプリのオンライン待受・実際のLAN通信はまだ接続していない。

## 今回の実装範囲

| 実装 | 内容 |
|---|---|
| [PeerContracts.cs](../windows/src/DynamicPhotoWall.Core/Networking/PeerContracts.cs) | ピア・画面・共有グループ・原寸写真・顔メタデータ・キャッシュ世代と期限のデータ契約、受信データの検証 |
| [GroupTimeline.cs](../windows/src/DynamicPhotoWall.Core/Networking/GroupTimeline.cs) | 共通時刻からグループ再生位置を評価、予約されたpause／resume／Next、要求再送の重複排除 |
| [PeerPlaybackRecovery.cs](../windows/src/DynamicPhotoWall.Core/Networking/PeerPlaybackRecovery.cs) | 残存側の同期継続、孤立側の60秒繰返し→単体再生、接続復旧と予定時刻での同期復帰を分離 |
| [EncryptedPhotoCache.cs](../windows/src/DynamicPhotoWall.Core/Networking/EncryptedPhotoCache.cs) | 原データと顔メタデータの暗号化保存、世代切替、14日期限、改ざん・誤った鍵・すり替えの拒否 |

描画・写真抽選・OSの通常設定は変更していない。Coreの状態とデータを既存の表示・キャッシュ・通知へ接続する入口を用意した段階で、顔検出の呼出しや写真ソースの走査も既存アプリへは組み込んでいない。後任の自動選出は必須要件だが、選出プロトコルはこの実装に含めない。

## データ契約と共有fixture

JSONはcamelCase、列挙値は文字列、IDはUUID、画像IDは小文字のSHA-256とする。時刻は、再生時計では共通時刻軸の秒数、キャッシュではUTC日時を使う。未知のメンバー・数値の列挙値を拒否し、デシリアライズ後に各DTOの`Validate()`を呼ぶ。通信メッセージの包み・認証・サイズ制限はトランスポート層で別途実装する。

画面は`(peerId, displayId)`で区別し、同じOS画面名でも別ピアなら別画面とする。共通グループはUUID、単独画面の`groupId`はnull。`PeerGroupLayout`は選択された同一グループの画面だけを既存の`WallLayout`へ渡す。接続中か否かによる保存領域の除去は行わない。

写真は`providerId`・`sourceId`・`generationId`・`imageId`で区別する。顔メタデータは向き補正後の画素数・左上原点の正規化顔矩形・検出器と版を持つ。`pending`・`complete`・`failed`を区別し、未解析は計画作成に利用しない。`complete`で顔0件と、解析失敗時の顔なし動作は利用できる。原寸画像との画素数の一致を検証する。

[PeerProtocol.v1.json](../tests/Fixtures/PeerProtocol.v1.json)はMac／Windowsで今後共有する入出力fixture。ピアをまたぐ2画面＋同一ピアの単独画面、原寸6000×4000の写真と顔矩形、pause／resume／Nextを含む再生位置の期待値を手で定義している。今回はC#側で実行済み。Swift側のDTO・fixture読取り・実機検証は今後追加する。

## 時計と切断状態の使い方

`GroupTimeline`へ共通時刻のanchorと確定順の操作を事前登録し、描画時に`PositionAt(sharedNow)`を評価する。受信時刻はAPIへ渡さない。Nextは、予約時刻に適用する新しい再生位置として表現する。既存の定速移動・イージング・顔停止後の保持を含む実際の描画への接続は次段階。

`PeerPlaybackRecovery`は、時計・ソケット・UIを所有しない状態機械。`SetOnline`だけでは接続を試みず、利用者が候補を選択したとき・受信側が接続を受け入れたとき・登録済みピアを再接続するときに`BeginConnection`を呼ぶ。トランスポートが接続したら`ConnectionRestored`、必要なデータを準備したら`PrepareSynchronization`、予約時刻に達したら`Tick`で同期へ戻る。

切断時、呼出し側が接続群の状況を確認し、`ConnectionLost(..., canContinueWithOtherPeers)`へ同期継続の可否を渡す。継続できる側は同期状態を保ち、孤立側は60秒でスタンドアロンへ移る。生存確認・接続群の形成・選出はこのクラスに実装していない。再接続中の揺れで期限はリセットしない。

状態機械の`elapsed`は、スリープを含む実経過秒を単調に渡す契約。`sharedNow`は同期用の共通時刻で、両者を別に渡す。OSごとの時計アダプターは今後実装する。停止・ユーザーpause・画面遮蔽は描画側で管理し、この状態機械はそれらを解除しない。戻り値の接続通知をOS通知へ渡す処理も未実装。

## 暗号化キャッシュの形式と境界

保存鍵は呼出し側から256bitで供給し、このクラスは鍵ファイルを作らない。DPAPI／Keychainの鍵保護は未実装なので、アプリの実写真キャッシュへ接続する前に必ず実装する。テストは合成データとプロセス内で生成した一時鍵だけを使用する。

写真本体のストリームを64KiBずつ暗号化し、画像を縮小・再圧縮しない。メタデータも暗号化する。各ファイルに32byteの乱数saltを生成し、HKDF-SHA256で保存鍵からファイル固有のAES-256-GCM鍵を導出する。ブロック0をメタデータ、1以降を画像チャンクとし、ファイル固有鍵の下でブロック番号をnonceに対応させる。

```text
magic:       ASCII "DPWCAC01" (8 bytes)
salt:        32 random bytes
block 0:     encrypted PhotoCacheHeader JSON
block 1..N:  encrypted original image chunks, at most 65,536 bytes each

each block:  int32 little-endian ciphertext length | ciphertext | 16-byte GCM tag
file key:    HKDF-SHA256(master key, salt, info="DynamicPhotoWall/photo-cache/v1", length=32)
nonce:       four zero bytes | uint64 big-endian block number
AAD:         UTF-8 invariant "DPWCAC01:{opaqueId}:{blockNumber}:{plaintextLength}"
opaqueId:    lowercase SHA-256 of UTF-8 "{provider:N}:{source:N}:{generation:N}:{imageId}"
```

画像ID・ソース・世代とブロック順を認証へ結び付ける。読取りではメタデータの版と長さを検証し、全画像チャンクの認証とSHA-256照合を終えてから呼出し側へ返す。切詰め・末尾追加・チャンク並替え・別ソースへのファイルすり替えを拒否する。保存形式はネットワーク転送形式とは別で、端末の保存鍵を他ピアへ送らない。

ファイルは`providerId/generationId/opaqueId.pwc`に保存する。書込み中のファイルも暗号化済み`.tmp`とし、検証が完了してから同じディレクトリ内で置換する。キャンセル・検証失敗時は一時ファイルを削除する。パスに元の写真名・アルバム名を使わない。

`ActivateGeneration`は、共有設定の確定処理が選んだ世代を呼出し側から渡す。新世代への切替時はその提供ピアの旧世代ファイルだけを削除し、その後の旧ジョブの書込みを拒否する。別ピアの同一写真は保持する。同じ世代での再起動・通信再開ではキャッシュを再利用する。世代の設定バージョン検証・永続化・転送ジョブ制御は今後追加する。

`Put`の`cachedAt`は呼出し側が指定する検証済みデータの生成日時で、有効期限はその14日後。`Read`はアクセスで期限を延長せず、期限切れを削除・利用不可にする。定期削除・期限前更新ジョブは今後実装する。Core内の操作は直列化しており、呼出し側がバックグラウンド処理へ載せる。複数プロセスから同じ保存領域へ書き込むAPIではない。

現在の読取りAPIは原データをbyte配列で返し、1画像の上限は既定256MiB（コンストラクターで変更可能）。ディスク全体の予算・並列転送数・デコード時のメモリ予算はアプリ側で別途管理する。上限超過時に縮小して保存する代替処理は行わない。

## 検証と再現

リポジトリ直下から、アプリを起動せずに実行できる。

```powershell
.\.tools\dotnet\dotnet.exe run --project tests/NetworkCore.Tests/NetworkCore.Tests.csproj -c Release -- artifacts/windows/network-core
```

MacでC#側を確認する場合はインストール済み.NET 10で次を実行する。Swift実装の試験とは別。

```sh
dotnet run --project tests/NetworkCore.Tests/NetworkCore.Tests.csproj -c Release -- artifacts/macos/network-core
```

Windowsの`Build.ps1 -Test`／`-DesktopTest`にもこの基盤テストを追加した。通常設定や個人写真は参照せず、結果JSONと合成データの暗号化ファイルを指定のartifactディレクトリだけへ出す。

2026-10-18のWindows検証:

- 基盤10項目・85 assertions成功。グループ統合、顔データ、時刻評価、60秒境界、オンライン待受と接続開始の区別、暗号化・再起動・期限・世代更新・不正データ・中断を確認。
- WPFアプリ＋既存テストのReleaseビルド成功、既存20項目成功。NuGet脆弱性情報はネットワーク制限により取得できずNU1900の警告あり。
- 既存のC#／Swift共通fixtureはC#側で704 assertions成功。旧モーション・Gallery・写真選択の期待値を維持。
- Macアプリ・Swift・実際のLAN・OS鍵保護・OS通知・自動選出・設定UIへの接続は未検証／未実装。完成したネットワーク機能としてはまだ利用できない。

次は、保護された端末鍵とピアIDの保存、オンライン待受・自動検出・暗号化トランスポート、確定済み設定とキャッシュ世代の管理、Swiftの同じデータ契約とfixture、自動選出・状態複製、既存の表示部と写真ソースへの接続の順で進める。

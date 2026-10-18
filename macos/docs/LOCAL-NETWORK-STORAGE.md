# MacのKeychainを使わない通信データ保存

2026-10-19、ユーザーが確認ダイアログを出さない方式を選択したため、1.1.0 build 11でKeychainアダプターと対話許可の経路を削除した。鍵と信頼情報の重複した読取り・書込みを減らすだけではなく、通常処理からKeychain APIへの呼出しをなくす。旧Keychain項目の自動移行・削除・ACL変更は行わない。

## 保存と保護の範囲

sandbox内のApplication Support `DynamicPhotoWall/network/local-v2/`を使用する。アプリ本体の置換先や署名hashを保存先の識別子へ含めない。同じアプリのデータ領域が保たれる更新では同じ端末ID・TLS証明書・暗号鍵・信頼情報を読む。

- `credentials/identity-v1`: 端末ID、TLS秘密鍵・証明書、写真・共有設定の暗号鍵。
- `credentials/trusted-peers-v1`: 認証済みの相手の証明書指紋。
- `cache/`: 既存と同じAES-256-GCMの暗号化写真。
- `wall.encrypted`: AES-256-GCMの共有設定。

`PNFileSecrets`は専用ディレクトリを0700、各秘密ファイルを0600で作る。ディレクトリをバックアップ除外に指定し、秘密ファイルへ予期しない名前、シンボリックリンク、ハードリンク、別所有者、広いPOSIX権限があれば読まない。小さな一時ファイルも最初から0600で作り、書込み・同期後に公開する。端末identityの既存ファイルを置き換える書込みは禁止し、信頼情報は同じディレクトリ内で原子的に更新する。読取り上限は2MiB。壊れた鍵や保存失敗で別鍵へ黙って切り替えない。

秘密ファイル自体は平文のJSON（バイナリ値はbase64）であり、保護の根拠はアプリのsandboxとファイル権限。ファイルを読める同一ユーザー権限の別プロセス・管理者等への保護はKeychainと同等ではない。ユーザーがこの差を確認して方式を選んだ。秘密ファイルをソース管理、配布APP・ZIP・DMG、ログ、共有状態へコピーしない。通信の相互TLS・証明書pinと写真・共有設定の暗号化は維持する。WindowsのDPAPIとwire形式は変更しない。

Appleは[App Sandboxからのファイルアクセス](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)でsandboxとは別にPOSIX権限等の制御も適用されることを説明している。[TN3137](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)のData Protection Keychainへの変更とは異なる選択である。

## build 10以前のデータがある場合

旧`network/wall.encrypted`や`network/cache/`があるのに新方式の鍵がない場合、オンライン化を保留し、ネットワーク設定に説明と「新しい通信設定を作成」を表示する。旧Keychainを読まずに旧TLS identity・復号鍵を引き継ぐことはできないため、勝手な移行はしない。

ボタンを選ぶと、新しい領域へ別の端末IDと鍵を作り、オンラインモードはOFFにする。ユーザーがオンライン化して、他の端末と接続し直す。共有する写真ソースと共有側のグループ・配置は再確認が必要。単体用の写真フォルダー・アルバム・表示設定は維持する。旧通信データとKeychain項目は残す。旧データを新しい鍵で開いたり、復号失敗を理由に削除したりしない。

新方式を使用後に鍵だけが消失した場合は、同じ領域の新規鍵生成を禁止して停止する。新しい設定の作成ボタンもこの条件を迂回できない。Keychainの読取り失敗から平文へ自動退避する経路ではなく、明示された保存方針と旧データを区別して扱う。

## 検証

`FileSecretsTests`は専用の一時領域だけを使い、再起動相当の端末ID・鍵・pin保持、0700／0600とバックアップ除外、原子的な信頼情報更新、identity上書き禁止、リンク・権限不正・サイズ超過の拒否、破損・鍵欠落時の停止、旧データが明示操作まで不変であることを検証する。`NetworkAvailabilityTests`は初期化の再利用とI/O失敗時の非接続を確認する。OSのKeychain・通常設定・個人写真は使わず、GUI操作を行わない。

検証結果・ローカル配布物の照合は`artifacts/macos/file-secrets-2026-10-19/`へ出す。実アプリの置換後の操作・実Windows端末との再接続は手動確認として残す。

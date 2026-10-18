# ネットワーク共通fixture

`PeerProtocol.v1.json`はピア・画面・顔・時刻評価の手定義の値。`NetworkWire.v1.json`は合成原データ、公開された試験専用の256bit鍵、C#で生成したDPWCAC01暗号文、共有状態、表示計画、メッセージ、ハッシュの照合値を含む。個人写真・実際の秘密鍵・端末設定は含まない。

C#の`NetworkCore.Tests`とSwiftの`NetworkModuleTests`が読み込む。Swift側の試験はMacで実行する。相互接続とは別に、IDの大文字小文字、UTF-16の画面ID長、JSONの整数とbase64、暗号化ヘッダー／AAD／nonce／チャンクを照合するためのデータである。

`NetworkWire.v1.json`の画面には試験用ディスプレイ名も含め、共有状態・表示計画・メッセージで保持することを照合する。名前のない旧形式の読込みは`PeerProtocol.v1.json`と各OSのテストで確認する。

`DisplaySnapping.v1.json`はGUIを開かずに検証する配置スナップの共通値。上下左右、角、隙間・重なり、異なるサイズ・中央揃え、縮尺に応じた許容距離、負座標、遠い画面の除外、候補順によらない選択をC#とSwiftで照合する。

`MirrorPolicy.v1.json`は低画素写真の自動ミラーの共通値8ケース。グループの長辺方向で向き補正後の写真の画素数が半分未満かを比較する。横長・縦長・正方形、半分ちょうどの除外、短辺方向や写真自身の長辺を判定に使わないことをC#とSwiftで照合する。

再生成が必要な場合はリポジトリ直下で次を実行し、差分を確認してからfixtureだけをコピーする。生成物はartifactsに置く。

```powershell
.\.tools\dotnet\dotnet.exe run --project tests/NetworkCore.Tests -c Release -- --export-fixtures artifacts/windows/network-vectors
Copy-Item artifacts/windows/network-vectors/NetworkWire.v1.json tests/Fixtures/NetworkWire.v1.json
```

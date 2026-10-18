# ネットワーク共通fixture

`PeerProtocol.v1.json`はピア・画面・顔・時刻評価の手定義の値。`NetworkWire.v1.json`は合成原データ、公開された試験専用の256bit鍵、C#で生成したDPWCAC01暗号文、共有状態、表示計画、メッセージ、ハッシュの照合値を含む。個人写真・実際の秘密鍵・端末設定は含まない。

C#の`NetworkCore.Tests`とSwiftの`NetworkModuleTests`が読み込む。Swift側の試験はMacで実行する。相互接続とは別に、IDの大文字小文字、UTF-16の画面ID長、JSONの整数とbase64、暗号化ヘッダー／AAD／nonce／チャンクを照合するためのデータである。

再生成が必要な場合はリポジトリ直下で次を実行し、差分を確認してからfixtureだけをコピーする。生成物はartifactsに置く。

```powershell
.\.tools\dotnet\dotnet.exe run --project tests/NetworkCore.Tests -c Release -- --export-fixtures artifacts/windows/network-vectors
Copy-Item artifacts/windows/network-vectors/NetworkWire.v1.json tests/Fixtures/NetworkWire.v1.json
```

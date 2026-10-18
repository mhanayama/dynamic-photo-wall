# Native Swift / .NET transport probe

Mac上で両方の本番トランスポートを起動し、双方からの接続・相互TLS・helloとlength-prefixed JSONの交換を確認する。Windows実機でSchannelやファイアウォールを検証した結果とは区別する。

```sh
bash macos/scripts/verify-network-interop.sh
bash macos/scripts/verify-network-interop.sh --with-discovery
```

既定ではTLSをloopbackだけへbindする。`--with-discovery`は実アプリの47391番と異なる一時ポートでUDP multicastの相互検出も確認する。このときはローカルネットワークを使う。候補は識別子・合成端末名・ポートのみで、写真は公開しない。広告の検出と接続の検証を分け、TLS接続先はloopbackに限定する。

両側のID・鍵・証明書・信頼情報はメモリのみ。Keychain・通常設定・個人写真・デスクトップ出力は使わない。ネイティブ側はアプリと同じ`PeerContracts.swift`、`PeerStorage.swift`、`PeerTransport.swift`をコンパイルする。

バイナリ・モジュールキャッシュ・各実行のログ・端点JSONは`artifacts/macos/network-interop/`へ出力する。ログには試験用秘密鍵を出さない。

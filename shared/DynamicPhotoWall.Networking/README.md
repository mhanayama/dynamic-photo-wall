# DynamicPhotoWall.Networking

OSのUI・通常再生Coreから独立したネットワークライブラリー。`Session/Ports.cs`で通信、時計、保存、写真提供、計画、出力、通知を注入する。構成とwire契約、ネイティブSwiftの対応部品、検証手順は[NETWORK-CORE.md](../../docs/NETWORK-CORE.md)を参照。

単体・統合試験は`tests/NetworkCore.Tests`で実行する。Win32、WPF、DPAPIはこのプロジェクトへ追加せず、Windowsアプリの`Networking/`アダプターへ置く。Macは同じ契約をSwiftで実装し、`tests/Fixtures/NetworkWire.v1.json`を共用する。

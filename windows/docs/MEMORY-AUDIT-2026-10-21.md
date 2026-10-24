# Issue #5: Windows同期再生のメモリ保持

**追加調査と第2候補:** 手動再起動後の本体を30秒観測し、Working Set約641MiB、Private Bytes約785MiB、GPU平均5.91%を記録。使わないローカルLRU約104MiBと画面外の写真Drawingの保持・更新を次の対象とし、追加修正を確認用EXEへ反映した。[第2候補の実測・修正・検証と制限](MEMORY-GPU-FOLLOWUP-2026-10-21.md)を参照。以下は第1候補の記録。

Windows同期再生で、開始確定済みの過去256件のシーン計画が背景PNGごと残ることを特定し、準備待ちの辞書から開始確定時に取り除く。稼働バイナリのヒープと、実際のprepare/ready/commitを通すCLI回帰テストで確認した。Issue #5全体の完了、通常表示100MB未満の達成、通常アプリでの削減量は未確認。

## 手動確認用のRelease EXE

ユーザーの指示で2026-10-21 08:51 JSTにWindows Releaseの単一EXEを`release/windows/win-x64/DynamicPhotoWall.exe`へ作成した。製品バージョンは`0.1.0+dbdcaed2268ba011ab66716ed338dcf2c0feeaa4`。このベースコミットへ未コミットのメモリ保持修正を加えた候補であることを`BUILD-INFO.txt`にも記録した。GUIなしの発行済み依存読み込み検証が成功。NuGet脆弱性情報を取得できない`NU1900`警告は継続しているが、発行は成功した。

ビルドログ・ソース差分・ソースハッシュ・EXEハッシュ・ルートファイル比較は`artifacts/windows/memory-audit/release-build-20261020-235126/`。旧EXEと旧ZIP・チェックサムはその`previous-release/`へ退避した。今回はEXEの確認依頼のためZIPは新規作成せず、配布先の`SHA256SUMS.txt`は新EXEだけを対象とする。起動スクリプトとショートカットの参照先は従来のまま。旧PID 49728は停止・再起動せず維持した。ユーザーによる終了・新EXE起動後の稼働確認とメモリ効果測定は未実施。以下は候補作成前の調査記録。

## 稼働中アプリの観測条件

- 2026-10-21、WindowsのPID 49728。2026-10-20 19:50:34 JST起動、製品バージョン`0.1.0+799d570180684f9d35bc1abff29a352112403a18`。起動後約13時間の通常再生。
- 保存設定はオンラインON、背景ON、画像キャッシュ256MiB、Gallery最大20枚。Gallery・scroll・縦Pan・横Pan有効、Zoom無効。各観測時の実シーンや接続先の再生状態は固定・取得していない。
- 保存された画面寸法は3840×1100が1台、1920×1080が2台。後者2台が同一グループ。実画面の列挙による配置照合、写真枚数・原画像解像度の全件調査は未実施。
- 設定変更、再起動、GUI操作、配布物の更新は行っていない。ヒープ取得時は診断に伴う停止やページの読み出しがあり得るため、その直後の値を通常再生の性能基準としない。

| 指標 | 観測値 | 意味・制限 |
|---|---:|---|
| 調査開始時Working Set、1回 | 1075.03 MiB | 常駐ページ。Private Bytesとは加算しない |
| 同Private Bytes | 1037.48 MiB | プロセスの専用コミット。画像やWPFのネイティブ領域も含む |
| GC確保領域 | 228.15 MiB | `eeheap -gc`、空き領域を含む |
| GCコミット | 236.61 MiB | 同上、OSへコミット済みのGC領域 |
| GCルートから到達できるmanagedオブジェクト | 192.85 MiB | `dumpheap -live -stat`。ネイティブ画像は含まない |
| ローカル画像LRUの`CachedBytes` | 54.19 MiB | ヒープ内の実フィールド値。表示用画像・描画バッファは別 |
| 過去計画辞書から到達可能なオブジェクト | 154.13 MiB | `objsize`。別の参照との重複を含み、全量が解放できるという値ではない |
| うち`byte[]` | 151.03 MiB | 11,144配列。背景PNG以外の共有参照も含み得る |

ヒープ採取は08:41:12 JST、`artifacts/windows/memory-audit/baseline/process.dmp`。`heap-summary.txt`、`live-heap.txt`、`retained.txt`、`roots.txt`、`history-size.txt`に内訳と参照経路を保存した。ダンプと写真・設定をGitやPRへ添付しない。

ヒープ取得後に既存`Measure-Gpu.ps1`で30サンプル観測した値は、Dedicated平均365.25MiB、Shared平均62.87MiB、Working Set平均1486.04MiB。直前のダンプ取得が常駐量へ影響し得るため補助記録とする。GPUカウンターはPrivate BytesやGC Heapと排他的な分類ではなく、差し引きによるネイティブ／D3D内訳は算出しない。生データは`artifacts/windows/gpu-audit/20261021-084137/`。

ビルド・回帰テスト終了後の08:47:05〜08:47:19 JSTに、同じ旧PIDを新しい`Measure-Memory.ps1`で15サンプル受動観測した。Working Setは全サンプル1185.18MiB、Private Bytes平均1000.49MiB、範囲991.91〜1003.43MiB。これは修正前バイナリの別区間で、修正後との比較ではない。生データは`artifacts/windows/memory-audit/20261020-234705-732-passive/`。ディレクトリ名・CSV時刻はUTC。

## 原因と修正

`PeerSession.knownPlans`は受信した`SharedScenePlan`を最大256件保持する。`sceneCommit`後も`TryGetValue`で参照するだけで削除せず、過去計画の`AmbientFrame.Png`が生存する。ヒープで辞書の有効件数256、`gcroot`で`PeerSession → knownPlans → SharedScenePlan`の参照を確認した。これは件数上限のある不要な履歴保持であり、無制限リークと断定しない。

開始確定時に`Remove(..., out plan)`で辞書から受け取り、従来どおり`SceneCoordinator.Observe`へ渡す。現在計画と描画側の保持は維持する。設定やwall更新で計画を無効化するときにも準備待ち辞書を空にする。未確定の準備には従来の256件上限を残す。通信形式、共有開始時刻、画像デコード、描画品質、キャッシュ既定値は変更しない。

`SceneRetentionTests`は、偽の通信路を使いながら本物のJSON受信ハンドラー・画像準備・ready・commitを300回通す。描画側が手放したPNGをweak referenceで追跡し、GC後に過去299件へ参照が残るか調べる。全301回の準備へ64KiBの元のpayloadが届くこと、全300件のcommit ID・group・開始時刻が変わらないことも確認する。

| 同じCLI条件 | 表示終了したPNGの生存数 / 299件 |
|---|---:|
| 修正前 | 256 |
| 修正後 | 0 |

GCはテストプロセス内だけで実行する。合成payloadの解放を通常アプリのメモリ削減率へ換算しない。修正前結果は`before-tests2.log`、修正後は`verified-network.log`。Windows Releaseビルド成功（コンパイルエラー0、NuGet脆弱性情報を取得できない`NU1900`警告2件）。ネットワーク27ケース・既存241 assertionsと新しい保持回帰が成功。WindowsのGUIなし回帰7件も成功し、共有描画680出力の最大色差2/255、Gallery仮想2時間の継続、シーン交代・出力保持を確認した。証明書の読み込みが制限環境で失敗したネットワーク試験は通常権限で再実行して成功した。

## 再現・検証手順

```powershell
# 既存アプリを観測するだけ。PIDはGet-Process DynamicPhotoWallで確認。
.\windows\scripts\Measure-Memory.ps1 -TargetProcessId 49728 -Samples 180

# GUI操作なしの回帰。出力を明示する。
.\.tools\dotnet\dotnet.exe run --project tests/NetworkCore.Tests/NetworkCore.Tests.csproj -c Release -- artifacts/windows/memory-audit/network
.\.tools\dotnet\dotnet.exe build windows/tests/DynamicPhotoWall.Tests/DynamicPhotoWall.Tests.csproj -c Release
.\.tools\dotnet\dotnet.exe windows/tests/DynamicPhotoWall.Tests/bin/Release/net10.0-windows10.0.19041.0/DynamicPhotoWall.Tests.dll artifacts/windows/memory-audit/windows --scan-only --shared-rendering --gallery-continuation --scene-transitions
```

ヒープを再調査する場合は、既存の`.tools/diagnostics/dotnet-dump.exe collect --process-id <PID> --type Heap --output artifacts/windows/memory-audit/<区間>/process.dmp`を使う。単一EXEの解析では対応するランタイムの`setclrpath C:\dev\photowall\.tools\dotnet\shared\Microsoft.NETCore.App\10.0.12`を指定してから`eeheap -gc`、`dumpheap -live -stat`、`gcroot`、`objsize`を実行する。別バージョンを測るときは対応するDACを使う。

## 残る調査

- 稼働版へ反映後の同条件A/B。起動直後・静止Gallery・交換中・フォルダー変更後・複数画面・数時間後を分け、同じ写真、設定、画面、接続先、ビルド、起動後時間を記録する。通常再生のWorking Set／Private Bytes、GC、GPU、CPU、滑らかさを別々に比較する。
- WPF/WIC/D3Dのネイティブ領域、表示中と次シーンのデコード済みbitmap、Core Animationに相当する描画面の内訳。このダンプだけでは約1GiB全体の原因は確定していない。
- オンライン切り替え後も残っていたローカルLRU約54MiB、複数解像度variant、表示終了後・停止後のbitmap参照。初期値を下げる判断には再デコードのCPU／画質への影響も必要。
- Windowsの既存入力は「見た目」にある64〜1024MiB・既定256MiB。Issueで求める詳細設定への整理、使用量表示と「再利用キャッシュの上限であり、プロセス全体のメモリ上限ではない」という説明の追加は別作業。オンライン経路ではデコード寸法にも予算が使われ、ローカルLRUだけを表示して総使用量と誤認させない。
- Macは別のSwift実装。今回Macのコード・配布物は変更せず、Physical Footprint測定と同等の保持経路の監査はMac側で実施する。Windowsの100MB未満は確約せず、Issue #5を完了扱いにしない。

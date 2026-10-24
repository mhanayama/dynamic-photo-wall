# 稼働EXEのメモリ領域別解析

## 結果

2026-10-21 16:54〜17:04 JST、ユーザーの詳細モニター依頼により、約7時間以上稼働しているWindows第4候補の本体PID 21116を解析した。大部分を.NETの生存オブジェクトが占めている状態ではない。Windowsのネイティブヒープと、それ以外の私有領域が大きい。画像・描画処理が今後の調査対象だが、各ネイティブ領域の割り当て元関数までは確定していない。

ユーザーが安定動作を報告したEXE・設定・再生状態を維持した。製品コードの追加変更、EXEの置き換え、アプリの終了・再起動、強制GC、GUI操作テストは行っていない。

## 通常運転の観測

侵襲的な解析の前に30秒、1秒間隔で記録した。

| 指標 | 平均 | 最小〜最大 |
|---|---:|---:|
| Working Set | 548.27MiB | 516.03〜550.97MiB |
| Private Bytes | 1,096.06MiB | 1,071.50〜1,106.02MiB |

Working Setは物理メモリ上のページを含む指標、Private Bytesはプロセスの私有commitの指標であり、合算しない。タスクマネージャーの既定の「メモリ」列とWorking Setを同一とは扱わない。この30秒は、起動からの7時間全体の連続記録ではない。

## Windows領域別の内訳

署名がValidでMicrosoft CorporationのVMMap 64bitを公式配布から取得し、`-p 21116 <output.xml>`で既存プロセスの領域を保存した。新規プロセスの起動トレース機能は使用しない。XMLのFILETIMEから、第1回は17:00:46 JST、第2回は17:04:24 JSTの観測と確認した。

XMLの最上位Regionだけを集計し、子Regionの二重計上を避けた。Working SetはPrivateWS + ShareableWS。SharedWSはShareableWSの内数なので加算しない。以下は2回の観測範囲。

| VMMap分類 | 物理メモリ上の量 | commit／マッピングされた領域 |
|---|---:|---:|
| Private Data（GC領域なども含む、割り当て元未分類の私有領域） | 209.73〜228.27MiB | 717.80〜789.69MiB |
| Heap (Private Data)（Windowsネイティブヒープ） | 143.26〜154.32MiB | 264.07〜274.86MiB |
| Image／Image (ASLR)（DLL・EXE） | 約105.08MiB | 約306.87MiB |
| Shareable（共有可能なマッピング） | 約48.71〜48.72MiB | 約176.20MiB |
| Mapped File | 約2.46MiB | 約78.60MiB |
| Thread Stack | 約0.17〜0.21MiB | 約0.71〜0.76MiB |

ImageやMapped Fileのマッピング量をPrivate Bytesへ加算しない。Heapのcommitも生存している個別データの合計ではなく、空きブロックや再利用のため保持する容量を含み得る。Private DataをすべてWPF、画像、GPUドライバーのいずれかに割り当てたとは言えない。

独自の読み取り専用Windows API計測も行った。`VirtualQueryEx`でcommit済み領域を列挙し、`QueryWorkingSetEx`でページのresident／shareable情報を取得。DLLなどのファイル名は`GetMappedFileName`で照合した。領域走査は逐次処理であり、VMMapや後続のPSS取得と同時刻の原子的な観測ではない。

## .NETと画像をさらに分解

ClrMDの`DataTarget.CreateSnapshotAndAttach`でPSSクローンを作り、CLRのDACからGCセグメントとオブジェクトを読んだ。全メモリダンプのディスク保存や、強制GCは行っていない。

| PSS取得時刻（JST） | 強い参照から到達するmanagedデータ | GCセグメントのcommit範囲 | GC領域の非Freeオブジェクト総量 |
|---|---:|---:|---:|
| 16:57:35 | 11.66MiB | 31.50MiB | 19.43MiB |
| 16:58:16 | 8.55MiB | 30.23MiB | 20.17MiB |
| 17:02:26 | 8.52MiB | 51.25MiB | 43.49MiB |

強い参照の走査は保守的な根とdependent handleを含む。非Freeオブジェクトの総量は、既に不要だが次のGC待ちのオブジェクトを含む。GCセグメントのcommit範囲はデータを入れる容量であり、生存データ量ではない。GCのFree Regionや管理用領域は、この表の生存オブジェクトとは別。CLRのネイティブヒープ範囲も取得したが、予約範囲をそのままcommit量として合算しない。

第1回はGC情報保存後に診断コードの未分類領域処理でNullReferenceとなったため、画像と領域照合には使用しない。診断コードを修正し、第2・3回は最後まで成功した。対象アプリの例外ではない。クローンは`using`で破棄する。

第2・3回で確認した画像とアプリの保持状態:

- デコード済み画像のWPF native memory pressure推定は89.86／90.91MiB。第2回の2つの再生シーンは画像辞書12枚と17枚で、寸法からのRGBA換算は合計約88.89MiB。先読みや表示終了済みを含む計画単位の保持であり、画面に見える枚数ではない。
- これはWPFオブジェクトに記録された割り当て推定値であり、Windows領域別表とは独立の加算項目ではない。ネイティブCOM内部の全コピー、GPU転送面、ページのresident量を排他的に数えた値ではない。
- ローカル再生用`ImageCache.bytes`は0、`BitmapImage.StreamSource`からの入力配列保持も0 bytes。今回追加したwrapperの内部streamもたどって確認した。
- 強い参照から到達する`SharedVisual`と`SharedScenePlan`は各2件。過去256計画を保持する状態には戻っていなかった。

これらから、既存修正の解放対象はなくなっている一方、それ以外のネイティブ領域の大きさがプロセス全体を支配していると判断する。生存managedヒープ約9MiBをさらに削るだけでは、約500MiBのWorking Set全体を大幅に下げる見込みは小さい。

## GPUメモリの別観測

16:58:21から5サンプルの`GPU Process Memory(pid_21116_*)`カウンターは、Dedicated Usage平均678.39MiB、Shared Usage平均134.59MiBだった。プロセスが持つGPUリソースのカウンターであり、CPU側のWorking Set、WPFのnative pressure、Windowsの共有領域と合算しない。実際のGPU物理常駐や一意に保持する画像数、リークをこの数字だけで断定しない。

## 分かった範囲と残件

確定できたのは、Windowsの領域別サイズ、GCの容量と生存オブジェクト、管理側から見える画像保持、既存の解放対象が0であることまで。WPF・WIC・Skia・D3D9・AMDドライバーなどのDLLがロードされているが、ロード有無や領域サイズだけでは、そのモジュールが確保したネイティブメモリの量は決まらない。

割り当て元の関数と解放を追うには、ネイティブ割り当てのスタック付き記録が必要。既に存在する割り当ての呼び出し履歴を、このスナップショットから遡って復元することはしていない。次の調査対象は画像デコード・描画資源のネイティブ割り当てとその再利用／解放であり、今回の計測を根拠に製品の追加修正やリーク判定は行わない。

PSSやVMMapはページ読み出しや一時的な共有状態に影響するため、取得後のWorking SetやPrivateWSを、冒頭の通常運転値と同条件の性能比較には使わない。約10分の調査も、7時間全体で増え続けた証明にはならない。

## 証跡と参照

通常観測は`artifacts/windows/memory-audit/20261021-075440-819-passive/`。領域XML、PSS集計JSON、GPUカウンター、独自診断コードは`artifacts/windows/memory-audit/20261021-075439-detailed/`へ保存した。生データはパス等を含むためローカルのGit対象外に保管し、外部へ送信しない。EXEと本体PID 21116、補助PID 13936は維持した。

- [Microsoft Sysinternals VMMap](https://learn.microsoft.com/en-us/sysinternals/downloads/vmmap)
- [VirtualQueryEx](https://learn.microsoft.com/en-us/windows/win32/api/memoryapi/nf-memoryapi-virtualqueryex)
- [QueryWorkingSetEx](https://learn.microsoft.com/en-us/windows/win32/api/psapi/nf-psapi-queryworkingsetex)
- [Working Setのページ属性](https://learn.microsoft.com/en-us/windows/win32/api/psapi/ns-psapi-psapi_working_set_ex_block)

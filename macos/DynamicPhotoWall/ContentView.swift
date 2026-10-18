import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            AppHeaderView(isPlaying: model.isPlaying, stateLabel: model.playbackStateLabel)

            TabView {
                DisplaySettingsView(model: model)
                    .tabItem { Label("一般", systemImage: "display") }

                Group {
                    if let network = model.network, network.online { NetworkDisplaySettingsView(network: network, layout: false) }
                    else { UsedDisplaysView(model: model) }
                }
                    .tabItem { Label("使用ディスプレイ", systemImage: "display.2") }
                Group {
                    if let network = model.network, network.online { NetworkDisplaySettingsView(network: network) }
                    else { DisplayGroupingView(model: model) }
                }
                    .tabItem { Label("画面グルーピング", systemImage: "rectangle.3.group") }

                PhotoSettingsView(model: model)
                    .tabItem { Label("写真", systemImage: "photo.on.rectangle") }

                CompositionSettingsView(settings: $model.settings)
                    .tabItem { Label("表示モード", systemImage: "rectangle.3.group") }

                MotionSettingsView(settings: $model.settings)
                    .tabItem { Label("動き", systemImage: "waveform.path") }

                AppearanceSettingsView(settings: $model.settings)
                    .tabItem { Label("見た目", systemImage: "paintpalette") }
                if let network = model.network {
                    NetworkSettingsView(network: network).tabItem { Label("ネットワーク", systemImage: "network") }
                }
            }

            .tabViewStyle(.grouped)

            if let warning = model.settingsWarning { Text(warning).foregroundStyle(.orange) }
            StatusAndSaveView(model: model)
        }
        .padding(24)
        .frame(minWidth: 900, idealWidth: 1040, minHeight: 680, idealHeight: 800)
        .onChange(of: model.settings) { _, _ in model.network?.optionsEdited(model.settings) }
    }
}

private struct AppHeaderView: View {
    let isPlaying: Bool
    let stateLabel: String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Dynamic Photo Wall")
                    .font(.largeTitle)
                    .fontWeight(.semibold)
                Text("いつものデスクトップを、静かなフォトギャラリーに。")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label(stateLabel, systemImage: isPlaying ? "play.circle.fill" : "stop.circle")
                .foregroundStyle(isPlaying ? .green : .secondary)
        }
    }
}

private struct DisplaySettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("起動") {
                Toggle("ログイン時にアプリを起動", isOn: $model.settings.autoStart)
                Text(model.loginItemStatus).foregroundStyle(.secondary)
                Button("システム設定のログイン項目を開く", action: LoginItemService.openSettings)
                Toggle("アプリ起動時にスライドショーを開始", isOn: $model.settings.startOnLaunch)
            }

            Section("再生操作") {
                HStack {
                    Button(model.userPaused ? "再開" : "一時停止", action: model.togglePause)
                        .disabled(!model.isPlaying)
                    Button("次の構成", action: model.showNextScene)
                        .disabled(!model.canAdvance)
                    if model.isWaiting {
                        Button("再検索して再試行", action: model.retryPlayback)
                            .disabled(model.isScanning)
                    }
                }
                Text("設定画面を閉じても再生は続きます。終了はメニューバーのメニューから操作できます。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct PhotoSettingsView: View {
    @Bindable var model: AppModel
    @State private var selectedFolderIDs: Set<UUID> = []
    @State private var showingAlbums = false

    var body: some View {
        Form {
            Section("写真フォルダー") {
                List(selection: $selectedFolderIDs) {
                    ForEach(model.folders) { folder in
                        HStack {
                            Label(folder.path ?? "未解決の登録フォルダー", systemImage: folder.isAccessible ? "folder" : "exclamationmark.triangle")
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(folder.isAccessible ? Color.primary : Color.orange)
                            Spacer()
                            Button(role: .destructive) { model.removeFolders(ids: [folder.id]) } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("このフォルダーを解除")
                            .accessibilityLabel("フォルダーを削除: \(folder.path ?? "未解決の登録フォルダー")")
                            .accessibilityIdentifier("remove-folder-\(folder.id)")
                        }
                        .tag(folder.id)
                    }
                    .onDelete(perform: model.removeFolders)
                }
                .frame(minHeight: 180)
                .onChange(of: model.folders.map(\.id)) { _, ids in
                    selectedFolderIDs.formIntersection(ids)
                }

                HStack {
                    Button("フォルダーを追加／再許可", systemImage: "plus", action: model.chooseFolder)
                    Button("選択を削除", systemImage: "minus") {
                        model.removeFolders(ids: selectedFolderIDs)
                        selectedFolderIDs.removeAll()
                    }
                    .disabled(selectedFolderIDs.isEmpty)
                    Button("再検索／アクセス再試行", systemImage: "arrow.clockwise", action: model.retryFolders)
                }
                if let warning = model.folderWarning { Text(warning).foregroundStyle(.orange) }
                if model.needsFolderRecovery {
                    Button("壊れた登録情報を退避して再登録", action: model.recoverFolders)
                }

                Toggle("サブフォルダーも検索", isOn: $model.settings.recursive)

                Text("JPEG / PNG / WebP / HEIC / HEIF対応。")
                    .foregroundStyle(.secondary)
            }

            Section("写真アプリのアルバム") {
                ForEach(model.photoAlbums) { album in
                    HStack {
                        Label(album.title, systemImage: "photo.stack")
                        Spacer()
                        Button(role: .destructive) { model.removePhotoAlbum(id: album.id) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("アルバムを削除: \(album.title)")
                    }
                }
                HStack {
                    Button("アルバムを追加", systemImage: "plus") { showingAlbums = true }
                    Button("再検索", systemImage: "arrow.clockwise", action: model.rescanPhotoAlbums)
                        .disabled(model.isScanning || model.isScanningAlbums)
                }
                if model.isScanningAlbums {
                    ProgressView("アルバムの写真を検索しています…")
                } else if let count = model.albumPhotoCount, !model.photoAlbums.isEmpty {
                    Text("選択したアルバムの写真: \(count)枚")
                        .foregroundStyle(.secondary)
                }
                if let warning = model.displayPhotoAlbumsWarning { Text(warning).foregroundStyle(.orange) }
                Text("アルバムを追加すると自動で写真を検索します。「保存して適用」で再生を開始します。")
                    .foregroundStyle(.secondary)
                Text("写真アプリのシステム写真ライブラリから選択します。フォルダーと併用できます。iCloud上の写真は表示時にダウンロードします。")
                    .foregroundStyle(.secondary)
            }

            Section("再生する写真") {
                Toggle("ランダムに再生", isOn: $model.settings.randomOrder)

                LabeledContent("再表示を抑制する直近の写真数") {
                    TextField("30", value: $model.settings.recentCount, format: .number)
                        .frame(width: 100)
                }

                Text("画像の表示・顔の解析はMac内で処理されます。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingAlbums) { PhotoAlbumPicker(model: model) }
    }
}

private struct PhotoAlbumPicker: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIDs: Set<String> = []
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("写真アプリのアルバムを追加").font(.title2)
            Text("初回はmacOSで写真へのアクセスを許可してください。選択は「保存して適用」で保存されます。")
                .foregroundStyle(.secondary)
            TextField("アルバム名で検索", text: $query)
            if model.isLoadingAlbums {
                ProgressView("アルバムを読み込んでいます…")
                    .frame(maxWidth: .infinity, minHeight: 240)
            } else {
                List(selection: $selectedIDs) {
                    ForEach(model.availablePhotoAlbums.filter { query.isEmpty || $0.title.localizedStandardContains(query) }) { album in
                        HStack {
                            Label(album.title, systemImage: "photo.stack")
                            Spacer()
                            if model.photoAlbums.contains(where: { $0.id == album.id }) {
                                Text("追加済み").foregroundStyle(.secondary)
                            }
                        }
                        .tag(album.id)
                    }
                }
                .frame(minHeight: 240)
                if model.availablePhotoAlbums.isEmpty && model.photoAlbumsWarning == nil {
                    Text("アルバムがありません。写真アプリでアルバムを作成してから再読み込みしてください。")
                        .foregroundStyle(.secondary)
                }
            }
            if let warning = model.photoAlbumsWarning { Text(warning).foregroundStyle(.orange) }
            HStack {
                Button("再読み込み") { Task { await model.loadPhotoAlbums() } }
                    .disabled(model.isLoadingAlbums)
                Spacer()
                Button("キャンセル", role: .cancel) { dismiss() }
                Button("選択したアルバムを追加") {
                    model.addPhotoAlbums(ids: selectedIDs)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedIDs.isEmpty || model.isLoadingAlbums)
            }
        }
        .padding(24)
        .frame(width: 560)
        .task { await model.loadPhotoAlbums() }
    }
}

private struct CompositionSettingsView: View {
    @Binding var settings: WallSettings

    var body: some View {
        Form {
            Section("表示モード") {
                HStack {
                    Toggle("Gallery — 複数の写真を並べる", isOn: $settings.galleryEnabled)
                    Spacer()
                    Toggle("ディスプレイごとに表示", isOn: $settings.galleryPerDisplay)
                        .accessibilityIdentifier("galleryPerDisplay")
                }
                HStack {
                    Toggle("Scrolling Gallery — 新しい写真が横から流れてくる", isOn: $settings.galleryScrollEnabled)
                    Spacer()
                    Toggle("ディスプレイごとに表示", isOn: $settings.galleryScrollPerDisplay)
                        .accessibilityIdentifier("galleryScrollPerDisplay")
                }
                HStack {
                    Toggle("Vertical Pan — 縦写真を上下に見せる", isOn: $settings.verticalPanEnabled)
                    Spacer()
                    Toggle("ディスプレイごとに表示", isOn: $settings.verticalPanPerDisplay)
                        .accessibilityIdentifier("verticalPanPerDisplay")
                }
                HStack {
                    Toggle("Horizontal Pan — パノラマを左右に見せる", isOn: $settings.horizontalPanEnabled)
                    Spacer()
                    Toggle("ディスプレイごとに表示", isOn: $settings.horizontalPanPerDisplay)
                        .accessibilityIdentifier("horizontalPanPerDisplay")
                }
                HStack {
                    Toggle("Cinematic Zoom — ゆっくり拡大・縮小", isOn: $settings.zoomEnabled)
                    Spacer()
                    Toggle("ディスプレイごとに表示", isOn: $settings.zoomPerDisplay)
                        .accessibilityIdentifier("zoomPerDisplay")
                }
            }

            Section("抽選ウェイト（0で抽選対象から除外）") {
                NumericField(title: "Gallery", value: $settings.galleryWeight)
                NumericField(title: "Pan（縦・横の合計）", value: $settings.panWeight)
                NumericField(title: "Zoom", value: $settings.zoomWeight)
            }

            Section("構成") {
                NumericField(title: "Galleryの最大枚数（1〜20）", value: $settings.galleryMax)
                DoubleField(title: "パンで許容する拡大率（1〜12倍、初期値4倍）", value: $settings.maxPanUpscale)
                DoubleField(title: "縦パンの表示幅（画面幅の割合、0.3〜1.0）", value: $settings.panWidthFraction)
                Toggle("顔が見える位置で縦パンを止める", isOn: $settings.stopAtFace)
                Toggle("全画面表示でも顔が見える位置を優先", isOn: $settings.faceAwareFraming)
                Toggle("スパン時に顔が画面の境目に重ならないよう配置", isOn: $settings.avoidFaceDisplayBoundaries)
                Text("画面より小さい画像もパンできます。粗さが気になる場合は許容拡大率を下げてください。拡大率を超える写真はGalleryで表示します。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct MotionSettingsView: View {
    @Binding var settings: WallSettings

    var body: some View {
        Form {
            Section("ゆったりとしたモーション") {
                Toggle("顔の反対側からパンを開始する", isOn: $settings.faceAwarePanDirection)
                    .accessibilityIdentifier("faceAwarePanDirection")
                DoubleField(title: "パン速度（物理px / 秒、5〜500）", value: $settings.panPixelsPerSecond)
                DoubleField(title: "Scrolling Galleryの速度（px / 秒、5〜200）", value: $settings.galleryScrollPixelsPerSecond)
                DoubleField(title: "ズームの所要時間（秒、10〜600）", value: $settings.zoomSeconds)
                DoubleField(title: "最大ズーム倍率（1.0〜1.15）", value: $settings.maxZoom)
                DoubleField(title: "クロスフェード（秒、0.2〜10）", value: $settings.fadeSeconds)
                DoubleField(title: "Galleryの更新間隔 — 最短（秒）", value: $settings.galleryMinSeconds)
                DoubleField(title: "Galleryの更新間隔 — 最長（秒）", value: $settings.galleryMaxSeconds)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AppearanceSettingsView: View {
    @Binding var settings: WallSettings

    var body: some View {
        Form {
            Section("写真の見せ方") {
                Toggle("表示中の写真に追従するガラス風の背景", isOn: $settings.glassBackground)
                LabeledContent("背景色（例：#101116）") {
                    TextField("#101116", text: $settings.backgroundHex)
                        .frame(width: 120)
                }
                DoubleField(title: "写真の間隔（px）", value: $settings.gap)
                DoubleField(title: "写真の角丸（px、0で無効）", value: $settings.cornerRadius)
                Toggle("ファイル名・解像度・撮影日時を表示", isOn: $settings.exifOverlay)
                NumericField(title: "画像キャッシュ予算（MiB、64〜1024）", value: $settings.cacheMegabytes)
            }
        }
        .formStyle(.grouped)
    }
}

private struct NumericField: View {
    let title: String
    @Binding var value: Int

    var body: some View {
        LabeledContent(title) {
            TextField("", value: $value, format: .number)
                .multilineTextAlignment(.trailing)
                .frame(width: 100)
        }
    }
}

private struct DoubleField: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        LabeledContent(title) {
            TextField("", value: $value, format: .number.precision(.fractionLength(0...2)))
                .multilineTextAlignment(.trailing)
                .frame(width: 100)
        }
    }
}

private struct StatusAndSaveView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
            Text("\(model.displayStatusMessage) · ライブラリ \(model.photoAssets.count)枚 · \(model.currentMode ?? "—")")
                .foregroundStyle(.secondary)
            }
            HStack {
            Button("保存して表示開始", action: model.start).disabled(!model.canStart)
            Button("表示停止", action: model.stop).disabled(!model.desiredRunning && !model.testPatternVisible)
            Spacer()
            Button("変更を取り消す", action: model.cancelDraft)
            Button("保存して適用", action: model.saveSettings)
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

#Preview {
    ContentView(model: AppModel.makeUITestModel(profile: "Preview"))
}

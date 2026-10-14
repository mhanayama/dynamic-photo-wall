import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            AppHeaderView(isPlaying: model.isPlaying)

            TabView {
                DisplaySettingsView(model: model)
                    .tabItem { Label("Display", systemImage: "display") }

                PhotoSettingsView(model: model)
                    .tabItem { Label("Photos", systemImage: "photo.on.rectangle") }

                CompositionSettingsView(settings: $model.settings)
                    .tabItem { Label("Composition", systemImage: "rectangle.3.group") }

                MotionSettingsView(settings: $model.settings)
                    .tabItem { Label("Motion", systemImage: "waveform.path") }

                AppearanceSettingsView(settings: $model.settings)
                    .tabItem { Label("Appearance", systemImage: "paintpalette") }
            }

            if let warning = model.settingsWarning { Text(warning).foregroundStyle(.orange) }
            StatusAndSaveView(model: model)
        }
        .padding(24)
        .frame(minWidth: 760, idealWidth: 880, minHeight: 640, idealHeight: 760)
    }
}

private struct AppHeaderView: View {
    let isPlaying: Bool

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
            Label(isPlaying ? "再生中" : "停止中", systemImage: isPlaying ? "play.circle.fill" : "stop.circle")
                .foregroundStyle(isPlaying ? .green : .secondary)
        }
    }
}

private struct DisplaySettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("表示するディスプレイ") {
                Picker("対象画面", selection: $model.selectedScreenID) {
                    if let id = model.selectedScreenID, model.selectedScreen == nil {
                        Text("未接続のディスプレイ（ID \(id)）").tag(Optional(id))
                    }
                    ForEach(model.screens) { screen in
                        Text("\(screen.name)（\(screen.resolutionDescription)）")
                            .tag(Optional(screen.id))
                    }
                }
                Button("ディスプレイを再検出", systemImage: "arrow.clockwise") {
                    model.refreshScreens()
                }
                Toggle("アプリ起動時にスライドショーを開始", isOn: $model.settings.startOnLaunch)
            }

            Section("再生操作") {
                HStack {
                    Button("保存して表示開始", action: model.start)
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canStart)
                    Button("表示停止", action: model.stop)
                        .disabled(!model.isPlaying)
                    Button(model.userPaused ? "再開" : "一時停止", action: model.togglePause)
                        .disabled(!model.isPlaying)
                    Button("次の構成", action: model.showNextScene)
                        .disabled(!model.isPlaying)
                }
                Text("設定画面を閉じても再生は続きます。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct PhotoSettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("写真フォルダ") {
                List {
                    ForEach(model.folders) { folder in
                        Label(folder.path ?? "未解決の登録フォルダ", systemImage: folder.isAccessible ? "folder" : "exclamationmark.triangle")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(folder.isAccessible ? Color.primary : Color.orange)
                    }
                    .onDelete(perform: model.removeFolders)
                }
                .frame(minHeight: 180)

                HStack {
                    Button("フォルダを追加／再許可", systemImage: "plus", action: model.chooseFolder)
                    Button("再検索／アクセス再試行", systemImage: "arrow.clockwise", action: model.retryFolders)
                }
                if let warning = model.folderWarning { Text(warning).foregroundStyle(.orange) }

                Toggle("サブフォルダも検索", isOn: $model.settings.recursive)
                Toggle("ランダムに再生", isOn: $model.settings.randomOrder)

                LabeledContent("再表示を抑制する直近の写真数") {
                    TextField("30", value: $model.settings.recentCount, format: .number)
                        .frame(width: 100)
                }

                Text("JPEG / PNG / WebP / HEIC / HEIF対応。写真はMac内で処理されます。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct CompositionSettingsView: View {
    @Binding var settings: WallSettings

    var body: some View {
        Form {
            Section("表示モード") {
                Toggle("Gallery — 複数の写真を並べる", isOn: $settings.galleryEnabled)
                Toggle("横スクロールGallery — 新しい写真が横から流れてくる", isOn: $settings.galleryScrollEnabled)
                Toggle("Vertical Pan — 縦写真を下側から上側へ見せる", isOn: $settings.verticalPanEnabled)
                Toggle("Horizontal Pan — 横長写真を左右に見せる", isOn: $settings.horizontalPanEnabled)
                Toggle("Cinematic Zoom — ゆっくり拡大・縮小", isOn: $settings.zoomEnabled)
            }

            Section("抽選ウェイト") {
                NumericField(title: "Gallery", value: $settings.galleryWeight)
                NumericField(title: "Pan（縦・横の合計）", value: $settings.panWeight)
                NumericField(title: "Zoom", value: $settings.zoomWeight)
            }

            Section("構成") {
                NumericField(title: "Galleryの最大枚数（1〜5）", value: $settings.galleryMax)
                DoubleField(title: "パンで許容する拡大率（1〜12倍）", value: $settings.maxPanUpscale)
                DoubleField(title: "縦パンの表示幅（0.3〜1.0）", value: $settings.panWidthFraction)
                Text("拡大率を超える写真はGalleryで表示します。")
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
                DoubleField(title: "パン速度（物理px / 秒、5〜500）", value: $settings.panPixelsPerSecond)
                DoubleField(title: "横スクロールGalleryの速度（px / 秒、5〜200）", value: $settings.galleryScrollPixelsPerSecond)
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
                LabeledContent("背景色") {
                    TextField("#101116", text: $settings.backgroundHex)
                        .frame(width: 120)
                }
                DoubleField(title: "写真の間隔（px）", value: $settings.gap)
                DoubleField(title: "写真の角丸（px、0で無効）", value: $settings.cornerRadius)
                Toggle("ファイル名・解像度を表示", isOn: $settings.exifOverlay)
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
        HStack {
            Text("\(model.statusMessage) · ライブラリ \(model.photoAssets.count)枚 · \(model.currentMode ?? "—")")
                .foregroundStyle(.secondary)
            Spacer()
            Button("保存して適用", action: model.saveSettings)
                .buttonStyle(.borderedProminent)
        }
    }
}

#Preview {
    ContentView(model: AppModel())
}

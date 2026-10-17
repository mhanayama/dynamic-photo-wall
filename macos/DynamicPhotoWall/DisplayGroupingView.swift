import SwiftUI

struct UsedDisplaysView: View {
    @Bindable var model: AppModel
    var body: some View {
        Form {
            Section("写真を表示する画面") {
                ForEach($model.displays) { $display in
                    Toggle(isOn: $display.enabled) {
                        VStack(alignment: .leading) {
                            Text(display.name).lineLimit(2)
                            Text("\(Int(display.width)) × \(Int(display.height)) px · ID \(display.id)" + (model.screens.contains(where: { $0.id == display.id }) ? "" : " · 未接続"))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("display-enabled-\(display.id)")
                }
                Button("ディスプレイを再検出", systemImage: "arrow.clockwise", action: model.refreshScreens)
                Text(model.displayConnectionMessage).foregroundStyle(.secondary)
            }
            Section {
                Text("Dockとメニューバーの表示はmacOSのシステム設定に従います。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct DisplayGroupingView: View {
    @Bindable var model: AppModel
    var body: some View {
        Form {
            Section("グループ一覧（\(model.displayGroupNames.count)件）") {
                Button("グループを追加", systemImage: "plus", action: model.addDisplayGroup)
                ForEach(model.displayGroupNames, id: \.self) { name in
                    HStack {
                        let members = model.displays.filter { $0.enabled && DisplayLayout.cleanName($0.groupID) == name }
                        VStack(alignment: .leading) {
                            Text("\(name) · \(members.count)台").fontWeight(.semibold)
                            Text(members.isEmpty ? "画面未割り当て" : members.map(\.name).joined(separator: "、"))
                                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Button("削除", role: .destructive) { model.deleteDisplayGroup(name) }
                            .accessibilityIdentifier("delete-group-\(name)")
                    }
                }
            }
            Section("画面の所属") {
                ForEach($model.displays) { $display in
                    Picker(display.name + (display.enabled ? "" : "（未選択）"), selection: $display.groupID) {
                        Text("独立して表示").tag(Optional<String>.none)
                        ForEach(model.displayGroupNames, id: \.self) { Text($0).tag(Optional($0)) }
                    }
                    .accessibilityIdentifier("display-group-\(display.id)")
                }
            }
            Section("配置プレビュー · ドラッグで移動、端と中央にスナップ") {
                if let groups = try? DisplayLayout.groups(model.displays) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading) {
                            Text(group.name).fontWeight(.semibold)
                            DisplayLayoutEditor(displays: $model.displays, group: group)
                                .frame(height: 200)
                        }
                    }
                } else { Text("寸法・座標を確認してください。").foregroundStyle(.orange) }
                DisclosureGroup("配置を数値で調整") {
                    ForEach($model.displays) { $display in
                        HStack {
                            Text(display.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            Text("X"); TextField("X", value: $display.x, format: .number).frame(width: 90)
                            Text("Y"); TextField("Y", value: $display.y, format: .number).frame(width: 90)
                        }
                    }
                    Button("OSの配置へリセット", action: model.resetDisplayPositions)
                }
            }
            Section("テストパターン") {
                Button(model.testPatternVisible ? "表示停止" : "表示", action: model.toggleTestPattern)
                    .accessibilityIdentifier("test-pattern-toggle")
                Text("保存・写真の登録なしで現在の配置を確認できます。設定画面を閉じても表示を続けます。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct DisplayLayoutEditor: View {
    @Binding var displays: [WallDisplay]
    let group: WallDisplayGroup
    @State private var editingBounds: CGRect?
    @State private var dragOrigins: [UInt32: CGPoint] = [:]

    var body: some View {
        GeometryReader { proxy in
            let bounds = editingBounds ?? group.bounds
            let scale = min((proxy.size.width - 24) / max(1, bounds.width), (proxy.size.height - 24) / max(1, bounds.height))
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.06)
                ForEach(group.displays) { display in
                    let region = display.rect.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.blue.opacity(0.22))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.blue, lineWidth: 2))
                        .overlay(Text(display.name).font(.caption).lineLimit(2).padding(4))
                        .frame(width: region.width * scale, height: region.height * scale)
                        .offset(x: 12 + region.minX * scale, y: 12 + region.minY * scale)
                        .gesture(DragGesture().onChanged { value in
                            guard let i = displays.firstIndex(where: { $0.id == display.id }) else { return }
                            if editingBounds == nil { editingBounds = group.bounds }
                            let origin = dragOrigins[display.id] ?? CGPoint(x: display.x, y: display.y)
                            dragOrigins[display.id] = origin
                            let rect = CGRect(x: origin.x + value.translation.width / scale,
                                y: origin.y + value.translation.height / scale, width: display.width, height: display.height)
                            let snapped = DisplayLayout.snapped(rect, against: group.displays.filter { $0.id != display.id }.map(\.rect), threshold: 10 / scale)
                            displays[i].x = snapped.x.rounded(); displays[i].y = snapped.y.rounded()
                        }.onEnded { _ in dragOrigins.removeValue(forKey: display.id); editingBounds = nil })
                }
            }
            .clipped()
        }
    }
}

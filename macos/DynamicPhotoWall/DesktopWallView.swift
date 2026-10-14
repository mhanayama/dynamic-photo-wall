import SwiftUI

struct DesktopWallView: View {
    let photoAssets: [PhotoAsset]
    let initialSceneIndex: Int
    let settings: WallSettings

    @State private var playbackStart = Date()
    @State private var playbackSeed = UInt64.random(in: UInt64.min...UInt64.max)

    var body: some View {
        if photoAssets.isEmpty {
            EmptyWallView()
        } else {
            GeometryReader { proxy in
                TimelineView(.animation) { context in
                    let elapsed = context.date.timeIntervalSince(playbackStart)
                    let position = WallPlaybackPosition.resolve(
                        elapsed: elapsed,
                        assets: photoAssets,
                        settings: settings,
                        viewport: proxy.size,
                        seed: playbackSeed,
                        startingSceneIndex: initialSceneIndex
                    )

                    ZStack {
                        WallSceneLayer(
                            scene: position.currentScene,
                            allAssets: photoAssets,
                            progress: position.progress,
                            settings: settings
                        )
                        .opacity(1 - position.transitionProgress)

                        if position.transitionProgress > 0 {
                            WallSceneLayer(
                                scene: position.nextScene,
                                allAssets: photoAssets,
                                progress: 0,
                                settings: settings
                            )
                            .opacity(position.transitionProgress)
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                }
            }
            .background(Color(hex: settings.backgroundHex))
            .onChange(of: photoAssets) {
                playbackStart = Date()
            }
        }
    }
}

private struct EmptyWallView: View {
    var body: some View {
        ZStack {
            Color.black
            ContentUnavailableView(
                "写真がありません",
                systemImage: "photo.on.rectangle.angled",
                description: Text("設定画面で写真を含むフォルダを選択してください。")
            )
            .foregroundStyle(.white)
        }
        .ignoresSafeArea()
    }
}

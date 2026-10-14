import SwiftUI

struct DesktopWallView: View {
    let playback: WallPlaybackController

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation(paused: playback.isPaused || playback.isWaiting)) { context in
                ZStack {
                    // The scene's identity survives current -> outgoing. Moving
                    // it between two conditional view trees would recreate NSViews.
                    ForEach(playback.layers()) { layer in
                        WallSceneLayer(presentation: layer.presentation, settings: playback.settings,
                                       images: playback.imageStore ?? .shared)
                            .opacity(layer.opacity)
                    }
                }
                // Plans, eligibility and velocities use physical pixels. The surface
                // is converted to the selected NSScreen's point space only here.
                .frame(width: playback.viewport.width, height: playback.viewport.height)
                .clipped()
                .scaleEffect(x: proxy.size.width / playback.viewport.width,
                             y: proxy.size.height / playback.viewport.height, anchor: .topLeading)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                .onChange(of: context.date, initial: true) { playback.update() }
            }
        }
        .background(Color(hex: playback.settings.backgroundHex))
    }
}

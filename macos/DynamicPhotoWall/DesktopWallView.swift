import SwiftUI

struct DesktopWallView: View {
    let playback: WallPlaybackController

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation(paused: playback.isPaused)) { context in
                ZStack {
                    if let old = playback.outgoing {
                        WallSceneLayer(presentation: old, settings: playback.settings)
                    }
                    if let current = playback.presentation() {
                        WallSceneLayer(presentation: current, settings: playback.settings)
                            .opacity(playback.transitionProgress())
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

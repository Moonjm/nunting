import SwiftUI
import AVKit

struct InlineVideoPlayer: View {
    let url: URL

    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .frame(maxWidth: .infinity)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onAppear {
                if player == nil {
                    player = AVPlayer(url: url)
                }
            }
            .onChange(of: url) { _, newURL in
                player?.pause()
                player = AVPlayer(url: newURL)
            }
            .onDisappear {
                player?.pause()
                player = nil
            }
    }
}

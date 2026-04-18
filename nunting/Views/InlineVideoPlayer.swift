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
                    let p = AVPlayer(url: url)
                    p.isMuted = true   // iOS blocks autoplay with sound
                    player = p
                }
                player?.play()
            }
            .onChange(of: url) { _, newURL in
                player?.pause()
                let p = AVPlayer(url: newURL)
                p.isMuted = true
                player = p
                p.play()
            }
            .onDisappear {
                player?.pause()
                player = nil
            }
    }
}

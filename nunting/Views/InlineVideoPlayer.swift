import SwiftUI
import AVKit

struct InlineVideoPlayer: View {
    let url: URL

    @State private var player: AVPlayer?
    @State private var playbackEndObserver: NSObjectProtocol?
    @State private var isReady: Bool = false

    var body: some View {
        // Single stable ZStack — every layer is always present, just toggled
        // by opacity. Avoids the SwiftUI view-identity swap that, combined
        // with the parent ScrollView's implicit animation, made the player
        // look like it was sliding in from the right while loading.
        ZStack {
            Color.black

            if let posterURL {
                CachedAsyncImage(url: posterURL, maxDimension: 720)
                    .opacity(isReady ? 0 : 1)
                    .allowsHitTesting(false)
            }

            VideoPlayer(player: player)
                .opacity(isReady ? 1 : 0)
                // VideoPlayer wraps AVPlayerViewController whose gesture
                // recognisers eat scroll touches even with opacity 0 and a
                // nil player. Block hit-testing until the asset is actually
                // playable so the parent ScrollView still receives swipes
                // while the video is loading.
                .allowsHitTesting(isReady)

            ProgressView()
                .controlSize(.regular)
                .tint(.white)
                .opacity(isReady ? 0 : 1)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .transaction { $0.animation = nil }
        .task(id: url) { await loadPlayer() }
        .onDisappear {
            if let playbackEndObserver {
                NotificationCenter.default.removeObserver(playbackEndObserver)
                self.playbackEndObserver = nil
            }
            player?.pause()
            player = nil
            isReady = false
        }
    }

    /// Construct the poster URL from the aagag CDN's `/{q}.mp4` pattern.
    private var posterURL: URL? {
        guard url.host?.contains("aagag.com") == true else { return nil }
        let last = (url.path as NSString).lastPathComponent
        guard last.hasSuffix(".mp4") else { return nil }
        let q = String(last.dropLast(4))
        return URL(string: "https://i.aagag.com/o/\(q).jpg")
    }

    /// Load the asset off the main thread so VideoPlayer creation doesn't
    /// block UI scroll. Once the asset reports playable, install the player
    /// and start muted autoplay.
    private func loadPlayer() async {
        if Task.isCancelled { return }
        let asset = AVURLAsset(url: url)
        let playable: Bool
        do {
            playable = try await asset.load(.isPlayable)
        } catch {
            return
        }
        if Task.isCancelled || !playable { return }

        let item = AVPlayerItem(asset: asset)
        let p = AVPlayer(playerItem: item)
        p.isMuted = true   // iOS blocks autoplay with sound
        p.actionAtItemEnd = .none

        // Clear isReady when item buffers far enough to start. The
        // `timeControlStatus` observer would be more accurate but adds
        // KVO plumbing — for now, flip it after the asset reports ready.
        await MainActor.run {
            playbackEndObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak p] _ in
                p?.seek(to: .zero)
                p?.play()
            }
            self.player = p
            self.isReady = true
            p.play()
        }
    }
}

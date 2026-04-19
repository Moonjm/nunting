import SwiftUI
import UIKit
import ImageIO

struct ImageViewerItem: Identifiable {
    let url: URL

    var id: String { url.absoluteString }
}

struct ImageViewer: View {
    let url: URL

    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var failed = false
    @State private var isZoomed = false
    @State private var dismissOffset: CGFloat = 0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
                .opacity(backgroundOpacity)

            if let image {
                ZoomableImageView(image: image, isZoomed: $isZoomed)
                    .offset(y: isZoomed ? 0 : dismissOffset)
                    .simultaneousGesture(dismissDrag)
                    .ignoresSafeArea()
            } else if failed {
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.black.opacity(0.45), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(.top, 12)
            .padding(.trailing, 12)
            .accessibilityLabel("이미지 닫기")
        }
        .statusBarHidden()
        .task(id: url) { await loadImage() }
    }

    private var dismissDrag: some Gesture {
        DragGesture()
            .onChanged { value in
                guard !isZoomed else { return }
                dismissOffset = max(0, value.translation.height)
            }
            .onEnded { value in
                guard !isZoomed else { return }
                if value.translation.height > 120 || value.predictedEndTranslation.height > 220 {
                    dismiss()
                } else {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                        dismissOffset = 0
                    }
                }
            }
    }

    private var backgroundOpacity: Double {
        guard !isZoomed else { return 1 }
        return max(0.35, 1 - Double(dismissOffset / 360))
    }

    private func loadImage() async {
        image = nil
        failed = false

        if let cached = ImageCache.shared.image(for: url) {
            image = cached
            return
        }

        do {
            let (data, response) = try await Networking.session.data(for: URLRequest(url: url))
            try Task.checkCancellation()
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                failed = true
                return
            }
            let decoded = try await decodeOffMain(data: data, scale: displayScale)
            try Task.checkCancellation()
            if let decoded {
                ImageCache.shared.store(decoded, for: url)
                image = decoded
            } else {
                failed = true
            }
        } catch is CancellationError {
            return
        } catch {
            failed = true
        }
    }

    private func decodeOffMain(data: Data, scale: CGFloat) async throws -> UIImage? {
        try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            // Clamp the thumbnail pixel size so ultra-high-DPI devices don't
            // ask CoreGraphics to materialise a ~14k px thumbnail and peak
            // memory unnecessarily. 4096 covers every iPhone/iPad retina
            // class with headroom for pinch-to-zoom.
            let maxPixelSize = min(max(2400 * scale, 1024), 4096)
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            ]
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            else { return nil }
            try Task.checkCancellation()
            return UIImage(cgImage: cg, scale: scale, orientation: .up)
        }.value
    }
}

private struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    @Binding var isZoomed: Bool

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.backgroundColor = .clear
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.decelerationRate = .fast

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        imageView.frame = scrollView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.addSubview(imageView)

        context.coordinator.scrollView = scrollView
        context.coordinator.imageView = imageView

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        guard context.coordinator.imageView?.image !== image else { return }
        context.coordinator.imageView?.image = image
        // setZoomScale fires scrollViewDidZoom, which resets isZoomed — no
        // need to push a SwiftUI state mutation from inside updateUIView.
        scrollView.setZoomScale(1, animated: false)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isZoomed: $isZoomed)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        @Binding var isZoomed: Bool
        weak var scrollView: UIScrollView?
        weak var imageView: UIImageView?

        init(isZoomed: Binding<Bool>) {
            _isZoomed = isZoomed
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            isZoomed = scrollView.zoomScale > 1.01
            centerImage(in: scrollView)
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView else { return }
            if scrollView.zoomScale > 1.01 {
                scrollView.setZoomScale(1, animated: true)
                isZoomed = false
            } else {
                let point = recognizer.location(in: imageView)
                let targetScale = min(scrollView.maximumZoomScale, 2.5)
                let size = CGSize(
                    width: scrollView.bounds.width / targetScale,
                    height: scrollView.bounds.height / targetScale
                )
                let rect = CGRect(
                    x: point.x - size.width / 2,
                    y: point.y - size.height / 2,
                    width: size.width,
                    height: size.height
                )
                scrollView.zoom(to: rect, animated: true)
                isZoomed = true
            }
        }

        private func centerImage(in scrollView: UIScrollView) {
            guard let imageView else { return }
            let bounds = scrollView.bounds.size
            let content = imageView.frame.size
            let horizontal = max(0, (bounds.width - content.width) / 2)
            let vertical = max(0, (bounds.height - content.height) / 2)
            scrollView.contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
        }
    }
}

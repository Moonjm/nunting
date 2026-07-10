import SwiftUI
import UIKit
import SDWebImage

struct ImageViewerItem: Identifiable {
    let url: URL

    var id: String { url.absoluteString }
}

struct ImageViewer: View {
    let url: URL
    /// Fires the moment the viewer commits a dismiss (X tap or drag-down
    /// past threshold), BEFORE SwiftUI starts animating the cover off.
    /// The host (PostDetailView) raises a full-screen black overlay
    /// during the slide-down so the underlying detail doesn't reveal
    /// progressively under the dismissing cover. See the matching
    /// callback on `InlineVideoPlayer` for the full reasoning.
    var onDismissBegin: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var failed = false
    @State private var isZoomed = false
    @State private var dismissOffset: CGFloat = 0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            if let image {
                // GeometryReader 로 뷰 크기를 prop 으로 — updateUIView 시점에
                // bounds 가 아직 0 인 레이스 없이 동적 max zoom 을 계산한다.
                GeometryReader { geo in
                    ZoomableImageView(image: image, viewSize: geo.size, isZoomed: $isZoomed)
                }
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
                onDismissBegin()
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
                    onDismissBegin()
                    dismiss()
                } else {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                        dismissOffset = 0
                    }
                }
            }
    }

    private func loadImage() async {
        image = nil
        failed = false

        // Cap the long edge so ultra-high-DPI devices don't ask the
        // decoder to materialise a ~14k px image and peak memory
        // unnecessarily. 4096 covers every iPhone/iPad retina class
        // with headroom for pinch-to-zoom.
        let maxPixelSize = min(max(2400 * displayScale, 1024), 4096)
        let result = await decode(boxPixels: CGSize(width: maxPixelSize, height: maxPixelSize))

        guard !Task.isCancelled else { return }
        guard let result else {
            failed = true
            return
        }

        // 극단 세로형(웹툰형 짤)이 정사각 박스에 깎였으면 tall 버짓 박스로 2차
        // 디코드 — 1차 결과의 aspect(다운샘플은 비율 보존)로 원본 비례를 안다.
        // 정사각 4096 박스는 800×24000 을 137px 폭으로 뭉갰다(인라인보다 흐림).
        // 뷰어는 동시 1장이라 20MP(≈80MB) 버짓으로 통상 세로 짤은 native 폭.
        let px = CGSize(width: result.size.width * result.scale,
                        height: result.size.height * result.scale)
        if Self.needsTallRedecode(decodedPixels: px, firstPassBoxEdge: maxPixelSize) {
            let box = Self.tallDecodeBoxPixels(aspect: px.width / px.height, displayScale: displayScale)
            image = result // 2차 디코드 동안 1차 결과 먼저 표시(스피너 대신).
            if let sharp = await decode(boxPixels: box), !Task.isCancelled {
                image = sharp
            }
            return
        }
        image = result
    }

    /// SDWebImageManager.loadImage handles fetch + decode + memory / disk
    /// cache. The `imageThumbnailPixelSize` context derives a separate cache
    /// key per box, so the viewer's decodes are their own cache namespace —
    /// same isolation the legacy `cacheVariant: "viewer"` provided (tall 2차
    /// 디코드도 박스가 달라 1차와 캐시 충돌 없음).
    private func decode(boxPixels: CGSize) async -> UIImage? {
        let context: [SDWebImageContextOption: Any] = [
            .imageThumbnailPixelSize: NSValue(cgSize: boxPixels),
            // Decode animated WebP/GIF as a *lazy* `SDAnimatedImage` (frames
            // decoded on demand during playback) instead of the default path,
            // which materialises every frame into `UIImage.images` up front —
            // for a 354-frame / 720×1280 짤방 that's ~14s + ~1.2 GB and froze
            // the viewer behind a spinner. The lazy image returns in ~50ms;
            // `SDAnimatedImageView` (below) then plays it within a bounded
            // buffer. Static images are unaffected (single-frame SDAnimatedImage).
            .animatedImageClass: SDAnimatedImage.self,
        ]
        return await withCheckedContinuation { continuation in
            SDWebImageManager.shared.loadImage(
                with: url.atsSafe,
                options: [.retryFailed],
                context: context,
                progress: nil
            ) { uiImage, _, _, _, _, _ in
                continuation.resume(returning: uiImage)
            }
        }
    }

    // MARK: - tall 이미지 계약 (단위 테스트로 핀)

    /// 1차(정사각 박스) 디코드가 높이 캡에 닿았고(=원본이 박스보다 큼) 극단
    /// 세로형(폭/높이 < 1/4)일 때만 2차 재디코드. 캡에 안 닿았으면 이미
    /// native 디코드라 다시 할 게 없다.
    nonisolated static func needsTallRedecode(decodedPixels: CGSize, firstPassBoxEdge: CGFloat) -> Bool {
        guard decodedPixels.width > 0, decodedPixels.height > 0 else { return false }
        let aspect = decodedPixels.width / decodedPixels.height
        return aspect < 0.25 && decodedPixels.height >= firstPassBoxEdge - 2
    }

    /// tall 2차 디코드 박스 — 버짓 20MP(RGBA ≈ 80MB, 뷰어 단일 이미지 한정)를
    /// aspect 에 맞춰 배분: 폭 = min(정사각 캡, sqrt(버짓×aspect)), 높이는
    /// hard max 24576 안. 통상 세로 짤(800×24000 = 19.2MP)은 native 통과.
    nonisolated static func tallDecodeBoxPixels(aspect: CGFloat, displayScale: CGFloat) -> CGSize {
        let budget: CGFloat = 20_000_000
        let hardMaxHeight: CGFloat = 24_576
        let widthCap = min(max(2400 * displayScale, 1024), 4096)
        let width = min(widthCap, (budget * aspect).squareRoot())
        let height = min(width / aspect, hardMaxHeight)
        return CGSize(width: width, height: height)
    }

    /// 더블탭 줌 대상 rect — 탭 지점을 aspectFit 으로 그려진 이미지 영역 안
    /// 으로 클램프한다. 세로 초대형은 얇은 세로 띠로 그려져서, 레터박스를
    /// 탭하면 rect 가 이미지 밖(여백)에 잡혀 빈 화면으로 확대됐다.
    nonisolated static func doubleTapZoomRect(
        tapPoint: CGPoint, imageSize: CGSize, boundsSize: CGSize, targetScale: CGFloat
    ) -> CGRect {
        let rectSize = CGSize(width: boundsSize.width / targetScale,
                              height: boundsSize.height / targetScale)
        var center = tapPoint
        if imageSize.width > 0, imageSize.height > 0 {
            // aspectFit 으로 그려진 이미지 rect (imageView 좌표 = bounds 좌표).
            let fit = min(boundsSize.width / imageSize.width, boundsSize.height / imageSize.height)
            let drawn = CGSize(width: imageSize.width * fit, height: imageSize.height * fit)
            let origin = CGPoint(x: (boundsSize.width - drawn.width) / 2,
                                 y: (boundsSize.height - drawn.height) / 2)
            // 탭 중심을 "rect 가 이미지 안에 머무는" 범위로 클램프. 이미지가
            // rect 보다 좁으면(세로 띠) 그 축은 이미지 중심으로 고정된다.
            center.x = clamp(center.x,
                             min: origin.x + rectSize.width / 2,
                             max: origin.x + drawn.width - rectSize.width / 2,
                             fallback: origin.x + drawn.width / 2)
            center.y = clamp(center.y,
                             min: origin.y + rectSize.height / 2,
                             max: origin.y + drawn.height - rectSize.height / 2,
                             fallback: origin.y + drawn.height / 2)
        }
        return CGRect(x: center.x - rectSize.width / 2,
                      y: center.y - rectSize.height / 2,
                      width: rectSize.width, height: rectSize.height)
    }

    /// min > max(이미지가 rect 보다 작은 축)면 fallback(이미지 중심)으로.
    private nonisolated static func clamp(
        _ v: CGFloat, min lower: CGFloat, max upper: CGFloat, fallback: CGFloat
    ) -> CGFloat {
        guard lower <= upper else { return fallback }
        return Swift.min(Swift.max(v, lower), upper)
    }

    /// 동적 최대 줌 — aspectFit(줌 1) 기준 폭맞춤까지 필요한 배율의 2배.
    /// 세로 초대형은 fit 이 폭을 수십 pt 로 만들어 종전 고정 5×로는 "확대가
    /// 중간에 끝나" 읽을 수 없었다. 일반 사진은 종전 5× 유지, 상한 60.
    nonisolated static func maxZoomScale(imageSize: CGSize, viewSize: CGSize) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0,
              viewSize.width > 0, viewSize.height > 0 else { return 5 }
        let fit = min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let widthFill = viewSize.width / imageSize.width
        guard fit > 0 else { return 5 }
        return min(max(5, widthFill / fit * 2), 60)
    }
}

private struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    let viewSize: CGSize
    @Binding var isZoomed: Bool

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.backgroundColor = .clear
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        // 세로 초대형은 aspectFit 이 폭을 수십 pt 로 만들므로 이미지/뷰 비율
        // 기반 동적 상한 — updateUIView 가 실제 크기로 갱신한다.
        scrollView.maximumZoomScale = ImageViewer.maxZoomScale(imageSize: image.size, viewSize: viewSize)
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.decelerationRate = .fast

        // `SDAnimatedImageView` (a `UIImageView` subclass) plays a lazy
        // `SDAnimatedImage` frame-by-frame; a plain `UIImageView` would show
        // only its poster frame. `maxBufferSize` caps decoded-frame residency
        // (default 0 = buffer every frame → ~1.2 GB on a 354-frame 짤방).
        let imageView = SDAnimatedImageView()
        imageView.image = image
        imageView.maxBufferSize = 16 * 1024 * 1024
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
        // 이미지 교체(tall 2차 디코드 포함)나 뷰 크기 변화 모두 상한 재계산.
        scrollView.maximumZoomScale = ImageViewer.maxZoomScale(imageSize: image.size, viewSize: viewSize)
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
                let imageSize = imageView?.image?.size ?? .zero
                let bounds = scrollView.bounds
                // 세로 초대형은 더블탭 한 번에 "폭맞춤"(웹툰 리더 배율)으로 —
                // 고정 2.5×는 폭 수십 pt 표시에선 읽기 배율에 한참 못 미친다.
                var targetScale = min(scrollView.maximumZoomScale, 2.5)
                if imageSize.height > 0 {
                    let fitWidth = min(bounds.width, bounds.height * (imageSize.width / imageSize.height))
                    if fitWidth > 0 {
                        let widthFill = bounds.width / fitWidth
                        if widthFill > 2.5 {
                            targetScale = min(scrollView.maximumZoomScale, widthFill)
                        }
                    }
                }
                // 탭 지점을 이미지 영역으로 클램프 — 레터박스 더블탭이 여백으로
                // 확대되지 않게(계약은 doubleTapZoomRect 테스트로 핀).
                let rect = ImageViewer.doubleTapZoomRect(
                    tapPoint: point, imageSize: imageSize,
                    boundsSize: bounds.size, targetScale: targetScale)
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

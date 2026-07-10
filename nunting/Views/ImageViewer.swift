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
        // task 취소를 SD operation 에 연결 — 안 하면 뷰어를 닫아도 20MP 2차
        // 디코드가 끝까지 돈다(취소는 대입만 막았음). SD 는 cancel 시에도
        // completion 을 (cancelled 에러로) 호출하므로 continuation 은 누수 없이
        // nil 로 재개된다(실측: onFailure 로 전달되는 SD 2002 cancelled).
        let box = OperationBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let operation = SDWebImageManager.shared.loadImage(
                    with: url.atsSafe,
                    options: [.retryFailed],
                    context: context,
                    progress: nil
                ) { uiImage, _, _, _, _, _ in
                    continuation.resume(returning: uiImage)
                }
                box.store(operation)
            }
        } onCancel: {
            box.cancel()
        }
    }

    /// loadImage 의 operation 을 task 취소에 연결하는 스레드 안전 보관함 —
    /// onCancel 은 임의 스레드에서 불리고 store(메인)와 순서 보장이 없으므로,
    /// "취소가 먼저 온 뒤 등록된 operation 도 즉시 취소" 를 락으로 보장한다.
    /// internal 인 이유: 이 레이스 계약을 단위 테스트로 핀.
    /// nonisolated: View 중첩 타입은 MainActor 를 상속하는데, onCancel 은
    /// 임의 스레드에서 부른다 — 격리 대신 내부 락으로 지킨다.
    nonisolated final class OperationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var operation: (any SDWebImageOperation)?
        private var isCancelled = false

        func store(_ operation: (any SDWebImageOperation)?) {
            lock.lock()
            defer { lock.unlock() }
            if isCancelled {
                operation?.cancel()
            } else {
                self.operation = operation
            }
        }

        func cancel() {
            lock.lock()
            defer { lock.unlock() }
            isCancelled = true
            operation?.cancel()
            operation = nil
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

    /// 뷰포트에 aspectFit 한 이미지의 표시 크기 — 줌 대상 imageView 의 프레임.
    /// 뷰포트 크기 뷰를 확대하면 레터박스까지 콘텐츠가 돼 이미지 밖 여백을
    /// 한없이 패닝하게 되므로(Codex P2), imageView 를 이 크기로 잡는다.
    nonisolated static func fittedSize(imageSize: CGSize, viewportSize: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else { return viewportSize }
        let fit = min(viewportSize.width / imageSize.width, viewportSize.height / imageSize.height)
        return CGSize(width: imageSize.width * fit, height: imageSize.height * fit)
    }

    /// 1차 → 2차(화질만) 교체 판별 — aspect 가 같아 fit 크기가 사실상 일치.
    /// 이 경우 줌/오프셋을 보존한 채 이미지만 갈아끼운다(읽던 위치 유지).
    nonisolated static func isSameFittedSize(_ a: CGSize, _ b: CGSize) -> Bool {
        abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1
    }

    /// 더블탭 줌 대상 rect — imageView(=fit 된 이미지) 좌표계. 레터박스 탭은
    /// 이미지 밖 좌표(음수/초과)로 들어오므로 rect 가 이미지 안에 머물게
    /// 클램프한다. rect 가 이미지보다 큰 축은 이미지 중심으로 폴백.
    nonisolated static func doubleTapZoomRect(
        tapPoint: CGPoint, fittedImageSize: CGSize, viewportSize: CGSize, targetScale: CGFloat
    ) -> CGRect {
        let rectSize = CGSize(width: viewportSize.width / targetScale,
                              height: viewportSize.height / targetScale)
        var center = tapPoint
        center.x = clamp(center.x,
                         min: rectSize.width / 2,
                         max: fittedImageSize.width - rectSize.width / 2,
                         fallback: fittedImageSize.width / 2)
        center.y = clamp(center.y,
                         min: rectSize.height / 2,
                         max: fittedImageSize.height - rectSize.height / 2,
                         fallback: fittedImageSize.height / 2)
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
        // 줌 대상 = fit 된 이미지 크기(뷰포트 아님). 뷰포트 크기면 레터박스가
        // 콘텐츠에 포함돼 확대 후 이미지 밖 여백을 한없이 패닝하게 된다.
        // 가운데 정렬은 Coordinator.centerImage 의 contentInset 이 담당.
        let fitted = ImageViewer.fittedSize(imageSize: image.size, viewportSize: viewSize)
        imageView.frame = CGRect(origin: .zero, size: fitted)
        scrollView.addSubview(imageView)
        scrollView.contentSize = fitted

        context.coordinator.scrollView = scrollView
        context.coordinator.imageView = imageView
        context.coordinator.lastViewSize = viewSize
        context.coordinator.centerImage(in: scrollView)

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        // 이미지 교체(tall 2차 디코드 포함)나 뷰 크기 변화 모두 상한 재계산.
        scrollView.maximumZoomScale = ImageViewer.maxZoomScale(imageSize: image.size, viewSize: viewSize)
        guard let imageView = context.coordinator.imageView else { return }

        let fitted = ImageViewer.fittedSize(imageSize: image.size, viewportSize: viewSize)
        let viewSizeChanged = context.coordinator.lastViewSize != viewSize
        context.coordinator.lastViewSize = viewSize

        if imageView.image !== image {
            // 화질만 바뀌는 교체(1차 → 2차 tall 디코드, aspect 동일)는 줌/
            // 오프셋을 보존한 채 비트맵만 갈아끼운다 — 사용자가 2차 완료 전에
            // 확대해 읽기 시작한 위치를 잃지 않게(Codex P2). bounds 는 zoom
            // transform 의 영향을 받지 않아 fit 크기 비교에 안전하다.
            if !viewSizeChanged, ImageViewer.isSameFittedSize(imageView.bounds.size, fitted) {
                imageView.image = image
                return
            }
            imageView.image = image
        } else if !viewSizeChanged {
            return
        }
        // 신규 이미지 또는 뷰 크기 변화(회전): fit 기준으로 리셋.
        // setZoomScale fires scrollViewDidZoom, which resets isZoomed — no
        // need to push a SwiftUI state mutation from inside updateUIView.
        scrollView.setZoomScale(1, animated: false)
        imageView.frame = CGRect(origin: .zero, size: fitted)
        scrollView.contentSize = fitted
        scrollView.contentOffset = .zero
        context.coordinator.centerImage(in: scrollView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isZoomed: $isZoomed)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        @Binding var isZoomed: Bool
        weak var scrollView: UIScrollView?
        weak var imageView: UIImageView?
        /// GeometryReader 가 준 뷰포트 크기 — makeUIView 시점엔 scrollView
        /// bounds 가 아직 0 일 수 있어 센터링 계산은 이 값을 쓴다.
        var lastViewSize: CGSize = .zero

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
                // imageView = fit 된 이미지 크기이므로 이 좌표가 곧 이미지 좌표.
                let point = recognizer.location(in: imageView)
                let fitted = imageView?.bounds.size ?? .zero
                let viewport = lastViewSize == .zero ? scrollView.bounds.size : lastViewSize
                // 세로 초대형은 더블탭 한 번에 "폭맞춤"(웹툰 리더 배율)으로 —
                // 고정 2.5×는 폭 수십 pt 표시에선 읽기 배율에 한참 못 미친다.
                var targetScale = min(scrollView.maximumZoomScale, 2.5)
                if fitted.width > 0 {
                    let widthFill = viewport.width / fitted.width
                    if widthFill > 2.5 {
                        targetScale = min(scrollView.maximumZoomScale, widthFill)
                    }
                }
                // 탭 지점을 이미지 영역으로 클램프 — 레터박스 더블탭이 여백으로
                // 확대되지 않게(계약은 doubleTapZoomRect 테스트로 핀).
                let rect = ImageViewer.doubleTapZoomRect(
                    tapPoint: point, fittedImageSize: fitted,
                    viewportSize: viewport, targetScale: targetScale)
                scrollView.zoom(to: rect, animated: true)
                isZoomed = true
            }
        }

        // makeUIView/updateUIView 에서도 호출 — imageView 가 fit 크기라 정렬은
        // 전적으로 이 contentInset 이 담당한다. scrollView.bounds 가 아직 0 인
        // 최초 시점(makeUIView)은 GeometryReader 가 준 lastViewSize 로 계산.
        func centerImage(in scrollView: UIScrollView) {
            guard let imageView else { return }
            var bounds = scrollView.bounds.size
            if bounds == .zero { bounds = lastViewSize }
            let content = imageView.frame.size
            let horizontal = max(0, (bounds.width - content.width) / 2)
            let vertical = max(0, (bounds.height - content.height) / 2)
            scrollView.contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
        }
    }
}

import UIKit
import AVFoundation

/// Minimal scrub bar — a 3pt-thick progress line at the bottom of the
/// inline video, with a 30pt touch strip wrapped around it for
/// comfortable drag/tap. Renders nothing else (no thumb, no time, no
/// play button) so the inline video keeps its "moving image" feel.
/// Tap anywhere on the strip seeks to that position; pan drags the
/// playhead live then commits on touch-up.
/// Marker conformance used by `ContentView`'s back-drag hit-test to
/// detect that a touch started inside an inline video's scrub strip
/// without `ContentView` having to import / type-check against the
/// concrete `VideoScrubBarView`. A type check (`is InlineVideoScrubBarMarking`) keeps
/// the contract refactor-safe — a string `accessibilityIdentifier`
/// would collide with VoiceOver / UI-test instrumentation and could
/// be silently shadowed by a future contributor who doesn't know
/// gesture routing depends on it.
protocol InlineVideoScrubBarMarking: AnyObject {}

final class VideoScrubBarView: UIView, InlineVideoScrubBarMarking {

    /// Strong-ish ref via `weak` so the view itself doesn't keep the
    /// AVPlayer alive past the `InlineAutoplayUIView`'s tear-down.
    /// Setter installs/removes the periodic time observer.
    weak var player: AVPlayer? {
        didSet {
            if oldValue === player { return }
            removeTimeObserverFromPreviousPlayer(oldValue)
            installTimeObserver()
            updateFill()
        }
    }

    /// Visible bar height. 3pt is the thinnest that's still
    /// comfortably visible on a retina display; a thicker bar would
    /// pull the eye away from the actual video frame above.
    private let barHeight: CGFloat = 3

    private let backgroundLayer = CALayer()
    private let fillLayer = CALayer()
    /// Translucent black fade behind the bar. The resting track is
    /// white-32% and the fill is white-95%; on videos with bright
    /// pixels at the bottom edge (snow, sky, white-background webcomics)
    /// both layers blend into the frame and the bar disappears.
    /// Painting a short dark gradient under the bar gives consistent
    /// contrast regardless of source content, while staying
    /// unobtrusive enough to preserve the "moving image" feel.
    private let backdropGradient = CAGradientLayer()

    /// `addPeriodicTimeObserver` returns an `Any` token; held so
    /// `removeTimeObserver` can pair off correctly when the player
    /// changes or the bar is torn down.
    private var timeObserverToken: Any?
    /// `true` between drag/pan `.began` and `.ended`. While true the
    /// fill renders from `dragProgress` instead of the player's clock,
    /// so the scrub feels live (no lag while the player processes the
    /// seek). On touch-up we seek and clear the flag.
    private var isDragging = false
    private var dragProgress: Double = 0
    /// Held as a property (not a local in `init`) so `didMoveToWindow`
    /// can install a `require(toFail:)` dependency on the enclosing
    /// scroll view's pan once the view chain is connected — keeping
    /// quick taps as seek while routing scroll attempts to the
    /// parent ScrollView.
    private let tap = UITapGestureRecognizer()
    /// Last scroll view whose pan `tap` was made to require to fail.
    /// Tracked so re-entry to a window (the scrub bar's parent
    /// `InlineAutoplayUIView` is reused via `VideoPlayerPool`, so
    /// `didMoveToWindow` may fire multiple times against different
    /// scroll views) doesn't accumulate dependencies — `require(toFail:)`
    /// has no dedup, and a stale entry would force `tap` to wait for
    /// an unrelated scroll view that never tracks the current touch.
    private weak var tapRequiredScrollPan: UIPanGestureRecognizer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        // Darken the resting bar so it's visible over both light
        // (snow / sky scenes) and dark (night / black-letterbox)
        // video backgrounds. The fill is brighter for contrast.
        backgroundLayer.backgroundColor = UIColor.white.withAlphaComponent(0.32).cgColor
        fillLayer.backgroundColor = UIColor.white.withAlphaComponent(0.95).cgColor
        backdropGradient.colors = [
            UIColor.black.withAlphaComponent(0).cgColor,
            UIColor.black.withAlphaComponent(0.55).cgColor,
        ]
        backdropGradient.startPoint = CGPoint(x: 0.5, y: 0)
        backdropGradient.endPoint = CGPoint(x: 0.5, y: 1)
        layer.addSublayer(backdropGradient)
        layer.addSublayer(backgroundLayer)
        layer.addSublayer(fillLayer)

        let pan = DirectionalScrubPanGestureRecognizer(
            target: self,
            action: #selector(handlePan(_:))
        )
        addGestureRecognizer(pan)
        tap.addTarget(self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        removeTimeObserverFromPreviousPlayer(player)
    }

    /// Once the view is in a window the superview chain is settled, so
    /// walk up to find the post detail's enclosing `UIScrollView` (the
    /// UIKit object SwiftUI builds `ScrollView` on top of) and make the
    /// seek tap wait for its pan recognizer to fail. The tap then only
    /// fires when the touch ends without enough movement to trigger a
    /// scroll — a deliberate tap on the strip — while a touch that the
    /// scroll view's pan claims (vertical scroll attempt) marks this
    /// tap as failed and skips the seek.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        var current: UIView? = superview
        while let c = current {
            if let sv = c as? UIScrollView {
                if sv.panGestureRecognizer !== tapRequiredScrollPan {
                    tap.require(toFail: sv.panGestureRecognizer)
                    tapRequiredScrollPan = sv.panGestureRecognizer
                }
                return
            }
            current = c.superview
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let barY = bounds.height - barHeight
        backgroundLayer.frame = CGRect(x: 0, y: barY, width: bounds.width, height: barHeight)
        // Disable implicit CALayer animation so a frame change during
        // bounds updates (e.g. aspect ratio snap on first metadata
        // load) doesn't cross-fade the gradient through a visible
        // transition.
        let backdropHeight: CGFloat = 18
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdropGradient.frame = CGRect(
            x: 0,
            y: bounds.height - backdropHeight,
            width: bounds.width,
            height: backdropHeight
        )
        CATransaction.commit()
        updateFill()
    }

    private func updateFill() {
        let progress = displayProgress()
        let barY = bounds.height - barHeight
        let fillWidth = bounds.width * CGFloat(progress)
        // Disable implicit CALayer animation so the fill tracks
        // playback continuously without the default 0.25s cross-fade
        // every time the periodic observer ticks (4× per second).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.frame = CGRect(x: 0, y: barY, width: fillWidth, height: barHeight)
        CATransaction.commit()
    }

    private func displayProgress() -> Double {
        if isDragging { return dragProgress }
        guard let player, let item = player.currentItem else { return 0 }
        let duration = item.duration.seconds
        guard duration.isFinite, duration > 0 else { return 0 }
        let current = player.currentTime().seconds
        return min(1, max(0, current / duration))
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        let location = recognizer.location(in: self)
        let progress = max(0, min(1, location.x / bounds.width))
        seekToProgress(progress)
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        let location = recognizer.location(in: self)
        let progress = max(0, min(1, location.x / bounds.width))
        switch recognizer.state {
        case .began:
            isDragging = true
            dragProgress = progress
            updateFill()
        case .changed:
            dragProgress = progress
            updateFill()
        case .ended:
            // `.ended` only follows `.began`/`.changed`, so `isDragging`
            // is always set when we land here. The gate is defensive —
            // belt-and-braces against any future code path that fails
            // the recognizer after `.began` and then somehow surfaces
            // `.ended`. UIKit doesn't fire the action when a continuous
            // recognizer transitions `.possible → .failed`, so the
            // directional pan's vertical-drag self-fail never reaches
            // this switch.
            if isDragging {
                isDragging = false
                seekToProgress(progress)
            }
        case .cancelled, .failed:
            // Mid-drag abort. `.cancelled` is the case that actually
            // fires here — UIKit sends it when an external interruption
            // (incoming call, scroll view claiming the touch, view
            // detachment) yanks a recognized continuous gesture out
            // from under us. `.failed` is bundled for symmetry but
            // does not fire for `.possible → .failed`. Snap the fill
            // back to the player's clock instead of stranding it at
            // the abort point; never seek.
            if isDragging {
                isDragging = false
                updateFill()
            }
        default:
            break
        }
    }

    private func seekToProgress(_ progress: Double) {
        guard let player, let item = player.currentItem else { return }
        let duration = item.duration.seconds
        guard duration.isFinite, duration > 0 else { return }
        // Zero tolerance so the bar lands exactly where the user
        // dragged. Default tolerance can offset the actual seek by
        // ~half a keyframe interval, which is visible as the fill
        // jumping back slightly after touch-up.
        let target = CMTime(seconds: progress * duration, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func installTimeObserver() {
        guard let player else { return }
        // 4 Hz tick is plenty for a 3pt bar — the eye can't resolve
        // sub-quarter-second movement on something that thin. Higher
        // rates (10-30 Hz) wake the main thread for no visual gain.
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] _ in
            guard let self, !self.isDragging else { return }
            self.updateFill()
        }
    }

    private func removeTimeObserverFromPreviousPlayer(_ previous: AVPlayer?) {
        if let token = timeObserverToken, let previous {
            previous.removeTimeObserver(token)
        }
        timeObserverToken = nil
    }
}

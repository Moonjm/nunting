import SwiftUI
import UIKit

/// Bridges to UILabel so the title can use `.lineBreakStrategy = .standard`,
/// which SwiftUI `Text` doesn't expose. SwiftUI's default for Korean text
/// keeps mixed-script tokens like "(gpt-image-2)" glued to the preceding
/// Hangul word, leaving the previous line short. The standard strategy
/// allows breaking between Hangul and adjacent punctuation/Latin tokens.
struct WrappingTitleLabel: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.lineBreakStrategy = .standard
        label.font = .preferredFont(forTextStyle: .headline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }

    func updateUIView(_ label: UILabel, context: Context) {
        if label.text != text {
            label.text = text
            label.invalidateIntrinsicContentSize()
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UILabel,
        context: Context
    ) -> CGSize? {
        let width = proposal.width ?? 0
        guard width > 0 else { return nil }
        let fitted = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        )
        return CGSize(width: width, height: ceil(fitted.height))
    }
}

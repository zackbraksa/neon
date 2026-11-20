import SwiftUI
#if os(iOS)
import UIKit

/// UITextView supplies range selection on iOS; SwiftUI Text selection there
/// can expose only a whole-text copy action on older supported releases.
struct SelectableText: UIViewRepresentable {
    let text: AttributedString
    var heading = false
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        let attributed = NSMutableAttributedString(attributedString: NSAttributedString(text))
        let range = NSRange(location: 0, length: attributed.length)
        let font = UIFont.preferredFont(forTextStyle: heading ? .headline : .body)
        // Fill missing base attributes without removing inline Markdown traits.
        attributed.enumerateAttribute(.font, in: range) { value, subrange, _ in
            if value == nil { attributed.addAttribute(.font, value: font, range: subrange) }
        }
        for run in text.runs {
            guard let intent = run.inlinePresentationIntent else { continue }
            let runRange = NSRange(location: String(text.characters[..<run.range.lowerBound]).utf16.count,
                                   length: String(text.characters[run.range]).utf16.count)
            var traits: UIFontDescriptor.SymbolicTraits = []
            if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
            if intent.contains(.emphasized) { traits.insert(.traitItalic) }
            let styled: UIFont
            if intent.contains(.code) { styled = .monospacedSystemFont(ofSize: font.pointSize, weight: .regular) }
            else if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) { styled = UIFont(descriptor: descriptor, size: 0) }
            else { styled = font }
            attributed.addAttribute(.font, value: styled, range: runRange)
            if intent.contains(.strikethrough) { attributed.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: runRange) }
        }
        attributed.addAttribute(.foregroundColor, value: UIColor.label, range: range)
        if view.attributedText != attributed { view.attributedText = attributed }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }
}
#else
struct SelectableText: View {
    let text: AttributedString
    var heading = false
    var body: some View {
        Text(text).font(heading ? .title3.bold() : ChatAppearance.body).lineSpacing(5).textSelection(.enabled)
    }
}
#endif

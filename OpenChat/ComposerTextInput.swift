import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit

final class ImagePasteTextView: NSTextView {
    var pasteImages: (([NSItemProvider]) -> Void)?
    var send: (() -> Void)?
    var focusChanged: ((Bool) -> Void)?
    var hasContent = false
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { focusChanged?(true) }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { focusChanged?(false) }
        return accepted
    }
    override func paste(_ sender: Any?) {
        let providers = (NSPasteboard.general.pasteboardItems ?? []).compactMap { item -> NSItemProvider? in
            guard let type = item.types.first(where: { UTType($0.rawValue)?.conforms(to: .image) == true }),
                  let data = item.data(forType: type) else { return nil }
            return NSItemProvider(item: data as NSData, typeIdentifier: type.rawValue)
        }
        if !providers.isEmpty { pasteImages?(providers) }
        else { super.paste(sender) }
    }
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), NSPasteboard.general.types?.contains(where: { UTType($0.rawValue)?.conforms(to: .image) == true }) == true {
            return isEditable
        }
        return super.validateUserInterfaceItem(item)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            var modifiers: EventModifiers = []
            if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
            if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
            if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
            if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
            let result = ComposerReturnAction.handle(modifiers: modifiers, composing: hasMarkedText(), hasText: hasContent,
                                                      insertNewline: { self.insertNewline(nil); return true }, send: { self.send?() })
            if result == .handled { return }
        }
        super.keyDown(with: event)
    }
}

struct ComposerTextInput: NSViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let hasContent: Bool
    let pasteImages: ([NSItemProvider]) -> Void
    let send: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let view = ImagePasteTextView()
        view.isRichText = false
        view.importsGraphics = false
        view.drawsBackground = false
        view.textColor = .white
        view.insertionPointColor = .white
        view.font = .systemFont(ofSize: 15)
        view.textContainerInset = NSSize(width: 0, height: 12)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.lineFragmentPadding = 0
        view.delegate = context.coordinator
        view.setAccessibilityLabel("Message")
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? ImagePasteTextView else { return }
        if view.string != text { view.string = text }
        view.pasteImages = pasteImages
        view.send = send
        view.focusChanged = { [weak coordinator = context.coordinator] in coordinator?.parent.focused = $0 }
        view.hasContent = hasContent
        if focused, view.window?.firstResponder !== view {
            DispatchQueue.main.async { if self.focused { view.window?.makeFirstResponder(view) } }
        } else if !focused, view.window?.firstResponder === view {
            DispatchQueue.main.async { if !self.focused { view.window?.makeFirstResponder(nil) } }
        }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let width = proposal.width ?? 300
        let measuredText = text.isEmpty || text.hasSuffix("\n") ? text + " " : text
        let rect = measuredText.boundingRect(with: NSSize(width: max(1, width - 12), height: .greatestFiniteMagnitude),
                                            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: NSFont.systemFont(ofSize: 15)])
        return CGSize(width: width, height: min(150, max(44, ceil(rect.height) + 24)))
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextInput
        init(_ parent: ComposerTextInput) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
        }
    }
}
#else
import UIKit

final class ImagePasteTextView: UITextView {
    var pasteImages: (([NSItemProvider]) -> Void)?
    override func paste(_ sender: Any?) {
        let providers = UIPasteboard.general.itemProviders.filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }
        if !providers.isEmpty { pasteImages?(providers) }
        else { super.paste(sender) }
    }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), UIPasteboard.general.hasImages { return true }
        return super.canPerformAction(action, withSender: sender)
    }
}

struct ComposerTextInput: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let hasContent: Bool
    let pasteImages: ([NSItemProvider]) -> Void
    let send: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> ImagePasteTextView {
        let view = ImagePasteTextView()
        view.backgroundColor = .clear
        view.textColor = .white
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.delegate = context.coordinator
        view.accessibilityLabel = "Message"
        return view
    }
    func updateUIView(_ view: ImagePasteTextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text { view.text = text }
        view.pasteImages = pasteImages
        if focused && !view.isFirstResponder { DispatchQueue.main.async { if self.focused { view.becomeFirstResponder() } } }
        else if !focused && view.isFirstResponder { DispatchQueue.main.async { if !self.focused { view.resignFirstResponder() } } }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ImagePasteTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 300
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: min(150, max(44, size.height)))
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextInput
        init(_ parent: ComposerTextInput) { self.parent = parent }
        func textViewDidChange(_ textView: UITextView) { parent.text = textView.text }
        func textViewDidBeginEditing(_ textView: UITextView) { parent.focused = true }
        func textViewDidEndEditing(_ textView: UITextView) { parent.focused = false }
    }
}
#endif

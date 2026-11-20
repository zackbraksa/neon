#if os(macOS)
import AppKit
import SwiftUI

@MainActor struct MacComposerSubmission: ViewModifier {
    let hasText: Bool
    let send: () -> Void

    func body(content: Content) -> some View {
        content.onKeyPress(.return, phases: .down) { press in
            let composing = (NSApp.keyWindow?.firstResponder as? NSTextInputClient)?.hasMarkedText() ?? false
            return ComposerReturnAction.handle(modifiers: press.modifiers, composing: composing, hasText: hasText,
                                               insertNewline: {
                guard let editor = NSApp.keyWindow?.firstResponder as? NSTextInputClient else { return false }
                editor.insertText("\n", replacementRange: editor.selectedRange())
                return true
            }, send: send)
        }
    }
}

@MainActor enum ComposerReturnAction {
    static func handle(modifiers: EventModifiers, composing: Bool, hasText: Bool,
                       insertNewline: () -> Bool = { false }, send: () -> Void) -> KeyPress.Result {
        guard !composing else { return .ignored }
        let commandModifiers = modifiers.intersection([.shift, .control, .option, .command])
        if commandModifiers == .shift { return insertNewline() ? .handled : .ignored }
        guard commandModifiers.isEmpty else { return .ignored }
        if hasText { send() }
        return .handled
    }
}
#endif

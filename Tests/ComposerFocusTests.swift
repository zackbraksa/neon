import AppKit
import SwiftUI
import XCTest
@testable import OpenChat

@MainActor final class ComposerFocusTests: XCTestCase {
    func testChatComposerKeepsClickedFocusAcrossUpdatesAndTyping() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = try BackendCredentials(address: "https://example.test", token: String(repeating: "t", count: 32))
        let remote = try RemoteChatStore(client: BackendClient(credentials), directory: directory.appendingPathComponent("remote"))
        remote.newChat()
        let id = try XCTUnwrap(remote.selectedID)
        let sessions = FakeBackendSessionStorage()
        let store = ChatStore(direct: DirectChatStore(storageDirectory: directory.appendingPathComponent("direct"), readKey: { "" }),
                              remote: remote, sessions: sessions, push: sessions.pushCoordinator())
        let host = NSHostingView(rootView: ChatView(store: store, id: id, drawerPresented: false,
                                                   openDrawer: {}, openModels: {}, newChat: {}, restored: {}))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close(); remote.suspend() }
        host.layoutSubtreeIfNeeded()
        await settleUpdates()
        let editor = try XCTUnwrap(findEditor(in: host))
        XCTAssertTrue(window.makeFirstResponder(editor))
        await settleUpdates()

        store.update(id) { $0.title = "Updated while the composer is focused" }
        await settleUpdates()
        XCTAssertTrue(window.firstResponder === editor, "A chat update must not remove clicked focus before typing begins")

        let character = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                      windowNumber: window.windowNumber, context: nil, characters: "x",
                                                      charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7))
        window.sendEvent(character)
        await settleUpdates()
        XCTAssertEqual(store.chat(id)?.draft, "x")
        XCTAssertEqual(editor.string, "x")
        XCTAssertTrue(window.firstResponder === editor, "Typing must keep the composer as first responder")

        host.rootView = ChatView(store: store, id: id, drawerPresented: true,
                                 openDrawer: {}, openModels: {}, newChat: {}, restored: {})
        await settleUpdates()
        XCTAssertFalse(window.firstResponder === editor, "Opening the drawer must dismiss composer focus")
    }

    private func findEditor(in view: NSView) -> ImagePasteTextView? {
        if let editor = view as? ImagePasteTextView { return editor }
        return view.subviews.lazy.compactMap { self.findEditor(in: $0) }.first
    }

    private func settleUpdates() async {
        for _ in 0..<3 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }
}

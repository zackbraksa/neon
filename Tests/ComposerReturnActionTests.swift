import SwiftUI
import XCTest
@testable import OpenChat

@MainActor final class ComposerReturnActionTests: XCTestCase {
    func testPlainReturnSendsExactlyOnce() {
        var sends = 0
        let result = ComposerReturnAction.handle(modifiers: [], composing: false, hasText: true) { sends += 1 }
        XCTAssertEqual(result, .handled)
        XCTAssertEqual(sends, 1)
    }

    func testModifiedReturnStaysWithNativeTextAndShortcutHandling() {
        for modifiers: EventModifiers in [.command, .control, .option, [.shift, .command]] {
            var sends = 0
            let result = ComposerReturnAction.handle(modifiers: modifiers, composing: false, hasText: true) { sends += 1 }
            XCTAssertEqual(result, .ignored)
            XCTAssertEqual(sends, 0)
        }
    }

    func testShiftReturnInsertsNativeNewlineWithoutSending() {
        var newlines = 0
        var sends = 0
        let result = ComposerReturnAction.handle(modifiers: .shift, composing: false, hasText: true,
                                                insertNewline: { newlines += 1; return true }) { sends += 1 }
        XCTAssertEqual(result, .handled)
        XCTAssertEqual(newlines, 1)
        XCTAssertEqual(sends, 0)
    }

    func testShiftReturnDuringIMEConfirmationDoesNotInsertOrSend() {
        var newlines = 0
        var sends = 0
        let result = ComposerReturnAction.handle(modifiers: .shift, composing: true, hasText: true,
                                                insertNewline: { newlines += 1; return true }) { sends += 1 }
        XCTAssertEqual(result, .ignored)
        XCTAssertEqual(newlines, 0)
        XCTAssertEqual(sends, 0)
    }

    func testIMEConfirmationDoesNotSend() {
        var sends = 0
        let result = ComposerReturnAction.handle(modifiers: [], composing: true, hasText: true) { sends += 1 }
        XCTAssertEqual(result, .ignored)
        XCTAssertEqual(sends, 0)
    }

    func testEmptyReturnDoesNotSendOrFallThroughToAStopShortcut() {
        var sends = 0
        let result = ComposerReturnAction.handle(modifiers: [], composing: false, hasText: false) { sends += 1 }
        XCTAssertEqual(result, .handled)
        XCTAssertEqual(sends, 0)
    }

    func testCapsLockDoesNotChangePlainReturnBehavior() {
        var sends = 0
        let result = ComposerReturnAction.handle(modifiers: .capsLock, composing: false, hasText: true) { sends += 1 }
        XCTAssertEqual(result, .handled)
        XCTAssertEqual(sends, 1)
    }
}

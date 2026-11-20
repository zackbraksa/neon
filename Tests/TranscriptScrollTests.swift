import XCTest
@testable import OpenChat

final class TranscriptScrollTests: XCTestCase {
    private func metrics(_ offset: CGFloat = 500, content: CGFloat = 1000, viewport: CGFloat = 500, width: CGFloat = 390) -> TranscriptScrollMetrics {
        TranscriptScrollMetrics(offset: offset, contentHeight: content, viewportHeight: viewport, viewportWidth: width)
    }

    func testInitialShortContentAndBottomTolerance() {
        var state = TranscriptScrollState()
        XCTAssertFalse(state.showsArrow)
        XCTAssertTrue(state.receive(metrics(0, content: 200)))
        XCTAssertFalse(state.showsArrow)
        XCTAssertTrue(state.following)
        XCTAssertTrue(metrics(476).isNearBottom)
        XCTAssertFalse(metrics(475).isNearBottom)
    }
    func testMovementAwayPausesAndManualReturnResumes() {
        var state = TranscriptScrollState()
        _ = state.receive(metrics())
        state.interactionBegan()
        XCTAssertFalse(state.receive(metrics(400)))
        XCTAssertFalse(state.following)
        XCTAssertTrue(state.showsArrow)
        XCTAssertFalse(state.receive(metrics(480)))
        XCTAssertTrue(state.following)
        XCTAssertFalse(state.showsArrow)
        XCTAssertFalse(state.interactionEnded())
    }
    func testStationaryTrackingAndHorizontalGestureDoNotPause() {
        var state = TranscriptScrollState()
        _ = state.receive(metrics())
        state.interactionBegan()
        XCTAssertFalse(state.receive(metrics()))
        XCTAssertTrue(state.following)
        XCTAssertFalse(state.receive(metrics(500, content: 1100)))
        XCTAssertTrue(state.following)
        XCTAssertTrue(state.interactionEnded())
    }
    func testGrowthAndViewportChangesFollowOnlyWhenFollowing() {
        var state = TranscriptScrollState()
        _ = state.receive(metrics())
        XCTAssertTrue(state.receive(metrics(500, content: 1100)))
        XCTAssertTrue(state.receive(metrics(500, content: 1100, viewport: 300)))
        XCTAssertTrue(state.following)
        _ = state.receive(metrics(400, content: 1100, viewport: 300))
        XCTAssertFalse(state.following)
        XCTAssertFalse(state.receive(metrics(400, content: 1200, viewport: 300)))
        XCTAssertFalse(state.receive(metrics(400, content: 1200, viewport: 500)))
    }
    func testReflowThatRevealsTheEndResumesFollowing() {
        var state = TranscriptScrollState()
        _ = state.receive(metrics())
        _ = state.receive(metrics(300))
        XCTAssertFalse(state.following)
        XCTAssertTrue(state.receive(metrics(300, content: 700)))
        XCTAssertFalse(state.showsArrow)
        XCTAssertTrue(state.following)
        XCTAssertTrue(state.receive(metrics(300, content: 1000)))
    }
    func testUnexplainedWheelOrKeyboardOffsetPausesWithoutTouchPhase() {
        var state = TranscriptScrollState()
        _ = state.receive(metrics())
        _ = state.receive(metrics(350))
        XCTAssertFalse(state.following)
        _ = state.receive(metrics(500))
        XCTAssertTrue(state.following)
    }
    func testSlowSubpointScrollingAwayDoesNotSnapBack() {
        var state = TranscriptScrollState()
        _ = state.receive(metrics())
        state.interactionBegan()
        for step in 1...120 { _ = state.receive(metrics(500 - CGFloat(step) * 0.25)) }
        XCTAssertFalse(state.following)
        XCTAssertTrue(state.showsArrow)
        XCTAssertFalse(state.interactionEnded())
    }
    func testMovementDuringStreamingGrowthPausesLegacyInference() {
        var state = TranscriptScrollState()
        _ = state.receive(metrics())
        state.requestBottom()
        XCTAssertFalse(state.receive(metrics(450, content: 1020)))
        XCTAssertFalse(state.following)
    }
    func testLegacyMovementAwaySurvivesLazyHeightEstimateShrink() {
        var state = TranscriptScrollState()
        _ = state.receive(metrics(1500, content: 2000))
        state.requestBottom()
        XCTAssertFalse(state.receive(metrics(1300, content: 1900)))
        XCTAssertFalse(state.following)
        XCTAssertTrue(state.showsArrow)
    }
    func testLayoutClampsDoNotCountAsUserScrolling() {
        var state = TranscriptScrollState()
        _ = state.receive(metrics())
        XCTAssertTrue(state.receive(metrics(300, content: 800)))
        XCTAssertTrue(state.following)
        XCTAssertTrue(state.receive(metrics(100, content: 800, viewport: 700)))
        XCTAssertTrue(state.following)
    }
    func testProgrammaticBottomMovementKeepsFollowing() {
        var state = TranscriptScrollState()
        _ = state.receive(metrics())
        _ = state.receive(metrics(300))
        state.requestBottom()
        _ = state.receive(metrics(400))
        XCTAssertTrue(state.following)
        _ = state.receive(metrics(500))
        XCTAssertTrue(state.following)
    }
    func testRepeatedExplicitRequestsAndResetRestoreFollowing() {
        var state = TranscriptScrollState()
        _ = state.receive(metrics())
        _ = state.receive(metrics(200))
        state.requestBottom()
        XCTAssertTrue(state.following)
        state.requestBottom()
        state.interactionBegan()
        state = TranscriptScrollState()
        XCTAssertTrue(state.following)
        XCTAssertFalse(state.showsArrow)
        XCTAssertFalse(state.interacting)
    }
}

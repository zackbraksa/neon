import Foundation

struct TranscriptScrollMetrics: Equatable {
    let offset: CGFloat
    let contentHeight: CGFloat
    let viewportHeight: CGFloat
    var viewportWidth: CGFloat = 0

    var distanceFromBottom: CGFloat { max(0, contentHeight - viewportHeight - offset) }
    var isNearBottom: Bool { distanceFromBottom <= 24 }

    func layoutMatches(_ other: Self) -> Bool {
        abs(contentHeight - other.contentHeight) < 0.5
            && viewportMatches(other)
    }
    func viewportMatches(_ other: Self) -> Bool {
        abs(viewportHeight - other.viewportHeight) < 0.5
            && abs(viewportWidth - other.viewportWidth) < 0.5
    }
}

struct TranscriptScrollState {
    private(set) var following = true
    private(set) var interacting = false
    private(set) var metrics: TranscriptScrollMetrics?
    var showsArrow: Bool { metrics.map { !$0.isNearBottom } ?? false }

    mutating func receive(_ next: TranscriptScrollMetrics) -> Bool {
        let previous = metrics
        metrics = next
        if let previous, next.viewportMatches(previous) {
            let clampedPreviousOffset = min(previous.offset, max(0, next.contentHeight - next.viewportHeight))
            let movement = next.offset - clampedPreviousOffset
            if movement < -0.01 && !next.isNearBottom {
                following = false
            }
        }
        if next.isNearBottom {
            following = true
        }
        let layoutChanged = previous.map { !next.layoutMatches($0) } ?? true
        return following && !interacting && layoutChanged
    }

    mutating func interactionBegan() {
        interacting = true
    }
    mutating func interactionEnded() -> Bool {
        interacting = false
        return following && showsArrow
    }
    mutating func requestBottom() {
        following = true
    }
}

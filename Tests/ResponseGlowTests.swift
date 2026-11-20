import XCTest
@testable import OpenChat

final class ResponseGlowTests: XCTestCase {
    private let chat = UUID()
    private let job = UUID()
    private func input(active: UUID?, text: String = "", status: Message.Status = .streaming,
                       responseJob: UUID? = nil, conversation: UUID? = nil) -> ResponseGlowInput {
        ResponseGlowInput(conversationID: conversation ?? chat, activeJobID: active,
                          messages: [Message(role: .assistant, content: text, status: status, jobID: responseJob ?? job)])
    }

    func testLightPulseRhythmAndDepth() {
        let thinkingLow = ResponseGlowLight.values(at: 0, gathering: 1, flowing: 0, completion: 0)
        let thinkingHigh = ResponseGlowLight.values(at: 1.8, gathering: 1, flowing: 0, completion: 0)
        let thinkingRepeat = ResponseGlowLight.values(at: 3.6, gathering: 1, flowing: 0, completion: 0)
        let generatingLow = ResponseGlowLight.values(at: 0, gathering: 0, flowing: 1, completion: 0)
        let generatingHigh = ResponseGlowLight.values(at: 0.9, gathering: 0, flowing: 1, completion: 0)
        let generatingRepeat = ResponseGlowLight.values(at: 1.8, gathering: 0, flowing: 1, completion: 0)
        XCTAssertEqual(thinkingLow.coreOpacity, thinkingRepeat.coreOpacity, accuracy: 0.000001)
        XCTAssertEqual(generatingLow.coreOpacity, generatingRepeat.coreOpacity, accuracy: 0.000001)
        XCTAssertGreaterThan(thinkingHigh.coreOpacity - thinkingLow.coreOpacity,
                             generatingHigh.coreOpacity - generatingLow.coreOpacity)
        XCTAssertLessThan(thinkingHigh.expansion, 1.02)
        XCTAssertLessThan(generatingHigh.expansion, 1.02)
        XCTAssertGreaterThan(generatingHigh.radius, generatingLow.radius)
    }

    func testReducedMotionLightIsSteadyAndCompletionDoesNotExpand() {
        for phase in [ResponseGlowEnvelope.Values(), .init(gathering: 1), .init(flowing: 1)] {
            let first = ResponseGlowLight.values(at: 0, gathering: phase.gathering, flowing: phase.flowing,
                                                 completion: 0, animated: false)
            let later = ResponseGlowLight.values(at: 1.8, gathering: phase.gathering, flowing: phase.flowing,
                                                 completion: 1, animated: false)
            XCTAssertEqual(first.coreOpacity, later.coreOpacity)
            XCTAssertEqual(first.haloOpacity, later.haloOpacity)
            XCTAssertEqual(first.expansion, 1)
            XCTAssertEqual(later.expansion, 1)
            XCTAssertEqual(first.radius, later.radius)
        }
    }

    func testMatchingVisibleOutputOnly() {
        var state = ResponseGlowState()
        state.update(input(active: job, text: "old answer", responseJob: UUID()), at: 0)
        XCTAssertEqual(state.phase, .gathering)
        state.update(input(active: job, text: " \n\t"), at: 1)
        XCTAssertEqual(state.phase, .gathering)
        state.update(input(active: job, text: "Hello"), at: 2)
        XCTAssertEqual(state.phase, .flowing)
    }

    func testCompletionOccursOnceOnlyAfterObservedLiveJob() {
        var state = ResponseGlowState()
        state.update(input(active: nil, text: "history", status: .complete), at: 0)
        XCTAssertEqual(state.phase, .idle)
        state.update(input(active: job), at: 1)
        state.update(input(active: nil, text: "answer", status: .complete), at: 2)
        XCTAssertEqual(state.phase, .finishing)
        XCTAssertEqual(state.finishTime, 2)
        state.update(input(active: nil, text: "answer", status: .complete), at: 3)
        XCTAssertEqual(state.finishTime, 2)
    }

    func testStopFailureAndMissingResponseDoNotCelebrate() {
        for status in [Message.Status.stopped, .failed, .streaming] {
            var state = ResponseGlowState()
            state.update(input(active: nil), at: -1)
            state.update(input(active: job), at: 0)
            state.update(input(active: nil, status: status), at: 1)
            XCTAssertEqual(state.phase, .idle)
            XCTAssertNil(state.finishTime)
        }
        var state = ResponseGlowState()
        state.update(input(active: job), at: 0)
        state.update(ResponseGlowInput(conversationID: chat), at: 1)
        XCTAssertEqual(state.phase, .idle)
    }

    func testNewJobAndConversationCancelCompletion() {
        var state = ResponseGlowState()
        state.update(input(active: nil), at: -1)
        state.update(input(active: job), at: 0)
        state.update(input(active: nil, status: .complete), at: 1)
        state.update(input(active: UUID(), text: "old", status: .complete), at: 1)
        XCTAssertEqual(state.phase, .gathering)
        XCTAssertNil(state.finishTime)
        state.update(input(active: nil, status: .complete, conversation: UUID()), at: 2)
        XCTAssertEqual(state.phase, .idle)
        XCTAssertNil(state.finishTime)
    }

    func testEnergyCoalescesAndNeverPulsesForDuplicatesOrShrink() {
        var state = ResponseGlowState()
        state.update(input(active: nil), at: -1)
        state.update(input(active: job, text: "Hello"), at: 0)
        state.update(input(active: job, text: "Hello world"), at: 0.1)
        XCTAssertEqual(state.energyTime, 0)
        state.update(input(active: job, text: "Hello world!"), at: 0.25)
        XCTAssertEqual(state.energyTime, 0.25)
        let energy = state.energy
        state.update(input(active: job, text: "Hello world!"), at: 1)
        state.update(input(active: job, text: "Hi"), at: 2)
        XCTAssertEqual(state.energyTime, 0.25)
        XCTAssertEqual(state.energy, energy)
        XCTAssertLessThanOrEqual(state.outputEnergy(at: 0.5), 1)
    }

    func testEnergyAndPhaseTransitionsAreContinuous() {
        var state = ResponseGlowState()
        state.update(input(active: nil), at: -1)
        state.update(input(active: job, text: "Hello"), at: 0)
        let before = state.outputEnergy(at: 0.3)
        state.update(input(active: job, text: String(repeating: "x", count: 100)), at: 0.3)
        XCTAssertEqual(state.outputEnergy(at: 0.3), before, accuracy: 0.000001)
        var envelope = ResponseGlowEnvelope()
        envelope.transition(to: .gathering, at: 0)
        let current = envelope.values(at: 0.4)
        envelope.transition(to: .flowing, at: 0.4)
        XCTAssertEqual(envelope.values(at: 0.4).gathering, current.gathering)
        XCTAssertEqual(envelope.values(at: 0.4).flowing, 0)
        XCTAssertGreaterThan(envelope.values(at: 1.4).flowing, 0.95)
    }

    func testReopenedLiveJobRequiresNewProgressBeforeCelebrating() {
        var state = ResponseGlowState()
        state.update(input(active: job, text: "cached"), at: 0)
        XCTAssertNil(state.energyTime)
        state.update(input(active: nil, text: "cached", status: .complete), at: 1)
        XCTAssertEqual(state.phase, .idle)
        state = ResponseGlowState()
        state.update(input(active: job, text: "cached"), at: 0)
        state.update(input(active: job, text: "cached new output"), at: 1)
        state.update(input(active: nil, text: "cached new output", status: .complete), at: 2)
        XCTAssertEqual(state.phase, .finishing)
    }

    func testNewJobSmoothlyCancelsFinish() {
        var state = ResponseGlowState()
        state.update(input(active: nil), at: 0)
        state.update(input(active: job), at: 1)
        state.update(input(active: nil, status: .complete), at: 2)
        let swell = state.completionStrength(at: 3)
        state.update(input(active: UUID()), at: 3)
        XCTAssertEqual(state.phase, .gathering)
        XCTAssertEqual(state.completionStrength(at: 3), swell, accuracy: 0.000001)
        XCTAssertLessThan(state.completionStrength(at: 4), swell * 0.05)
    }

    func testEnergyDecaysContinuouslyOnTerminalAndJobHandoff() {
        for status in [Message.Status.complete, .stopped, .failed] {
            var state = ResponseGlowState()
            state.update(input(active: nil), at: 0)
            state.update(input(active: job, text: String(repeating: "x", count: 100)), at: 1)
            let current = state.outputEnergy(at: 1.3)
            state.update(input(active: nil, status: status), at: 1.3)
            XCTAssertEqual(state.outputEnergy(at: 1.3), current, accuracy: 0.000001)
            XCTAssertLessThan(state.outputEnergy(at: 3.4), current * 0.06)
        }
        var state = ResponseGlowState()
        state.update(input(active: nil), at: 0)
        state.update(input(active: job, text: String(repeating: "x", count: 100)), at: 1)
        let current = state.outputEnergy(at: 1.3)
        state.update(input(active: UUID()), at: 1.3)
        XCTAssertEqual(state.outputEnergy(at: 1.3), current, accuracy: 0.000001)
        XCTAssertLessThan(state.outputEnergy(at: 3.4), current * 0.06)
    }

    func testCompletionRetainsOutgoingWidthUntilOutwardPeak() {
        var state = ResponseGlowState()
        var envelope = ResponseGlowEnvelope()
        state.update(input(active: nil), at: 0)
        state.update(input(active: job, text: "answer"), at: 1)
        envelope.transition(to: .flowing, at: 1)
        state.update(input(active: nil, text: "answer", status: .complete), at: 3)
        let outgoing = envelope.values(at: 3)
        envelope.transition(to: .finishing, at: 3)
        XCTAssertEqual(envelope.values(at: 3).flowing, outgoing.flowing)
        var previousWidth = 1 + outgoing.flowing * 0.28
        for step in 1...12 {
            let time = 3 + Double(step) / 10
            let values = envelope.values(at: time)
            let width = 1 - values.gathering * 0.38 + values.flowing * 0.28 + state.completionStrength(at: time) * 0.14
            XCTAssertGreaterThanOrEqual(width, previousWidth - 0.000001)
            previousWidth = width
        }
        XCTAssertEqual(envelope.values(at: 5.4).flowing, 0, accuracy: 0.000001)
        let current = envelope.values(at: 4.5)
        envelope.transition(to: .gathering, at: 4.5)
        XCTAssertEqual(envelope.values(at: 4.5).flowing, current.flowing)
    }

    func testInactiveOrReducedMotionClearsCompletionEligibility() {
        do {
            var state = ResponseGlowState()
            state.update(input(active: nil), at: -1)
            state.update(input(active: job), at: 0)
            state.update(input(active: job), at: 1, enabled: false)
            state.update(input(active: nil, text: "finished while inactive", status: .complete), at: 2)
            XCTAssertEqual(state.phase, .idle)
            XCTAssertNil(state.finishTime)
        }
    }
}

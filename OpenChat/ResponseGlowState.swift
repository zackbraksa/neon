import Foundation

struct ResponseGlowInput: Equatable {
    struct Response: Equatable {
        let jobID: UUID
        let status: Message.Status
        let hasVisibleText: Bool
        let length: Int
    }
    var conversationID: UUID?
    var activeJobID: UUID?
    var responses: [Response] = []

    init(conversationID: UUID? = nil, activeJobID: UUID? = nil, messages: [Message] = []) {
        self.conversationID = conversationID
        self.activeJobID = activeJobID
        responses = messages.compactMap { message in
            guard message.role == .assistant, let jobID = message.jobID else { return nil }
            return Response(jobID: jobID, status: message.status,
                            hasVisibleText: !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                            length: message.content.utf16.count)
        }
    }
}

struct ResponseGlowState {
    enum Phase: Equatable { case idle, gathering, flowing, finishing }
    private(set) var phase: Phase = .idle
    private(set) var jobID: UUID?
    private(set) var finishTime: TimeInterval?
    private(set) var energyTime: TimeInterval?
    private(set) var energy = 0.0
    private var energyBase = 0.0
    private var conversationID: UUID?
    private var highWater = 0
    private var pendingGrowth = 0
    private var seeded = false
    private var eligible = false
    private var cancelledFinish = 0.0
    private var cancelledAt = 0.0

    mutating func update(_ input: ResponseGlowInput, at time: TimeInterval, enabled: Bool = true) {
        guard enabled else { self = Self(); return }
        if conversationID != input.conversationID {
            self = Self()
            conversationID = input.conversationID
        }
        let wasSeeded = seeded
        seeded = true
        if let active = input.activeJobID {
            let response = input.responses.last { $0.jobID == active }
            if jobID != active {
                cancelledFinish = completionStrength(at: time)
                cancelledAt = time
                jobID = active
                eligible = wasSeeded
                highWater = wasSeeded ? 0 : response?.length ?? 0
                pendingGrowth = 0
                decayEnergy(at: time)
                finishTime = nil
            }
            phase = response?.hasVisibleText == true ? .flowing : .gathering
            if let response, response.hasVisibleText, response.length > highWater {
                eligible = true
                pendingGrowth += response.length - highWater
                highWater = response.length
                if energyTime == nil || time - energyTime! >= 0.25 {
                    energyBase = outputEnergy(at: time)
                    energy = min(1 - energyBase, Double(pendingGrowth) / 100)
                    energyTime = time
                    pendingGrowth = 0
                }
            }
        } else if let previous = jobID {
            let response = input.responses.last { $0.jobID == previous }
            phase = eligible && response?.status == .complete ? .finishing : .idle
            finishTime = phase == .finishing ? time : nil
            jobID = nil
            pendingGrowth = 0
            decayEnergy(at: time)
        }
    }

    private mutating func decayEnergy(at time: TimeInterval) {
        energyBase = outputEnergy(at: time)
        energy = 0
        energyTime = energyBase > 0 ? time : nil
    }

    func completionStrength(at time: TimeInterval) -> Double {
        if let finishTime {
            let age = time - finishTime
            return age >= 0 && age < 2.4 ? pow(sin(.pi * age / 2.4), 2) : 0
        }
        return cancelledFinish * exp(-max(0, time - cancelledAt) / 0.3)
    }

    func outputEnergy(at time: TimeInterval) -> Double {
        guard let energyTime else { return 0 }
        let age = max(0, time - energyTime)
        return energyBase * exp(-age / 0.7)
            + energy * (1 - exp(-age / 0.12)) * exp(-age / 0.7)
    }
}

struct ResponseGlowEnvelope {
    struct Values {
        var gathering = 0.0
        var flowing = 0.0
    }
    private var from = Values()
    private var target = Values()
    private var changedAt = 0.0
    private var phase: ResponseGlowState.Phase = .idle
    private var releaseAt: TimeInterval?

    func values(at time: TimeInterval) -> Values {
        if let releaseAt {
            let progress = min(1, max(0, (time - releaseAt - 1.2) / 1.2))
            let retention = 1 - progress * progress * (3 - 2 * progress)
            return Values(gathering: from.gathering * retention, flowing: from.flowing * retention)
        }
        let blend = 1 - exp(-max(0, time - changedAt) / 0.3)
        return Values(gathering: from.gathering + (target.gathering - from.gathering) * blend,
                      flowing: from.flowing + (target.flowing - from.flowing) * blend)
    }
    mutating func transition(to phase: ResponseGlowState.Phase, at time: TimeInterval) {
        guard phase != self.phase else { return }
        from = values(at: time)
        self.phase = phase
        releaseAt = phase == .finishing ? time : nil
        let next = Values(gathering: phase == .gathering ? 1 : 0, flowing: phase == .flowing ? 1 : 0)
        target = next
        changedAt = time
    }
}

struct ResponseGlowLight {
    struct Values {
        let coreOpacity: Double
        let shadeOpacity: Double
        let haloOpacity: Double
        let expansion: Double
        let radius: Double
    }

    static func values(at time: TimeInterval, gathering: Double, flowing: Double,
                       completion: Double, animated: Bool = true) -> Values {
        let thinking = animated ? (1 - cos(time * 2 * .pi / 3.6)) / 2 : 0.5
        let generating = animated ? (1 - cos(time * 2 * .pi / 1.8)) / 2 : 0.5
        let bloom = animated ? completion : 0
        return Values(
            coreOpacity: 0.62 + gathering * (-0.18 + 0.46 * thinking)
                + flowing * (-0.02 + 0.18 * generating) + bloom * 0.16,
            shadeOpacity: 0.42 + gathering * (-0.08 + 0.16 * thinking)
                + flowing * (0.02 + 0.08 * generating) + bloom * 0.08,
            haloOpacity: 0.32 + gathering * (-0.12 + 0.22 * thinking)
                + flowing * (-0.02 + 0.14 * generating) + bloom * 0.10,
            expansion: 1 + (animated ? gathering * 0.018 * thinking + flowing * 0.01 * generating : 0)
                + bloom * 0.035,
            radius: 0.55 + (animated ? flowing * 0.06 * generating : 0))
    }
}

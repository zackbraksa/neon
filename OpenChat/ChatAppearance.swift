import SwiftUI

enum ChatAppearance {
    #if os(macOS)
    static let body = Font.system(size: 15)
    static let subheadline = Font.system(size: 14)
    static let headline = Font.system(size: 16, weight: .semibold)
    static let caption = Font.system(size: 12)
    static let caption2 = Font.system(size: 12)
    static let greeting = Font.system(size: 32)
    static let code = Font.system(size: 14, design: .monospaced)
    #else
    static let body = Font.body
    static let subheadline = Font.subheadline
    static let headline = Font.headline
    static let caption = Font.caption
    static let caption2 = Font.caption2
    static let greeting = Font.largeTitle
    static let code = Font.system(.callout, design: .monospaced)
    #endif
    static let canvas = Color.black
    static let surface = Color(white: 0.105)
    static let selected = Color(white: 0.095)
    static let accent = Color(red: 180.0 / 255, green: 1, blue: 53.0 / 255)
    static let accentShade = Color(red: 0.30, green: 0.78, blue: 0.04)
    static let muted = Color(white: 0.62)
    static func modelName(_ id: String, catalogName: String? = nil) -> String {
        if id.isEmpty { return "Choose model" }
        if Ollama.isModel(id) { return String(id.dropFirst(Ollama.modelPrefix.count)) }
        if id == "openrouter/auto" { return "Auto" }
        if let catalogName, !catalogName.isEmpty {
            return catalogName.split(separator: ":", maxSplits: 1).last
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? catalogName
        }
        let name = id.split(separator: "/").last.map(String.init) ?? id
        return name.split(separator: "-").map { word in
            if word.lowercased() == "gpt" { return "GPT" }
            return word.prefix(1).uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }
    static func initials(_ name: String) -> String {
        let letters = name.split(whereSeparator: \.isWhitespace).prefix(2).compactMap(\.first)
        return letters.isEmpty ? "O" : String(letters).uppercased()
    }
}

struct ChatBackdrop: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    var response = ResponseGlowInput()
    @State private var state = ResponseGlowState()
    @State private var envelope = ResponseGlowEnvelope()
    @State private var elapsed = 0.0
    @State private var resumedAt: Date?

    private var staticPhase: ResponseGlowEnvelope.Values {
        guard let job = response.activeJobID else { return .init() }
        let hasText = response.responses.last { $0.jobID == job }?.hasVisibleText == true
        return .init(gathering: hasText ? 0 : 1, flowing: hasText ? 1 : 0)
    }

    private func activeTime(_ date: Date) -> TimeInterval {
        elapsed + (resumedAt.map { max(0, date.timeIntervalSince($0)) } ?? 0)
    }
    private func receive() {
        let time = activeTime(Date())
        state.update(response, at: time, enabled: !reduceMotion && scenePhase == .active)
        envelope.transition(to: state.phase, at: time)
    }
    var body: some View {
        ZStack {
            ChatAppearance.canvas
            TimelineView(.animation(minimumInterval: 1.0 / 30,
                                    paused: reduceMotion || scenePhase != .active)) { context in
                let time = reduceMotion ? 0 : activeTime(context.date)
                let values = reduceMotion ? staticPhase : envelope.values(at: time)
                let swell = reduceMotion ? 0 : state.completionStrength(at: time)
                ChatGlowField(time: time, gathering: values.gathering, flowing: values.flowing,
                              swell: swell, pulsesEnabled: !reduceMotion)
            }
        }
        .onAppear {
            if scenePhase == .active && !reduceMotion { resumedAt = Date() }
            receive()
        }
        .onChange(of: response) { receive() }
        .onChange(of: scenePhase) {
            let now = Date()
            elapsed = activeTime(now)
            resumedAt = scenePhase == .active && !reduceMotion ? now : nil
            state = ResponseGlowState()
            envelope = ResponseGlowEnvelope()
            receive()
        }
        .onChange(of: reduceMotion) {
            let now = Date()
            elapsed = activeTime(now)
            resumedAt = scenePhase == .active && !reduceMotion ? now : nil
            state = ResponseGlowState()
            envelope = ResponseGlowEnvelope()
            receive()
        }
        .ignoresSafeArea(.container)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct ChatGlowField: View {
    let time: TimeInterval
    let gathering: Double
    let flowing: Double
    let swell: Double
    let pulsesEnabled: Bool
    var body: some View {
        GeometryReader { geometry in
            let extent = max(geometry.size.width, geometry.size.height)
            let width = min(extent * 0.95, geometry.size.width * 1.5)
            let height = extent * 0.85
            let light = ResponseGlowLight.values(at: time, gathering: gathering, flowing: flowing,
                                                completion: swell, animated: pulsesEnabled)
            let drift = 0.05 * sin(time * 0.19) + 0.025 * sin(time * 0.311)
            let scale = 0.88 + 0.025 * sin(time * 0.29)
            let shapeTime = time * 0.35
            ZStack {
                ChatGlowBlob(time: shapeTime + 17)
                    .fill(Color(red: 0.18, green: 0.70, blue: 0.05).opacity(light.haloOpacity))
                    .blur(radius: extent * 0.075)
                    .scaleEffect(x: 1.18, y: 0.9)
                    .offset(x: -width * 0.18, y: height * 0.08)
                ChatGlowBlob(time: shapeTime)
                    .fill(RadialGradient(stops: [
                        .init(color: ChatAppearance.accent.opacity(light.coreOpacity), location: 0),
                        .init(color: ChatAppearance.accentShade.opacity(light.shadeOpacity), location: 0.58),
                        .init(color: Color(red: 0.08, green: 0.45, blue: 0.02).opacity(0.15), location: 1)
                    ], center: .center, startRadius: 0, endRadius: width * light.radius))
                    .blur(radius: extent * 0.035)
            }
            .frame(width: width, height: height)
            .scaleEffect(x: scale * light.expansion,
                         y: (0.93 + 0.025 * cos(time * 0.337)) * light.expansion)
            .rotationEffect(.degrees(4 * sin(time * 0.157)))
            .position(x: geometry.size.width * (0.79 + drift),
                      y: geometry.size.height * 1.0)
        }
        .clipped()
    }
}

private struct ChatGlowBlob: Shape {
    let time: TimeInterval
    var fold: Double = 0

    func path(in rect: CGRect) -> Path {
        let count = 12
        let points = (0..<count).map { index in
            let angle = Double(index) * 2 * .pi / Double(count)
            let radius = 0.39 + 0.08 * sin(3 * angle + time * 0.41)
                + 0.065 * sin(2 * angle - time * 0.283)
                + 0.035 * cos(5 * angle + time * 0.173)
                + fold * 0.065 * sin(3 * angle - time * 0.67)
            return CGPoint(x: rect.midX + cos(angle) * radius * rect.width,
                           y: rect.midY + sin(angle) * radius * rect.height)
        }
        var path = Path()
        path.move(to: points[0])
        for index in 0..<count {
            let previous = points[(index + count - 1) % count]
            let current = points[index]
            let next = points[(index + 1) % count]
            let following = points[(index + 2) % count]
            path.addCurve(to: next,
                          control1: CGPoint(x: current.x + (next.x - previous.x) / 6,
                                            y: current.y + (next.y - previous.y) / 6),
                          control2: CGPoint(x: next.x - (following.x - current.x) / 6,
                                            y: next.y - (following.y - current.y) / 6))
        }
        path.closeSubpath()
        return path
    }
}

struct ChatRoundButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 19, weight: .regular))
            .frame(width: 44, height: 44)
            .foregroundStyle(prominent ? ChatAppearance.canvas : Color(white: 0.86))
            .background(prominent ? ChatAppearance.accent : Color.white.opacity(0.085), in: .circle)
            .overlay { Circle().strokeBorder(.white.opacity(0.07), lineWidth: 1) }
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(.circle)
    }
}
struct ChatProfileBadge: View {
    let name: String
    var body: some View {
        Text(ChatAppearance.initials(name))
            .font(ChatAppearance.subheadline.weight(.semibold))
            .foregroundStyle(ChatAppearance.canvas)
            .frame(width: 34, height: 34)
            .background(LinearGradient(colors: [ChatAppearance.accent, ChatAppearance.accentShade], startPoint: .topLeading, endPoint: .bottomTrailing), in: .circle)
            .overlay { Circle().strokeBorder(.white.opacity(0.15), lineWidth: 1) }
            .accessibilityHidden(true)
    }
}
struct ChatBrandMark: View {
    var size: CGFloat = 38
    var body: some View {
        Image(systemName: "sparkles")
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(LinearGradient(colors: [ChatAppearance.accent, ChatAppearance.accentShade, ChatAppearance.accent], startPoint: .topLeading, endPoint: .bottomTrailing))
            .accessibilityHidden(true)
    }
}

struct WelcomeBrandMark: View {
    var body: some View {
        Image("WelcomeBrandMark")
            .renderingMode(.original)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: 64, height: 64)
            .accessibilityHidden(true)
    }
}

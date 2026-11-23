import SwiftUI

struct TranscriptScrollView<Content: View>: View {
    let bottomRequest: Int
    @ViewBuilder let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scroll = TranscriptScrollState()
    @Namespace private var coordinateSpace
    private let bottomID = "transcript-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            observedScroll(proxy: proxy)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: bottomRequest) { requestBottom(proxy, animated: false) }
                .overlay(alignment: .bottomTrailing) {
                    if scroll.showsArrow {
                        Button { requestBottom(proxy, animated: true) } label: { Image(systemName: "arrow.down") }
                            .buttonStyle(ChatRoundButtonStyle()).padding(16)
                            .accessibilityLabel("Go to latest response")
                    }
                }

        }
    }

    @ViewBuilder private func observedScroll(proxy: ScrollViewProxy) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            scrollContent
                .onScrollGeometryChange(for: TranscriptScrollMetrics.self) { geometry in
                    TranscriptScrollMetrics(offset: geometry.contentOffset.y + geometry.contentInsets.top,
                                            contentHeight: geometry.contentSize.height + geometry.contentInsets.top,
                                            viewportHeight: geometry.containerSize.height,
                                            viewportWidth: geometry.containerSize.width)
                } action: { _, next in
                    if scroll.receive(next) { scrollToBottom(proxy, animated: false) }
                }
                .onScrollPhaseChange { _, phase in
                    switch phase {
                    case .tracking, .interacting, .decelerating: scroll.interactionBegan()
                    case .idle:
                        if scroll.interactionEnded() { scrollToBottom(proxy, animated: false) }
                    default: break
                    }
                }
        } else {
            scrollContent
                .coordinateSpace(name: coordinateSpace)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: TranscriptLegacyPreference.self, value: TranscriptLegacyGeometry(viewport: geometry.size))
                    }
                }
                .onPreferenceChange(TranscriptLegacyPreference.self) { geometry in
                    guard let viewport = geometry.viewport, let frame = geometry.contentFrame,
                          viewport.height > 0, frame.height > 0 else { return }
                    let next = TranscriptScrollMetrics(offset: -frame.minY, contentHeight: frame.height,
                                                       viewportHeight: viewport.height, viewportWidth: viewport.width)
                    if scroll.receive(next) { scrollToBottom(proxy, animated: false) }
                }
                .simultaneousGesture(DragGesture(minimumDistance: 6).onChanged { value in
                    if abs(value.translation.height) > abs(value.translation.width) { scroll.interactionBegan() }
                }.onEnded { _ in
                    if scroll.interacting && scroll.interactionEnded() { scrollToBottom(proxy, animated: false) }
                })
        }
    }

    private var scrollContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                content
                Color.clear.frame(height: 25).id(bottomID)
            }
            .frame(maxWidth: 780).padding(.horizontal, 24).padding(.top, 12).frame(maxWidth: .infinity)
            .background {
                if #unavailable(iOS 18.0, macOS 15.0) {
                    GeometryReader { geometry in
                        Color.clear.preference(key: TranscriptLegacyPreference.self, value: TranscriptLegacyGeometry(contentFrame: geometry.frame(in: .named(coordinateSpace))))
                    }
                }
            }
        }
    }

    private func requestBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        scroll.requestBottom()
        scrollToBottom(proxy, animated: animated)
    }
    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        guard !scroll.interacting else { return }
        if animated && !reduceMotion {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(bottomID, anchor: .bottom) }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { proxy.scrollTo(bottomID, anchor: .bottom) }
        }
    }
}

private struct TranscriptLegacyGeometry: Equatable {
    var viewport: CGSize?
    var contentFrame: CGRect?
}
private struct TranscriptLegacyPreference: PreferenceKey {
    static var defaultValue = TranscriptLegacyGeometry()
    static func reduce(value: inout TranscriptLegacyGeometry, nextValue: () -> TranscriptLegacyGeometry) {
        let next = nextValue()
        if let viewport = next.viewport { value.viewport = viewport }
        if let frame = next.contentFrame { value.contentFrame = frame }
    }
}

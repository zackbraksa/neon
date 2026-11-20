import SwiftUI

struct MessageView: View {
    let message: Message
    let edit: () -> Void
    let remove: () -> Void
    var summarize: (() -> Void)? = nil
    var readOnly = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var expanded = false
    @State private var copyReceipt: UUID?
    private var isUser: Bool { message.role == .user }
    private var canCollapse: Bool { message.content.count > 280 || message.content.components(separatedBy: "\n").count > 6 }
    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 3) {
            if isUser {
                HStack {
                    Spacer(minLength: 26)
                    VStack(alignment: .leading, spacing: 10) {
                        if message.status != .complete {
                            Text(message.status.rawValue.capitalized).font(ChatAppearance.caption).foregroundStyle(ChatAppearance.accent)
                        }
                        if let images = message.images, !images.isEmpty { AttachedImages(images: images) }
                        if !message.content.isEmpty {
                            Text(message.content).font(ChatAppearance.body).lineSpacing(4).textSelection(.enabled)
                                .lineLimit(canCollapse && !expanded ? 5 : nil)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if canCollapse {
                            Button { expanded.toggle() } label: {
                                HStack { Spacer(); Image(systemName: expanded ? "chevron.up" : "chevron.down").font(ChatAppearance.caption).frame(width: 32, height: 28) }
                            }.buttonStyle(.plain).foregroundStyle(ChatAppearance.muted)
                                .accessibilityLabel(expanded ? "Collapse message" : "Expand message")
                        }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 18)
                    .background(Color(red: 0.075, green: 0.09, blue: 0.12).opacity(0.9), in: .rect(cornerRadius: 28))
                }
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    if message.content.isEmpty && message.status == .streaming {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small).tint(ChatAppearance.accent)
                            Text("Thinking…").font(ChatAppearance.subheadline).foregroundStyle(ChatAppearance.muted)
                        }.padding(.vertical, 12).accessibilityLabel("Waiting for the response")
                    } else {
                        if message.status == .stopped { Text("Stopped").font(ChatAppearance.caption).foregroundStyle(ChatAppearance.muted) }
                        if !message.content.isEmpty { MarkdownBody(content: message.content, streaming: message.status == .streaming) }
                        else if message.status == .failed && message.failure == nil {
                            Text("Response interrupted.").font(ChatAppearance.subheadline).foregroundStyle(ChatAppearance.muted)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let failure = message.failure {
                Text(failure).font(ChatAppearance.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
            }
            if !message.content.isEmpty || !(message.images ?? []).isEmpty { actions }
            if !isUser, let caption = message.responseMetadata.caption {
                Text(caption).font(ChatAppearance.caption2).foregroundStyle(ChatAppearance.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(message.responseMetadata.breakdown)
                    .accessibilityLabel(message.responseMetadata.breakdown)
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .task(id: copyReceipt) {
            guard let receipt = copyReceipt else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            if copyReceipt == receipt { copyReceipt = nil }
        }
        .onDisappear { copyReceipt = nil }
    }
    private var actions: some View {
        HStack(spacing: 0) {
            if isUser { Spacer() }
            if !message.content.isEmpty {
            Button {
                Clipboard.copy(message.content)
                copyReceipt = UUID()
            } label: {
                Image(systemName: copyReceipt == nil ? "doc.on.doc" : "checkmark")
                    .foregroundStyle(copyReceipt == nil ? ChatAppearance.muted : ChatAppearance.accent)
                    .frame(width: 18, height: 18)
                    .frame(width: 44, height: 44).contentShape(.rect)
            }
                .accessibilityLabel(isUser ? "Copy message" : "Copy response")
                .accessibilityValue(copyReceipt == nil ? "" : "Copied")
                .help(copyReceipt == nil ? (isUser ? "Copy message" : "Copy response") : "Copied")
            }
            if !readOnly, !isUser, message.status == .complete,
               !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let summarize {
                Button(action: summarize) {
                    Image(systemName: "text.alignleft")
                        .foregroundStyle(ChatAppearance.muted)
                        .frame(width: 18, height: 18)
                        .frame(width: 44, height: 44).contentShape(.rect)
                }
                .accessibilityLabel("Summarize this response")
                .accessibilityHint("Adds a summary request and generates a new reply.")
                .help("Summarize this response")
            }
            if !readOnly && isUser && [.complete, .queued, .failed].contains(message.status) {
                Menu {
                    if message.status == .complete { Button("Edit in a new branch", systemImage: "pencil", action: edit) }
                    if message.status == .queued { Button("Remove from queue", systemImage: "xmark", action: remove) }
                    if message.status == .failed { Button("Restore draft", systemImage: "arrow.uturn.backward", action: remove) }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 18, height: 18)
                        .frame(width: 44, height: 44).contentShape(.rect)
                }
                .chatMenuStyle().accessibilityLabel("Message actions")
                .help("Message actions")
            }
            if !isUser {
                if message.model == "openrouter/auto",
                   let model = message.responseMetadata.responseModel,
                   model != "openrouter/auto" {
                    Text(ChatAppearance.modelName(model)).font(ChatAppearance.caption2)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                        .truncationMode(.middle).foregroundStyle(ChatAppearance.muted)
                        .padding(.leading, 12)
                        .fixedSize(horizontal: false, vertical: true).help(model)
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain).font(.system(size: 15, weight: .medium))
        .symbolRenderingMode(.monochrome).foregroundStyle(ChatAppearance.muted)
        .padding(isUser ? .trailing : .leading, -13)
    }
}

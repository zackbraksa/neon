import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import OpenChat

private final class ImageRequestURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor final class ImageAttachmentTests: XCTestCase {
    private func png(width: Int = 24, height: Int = 16) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0.3, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }
    func testOldConversationAndPendingFilesRemainReadable() throws {
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        var chat = Conversation()
        chat.messages = [Message(role: .user, content: "Before images")]
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(chat)) as? [String: Any])
        value.removeValue(forKey: "draftImages")
        XCTAssertNil(try decoder.decode(Conversation.self, from: JSONSerialization.data(withJSONObject: value)).draftImages)
        let pending = PendingSend(threadID: chat.id, prompt: "Old send", model: "model", steer: false)
        XCTAssertNil(try decoder.decode(PendingSend.self, from: encoder.encode(pending)).images)
        XCTAssertNil(try decoder.decode(Conversation.self, from: encoder.encode(chat)).messages.first?.images)
    }
    func testDraftQueueAndRequestHistoryPreserveImagesAndExcludeQueuedTurns() throws {
        let image = try ImageAttachment.normalize(png())
        var chat = Conversation()
        chat.draft = "Describe this"
        chat.draftImages = [image]
        chat.messages = [Message(role: .user, content: "", images: [image]), Message(role: .assistant, content: "Visible")]
        chat.enqueue("Queued", images: [image])
        let roundtrip = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(chat))
        XCTAssertEqual(roundtrip.draftImages, [image])
        XCTAssertEqual(roundtrip.messages.last?.images, [image])
        XCTAssertEqual(roundtrip.requestMessages.count, 2)
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(roundtrip.requestMessages.first!)) as? [String: Any])
        let parts = try XCTUnwrap(wire["content"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual((parts.first?["image_url"] as? [String: String])?["url"], image)
        let mixed = WireMessage(role: "user", content: "Describe", images: [image])
        let mixedJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(mixed)) as? [String: Any])
        XCTAssertEqual((mixedJSON["content"] as? [[String: Any]])?.first?["text"] as? String, "Describe")
        let plain = WireMessage(role: "user", content: "Text")
        let plainJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as? [String: Any])
        XCTAssertEqual(plainJSON["content"] as? String, "Text")
    }
    func testDurableOutboxCapturesImagesBeforeClearingDraft() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = try BackendCredentials(address: "https://example.test", token: String(repeating: "t", count: 32))
        let store = try RemoteChatStore(client: BackendClient(credentials), directory: directory)
        store.supportsImageInputs = true
        store.newChat(); let id = try XCTUnwrap(store.selectedID)
        let image = try ImageAttachment.normalize(png())
        store.update(id) { $0.draft = "Describe"; $0.draftImages = [image] }
        store.enqueue(id)
        let pending = try JSONDecoder().decode([PendingSend].self, from: Data(contentsOf: directory.appendingPathComponent("outbox.data")))
        XCTAssertEqual(pending.first?.prompt, "Describe")
        XCTAssertEqual(pending.first?.images, [image])
        XCTAssertTrue(try XCTUnwrap(store.chat(id)?.draft).isEmpty)
        XCTAssertNil(store.chat(id)?.draftImages)
        XCTAssertEqual(store.chat(id)?.messages.first?.images, [image])
        let reopened = try RemoteChatStore(client: BackendClient(credentials), directory: directory)
        XCTAssertEqual(reopened.chat(id)?.messages.first?.images, [image])
        var rejection = pending[0]; rejection.lastError = "Rejected"
        try JSONEncoder().encode([rejection]).write(to: directory.appendingPathComponent("outbox.data"), options: .atomic)
        let rejected = try RemoteChatStore(client: BackendClient(credentials), directory: directory)
        rejected.removeQueued(id, messageID: rejection.id)
        XCTAssertEqual(rejected.chat(id)?.draft, "Describe")
        XCTAssertEqual(rejected.chat(id)?.draftImages, [image])
        store.suspend(); reopened.suspend(); rejected.suspend()
    }
    func testOldServerKeepsImageDraftAndTextBodyOmitsImages() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = try BackendCredentials(address: "https://example.test", token: String(repeating: "t", count: 32))
        let store = try RemoteChatStore(client: BackendClient(credentials), directory: directory)
        store.newChat(); let id = try XCTUnwrap(store.selectedID)
        let image = try ImageAttachment.normalize(png())
        store.update(id) { $0.draftImages = [image] }
        store.enqueue(id)
        XCTAssertEqual(store.chat(id)?.draftImages, [image])
        XCTAssertTrue(store.chat(id)?.messages.isEmpty == true)
        XCTAssertNotNil(store.error)
        let pending = PendingSend(threadID: id, prompt: "Text", model: "model", steer: false, images: [])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(NormalMessageBody(pending))) as? [String: Any])
        XCTAssertNil(body["images"])
        store.suspend()
    }
    func testAcknowledgementsRequireExactImagePayloadIncludingForks() {
        let id = UUID(), thread = UUID()
        var pending = PendingSend(id: id, threadID: thread, prompt: "Prompt", model: "model", steer: false, images: ["image-a"])
        var job = BackendJob(id: id, threadId: thread, position: 1, prompt: "Prompt", model: "model", status: .queued, content: "", created: 0, updated: 0, images: ["image-a"])
        XCTAssertTrue(pending.matchesConfiguration(job))
        job.images = ["image-b"]
        XCTAssertFalse(pending.matchesConfiguration(job))
        pending.sourceThreadID = UUID(); pending.targetJobID = UUID()
        XCTAssertFalse(pending.matchesConfiguration(job))
        job.images = ["image-a"]
        XCTAssertTrue(pending.matchesConfiguration(job))
    }
    func testNormalizationBoundsPixelsAndRejectsUnsupportedContent() throws {
        let value = try ImageAttachment.normalize(png(width: 3000, height: 1000))
        let data = try XCTUnwrap(ImageAttachment.data(value))
        let image = try XCTUnwrap(ImageAttachment.thumbnail(data))
        XCTAssertLessThanOrEqual(image.width, ImageAttachment.maximumDimension)
        XCTAssertLessThanOrEqual(data.count, ImageAttachment.maximumBytes)
        XCTAssertThrowsError(try ImageAttachment.normalize(Data("Not an image".utf8)))
        XCTAssertThrowsError(try ImageAttachment.validate(Array(repeating: value, count: 5)))
    }
    func testPendingPasteRejectsSecondPasteAndStaysWithOriginalConversation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = try BackendCredentials(address: "https://example.test", token: String(repeating: "t", count: 32))
        let remote = try RemoteChatStore(client: BackendClient(credentials), directory: directory.appendingPathComponent("remote"))
        remote.supportsImageInputs = true
        remote.newChat(); let original = try XCTUnwrap(remote.selectedID)
        let direct = DirectChatStore(storage: try ConversationDisk(directory: directory.appendingPathComponent("direct")), readKey: { "" })
        let sessions = FakeBackendSessionStorage()
        let facade = ChatStore(direct: direct, remote: remote, sessions: sessions, push: sessions.pushCoordinator())
        let data = try png()
        let started = expectation(description: "Provider started")
        let provider = NSItemProvider()
        var complete: ((Data?, Error?) -> Void)?
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            complete = completion
            started.fulfill()
            return nil
        }
        facade.pasteImages([provider], to: original)
        await fulfillment(of: [started], timeout: 2)
        facade.pasteImages([NSItemProvider(item: data as NSData, typeIdentifier: UTType.png.identifier)], to: original)
        XCTAssertTrue(facade.error?.contains("before pasting another") == true)
        facade.setDraft(original, text: "Typed while loading")
        facade.send(original)
        XCTAssertEqual(remote.chat(original)?.draft, "Typed while loading")
        remote.newChat(); let other = try XCTUnwrap(remote.selectedID)
        complete?(data, nil)
        for _ in 0..<100 where remote.chat(original)?.draftImages == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(remote.chat(original)?.draftImages?.count, 1)
        XCTAssertNil(remote.chat(other)?.draftImages)
        XCTAssertEqual(remote.chat(original)?.draft, "Typed while loading")
        facade.send(original)
        let pending = try JSONDecoder().decode([PendingSend].self, from: Data(contentsOf: directory.appendingPathComponent("remote/outbox.data")))
        XCTAssertEqual(pending.first?.images?.count, 1)
        XCTAssertEqual(pending.first?.prompt, "Typed while loading")
        remote.suspend()
    }
    func testImageOnlyNewThreadAndMixedMessageRequestBodies() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory); ImageRequestURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImageRequestURLProtocol.self]
        let credentials = try BackendCredentials(address: "https://example.test", token: String(repeating: "t", count: 32))
        let client = BackendClient(credentials, session: URLSession(configuration: configuration))
        let store = try RemoteChatStore(client: client, directory: directory)
        store.supportsImageInputs = true
        store.newChat(); let id = try XCTUnwrap(store.selectedID)
        let image = try ImageAttachment.normalize(png())
        store.update(id) { $0.draftImages = [image] }
        store.enqueue(id)
        let chat = try XCTUnwrap(store.chat(id))
        XCTAssertFalse(chat.title.isEmpty)
        let pending = try JSONDecoder().decode([PendingSend].self, from: Data(contentsOf: directory.appendingPathComponent("outbox.data")))[0]
        XCTAssertEqual(pending.prompt, "")
        XCTAssertEqual(pending.images, [image])
        var captured: [[String: Any]] = []
        ImageRequestURLProtocol.handler = { request in
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
            }
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            captured.append(body)
            if request.url?.path == "/v1/threads" {
                XCTAssertEqual(body["title"] as? String, "New conversation")
                return try JSONSerialization.data(withJSONObject: ["id": id.uuidString, "title": chat.title, "paused": 0, "created": 0, "revision": 0])
            }
            return try JSONEncoder().encode(BackendJob(id: pending.id, threadId: id, position: 0, prompt: body["prompt"] as? String ?? "", model: pending.model, status: .queued, content: "", created: 0, updated: 0, images: [image]))
        }
        try await client.createThread(chat)
        let accepted = try await client.submit(pending)
        XCTAssertEqual(accepted.images, [image])
        let mixed = PendingSend(threadID: id, prompt: "Describe", model: pending.model, steer: false, images: [image])
        _ = try await client.submit(mixed)
        XCTAssertEqual(captured.count, 3)
        XCTAssertEqual(captured[1]["images"] as? [String], [image])
        XCTAssertEqual(captured[1]["prompt"] as? String, "")
        XCTAssertEqual(captured[2]["images"] as? [String], [image])
        XCTAssertEqual(captured[2]["prompt"] as? String, "Describe")
        store.suspend()
    }
    func testNativePasteCapturesClipboardImageWithoutChangingTypedText() throws {
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        defer {
            pasteboard.clearContents()
            let items = saved.map { representations -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in representations { item.setData(data, forType: type) }
                return item
            }
            pasteboard.writeObjects(items)
        }
        pasteboard.clearContents(); pasteboard.setData(try png(), forType: .png)
        let view = ImagePasteTextView()
        view.string = "Typed beside the image"
        let pasteItem = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        view.isRichText = false
        view.importsGraphics = false
        XCTAssertTrue(view.validateUserInterfaceItem(pasteItem))
        var count = 0
        view.pasteImages = { count += $0.count }
        view.paste(nil)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(view.string, "Typed beside the image")
        pasteboard.clearContents(); pasteboard.setString(" plain paste", forType: .string)
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        view.paste(nil)
        XCTAssertEqual(view.string, "Typed beside the image plain paste")
        XCTAssertEqual(count, 1)
    }
}

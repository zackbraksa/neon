import Foundation
import ImageIO
import UniformTypeIdentifiers
import SwiftUI

// ImageIO creates bounded thumbnails before pixel decoding, including for cached server images.
enum ImageAttachment {
    static let maximumCount = 4
    static let maximumBytes = 2 * 1024 * 1024
    static let maximumDimension = 2048

    static func validate(_ images: [String]) throws {
        guard images.count <= maximumCount else { throw RouterError(message: "You can attach up to four images per message.") }
        for image in images {
            guard let data = data(image), data.count <= maximumBytes else {
                throw RouterError(message: "Use PNG or JPEG images up to 2 MiB each.")
            }
        }
    }
    static func data(_ value: String) -> Data? {
        guard value.hasPrefix("data:image/png;base64,") || value.hasPrefix("data:image/jpeg;base64,"),
              let comma = value.firstIndex(of: ","), value.utf8.count <= maximumBytes * 4 / 3 + 100 else { return nil }
        return Data(base64Encoded: String(value[value.index(after: comma)...]))
    }
    static func thumbnail(_ data: Data, dimension: Int = maximumDimension) -> CGImage? {
        guard data.count <= 64 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source), UTType(type as String)?.conforms(to: .image) == true else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: dimension,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }
    static func normalize(_ data: Data) throws -> String {
        guard let image = thumbnail(data) else { throw RouterError(message: "This clipboard image could not be read. Copy a PNG or JPEG image and try again.") }
        for (type, quality) in [(UTType.png, 1.0), (.jpeg, 0.85), (.jpeg, 0.65), (.jpeg, 0.45)] {
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            if CGImageDestinationFinalize(destination), output.length <= maximumBytes {
                return "data:\(type.preferredMIMEType!);base64,\((output as Data).base64EncodedString())"
            }
        }
        throw RouterError(message: "This image is too large. Copy a smaller image and try again.")
    }
}

struct AttachedImages: View {
    let images: [String]
    var remove: ((Int) -> Void)? = nil
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(Array(images.enumerated()), id: \.offset) { index, image in
                    AttachmentThumbnail(value: image, removable: remove != nil, position: index + 1, count: images.count) { remove?(index) }
                }
            }.padding(.vertical, 4)
        }.scrollIndicators(.hidden)
    }
}

private struct AttachmentThumbnail: View {
    let value: String
    let removable: Bool
    let position: Int
    let count: Int
    let remove: () -> Void
    @State private var thumbnail: CGImage?
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 1).resizable().scaledToFit()
                } else { Image(systemName: "photo").foregroundStyle(.secondary) }
            }
            .frame(width: removable ? 88 : 180, height: removable ? 88 : 160)
            .background(.white.opacity(0.06), in: .rect(cornerRadius: 12))
            .clipShape(.rect(cornerRadius: 12))
            .accessibilityLabel("Attached image")
            if removable {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 22))
                        .symbolRenderingMode(.palette).foregroundStyle(.white, .black)
                        .frame(width: 44, height: 44).contentShape(.rect)
                }.buttonStyle(.plain).accessibilityLabel("Remove image \(position) of \(count)")
            }
        }
        .task(id: value) {
            let value = value
            thumbnail = nil
            let result = await Task.detached(priority: .userInitiated) {
                ImageAttachment.data(value).flatMap { ImageAttachment.thumbnail($0, dimension: 400) }
            }.value
            guard !Task.isCancelled else { return }
            thumbnail = result
        }
    }
}

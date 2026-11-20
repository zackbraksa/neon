import AppKit
import ImageIO

let sourceURL = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Assets/AbstractNeonIcon.png")
let output = URL(fileURLWithPath: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "OpenChat/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let artwork = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fatalError("Cannot decode approved icon artwork")
}
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func render(size: Int, name: String) throws {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    context.addPath(CGPath(roundedRect: tile, cornerWidth: 184, cornerHeight: 184, transform: nil))
    context.clip()
    context.interpolationQuality = .high
    context.draw(artwork, in: tile)
    let destination = CGImageDestinationCreateWithURL(output.appendingPathComponent(name) as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

if !CommandLine.arguments.contains("--ios-only") {
    for size in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            try render(size: size * scale, name: "AppIcon-mac-\(size)@\(scale)x.png")
        }
    }
}

let artworkData = try Data(contentsOf: sourceURL)
try artworkData.write(to: output.appendingPathComponent("AppIcon.png"), options: .atomic)
let nativeAssets = URL(fileURLWithPath: "OpenChat/AppIcon.icon/Assets", isDirectory: true)
try FileManager.default.createDirectory(at: nativeAssets, withIntermediateDirectories: true)
try artworkData.write(to: nativeAssets.appendingPathComponent("Default.png"), options: .atomic)

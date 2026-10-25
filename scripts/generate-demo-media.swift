#!/usr/bin/swift
import AppKit
import Foundation
import ImageIO

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let artwork = root.appendingPathComponent("artifacts/handprint-options.png")
let output = root.appendingPathComponent("docs/media")
let width = 1280
let height = 720
let screenScale: CGFloat = 0.89
let frameRate = 24
let frameCount = 192
let duration = Double(frameCount) / Double(frameRate)
let backdropURL = root.appendingPathComponent("docs/artwork/keysplash-cta-light.png")
guard let backdropSource = CGImageSourceCreateWithURL(backdropURL as CFURL, nil),
      let sourceBackdrop = CGImageSourceCreateImageAtIndex(backdropSource, 0, nil) else {
    fatalError("Could not load KeySplash demo background at \(backdropURL.path)")
}
let backdropCropWidth = CGFloat(sourceBackdrop.height) * CGFloat(width) / CGFloat(height)
let backdropCrop = CGRect(x: (CGFloat(sourceBackdrop.width) - backdropCropWidth) / 2,
                          y: 0, width: backdropCropWidth, height: CGFloat(sourceBackdrop.height))
guard let backdropImage = sourceBackdrop.cropping(to: backdropCrop) else {
    fatalError("Could not crop KeySplash demo background")
}
let palette: [NSColor] = [
    NSColor(hex: 0xFF477E), NSColor(hex: 0x2FD6C5), NSColor(hex: 0xFFD34D),
    NSColor(hex: 0x9B6CFF), NSColor(hex: 0x34C759), NSColor(hex: 0xFF8D49), NSColor(hex: 0x55A9FF)
]

guard let sheetSource = CGImageSourceCreateWithURL(artwork as CFURL, nil),
      let sheet = CGImageSourceCreateImageAtIndex(sheetSource, 0, nil) else {
    fatalError("Could not load handprint artwork at \(artwork.path)")
}

let cellWidth = CGFloat(sheet.width) / 2
let cellHeight = CGFloat(sheet.height) / 2
let handprints: [[CGImage]] = (0..<4).compactMap { index in
    let cropRect = CGRect(x: CGFloat(index % 2) * cellWidth,
                          y: CGFloat(index / 2) * cellHeight,
                          width: cellWidth, height: cellHeight)
    guard let crop = sheet.cropping(to: cropRect) else { return nil }
    let pixelWidth = crop.width
    let pixelHeight = crop.height
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    var sourcePixels = [UInt8](repeating: 0, count: pixelWidth * pixelHeight * 4)
    sourcePixels.withUnsafeMutableBytes { buffer in
        guard let context = CGContext(data: buffer.baseAddress, width: pixelWidth, height: pixelHeight,
                                      bitsPerComponent: 8, bytesPerRow: pixelWidth * 4,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
    }
    return palette.compactMap { color in
        let rgb = color.usingColorSpace(.deviceRGB)!
        let red = UInt8((rgb.redComponent * 255).rounded())
        let green = UInt8((rgb.greenComponent * 255).rounded())
        let blue = UInt8((rgb.blueComponent * 255).rounded())
        var tintedPixels = [UInt8](repeating: 0, count: sourcePixels.count)
        for pixel in 0..<(pixelWidth * pixelHeight) {
            let offset = pixel * 4
            let luminance = 0.2126 * Double(sourcePixels[offset])
                + 0.7152 * Double(sourcePixels[offset + 1])
                + 0.0722 * Double(sourcePixels[offset + 2])
            let alpha = UInt8((255 - luminance).rounded())
            tintedPixels[offset] = UInt8(UInt16(red) * UInt16(alpha) / 255)
            tintedPixels[offset + 1] = UInt8(UInt16(green) * UInt16(alpha) / 255)
            tintedPixels[offset + 2] = UInt8(UInt16(blue) * UInt16(alpha) / 255)
            tintedPixels[offset + 3] = alpha
        }
        guard let provider = CGDataProvider(data: Data(tintedPixels) as CFData) else { return nil }
        return CGImage(width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: pixelWidth * 4, space: colorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
guard handprints.count == 4, handprints.allSatisfy({ $0.count == palette.count }) else {
    fatalError("Expected four handprint variants in every color")
}

let keys: [(time: Double, x: CGFloat, y: CGFloat, hand: Int, color: Int)] = [
    (0.00, 0.12, 0.16, 0, 0), (0.72, 0.28, 0.25, 2, 2), (1.15, 0.43, 0.38, 0, 1),
    (1.50, 0.67, 0.28, 2, 3), (1.86, 0.84, 0.43, 0, 4), (2.25, 0.22, 0.58, 2, 5),
    (2.58, 0.75, 0.60, 0, 2), (2.91, 0.37, 0.82, 2, 0), (3.26, 0.64, 0.84, 0, 6),
    (3.63, 0.17, 0.39, 2, 4), (3.91, 0.31, 0.47, 0, 1), (4.18, 0.45, 0.40, 2, 2),
    (4.43, 0.58, 0.47, 0, 5), (4.68, 0.72, 0.40, 2, 0), (5.04, 0.86, 0.58, 0, 3),
    (5.40, 0.10, 0.78, 2, 1), (5.78, 0.91, 0.20, 0, 6), (6.12, 0.50, 0.91, 2, 2)
]

try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let temporaryFrames = FileManager.default.temporaryDirectory
    .appendingPathComponent("keysplash-demo-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: temporaryFrames, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporaryFrames) }

for frame in 0..<frameCount {
    let time = Double(frame) / Double(frameRate)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: width * 4, bitsPerPixel: 32)!
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    graphics.imageInterpolation = .high
    drawBackdrop()
    drawMarks(at: time)
    drawControls()
    graphics.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    let frameURL = temporaryFrames.appendingPathComponent(String(format: "frame-%04d.png", frame))
    guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("Could not encode frame") }
    try data.write(to: frameURL)
}

let movieURL = output.appendingPathComponent("keysplash-play-demo.mp4")
let gifURL = output.appendingPathComponent("keysplash-play-demo.gif")
runFFmpeg([
    "-y", "-framerate", "\(frameRate)", "-i", temporaryFrames.appendingPathComponent("frame-%04d.png").path,
    "-an", "-c:v", "libx264", "-crf", "21", "-pix_fmt", "yuv420p", "-movflags", "+faststart", movieURL.path
])
runFFmpeg([
    "-y", "-framerate", "\(frameRate)", "-i", temporaryFrames.appendingPathComponent("frame-%04d.png").path,
    "-filter_complex", "[0:v]fps=12,scale=960:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=112:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:diff_mode=rectangle",
    "-loop", "0", gifURL.path
])
print("Created \(movieURL.path) and \(gifURL.path) (\(String(format: "%.1f", duration)) seconds)")

func drawBackdrop() {
    let canvas = CGRect(x: 0, y: 0, width: width, height: height)
    NSImage(cgImage: backdropImage, size: canvas.size)
        .draw(in: canvas, from: .zero, operation: .copy, fraction: 1)
}

func drawMarks(at time: Double) {
    for (index, key) in keys.enumerated() {
        let age = time - key.time
        guard age >= 0, age < 2.4 else { continue }
        let burst = keys.enumerated().filter { $0.offset <= index && time - $0.element.time < 2 }.count
        let size = CGFloat([220, 330, 185, 280, 245, 315, 195, 300, 265][index % 9])
            * screenScale * (1 + CGFloat(min(max(burst - 1, 0), 6)) * 0.11)
        let fade = age > 2.05 ? max(0, 1 - (age - 2.05) / 0.35) : 1
        let rect = CGRect(x: key.x * CGFloat(width) - size / 2,
                          y: (1 - key.y) * CGFloat(height) - size / 2,
                          width: size, height: size)
        let transform = NSAffineTransform()
        transform.translateX(by: rect.midX, yBy: rect.midY)
        transform.rotate(byDegrees: CGFloat((index * 29) % 53 - 26))
        transform.translateX(by: -rect.midX, yBy: -rect.midY)
        NSGraphicsContext.saveGraphicsState()
        transform.concat()
        let handIndex = (key.x < 0.5 ? 1 : 0) + (key.hand == 2 ? 2 : 0)
        let image = NSImage(cgImage: handprints[handIndex][key.color], size: rect.size)
        let handShadow = NSShadow()
        handShadow.shadowColor = palette[key.color].withAlphaComponent(0.45)
        handShadow.shadowBlurRadius = 16 * screenScale
        handShadow.shadowOffset = .zero
        handShadow.set()
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: fade)
        NSShadow().set()
        NSGraphicsContext.restoreGraphicsState()
        if burst >= 3 && age < 1.2 { drawSparkles(around: CGPoint(x: rect.midX, y: rect.midY), size: size, seed: index) }
    }
}

func drawSparkles(around center: CGPoint, size: CGFloat, seed: Int) {
    for index in 0..<4 {
        let angle = CGFloat((seed * 71 + index * 97) % 360) * .pi / 180
        let distance = size * CGFloat(0.30 + Double((seed + index) % 4) * 0.06)
        let point = CGPoint(x: center.x + cos(angle) * distance, y: center.y + sin(angle) * distance)
        let sparkle = NSBezierPath()
        let arm = 13 * screenScale
        let inner = 3 * screenScale
        let side = 12 * screenScale
        sparkle.move(to: CGPoint(x: point.x, y: point.y + arm))
        sparkle.line(to: CGPoint(x: point.x + inner, y: point.y + inner))
        sparkle.line(to: CGPoint(x: point.x + side, y: point.y))
        sparkle.line(to: CGPoint(x: point.x + inner, y: point.y - inner))
        sparkle.line(to: CGPoint(x: point.x, y: point.y - arm))
        sparkle.line(to: CGPoint(x: point.x - inner, y: point.y - inner))
        sparkle.line(to: CGPoint(x: point.x - side, y: point.y))
        sparkle.line(to: CGPoint(x: point.x - inner, y: point.y + inner))
        sparkle.close()
        palette[(seed + index) % palette.count].withAlphaComponent(0.92).setFill()
        sparkle.fill()
    }
}

func drawControls() {
    let scale = screenScale
    let panelSize = CGSize(width: 456 * scale, height: 320 * scale)
    let panel = CGRect(x: (CGFloat(width) - panelSize.width) / 2,
                       y: (CGFloat(height) - panelSize.height) / 2,
                       width: panelSize.width, height: panelSize.height)
    let icon = CGRect(x: CGFloat(width) / 2 - 17 * scale,
                      y: panel.minY + 260 * scale, width: 34 * scale, height: 24 * scale)
    NSColor.white.withAlphaComponent(0.84).setStroke()
    let keyboard = NSBezierPath(roundedRect: icon, xRadius: 3 * scale, yRadius: 3 * scale)
    keyboard.lineWidth = 1.6 * scale
    keyboard.stroke()
    NSColor.white.withAlphaComponent(0.84).setFill()
    for row in 0..<2 {
        for column in 0..<5 {
            let xOffset = 4 + CGFloat(column) * 3.2
            let yOffset = 13 + CGFloat(row) * 3.6
            let keySize = CGSize(width: 1.6 * scale, height: 1.3 * scale)
            let key = CGRect(origin: CGPoint(x: icon.minX + xOffset * scale,
                                            y: icon.minY + yOffset * scale), size: keySize)
            NSBezierPath(roundedRect: key, xRadius: 0.5 * scale, yRadius: 0.5 * scale).fill()
        }
    }
    drawCentered("Keyboard playtime!", y: panel.minY + 222 * scale, size: 22 * scale, color: .white, weight: .semibold, withContrast: true)
    drawCentered("Tap keys to make colorful handprints", y: panel.minY + 192 * scale, size: 14 * scale,
                 color: NSColor.white.withAlphaComponent(0.9), weight: .regular, withContrast: true)
    for index in 0..<5 {
        NSColor.white.withAlphaComponent(0.2).setFill()
        let dot = NSBezierPath(ovalIn: CGRect(x: CGFloat(width) / 2 + (-43 + CGFloat(index) * 19) * scale,
                                             y: panel.minY + 158 * scale,
                                             width: 10 * scale, height: 10 * scale))
        let dotShadow = NSShadow()
        dotShadow.shadowColor = NSColor.black.withAlphaComponent(0.9)
        dotShadow.shadowBlurRadius = 6 * scale
        dotShadow.shadowOffset = CGSize(width: 0, height: -2 * scale)
        dotShadow.set()
        dot.fill()
        NSShadow().set()
    }
    let unlock = CGRect(x: CGFloat(width) / 2 - 47 * scale, y: panel.minY + 101 * scale,
                        width: 94 * scale, height: 38 * scale)
    let unlockShadow = NSShadow()
    unlockShadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
    unlockShadow.shadowBlurRadius = 12 * scale
    unlockShadow.shadowOffset = CGSize(width: 0, height: -4 * scale)
    unlockShadow.set()
    fillRounded(unlock, color: NSColor.white, radius: 21 * scale)
    NSShadow().set()
    drawCentered("Unlock", y: panel.minY + 111 * scale, size: 14 * scale, color: NSColor(hex: 0x17191B), weight: .semibold)
    drawUnlockHint(y: panel.minY + 68 * scale, scale: scale)
}

func drawUnlockHint(y: CGFloat, scale: CGFloat) {
    let font = NSFont.systemFont(ofSize: 12 * scale)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.88)
    shadow.shadowBlurRadius = 3 * scale
    shadow.shadowOffset = CGSize(width: 0, height: -1 * scale)
    let text = NSAttributedString(string: "or press Esc five times", attributes: [
        .font: font,
        .foregroundColor: NSColor.white.withAlphaComponent(0.82),
        .shadow: shadow
    ])
    let iconSize = 13 * scale
    let gap = 10 * scale
    let x = (CGFloat(width) - text.size().width - gap - iconSize) / 2
    text.draw(at: CGPoint(x: x, y: y))

    let icon = CGRect(x: x + text.size().width + gap, y: y - 1 * scale,
                      width: iconSize, height: iconSize)
    let speaker = NSBezierPath()
    speaker.move(to: CGPoint(x: icon.minX, y: icon.minY + icon.height * 0.32))
    speaker.line(to: CGPoint(x: icon.minX + icon.width * 0.28, y: icon.minY + icon.height * 0.32))
    speaker.line(to: CGPoint(x: icon.minX + icon.width * 0.58, y: icon.minY))
    speaker.line(to: CGPoint(x: icon.minX + icon.width * 0.58, y: icon.maxY))
    speaker.line(to: CGPoint(x: icon.minX + icon.width * 0.28, y: icon.minY + icon.height * 0.68))
    speaker.line(to: CGPoint(x: icon.minX, y: icon.minY + icon.height * 0.68))
    speaker.close()
    NSColor.white.withAlphaComponent(0.78).setFill()
    speaker.fill()
    NSColor.white.withAlphaComponent(0.78).setStroke()

    for radius in [icon.width * 0.3, icon.width * 0.52] {
        let wave = NSBezierPath()
        wave.appendArc(withCenter: CGPoint(x: icon.minX + icon.width * 0.56, y: icon.midY),
                       radius: radius, startAngle: -50, endAngle: 50, clockwise: false)
        wave.lineWidth = 1.2 * scale
        wave.lineCapStyle = .round
        wave.stroke()
    }
}

func fillRounded(_ rect: CGRect, color: NSColor, radius: CGFloat) {
    color.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}

func drawCentered(_ text: String, y: CGFloat, size: CGFloat, color: NSColor, weight: NSFont.Weight, withContrast: Bool = false) {
    var attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
    if withContrast {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.88)
        shadow.shadowBlurRadius = 3 * screenScale
        shadow.shadowOffset = CGSize(width: 0, height: -1 * screenScale)
        attributes[.shadow] = shadow
    }
    let string = NSAttributedString(string: text, attributes: attributes)
    string.draw(at: CGPoint(x: (CGFloat(width) - string.size().width) / 2, y: y))
}

func runFFmpeg(_ arguments: [String]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["ffmpeg"] + arguments
    process.currentDirectoryURL = root
    try! process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { fatalError("ffmpeg failed with exit code \(process.terminationStatus)") }
}

extension NSColor {
    convenience init(hex: Int) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

#!/usr/bin/swift
import AppKit
import Foundation
import ImageIO

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let artwork = root.appendingPathComponent("artifacts/handprint-options.png")
let output = root.appendingPathComponent("docs/media")
let width = 1280
let height = 720
let screenScale: CGFloat = 0.62
let frameRate = 24
let frameCount = 192
let duration = Double(frameCount) / Double(frameRate)
let palette: [NSColor] = [
    NSColor(hex: 0xFF477E), NSColor(hex: 0x2FD6C5), NSColor(hex: 0xFFD34D),
    NSColor(hex: 0x9B6CFF), NSColor(hex: 0xFF8D49), NSColor(hex: 0x55A9FF)
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
    (0.25, 0.12, 0.16, 0, 0), (0.72, 0.28, 0.25, 2, 2), (1.15, 0.43, 0.38, 0, 1),
    (1.50, 0.67, 0.28, 2, 3), (1.86, 0.84, 0.43, 0, 4), (2.25, 0.22, 0.58, 2, 5),
    (2.58, 0.75, 0.60, 0, 2), (2.91, 0.37, 0.82, 2, 0), (3.26, 0.64, 0.84, 0, 3),
    (3.63, 0.17, 0.39, 2, 4), (3.91, 0.31, 0.47, 0, 1), (4.18, 0.45, 0.40, 2, 2),
    (4.43, 0.58, 0.47, 0, 5), (4.68, 0.72, 0.40, 2, 0), (5.04, 0.86, 0.58, 0, 3),
    (5.40, 0.10, 0.78, 2, 1), (5.78, 0.91, 0.20, 0, 4), (6.12, 0.50, 0.91, 2, 2)
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
    NSColor(hex: 0xF1F0EC).setFill()
    NSBezierPath(rect: CGRect(x: 0, y: 0, width: width, height: height)).fill()
    fillRounded(CGRect(x: 55, y: 46, width: 1170, height: 628), color: NSColor(hex: 0xFFFFFF), radius: 18)
    fillRounded(CGRect(x: 55, y: 626, width: 1170, height: 48), color: NSColor(hex: 0xF8F8F6), radius: 18)
    for (index, color) in [0xFC6155, 0xF9BE4D, 0x54BF69].enumerated() {
        NSColor(hex: color).setFill()
        NSBezierPath(ovalIn: CGRect(x: 76 + index * 21, y: 643, width: 11, height: 11)).fill()
    }
    drawText("A small space for big ideas", at: CGPoint(x: 160, y: 642), size: 15,
             color: NSColor(hex: 0x707675), weight: .medium)
    fillRounded(CGRect(x: 55, y: 46, width: 190, height: 582), color: NSColor(hex: 0xF8F8F6), radius: 0)
    drawText("Today", at: CGPoint(x: 84, y: 570), size: 16, color: NSColor(hex: 0x25292A), weight: .semibold)
    ["A little note", "Things to remember", "Weekend ideas"].enumerated().forEach { index, title in
        let y = 518 - index * 51
        fillRounded(CGRect(x: 72, y: y - 11, width: 154, height: 38),
                    color: index == 0 ? NSColor(hex: 0xE9E6FF) : NSColor(hex: 0xF8F8F6), radius: 8)
        drawText(title, at: CGPoint(x: 86, y: y), size: 11,
                 color: NSColor(hex: index == 0 ? 0x5038C9 : 0x707675), weight: .medium)
    }
    drawText("A little room for curious hands", at: CGPoint(x: 316, y: 536), size: 34,
             color: NSColor(hex: 0x25292A), weight: .semibold)
    drawText("A colorful place to explore while your work stays just where you left it.",
             at: CGPoint(x: 318, y: 500), size: 15, color: NSColor(hex: 0x7C8281), weight: .regular)
    for index in 0..<5 {
        fillRounded(CGRect(x: 318, y: 432 - index * 32, width: 630 - (index % 3) * 75, height: 7),
                    color: NSColor(hex: 0xE9E9E6), radius: 4)
    }
    fillRounded(CGRect(x: 990, y: 330, width: 175, height: 145), color: NSColor(hex: 0xF7F3E8), radius: 14)
    drawText("Little moments", at: CGPoint(x: 1009, y: 441), size: 12, color: NSColor(hex: 0x84795C), weight: .medium)
    drawText("are big things", at: CGPoint(x: 1009, y: 413), size: 17, color: NSColor(hex: 0x645A43), weight: .semibold)
    drawText("to little hands.", at: CGPoint(x: 1009, y: 388), size: 14, color: NSColor(hex: 0x84795C), weight: .regular)
}

func drawMarks(at time: Double) {
    for (index, key) in keys.enumerated() {
        let age = time - key.time
        guard age >= 0, age < 2.4 else { continue }
        let burst = keys.enumerated().filter { $0.offset <= index && time - $0.element.time < 2 }.count
        let size = CGFloat([205, 255, 175, 235, 195, 270, 180, 245, 220][index % 9])
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
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: fade)
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
    let panelSize = CGSize(width: 456 * scale, height: 324 * scale)
    let panel = CGRect(x: (CGFloat(width) - panelSize.width) / 2,
                       y: (CGFloat(height) - panelSize.height) / 2,
                       width: panelSize.width, height: panelSize.height)
    let icon = CGRect(x: CGFloat(width) / 2 - 12 * scale,
                      y: panel.minY + 260 * scale, width: 24 * scale, height: 24 * scale)
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
        NSColor.white.withAlphaComponent(index == 0 ? 0.88 : 0.24).setFill()
        let dot = NSBezierPath(ovalIn: CGRect(x: CGFloat(width) / 2 + (-27 + CGFloat(index) * 25) * scale,
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
    let unlock = CGRect(x: CGFloat(width) / 2 - 70 * scale, y: panel.minY + 100 * scale,
                        width: 140 * scale, height: 42 * scale)
    let unlockShadow = NSShadow()
    unlockShadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
    unlockShadow.shadowBlurRadius = 12 * scale
    unlockShadow.shadowOffset = CGSize(width: 0, height: -4 * scale)
    unlockShadow.set()
    fillRounded(unlock, color: NSColor.white, radius: 21 * scale)
    NSShadow().set()
    drawCentered("Unlock", y: panel.minY + 108 * scale, size: 14 * scale, color: NSColor(hex: 0x17191B), weight: .semibold)
    drawCentered("or press Esc five times", y: panel.minY + 68 * scale, size: 12 * scale,
                 color: NSColor.white.withAlphaComponent(0.9), weight: .regular, withContrast: true)
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

func drawText(_ text: String, at point: CGPoint, size: CGFloat, color: NSColor, weight: NSFont.Weight) {
    NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]).draw(at: point)
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

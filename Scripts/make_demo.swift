// Generated fixtures for UI checks; these are synthetic, not photographic quality evidence.
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "artifacts/demo/input", isDirectory: true)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let width = 1600, height = 1067
func write(_ name: String, draw: (CGContext) -> Void) throws {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(context)
    let destination = CGImageDestinationCreateWithURL(root.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImagePropertyOrientation: 1] as CFDictionary)
    if !CGImageDestinationFinalize(destination) { fatalError("Fixture encoding failed") }
}
try write("01_山谷合成测试图.png") { context in
    let colors = [CGColor(srgbRed: 0.16, green: 0.27, blue: 0.36, alpha: 1),
                  CGColor(srgbRed: 0.82, green: 0.72, blue: 0.54, alpha: 1)]
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: .zero, options: [])
    context.setFillColor(CGColor(srgbRed: 0.98, green: 0.84, blue: 0.59, alpha: 1))
    context.fillEllipse(in: CGRect(x: 1080, y: 700, width: 140, height: 140))
    for layer in 0..<5 {
        let path = CGMutablePath(); path.move(to: .zero)
        for x in stride(from: 0, through: width, by: 20) {
            let y = 560 - Double(layer) * 98 + sin(Double(x) / 210 + Double(layer)) * (100 - Double(layer) * 9) + cos(Double(x) / 99) * 25
            path.addLine(to: CGPoint(x: Double(x), y: y))
        }
        path.addLine(to: CGPoint(x: width, y: 0)); path.closeSubpath()
        context.setFillColor(CGColor(srgbRed: 0.25 - Double(layer) * 0.035, green: 0.38 - Double(layer) * 0.05,
                                     blue: 0.40 - Double(layer) * 0.05, alpha: 1))
        context.addPath(path); context.fillPath()
    }
}
try write("02_色彩与中性阶测试图.png") { context in
    context.setFillColor(CGColor(gray: 0.16, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let patches: [[CGFloat]] = [
        [0.45,0.29,0.23], [0.76,0.58,0.50], [0.36,0.48,0.61], [0.36,0.43,0.24], [0.51,0.51,0.68], [0.38,0.74,0.67],
        [0.86,0.48,0.16], [0.28,0.35,0.68], [0.75,0.30,0.36], [0.36,0.24,0.42], [0.61,0.74,0.25], [0.89,0.64,0.16],
        [0.18,0.24,0.59], [0.27,0.59,0.29], [0.69,0.19,0.23], [0.94,0.78,0.12], [0.73,0.28,0.59], [0.04,0.54,0.67],
        [0.95,0.95,0.95], [0.79,0.79,0.79], [0.63,0.63,0.63], [0.46,0.46,0.46], [0.30,0.30,0.30], [0.12,0.12,0.12]
    ]
    for (index, patch) in patches.enumerated() {
        context.setFillColor(CGColor(srgbRed: patch[0], green: patch[1], blue: patch[2], alpha: 1))
        let column = index % 6, row = 3 - index / 6
        context.fill(CGRect(x: 90 + column * 240, y: 90 + row * 240, width: 218, height: 218))
    }
}
if CommandLine.arguments.contains("--include-broken") {
    try Data("Deliberately corrupt fixture for error isolation checks".utf8).write(to: root.appendingPathComponent("03_损坏文件.png"))
}
print("Synthetic fixtures: \(root.path)")

import AppKit
import CoreGraphics

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconset = output.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 64, 128, 256, 512, 1024] {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Icon context") }
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
    let scale = CGFloat(size) / 1024
    graphics.cgContext.scaleBy(x: scale, y: scale)
    let outline = NSBezierPath(roundedRect: NSRect(x: 42, y: 42, width: 940, height: 940), xRadius: 210, yRadius: 210)
    NSGradient(starting: NSColor(calibratedRed: 0.17, green: 0.23, blue: 0.24, alpha: 1),
               ending: NSColor(calibratedRed: 0.06, green: 0.09, blue: 0.11, alpha: 1))!.draw(in: outline, angle: -60)
    let center = CGPoint(x: 512, y: 512)
    let ring = NSBezierPath(ovalIn: NSRect(x: 210, y: 210, width: 604, height: 604))
    ring.lineWidth = 9
    NSColor(calibratedRed: 0.78, green: 0.88, blue: 0.58, alpha: 0.35).setStroke(); ring.stroke()
    for index in 0..<6 {
        let angle = CGFloat(index) * .pi / 3
        let next = angle + .pi / 3
        let p = NSBezierPath()
        p.move(to: CGPoint(x: center.x + cos(angle) * 267, y: center.y + sin(angle) * 267))
        p.line(to: CGPoint(x: center.x + cos(next) * 267, y: center.y + sin(next) * 267))
        p.line(to: CGPoint(x: center.x + cos(next + 0.5) * 121, y: center.y + sin(next + 0.5) * 121))
        p.line(to: CGPoint(x: center.x + cos(angle + 0.5) * 121, y: center.y + sin(angle + 0.5) * 121))
        p.close()
        NSColor(calibratedRed: 0.78 + CGFloat(index % 2) * 0.06, green: 0.88, blue: 0.58, alpha: 0.8 + CGFloat(index % 2) * 0.15).setFill()
        p.fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("Icon PNG") }
    let filenames: [Int: [String]] = [16: ["icon_16x16.png"], 32: ["icon_16x16@2x.png", "icon_32x32.png"],
        64: ["icon_32x32@2x.png"], 128: ["icon_128x128.png"], 256: ["icon_128x128@2x.png", "icon_256x256.png"],
        512: ["icon_256x256@2x.png", "icon_512x512.png"], 1024: ["icon_512x512@2x.png"]]
    for filename in filenames[size] ?? [] { try data.write(to: iconset.appendingPathComponent(filename)) }
}
let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output.appendingPathComponent("AppIcon.icns").path]
try process.run(); process.waitUntilExit()
guard process.terminationStatus == 0 else { fatalError("iconutil failed") }

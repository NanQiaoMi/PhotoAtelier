import CoreImage
import Foundation
import PhotoCore

enum PreviewRaster {
    /// Own the pixel bytes before handing a CGImage to AppKit on the UI thread.
    static func make(_ image: CIImage, context: CIContext, colorSpace: CGColorSpace,
                     format: CIFormat = .RGBA8) throws -> CGImage {
        guard let cg = context.createCGImage(image, from: image.extent, format: format,
                                             colorSpace: colorSpace, deferred: false),
              let raw = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(raw),
              let provider = CGDataProvider(data: Data(bytes: bytes, count: CFDataGetLength(raw)) as CFData),
              let result = CGImage(width: cg.width, height: cg.height, bitsPerComponent: cg.bitsPerComponent,
                    bitsPerPixel: cg.bitsPerPixel, bytesPerRow: cg.bytesPerRow,
                    space: cg.colorSpace ?? colorSpace, bitmapInfo: cg.bitmapInfo,
                    provider: provider, decode: nil, shouldInterpolate: true, intent: cg.renderingIntent) else {
            throw AtelierError.imageRead("预览像素渲染失败")
        }
        return result
    }
}

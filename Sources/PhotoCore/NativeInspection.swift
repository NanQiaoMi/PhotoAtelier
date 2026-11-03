import CoreGraphics
import CoreImage
import Foundation

/// A location in the geometrically corrected output, measured from its TOP left.
/// This coordinate convention is local to inspection, not the mask convention.
public struct NativeInspectionRegion: Equatable {
    public var center: MaskPoint
    public var pixelSize: Int
    public init(center: MaskPoint = .init(x: 0.5, y: 0.5), pixelSize: Int = 768) {
        self.center = center; self.pixelSize = pixelSize
    }

    public func validate() throws {
        guard center.x.isFinite, center.y.isFinite,
              (0...1).contains(center.x), (0...1).contains(center.y),
              (64...1024).contains(pixelSize) else {
            throw AtelierError.invalidConfiguration("原尺寸检查位置须在画面内，检查边长须为 64...1024 像素。")
        }
    }

    public func bounds(in extent: CGRect) throws -> CGRect {
        try validate()
        guard !extent.isNull, !extent.isInfinite,
              [extent.minX, extent.minY, extent.maxX, extent.maxY].allSatisfy(\.isFinite),
              extent.width >= 1, extent.height >= 1 else {
            throw AtelierError.invalidConfiguration("原尺寸检查需要有限且非空的输出范围。")
        }
        let left = ceil(extent.minX), bottom = ceil(extent.minY)
        let right = floor(extent.maxX), top = floor(extent.maxY)
        guard right > left, top > bottom else {
            throw AtelierError.invalidConfiguration("输出范围没有完整的可检查像素。")
        }
        let width = min(CGFloat(pixelSize), right - left)
        let height = min(CGFloat(pixelSize), top - bottom)
        let cx = left + CGFloat(center.x) * (right - left)
        let cy = top - CGFloat(center.y) * (top - bottom)
        let x = max(left, min(right - width, floor(cx - width / 2)))
        let y = max(bottom, min(top - height, floor(cy - height / 2)))
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

/// Only small, materialized rasters leave the inspection task. No full source
/// graph, face coordinates or file paths are retained in this value.
public struct NativeInspectionResult {
    public let before: CGImage
    public let after: CGImage
    public let overview: CGImage
    public let outputExtent: CGRect
    public let sampleBounds: CGRect
    public let report: ProcessingReport
}

public final class NativeInspectionRenderer {
    private let engine: PhotoEngine
    public init(engine: PhotoEngine = PhotoEngine()) { self.engine = engine }

    public func render(_ image: CIImage, settings: AdjustmentSettings, lut: LUTCube?,
                       outputColorSpace: OutputColorSpace = .sRGB,
                       initialReport: ProcessingReport = .init(),
                       region: NativeInspectionRegion = .init(),
                       cancellation: CancellationToken? = nil) throws -> NativeInspectionResult {
        try region.validate()
        try cancellation?.check()
        // Source is deliberately not cropped or resized: every global reduction,
        // semantic selection, mask and adaptive measurement sees the full frame.
        let processed = try engine.process(image, settings: settings, lut: lut,
            initialReport: initialReport, outputColorSpace: outputColorSpace, cancellation: cancellation)
        try cancellation?.check()
        var base = settings; base.masks = []
        let before = try engine.process(image, settings: base, lut: nil,
            initialReport: initialReport, outputColorSpace: outputColorSpace, cancellation: cancellation)
        guard before.image.extent == processed.image.extent else {
            throw AtelierError.invalidConfiguration("原尺寸比较的基础图和完整效果几何范围不一致。")
        }
        let bounds = try region.bounds(in: processed.image.extent)
        let colorSpace = outputColorSpace.cgColorSpace
        func raster(_ input: CIImage, bounds: CGRect, padding: CGFloat = 0) throws -> CGImage {
            try cancellation?.check()
            let extent = input.extent
            let interior = CGRect(x: ceil(extent.minX), y: ceil(extent.minY),
                width: floor(extent.maxX) - ceil(extent.minX),
                height: floor(extent.maxY) - ceil(extent.minY))
            let renderedBounds = padding > 0
                ? bounds.insetBy(dx: -padding, dy: -padding).intersection(interior) : bounds
            guard let cg = engine.context.createCGImage(input, from: renderedBounds, format: .RGBA8,
                                                        colorSpace: colorSpace, deferred: false),
                  let raw = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(raw) else {
                throw AtelierError.imageRead("无法渲染原尺寸检查区域。")
            }
            // CI can otherwise hand back a deferred provider that retains the
            // full source graph and evaluates later on the UI thread.
            let owned = Data(bytes: bytes, count: CFDataGetLength(raw)) as CFData
            guard let provider = CGDataProvider(data: owned),
                  let raster = CGImage(width: cg.width, height: cg.height,
                    bitsPerComponent: cg.bitsPerComponent, bitsPerPixel: cg.bitsPerPixel,
                    bytesPerRow: cg.bytesPerRow, space: cg.colorSpace ?? colorSpace,
                    bitmapInfo: cg.bitmapInfo, provider: provider, decode: nil,
                    shouldInterpolate: false, intent: cg.renderingIntent) else {
                throw AtelierError.imageRead("无法保留原尺寸检查的独立像素缓冲。")
            }
            // RAW demosaicing can differ at a requested render boundary. Read a
            // small surrounding support region, then crop the owned raster.
            let crop = CGRect(x: bounds.minX - renderedBounds.minX,
                y: renderedBounds.maxY - bounds.maxY, width: bounds.width, height: bounds.height)
            guard let sample = raster.cropping(to: crop) else {
                throw AtelierError.imageRead("无法裁取原尺寸检查的完整像素区域。")
            }
            try cancellation?.check()
            return sample
        }
        let beforeRaster = try raster(before.image, bounds: bounds, padding: 8)
        let afterRaster = try raster(processed.image, bounds: bounds, padding: 8)
        guard beforeRaster.width == Int(bounds.width), beforeRaster.height == Int(bounds.height),
              afterRaster.width == beforeRaster.width, afterRaster.height == beforeRaster.height else {
            throw AtelierError.imageRead("原尺寸检查区域发生了意外缩放。")
        }
        let extent = processed.image.extent
        let scale = min(1, 360 / max(extent.width, extent.height))
        let w = max(1, Int((extent.width * scale).rounded()))
        let h = max(1, Int((extent.height * scale).rounded()))
        let overviewImage = processed.image
            .transformed(by: .init(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: .init(scaleX: CGFloat(w) / extent.width, y: CGFloat(h) / extent.height))
        let overview = try raster(overviewImage, bounds: CGRect(x: 0, y: 0, width: w, height: h))
        return NativeInspectionResult(before: beforeRaster, after: afterRaster, overview: overview,
            outputExtent: extent, sampleBounds: bounds, report: processed.report)
    }
}

import CLensfunBridge
import CoreGraphics
import CoreImage
import Foundation
import ImageIO

public struct LensProfileSummary: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let maker: String
    public let cropFactor: Double

    public init(id: String, name: String, maker: String, cropFactor: Double) {
        self.id = id
        self.name = name
        self.maker = maker
        self.cropFactor = cropFactor
    }
}

/// Lensfun-backed lens distortion correction. The database is loaded once and
/// treated as read-only; each correction receives its own Lensfun modifier.
public final class LensCorrection {
    public static let shared = LensCorrection()

    private static let maximumMapPixels = 40_000_000
    private static let geometryKernel = CIKernel(source: """
    kernel vec4 lensfunWarp(sampler source, sampler coordinateMap) {
        vec2 mapCoordinate = samplerCoord(coordinateMap);
        vec2 sourceCoordinate = sample(coordinateMap, mapCoordinate).rg;
        return sample(source, samplerTransform(source, sourceCoordinate));
    }
    """)

    private let bridge: OpaquePointer?
    private let creationError: String?
    private let profileSummaries: [LensProfileSummary]

    public var availabilityDescription: String {
        guard let bridge else { return creationError ?? "Lensfun 当前不可用。" }
        guard let value = lfb_availability(bridge) else { return "Lensfun 已加载，但状态信息不可用。" }
        return String(cString: value)
    }

    public var profiles: [LensProfileSummary] {
        profileSummaries
    }

    private static func readProfiles(from bridge: OpaquePointer) -> [LensProfileSummary] {
        let count = lfb_profile_count(bridge)
        guard count > 0 else { return [] }
        var result: [LensProfileSummary] = []
        result.reserveCapacity(min(count, 20_000))
        for index in 0..<count {
            var native = LFBProfileInfo()
            guard lfb_profile_at(bridge, index, &native) != 0,
                  let identifier = native.identifier,
                  let name = native.name,
                  let maker = native.maker else { continue }
            result.append(LensProfileSummary(id: String(cString: identifier),
                                             name: String(cString: name),
                                             maker: String(cString: maker),
                                             cropFactor: native.crop_factor))
        }
        return result.sorted {
            let lhs = "\($0.maker) \($0.name)"
            let rhs = "\($1.maker) \($1.name)"
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }

    public init() {
        let roots = Self.runtimeRoots()
        var errorBuffer = [CChar](repeating: 0, count: 1024)
        let created = Self.withCString(roots.project) { project in
            Self.withCString(roots.frameworks) { frameworks in
                Self.withCString(roots.resources) { resources in
                    errorBuffer.withUnsafeMutableBufferPointer { buffer in
                        lfb_create(project, frameworks, resources,
                                   buffer.baseAddress, buffer.count)
                    }
                }
            }
        }
        self.bridge = created
        self.profileSummaries = created.map(Self.readProfiles(from:)) ?? []
        if created == nil {
            let message = errorBuffer.withUnsafeBufferPointer { pointer -> String? in
                guard let baseAddress = pointer.baseAddress, baseAddress.pointee != 0 else { return nil }
                return String(cString: baseAddress)
            }
            self.creationError = message ?? "无法加载 Lensfun 运行库或数据库。"
        } else {
            self.creationError = nil
        }
    }

    /// Applies lens distortion correction when exactly one compatible profile
    /// is available. Missing or ambiguous metadata returns the original graph
    /// with a warning; operational failures throw for batch-level isolation.
    public func correct(_ image: CIImage,
                        properties: [String: Any],
                        profileID: String?,
                        cropFactor: Double,
                        focalLength: Double = 0) throws -> ProcessedPhoto {
        var report = ProcessingReport()
        guard let bridge else {
            report.warnings.append(availabilityDescription)
            return ProcessedPhoto(image: image, report: report)
        }
        let selectedFocalLength = focalLength == 0
            ? Self.focalLength(from: properties)
            : focalLength
        guard let selectedFocalLength,
              selectedFocalLength.isFinite,
              selectedFocalLength >= 1, selectedFocalLength <= 2_000 else {
            report.warnings.append("缺少有效 EXIF 焦距 FocalLength，未应用镜头配置校正。")
            return ProcessedPhoto(image: image, report: report)
        }
        guard cropFactor.isFinite, cropFactor >= 0, cropFactor <= 10 else {
            report.warnings.append("裁切系数无效，未应用镜头配置校正。")
            return ProcessedPhoto(image: image, report: report)
        }
        let extent = image.extent.integral
        guard !extent.isNull, !extent.isInfinite,
              extent.width > 0, extent.height > 0,
              extent.width <= CGFloat(Int32.max), extent.height <= CGFloat(Int32.max) else {
            report.warnings.append("图像尺寸无效，未应用镜头配置校正。")
            return ProcessedPhoto(image: image, report: report)
        }
        let width = Int(extent.width)
        let height = Int(extent.height)
        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixelCount > 0, pixelCount <= Self.maximumMapPixels else {
            report.warnings.append("镜头校正映射超过 4000 万像素安全上限，未应用校正。")
            return ProcessedPhoto(image: image, report: report)
        }

        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let cameraMake = Self.string(tiff[kCGImagePropertyTIFFMake as String])
        let cameraModel = Self.string(tiff[kCGImagePropertyTIFFModel as String])
        let lensMaker = Self.string(exif[kCGImagePropertyExifLensMake as String])
        let lensModel = Self.string(exif[kCGImagePropertyExifLensModel as String])
        let manualID = profileID.flatMap { $0.isEmpty ? nil : $0 }

        var mapPointer: UnsafeMutablePointer<Float>?
        var mapFloatCount = 0
        var mapInfo = LFBMapInfo()
        var errorBuffer = [CChar](repeating: 0, count: 1024)
        let status = Self.withCString(manualID) { profile in
            Self.withCString(cameraMake) { make in
                Self.withCString(cameraModel) { model in
                    Self.withCString(lensMaker) { maker in
                        Self.withCString(lensModel) { lens in
                            errorBuffer.withUnsafeMutableBufferPointer { buffer in
                                lfb_compute_geometry_map(bridge, profile, make, model, maker, lens,
                                                         selectedFocalLength, cropFactor,
                                                         Int32(width), Int32(height),
                                                         &mapPointer, &mapFloatCount,
                                                         &mapInfo, buffer.baseAddress, buffer.count)
                            }
                        }
                    }
                }
            }
        }
        guard status == LFB_STATUS_OK, let generatedMap = mapPointer else {
            let nativeMessage = errorBuffer.withUnsafeBufferPointer { pointer -> String? in
                guard let baseAddress = pointer.baseAddress, baseAddress.pointee != 0 else { return nil }
                return String(cString: baseAddress)
            }
            report.warnings.append(nativeMessage ?? String(cString: lfb_status_message(status)))
            return ProcessedPhoto(image: image, report: report)
        }
        defer {
            if let mapPointer { lfb_release_map(mapPointer) }
        }

        let expectedFloats = pixelCount.multipliedReportingOverflow(by: 2)
        guard !expectedFloats.overflow, mapFloatCount == expectedFloats.partialValue else {
            throw AtelierError.invalidConfiguration("Lensfun 映射长度与原图尺寸不匹配。")
        }
        let safeBounds = Self.largestValidRectangle(map: UnsafeBufferPointer(start: generatedMap,
                                                                              count: mapFloatCount),
                                                    width: width, height: height)
        guard let safeBounds, safeBounds.width >= width / 2,
              safeBounds.height >= height / 2 else {
            report.warnings.append("畸变映射没有足够大的完整图像区域，未应用镜头配置校正。")
            return ProcessedPhoto(image: image, report: report)
        }
        let validRect = Self.aspectPreservingRectangle(safeBounds,
                                                       canvasWidth: width,
                                                       canvasHeight: height)

        let dataBytes = mapFloatCount * MemoryLayout<Float>.size
        // Lensfun coordinates use top-left, integer-centered pixels. Core Image
        // samples from a lower-left, half-pixel-centered coordinate space. Keep
        // Lensfun's row order in the bitmap (row zero is the top row), and map
        // each source pixel center into Core Image coordinates in place.
        for row in 0..<height {
            for column in 0..<width {
                let offset = (row * width + column) * 2
                let sourceX = generatedMap[offset]
                let sourceY = generatedMap[offset + 1]
                generatedMap[offset] = Float(extent.minX) + sourceX + 0.5
                generatedMap[offset + 1] = Float(extent.minY) + Float(height) - sourceY - 0.5
            }
        }
        let mapData = Data(bytesNoCopy: UnsafeMutableRawPointer(generatedMap),
                           count: dataBytes,
                           deallocator: .custom { pointer, _ in
                               lfb_release_map(pointer.assumingMemoryBound(to: Float.self))
                           })
        mapPointer = nil
        let mapImage = CIImage(bitmapData: mapData,
                               bytesPerRow: width * 2 * MemoryLayout<Float>.size,
                               size: CGSize(width: width, height: height),
                               format: .RGf, colorSpace: nil)
        let translatedMap = mapImage.transformed(by: CGAffineTransform(translationX: extent.minX,
                                                                        y: extent.minY))
        guard let kernel = Self.geometryKernel else {
            throw AtelierError.invalidConfiguration("Core Image Lensfun 映射 kernel 编译失败。")
        }
        guard let warped = kernel.apply(extent: extent,
                                        roiCallback: { index, _ in
                                            index == 0 ? extent : translatedMap.extent
                                        },
                                        arguments: [image, translatedMap]) else {
            throw AtelierError.invalidConfiguration("Core Image Lensfun 映射无法生成输出。")
        }

        let ciCropRect = CGRect(x: extent.minX + validRect.minX,
                                y: extent.minY + validRect.minY,
                                width: validRect.width,
                                height: validRect.height)
        var corrected = warped.cropped(to: ciCropRect)
        if !validRect.equalTo(CGRect(origin: .zero, size: extent.size)) {
            let shifted = corrected.clampedToExtent()
                .transformed(by: CGAffineTransform(translationX: -ciCropRect.minX,
                                                   y: -ciCropRect.minY))
            let scale = extent.width / ciCropRect.width
            let scaled = shifted.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            corrected = scaled.transformed(by: CGAffineTransform(translationX: extent.minX,
                                                                  y: extent.minY)).cropped(to: extent)
            report.warnings.append("为避免镜头畸变校正产生透明边缘，已裁切安全区域并缩放回原尺寸。")
        }
        guard let profileName = mapInfo.profile_name,
              let profileMaker = mapInfo.profile_maker else {
            throw AtelierError.invalidConfiguration("Lensfun 成功返回映射，但缺少镜头配置描述。")
        }
        let name = String(cString: profileName)
        let maker = String(cString: profileMaker)
        report.lensCorrectionApplied = true
        report.lensProfile = maker.isEmpty ? name : "\(maker) \(name)"
        return ProcessedPhoto(image: corrected, report: report)
    }

    private struct PixelBounds {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
    }

    private static func aspectPreservingRectangle(_ bounds: PixelBounds,
                                                  canvasWidth: Int,
                                                  canvasHeight: Int) -> CGRect {
        let targetAspect = Double(canvasWidth) / Double(canvasHeight)
        let boundsAspect = Double(bounds.width) / Double(bounds.height)
        let cropWidth: CGFloat
        let cropHeight: CGFloat
        if boundsAspect > targetAspect {
            cropHeight = CGFloat(bounds.height)
            cropWidth = CGFloat(Double(bounds.height) * targetAspect)
        } else {
            cropWidth = CGFloat(bounds.width)
            cropHeight = CGFloat(Double(bounds.width) / targetAspect)
        }
        return CGRect(x: CGFloat(bounds.x) + (CGFloat(bounds.width) - cropWidth) / 2,
                      y: CGFloat(bounds.y) + (CGFloat(bounds.height) - cropHeight) / 2,
                      width: cropWidth, height: cropHeight)
    }

    private static func largestValidRectangle(map: UnsafeBufferPointer<Float>,
                                              width: Int, height: Int) -> PixelBounds? {
        guard map.count == width * height * 2 else { return nil }
        var heights = [Int](repeating: 0, count: width)
        var stack: [Int] = []
        stack.reserveCapacity(width)
        var best: PixelBounds?
        var bestArea = 0
        let centerX = width / 2
        let centerY = height / 2
        var foundInvalid = false

        for y in 0..<height {
            let lensFunRow = height - y - 1
            for x in 0..<width {
                let offset = (lensFunRow * width + x) * 2
                let sourceX = map[offset]
                let sourceY = map[offset + 1]
                let isValid = sourceX.isFinite && sourceY.isFinite &&
                    sourceX >= 0 && sourceX <= Float(width - 1) &&
                    sourceY >= 0 && sourceY <= Float(height - 1)
                if isValid {
                    heights[x] += 1
                } else {
                    heights[x] = 0
                    foundInvalid = true
                }
            }
            stack.removeAll(keepingCapacity: true)
            for x in 0...width {
                let currentHeight = x == width ? 0 : heights[x]
                while let last = stack.last, heights[last] > currentHeight {
                    let rectHeight = heights[stack.removeLast()]
                    let rectX = (stack.last ?? -1) + 1
                    let rectWidth = x - rectX
                    let rectY = y - rectHeight + 1
                    let rectBottom = y
                    let area = rectWidth * rectHeight
                    if rectWidth > 0, rectHeight > 0,
                       rectX <= centerX, centerX < rectX + rectWidth,
                       rectY <= centerY, centerY <= rectBottom,
                       area > bestArea {
                        bestArea = area
                        best = PixelBounds(x: rectX, y: rectY,
                                           width: rectWidth, height: rectHeight)
                    }
                }
                stack.append(x)
            }
        }
        if !foundInvalid { return PixelBounds(x: 0, y: 0, width: width, height: height) }
        return best
    }

    private static func focalLength(from properties: [String: Any]) -> Double? {
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        guard let value = exif[kCGImagePropertyExifFocalLength as String] else { return nil }
        if let number = value as? NSNumber { return number.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func string(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func withCString<T>(_ value: String?, body: (UnsafePointer<CChar>?) -> T) -> T {
        guard let value else { return body(nil) }
        return value.withCString(body)
    }

    private static func runtimeRoots() -> (project: String?, frameworks: String?, resources: String?) {
        let environment = ProcessInfo.processInfo.environment["PROJECT_ROOT"]
        let project = environment.flatMap { $0.isEmpty ? nil : $0 } ?? findDevelopmentProjectRoot()
        let frameworks = Bundle.main.privateFrameworksURL?
            .appendingPathComponent("Lensfun", isDirectory: true).path
        let resources = Bundle.main.resourceURL?.path
        return (project, frameworks, resources)
    }

    private static func findDevelopmentProjectRoot() -> String? {
        var current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        for _ in 0..<16 {
            let dependency = current.appendingPathComponent(".dependencies/lensfun", isDirectory: true)
            if FileManager.default.fileExists(atPath: dependency.path) {
                return current.path
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return nil
    }
}

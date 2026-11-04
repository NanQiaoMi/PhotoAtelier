import CoreGraphics
import CoreImage
import Foundation

// MARK: - Certificate photo sizes

/// Standard ID-photo sizes in millimetres freshly rendered at a requested DPI.
///
/// The millimetre values are the common Chinese certificate-photo definitions;
/// pixel sizes are rounded to whole pixels at the requested DPI. This is
/// geometry only — the crop heuristic (`cropRect`) is a v1 landmark heuristic,
/// not a commercial head-shot composition engine.
public enum IDPhotoSize: String, Codable, CaseIterable, Identifiable {
    case oneInch, twoInch, smallOneInch, largeOneInch, smallTwoInch

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .oneInch: return "一寸"
        case .twoInch: return "二寸"
        case .smallOneInch: return "小一寸"
        case .largeOneInch: return "大一寸"
        case .smallTwoInch: return "小二寸"
        }
    }

    /// Physical size in millimetres (width × height).
    public var millimeters: CGSize {
        switch self {
        case .oneInch: return CGSize(width: 25, height: 35)
        case .twoInch: return CGSize(width: 35, height: 49)
        case .smallOneInch: return CGSize(width: 22, height: 32)
        case .largeOneInch: return CGSize(width: 33, height: 48)
        case .smallTwoInch: return CGSize(width: 35, height: 45)
        }
    }
}

// MARK: - Cropping

/// Head-shot crop settings. All inputs are normalized to the source image
/// (bottom-left origin) and all outputs are pixel rectangles in Core Image
/// coordinates.
public struct IDPhotoCropSettings: Codable, Equatable {
    public var size: IDPhotoSize = .oneInch
    /// Output DPI used to convert the physical size to pixels (`72...1200`).
    public var dpi: Double = 300
    /// Target head height (hair top to chin) as a fraction of the crop height
    /// (`0.30...0.90`). 0.62 approximates a standard ID-photo head ratio.
    public var headHeightRatio: Double = 0.62
    /// Space above the head as a fraction of the crop height (`0...0.40`).
    public var headTopMarginRatio: Double = 0.08
    /// Horizontal shift as a fraction of the crop width (`-0.5...0.5`).
    public var horizontalOffset: Double = 0
    /// Multiplier applied to the detected face height to approximate the full
    /// head (hair above the Vision face box); `1.0...1.6`.
    public var faceInflate: Double = 1.30

    public init(size: IDPhotoSize = .oneInch,
                dpi: Double = 300,
                headHeightRatio: Double = 0.62,
                headTopMarginRatio: Double = 0.08,
                horizontalOffset: Double = 0,
                faceInflate: Double = 1.30) {
        self.size = size
        self.dpi = dpi
        self.headHeightRatio = headHeightRatio
        self.headTopMarginRatio = headTopMarginRatio
        self.horizontalOffset = horizontalOffset
        self.faceInflate = faceInflate
    }

    public func validated() throws -> IDPhotoCropSettings {
        guard dpi.isFinite, (72...1200).contains(dpi) else {
            throw AtelierError.invalidConfiguration("证件照 DPI 必须在 72...1200 之间。")
        }
        guard headHeightRatio.isFinite, (0.30...0.90).contains(headHeightRatio) else {
            throw AtelierError.invalidConfiguration("证件照头部高度比例必须在 0.30...0.90 之间。")
        }
        guard headTopMarginRatio.isFinite, (0...0.40).contains(headTopMarginRatio) else {
            throw AtelierError.invalidConfiguration("证件照头顶留白必须在 0...0.40 之间。")
        }
        guard horizontalOffset.isFinite, (-0.5...0.5).contains(horizontalOffset) else {
            throw AtelierError.invalidConfiguration("证件照水平偏移必须在 -0.5...0.5 之间。")
        }
        guard faceInflate.isFinite, (1.0...1.6).contains(faceInflate) else {
            throw AtelierError.invalidConfiguration("证件照头部膨胀系数必须在 1.0...1.6 之间。")
        }
        return self
    }

    public var pixelSize: CGSize {
        IDPhotoLayout.pixelSize(for: size, dpi: dpi)
    }
}

// MARK: - Print sheets

/// Common photo-paper sizes in millimetres.
public enum PrintPaper: String, Codable, CaseIterable, Identifiable {
    case fiveInch, sixInch, a4

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .fiveInch: return "5 寸相纸"
        case .sixInch: return "6 寸相纸"
        case .a4: return "A4 相纸"
        }
    }

    public var millimeters: CGSize {
        switch self {
        case .fiveInch: return CGSize(width: 88.9, height: 127)
        case .sixInch: return CGSize(width: 101.6, height: 152.4)
        case .a4: return CGSize(width: 210, height: 297)
        }
    }
}

/// Print-sheet settings. `rows`/`columns` nil means "fit as many as possible";
/// explicit values must fit inside the paper minus margins, otherwise the layout
/// throws instead of silently clipping photos.
public struct PrintSheetSettings: Codable, Equatable {
    public var paper: PrintPaper = .sixInch
    public var dpi: Double = 300
    /// Fixed row count (`nil` = automatic).
    public var rows: Int? = nil
    /// Fixed column count (`nil` = automatic).
    public var columns: Int? = nil
    public var spacingMM: Double = 2
    public var marginMM: Double = 3
    public var photoSize: IDPhotoSize = .oneInch

    public init(paper: PrintPaper = .sixInch,
                dpi: Double = 300,
                rows: Int? = nil,
                columns: Int? = nil,
                spacingMM: Double = 2,
                marginMM: Double = 3,
                photoSize: IDPhotoSize = .oneInch) {
        self.paper = paper
        self.dpi = dpi
        self.rows = rows
        self.columns = columns
        self.spacingMM = spacingMM
        self.marginMM = marginMM
        self.photoSize = photoSize
    }

    public func validated() throws -> PrintSheetSettings {
        guard dpi.isFinite, (72...1200).contains(dpi) else {
            throw AtelierError.invalidConfiguration("排版 DPI 必须在 72...1200 之间。")
        }
        guard spacingMM.isFinite, (0...50).contains(spacingMM) else {
            throw AtelierError.invalidConfiguration("排版间距必须在 0...50mm 之间。")
        }
        guard marginMM.isFinite, (0...50).contains(marginMM) else {
            throw AtelierError.invalidConfiguration("排版边距必须在 0...50mm 之间。")
        }
        if let rows { guard (1...20).contains(rows) else {
            throw AtelierError.invalidConfiguration("排版行数必须在 1...20 之间。")
        } }
        if let columns { guard (1...20).contains(columns) else {
            throw AtelierError.invalidConfiguration("排版列数必须在 1...20 之间。")
        } }
        return self
    }
}

/// Geometry for one print sheet. `cellOrigins` are bottom-left pixel origins in
/// row-major order starting from the sheet's bottom-left grid cell. The grid is
/// centred inside the paper with at least `marginPixels` on every side.
public struct PrintSheetLayout: Equatable {
    public var paperPixelSize: CGSize
    public var photoPixelSize: CGSize
    public var columns: Int
    public var rows: Int
    public var marginPixels: Double
    public var spacingPixels: Double
    public var cellOrigins: [CGPoint]

    public init(paperPixelSize: CGSize, photoPixelSize: CGSize,
                columns: Int, rows: Int, marginPixels: Double,
                spacingPixels: Double, cellOrigins: [CGPoint]) {
        self.paperPixelSize = paperPixelSize
        self.photoPixelSize = photoPixelSize
        self.columns = columns
        self.rows = rows
        self.marginPixels = marginPixels
        self.spacingPixels = spacingPixels
        self.cellOrigins = cellOrigins
    }

    public var count: Int { rows * columns }
}

// MARK: - Layout

/// Pure geometry for certificate-photo cropping and print-sheet layout.
public enum IDPhotoLayout {
    public static let millimetersPerInch = 25.4

    /// Pixel size of a physical photo size at `dpi`, rounded to whole pixels.
    public static func pixelSize(for size: IDPhotoSize, dpi: Double = 300) -> CGSize {
        let millimeters = size.millimeters
        guard dpi.isFinite, dpi > 0 else { return .zero }
        let width = (Double(millimeters.width) / millimetersPerInch * dpi).rounded()
        let height = (Double(millimeters.height) / millimetersPerInch * dpi).rounded()
        return CGSize(width: max(1, width), height: max(1, height))
    }

    /// Computes the pixel crop rectangle (Core Image, bottom-left origin) that
    /// places the detected face/head at the preset ratio.
    ///
    /// The face box is the normalized Vision face rectangle. The crop height is
    /// derived from an inflated head height (hair approximation), the crop is
    /// horizontally centred on the face and shifted by `headTopMarginRatio`. When
    /// the source is too small for the requested crop, the crop is clamped to the
    /// source bounds (the head ratio degrades rather than producing out-of-bounds
    /// sampling); callers should validate the returned aspect/ratio if they need
    /// an exact composition.
    public static func cropRect(faceBox: CGRect, sourceSize: CGSize,
                                settings: IDPhotoCropSettings = IDPhotoCropSettings()) throws -> CGRect {
        let settings = try settings.validated()
        guard sourceSize.width.isFinite, sourceSize.height.isFinite,
              sourceSize.width >= 8, sourceSize.height >= 8,
              sourceSize.width <= 100_000, sourceSize.height <= 100_000 else {
            throw AtelierError.invalidConfiguration("证件照裁剪的源图尺寸无效。")
        }
        let box = try validatedFaceBox(faceBox)
        let target = pixelSize(for: settings.size, dpi: settings.dpi)
        let aspect = Double(target.width) / Double(target.height)

        let faceHeight = Double(box.height)
        let inflatedTop = min(1.0, Double(box.maxY) + (settings.faceInflate - 1) * faceHeight)
        let chin = max(0.0, Double(box.minY))
        let headHeight = max(0.002, inflatedTop - chin)

        var cropHeight = headHeight * Double(sourceSize.height) / settings.headHeightRatio
        var cropWidth = cropHeight * aspect
        if cropWidth > Double(sourceSize.width) {
            cropWidth = Double(sourceSize.width)
            cropHeight = cropWidth / aspect
        }
        if cropHeight > Double(sourceSize.height) {
            cropHeight = Double(sourceSize.height)
            cropWidth = cropHeight * aspect
        }
        guard cropWidth >= 8, cropHeight >= 8 else {
            throw AtelierError.invalidConfiguration("源图尺寸不足以生成证件照裁剪。")
        }

        let headTopPixels = inflatedTop * Double(sourceSize.height)
        let desiredTop = headTopPixels + settings.headTopMarginRatio * cropHeight
        var originY = desiredTop - cropHeight
        originY = min(max(0, originY), Double(sourceSize.height) - cropHeight)

        let faceCenterX = Double(box.midX) * Double(sourceSize.width)
        var originX = faceCenterX - cropWidth / 2 + settings.horizontalOffset * cropWidth
        originX = min(max(0, originX), Double(sourceSize.width) - cropWidth)
        return CGRect(x: originX, y: originY, width: cropWidth, height: cropHeight)
    }

    /// Crops and resamples the photo to the exact preset pixel size. The output
    /// extent is `(0, 0, pixelWidth, pixelHeight)`.
    public static func render(photo: CIImage, faceBox: CGRect,
                              settings: IDPhotoCropSettings = IDPhotoCropSettings()) throws -> CIImage {
        let settings = try settings.validated()
        let extent = try PersonMatting.validExtent(of: photo)
        let sourceSize = extent.size
        var rect = try cropRect(faceBox: faceBox, sourceSize: sourceSize, settings: settings)
        // The crop is in source-image pixel coordinates; translate to the extent
        // origin if the image is offset.
        rect = rect.offsetBy(dx: extent.minX, dy: extent.minY)
        let target = pixelSize(for: settings.size, dpi: settings.dpi)
        let outputExtent = CGRect(origin: .zero, size: target)
        let scaleX = CGFloat(target.width) / rect.width
        let scaleY = CGFloat(target.height) / rect.height
        let output = photo
            .cropped(to: rect)
            .transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .cropped(to: outputExtent)
        guard output.extent.width.isFinite, output.extent.height.isFinite,
              output.extent.width > 0, output.extent.height > 0 else {
            throw AtelierError.invalidConfiguration("证件照渲染输出尺寸无效。")
        }
        return output
    }

    /// Computes the print-sheet grid. Automatic mode fits the maximum count; an
    /// explicit rows/columns value must fit or the layout fails loudly.
    public static func printLayout(_ settings: PrintSheetSettings = PrintSheetSettings()) throws -> PrintSheetLayout {
        let settings = try settings.validated()
        let paperMM = settings.paper.millimeters
        let paperPx = CGSize(
            width: (Double(paperMM.width) / millimetersPerInch * settings.dpi).rounded(),
            height: (Double(paperMM.height) / millimetersPerInch * settings.dpi).rounded())
        let photoPx = pixelSize(for: settings.photoSize, dpi: settings.dpi)
        func millimetersToPixels(_ mm: Double) -> Double {
            (mm / millimetersPerInch * settings.dpi).rounded()
        }
        let margin = millimetersToPixels(settings.marginMM)
        let spacing = millimetersToPixels(settings.spacingMM)
        let availableWidth = Double(paperPx.width) - 2 * margin
        let availableHeight = Double(paperPx.height) - 2 * margin
        guard availableWidth >= Double(photoPx.width),
              availableHeight >= Double(photoPx.height) else {
            throw AtelierError.invalidConfiguration("纸张可用区域小于证件照尺寸，无法排版。")
        }
        func maximumCount(available: Double, item: Double) -> Int {
            max(1, Int(floor((available + spacing) / (item + spacing))))
        }
        let maximumColumns = maximumCount(available: availableWidth,
                                          item: Double(photoPx.width))
        let maximumRows = maximumCount(available: availableHeight,
                                       item: Double(photoPx.height))
        let columns = settings.columns ?? maximumColumns
        let rows = settings.rows ?? maximumRows
        guard columns >= 1, rows >= 1 else {
            throw AtelierError.invalidConfiguration("排版行列数必须至少为 1。")
        }
        let gridWidth = Double(columns) * Double(photoPx.width) + Double(columns - 1) * spacing
        let gridHeight = Double(rows) * Double(photoPx.height) + Double(rows - 1) * spacing
        let tolerance = 0.5
        guard gridWidth <= availableWidth + tolerance,
              gridHeight <= availableHeight + tolerance else {
            throw AtelierError.invalidConfiguration("指定的排版行列超出纸张可用区域。")
        }
        let startX = (Double(paperPx.width) - gridWidth) / 2
        let startY = (Double(paperPx.height) - gridHeight) / 2
        var origins: [CGPoint] = []
        origins.reserveCapacity(rows * columns)
        for row in 0..<rows {
            for column in 0..<columns {
                origins.append(CGPoint(
                    x: startX + Double(column) * (Double(photoPx.width) + spacing),
                    y: startY + Double(row) * (Double(photoPx.height) + spacing)))
            }
        }
        return PrintSheetLayout(paperPixelSize: paperPx, photoPixelSize: photoPx,
                                columns: columns, rows: rows,
                                marginPixels: margin, spacingPixels: spacing,
                                cellOrigins: origins)
    }

    // MARK: Helpers

    static func validatedFaceBox(_ box: CGRect) throws -> CGRect {
        guard box.minX.isFinite, box.minY.isFinite,
              box.width.isFinite, box.height.isFinite,
              box.width >= 0.005, box.height >= 0.005 else {
            throw AtelierError.invalidConfiguration("证件照裁剪需要有效的人脸框（归一化坐标，宽高至少 0.5%）。")
        }
        let clipped = box.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !clipped.isNull, clipped.width >= 0.005, clipped.height >= 0.005 else {
            throw AtelierError.invalidConfiguration("证件照裁剪的人脸框不在图像范围内。")
        }
        return clipped
    }
}

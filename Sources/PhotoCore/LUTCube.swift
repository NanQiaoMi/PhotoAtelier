import Foundation

public enum LUTPresetGroup: String, Codable, CaseIterable, Equatable {
    case natural
    case portrait
    case cinematic
    case landscape
    case monochrome

    public var title: String {
        switch self {
        case .natural: return "自然"
        case .portrait: return "人像"
        case .cinematic: return "电影"
        case .landscape: return "风光"
        case .monochrome: return "黑白"
        }
    }
}

public struct LUTPreset: Identifiable {
    public let id: String
    public let name: String
    public let detail: String
    public let cube: LUTCube
    public let group: LUTPresetGroup
    public let recommendedIntensity: Double
    public let tags: [String]
    public let provenance: LUTProvenance?

    public init(id: String, name: String, detail: String, cube: LUTCube,
                group: LUTPresetGroup = .natural,
                recommendedIntensity: Double = 0.35,
                tags: [String] = [],
                provenance: LUTProvenance? = nil) {
        self.id = id
        self.name = name
        self.detail = detail
        self.cube = cube
        self.group = group
        self.recommendedIntensity = recommendedIntensity.isFinite
            ? min(max(recommendedIntensity, 0), 1) : 0.35
        self.tags = tags
        self.provenance = provenance
    }
}

/// A parsed, 3D `.cube` LUT. The RGBA rows are stored with red changing fastest,
/// then green, then blue, which is the ordering used by the `.cube` text format.
public struct LUTCube {
    public let title: String
    public let size: Int
    public let domainMin: SIMD3<Float>
    public let domainMax: SIMD3<Float>
    /// Four Float values per lattice point. Standard `.cube` files contain
    /// RGB triplets; alpha is synthesized as 1 for Core Image.
    public let rgba: [Float]

    private static let maximumDimension = 128
    private static let maximumTextBytes = 128 * 1024 * 1024

    init(title: String, size: Int, domainMin: SIMD3<Float>,
         domainMax: SIMD3<Float>, rgba: [Float]) {
        self.title = title
        self.size = size
        self.domainMin = domainMin
        self.domainMax = domainMax
        self.rgba = rgba
    }

    public static func load(url: URL) throws -> LUTCube {
        let data: Data
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let byteCount = attributes[.size] as? NSNumber,
               byteCount.int64Value > Int64(maximumTextBytes) {
                throw AtelierError.invalidLUT("文件超过 128 MiB 的安全解析上限。")
            }
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch let error as AtelierError {
            throw error
        } catch {
            throw AtelierError.invalidLUT("读取文件失败：\(error.localizedDescription)")
        }

        guard data.count <= maximumTextBytes,
              let text = String(data: data, encoding: .utf8) else {
            throw AtelierError.invalidLUT("文件必须是 UTF-8 文本，且不超过 128 MiB。")
        }
        return try parse(text)
    }

    public static func parse(_ text: String) throws -> LUTCube {
        guard text.utf8.count <= maximumTextBytes else {
            throw AtelierError.invalidLUT("文本超过 128 MiB 的安全解析上限。")
        }

        var title = "Untitled LUT"
        var dimension: Int?
        var domainMin = SIMD3<Float>(repeating: 0)
        var domainMax = SIMD3<Float>(repeating: 1)
        var sawDomainMin = false
        var sawDomainMax = false
        var sawInputRange = false
        var rows: [Float] = []
        var rowCount = 0
        var hasStartedData = false

        let cString = text.utf8CString
        try cString.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            var ptr = base
            var lineNumber = 1

            while ptr.pointee != 0 {
                // Check BOM on line 1
                if lineNumber == 1 && ptr.pointee == -17 /* 0xEF */ {
                    if (ptr + 1).pointee == -69 /* 0xBB */ && (ptr + 2).pointee == -65 /* 0xBF */ {
                        ptr += 3
                    }
                }

                // Skip leading spaces / tabs
                while ptr.pointee == 32 || ptr.pointee == 9 {
                    ptr += 1
                }

                // Check empty line or newline
                if ptr.pointee == 10 { // LF
                    ptr += 1
                    lineNumber += 1
                    continue
                }
                if ptr.pointee == 13 { // CR
                    ptr += 1
                    if ptr.pointee == 10 { ptr += 1 }
                    lineNumber += 1
                    continue
                }
                if ptr.pointee == 0 {
                    break
                }

                // Check comment line
                if ptr.pointee == 35 /* # */ {
                    while ptr.pointee != 0 && ptr.pointee != 10 && ptr.pointee != 13 {
                        ptr += 1
                    }
                    if ptr.pointee == 10 { ptr += 1 }
                    else if ptr.pointee == 13 {
                        ptr += 1
                        if ptr.pointee == 10 { ptr += 1 }
                    }
                    lineNumber += 1
                    continue
                }

                // Check if directive line (TITLE, LUT_, DOMAIN_)
                let c = ptr.pointee
                let isDirectiveCandidate = !hasStartedData && (c == 84 /* T */ || c == 116 /* t */ ||
                                                               c == 76 /* L */ || c == 108 /* l */ ||
                                                               c == 68 /* D */ || c == 100 /* d */)

                if isDirectiveCandidate {
                    let lineStart = ptr
                    while ptr.pointee != 0 && ptr.pointee != 10 && ptr.pointee != 13 {
                        ptr += 1
                    }
                    let len = ptr - lineStart
                    let lineBytes = UnsafeBufferPointer(start: lineStart, count: len)
                    let rawLine = String(decoding: lineBytes.map { UInt8(bitPattern: $0) }, as: UTF8.self)

                    if ptr.pointee == 10 { ptr += 1 }
                    else if ptr.pointee == 13 {
                        ptr += 1
                        if ptr.pointee == 10 { ptr += 1 }
                    }

                    let line = removingInlineComment(from: rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
                    if line.isEmpty {
                        lineNumber += 1
                        continue
                    }

                    let tokens = line.split(whereSeparator: \.isWhitespace)
                    guard let first = tokens.first else {
                        lineNumber += 1
                        continue
                    }
                    let directive = first.uppercased()

                    switch directive {
                    case "TITLE":
                        guard !hasStartedData else {
                            throw invalid(lineNumber, "TITLE 必须位于 LUT 数据之前。")
                        }
                        let remainder = line.dropFirst(first.count).trimmingCharacters(in: .whitespaces)
                        guard !remainder.isEmpty else {
                            throw invalid(lineNumber, "TITLE 缺少名称。")
                        }
                        title = parseTitle(remainder)
                        lineNumber += 1
                        continue

                    case "LUT_3D_SIZE":
                        guard !hasStartedData, dimension == nil, tokens.count == 2,
                              let parsed = Int(tokens[1]) else {
                            throw invalid(lineNumber, "LUT_3D_SIZE 格式无效或重复。")
                        }
                        guard (2...maximumDimension).contains(parsed) else {
                            throw invalid(lineNumber, "LUT_3D_SIZE 必须在 2 到 \(maximumDimension) 之间。")
                        }
                        dimension = parsed
                        let expectedRows = parsed * parsed * parsed
                        rows.reserveCapacity(expectedRows * 4)
                        lineNumber += 1
                        continue

                    case "DOMAIN_MIN", "DOMAIN_MAX":
                        guard !hasStartedData, tokens.count == 4, !sawInputRange else {
                            throw invalid(lineNumber, "\(directive) 需要三个数值，且必须位于 LUT 数据之前。")
                        }
                        let values = try parseFiniteVector(tokens.dropFirst(), line: lineNumber)
                        if directive == "DOMAIN_MIN" {
                            guard !sawDomainMin else { throw invalid(lineNumber, "DOMAIN_MIN 重复。") }
                            domainMin = values
                            sawDomainMin = true
                        } else {
                            guard !sawDomainMax else { throw invalid(lineNumber, "DOMAIN_MAX 重复。") }
                            domainMax = values
                            sawDomainMax = true
                        }
                        lineNumber += 1
                        continue

                    case "LUT_3D_INPUT_RANGE":
                        guard !hasStartedData, tokens.count == 3, !sawInputRange,
                              !sawDomainMin, !sawDomainMax,
                              let minimum = Float(tokens[1]), let maximum = Float(tokens[2]),
                              minimum.isFinite, maximum.isFinite else {
                            throw invalid(lineNumber, "LUT_3D_INPUT_RANGE 需要两个有限数值，且不能与 DOMAIN_MIN/MAX 混用或重复。")
                        }
                        domainMin = SIMD3<Float>(repeating: minimum)
                        domainMax = SIMD3<Float>(repeating: maximum)
                        sawInputRange = true
                        lineNumber += 1
                        continue

                    case "LUT_1D_SIZE", "LUT_1D_INPUT_RANGE":
                        throw invalid(lineNumber, "只支持带 DOMAIN_MIN/MAX 的 3D LUT；不支持 \(directive)。")

                    default:
                        // Not a recognized directive, rewind ptr and fall through to data parsing
                        ptr = lineStart
                    }
                }

                // Data row
                guard dimension != nil else {
                    throw invalid(lineNumber, "请先声明 LUT_3D_SIZE。")
                }

                var endPtr: UnsafeMutablePointer<CChar>? = nil
                var values: [Float] = []
                values.reserveCapacity(3)

                for _ in 0..<3 {
                    while ptr.pointee == 32 || ptr.pointee == 9 { ptr += 1 }
                    if ptr.pointee == 0 || ptr.pointee == 10 || ptr.pointee == 13 || ptr.pointee == 35 {
                        break
                    }
                    let val = strtof(ptr, &endPtr)
                    guard let ep = endPtr, ep != ptr else {
                        throw invalid(lineNumber, "标准 3D .cube LUT 每行必须正好包含 3 个 RGB 分量；不支持非标准 alpha 列。")
                    }
                    guard val.isFinite else {
                        throw invalid(lineNumber, "包含非数值或 NaN/Infinity。")
                    }
                    guard (-16...16).contains(val) else {
                        throw invalid(lineNumber, "RGB LUT 输出必须在 -16...16 之间。")
                    }
                    values.append(val)
                    ptr = UnsafePointer(ep)
                }

                guard values.count == 3 else {
                    throw invalid(lineNumber, "标准 3D .cube LUT 每行必须正好包含 3 个 RGB 分量；不支持非标准 alpha 列。")
                }

                // Check trailing characters on line
                while ptr.pointee == 32 || ptr.pointee == 9 { ptr += 1 }
                if ptr.pointee != 0 && ptr.pointee != 10 && ptr.pointee != 13 && ptr.pointee != 35 {
                    // Extra content (e.g. 4th alpha value)
                    throw invalid(lineNumber, "标准 3D .cube LUT 每行必须正好包含 3 个 RGB 分量；不支持非标准 alpha 列。")
                }

                // Skip comment to end of line
                while ptr.pointee != 0 && ptr.pointee != 10 && ptr.pointee != 13 {
                    ptr += 1
                }
                if ptr.pointee == 10 { ptr += 1 }
                else if ptr.pointee == 13 {
                    ptr += 1
                    if ptr.pointee == 10 { ptr += 1 }
                }

                rows.append(values[0])
                rows.append(values[1])
                rows.append(values[2])
                rows.append(1)
                rowCount += 1
                hasStartedData = true

                if let dimension, rowCount > dimension * dimension * dimension {
                    throw invalid(lineNumber, "LUT 数据行数超过 \(dimension)^3。")
                }

                lineNumber += 1
            }
        }

        guard let size = dimension else {
            throw AtelierError.invalidLUT("缺少 LUT_3D_SIZE。")
        }
        guard rowCount == size * size * size else {
            throw AtelierError.invalidLUT("需要 \(size * size * size) 行 LUT 数据，实际为 \(rowCount) 行。")
        }
        for axis in 0..<3 where !(domainMin[axis] < domainMax[axis]) {
            throw AtelierError.invalidLUT("DOMAIN_MIN 的每个分量都必须小于 DOMAIN_MAX。")
        }
        for axis in 0..<3 {
            let range = domainMax[axis] - domainMin[axis]
            guard domainMin[axis].isFinite, domainMax[axis].isFinite,
                  (-16...16).contains(domainMin[axis]),
                  (-16...16).contains(domainMax[axis]),
                  range.isFinite, range >= 0.000001 else {
                throw AtelierError.invalidLUT("DOMAIN 范围必须有限、位于 -16...16，且每个分量至少宽 1e-6。")
            }
        }

        return LUTCube(title: title, size: size, domainMin: domainMin,
                       domainMax: domainMax, rgba: rows)
    }

    /// Samples the 3D table with true trilinear interpolation. Values outside
    /// the declared domain use the nearest edge of the LUT.
    public func sample(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        let result = sampleRGBA(rgb)
        return SIMD3(result.x, result.y, result.z)
    }

    private func sampleRGBA(_ rgb: SIMD3<Float>) -> SIMD4<Float> {
        let x = latticeCoordinate(rgb.x, minimum: domainMin.x, maximum: domainMax.x)
        let y = latticeCoordinate(rgb.y, minimum: domainMin.y, maximum: domainMax.y)
        let z = latticeCoordinate(rgb.z, minimum: domainMin.z, maximum: domainMax.z)

        let r0 = Int(x.rounded(.down))
        let g0 = Int(y.rounded(.down))
        let b0 = Int(z.rounded(.down))
        let r1 = min(r0 + 1, size - 1)
        let g1 = min(g0 + 1, size - 1)
        let b1 = min(b0 + 1, size - 1)
        let fr = x - Float(r0)
        let fg = y - Float(g0)
        let fb = z - Float(b0)

        let c000 = node(red: r0, green: g0, blue: b0)
        let c100 = node(red: r1, green: g0, blue: b0)
        let c010 = node(red: r0, green: g1, blue: b0)
        let c110 = node(red: r1, green: g1, blue: b0)
        let c001 = node(red: r0, green: g0, blue: b1)
        let c101 = node(red: r1, green: g0, blue: b1)
        let c011 = node(red: r0, green: g1, blue: b1)
        let c111 = node(red: r1, green: g1, blue: b1)

        let z0 = lerp(lerp(c000, c100, fr), lerp(c010, c110, fr), fg)
        let z1 = lerp(lerp(c001, c101, fr), lerp(c011, c111, fr), fg)
        return lerp(z0, z1, fb)
    }

    private func node(red: Int, green: Int, blue: Int) -> SIMD4<Float> {
        let offset = (((blue * size) + green) * size + red) * 4
        return SIMD4(rgba[offset], rgba[offset + 1], rgba[offset + 2], rgba[offset + 3])
    }

    private func latticeCoordinate(_ value: Float, minimum: Float, maximum: Float) -> Float {
        let safeValue: Float
        if value.isNaN {
            safeValue = minimum
        } else {
            safeValue = value
        }
        let normalized = (safeValue - minimum) / (maximum - minimum)
        if normalized.isNaN { return 0 }
        return min(max(normalized, 0), 1) * Float(size - 1)
    }

    private func lerp(_ lhs: SIMD4<Float>, _ rhs: SIMD4<Float>, _ amount: Float) -> SIMD4<Float> {
        lhs + (rhs - lhs) * amount
    }

    private static func removingInlineComment(from line: String) -> String {
        var isQuoted = false
        var isEscaped = false
        for index in line.indices {
            let character = line[index]
            if isEscaped {
                isEscaped = false
                continue
            }
            if character == "\\", isQuoted {
                isEscaped = true
                continue
            }
            if character == "\"" {
                isQuoted.toggle()
                continue
            }
            if character == "#", !isQuoted {
                return String(line[..<index])
            }
        }
        return line
    }

    private static func parseTitle(_ value: String) -> String {
        guard value.first == "\"", value.last == "\"", value.count >= 2 else { return value }
        let body = value.dropFirst().dropLast()
        return body.replacingOccurrences(of: "\\\"", with: "\"")
                   .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func parseFiniteVector<S: Sequence>(_ tokens: S, line: Int) throws -> SIMD3<Float>
    where S.Element == Substring {
        let values = try parseFiniteScalars(tokens, line: line)
        guard values.count == 3 else { throw invalid(line, "需要三个数值。") }
        return SIMD3(values[0], values[1], values[2])
    }

    private static func parseFiniteScalars<S: Sequence>(_ tokens: S, line: Int) throws -> [Float]
    where S.Element == Substring {
        try tokens.map { token in
            guard let value = Float(token), value.isFinite else {
                throw invalid(line, "包含非数值或 NaN/Infinity。")
            }
            return value
        }
    }

    private static func invalid(_ line: Int, _ reason: String) -> AtelierError {
        .invalidLUT("第 \(line) 行：\(reason)")
    }

    private static let builtInStorage: [LUTPreset] = [
        makePreset(id: "neutral", name: "自然", detail: "轻微柔和反差，保留中性色", style: .neutral,
                   group: .natural, recommendedIntensity: 0.35, tags: ["中性", "柔和", "通用"]),
        makePreset(id: "soft-film", name: "柔和电影", detail: "抬起暗部并压低高光", style: .softFilm,
                   group: .cinematic, recommendedIntensity: 0.35, tags: ["低反差", "抬黑", "柔和"]),
        makePreset(id: "warm-light", name: "暖光", detail: "温暖的中高光与自然肤色", style: .warmLight,
                   group: .portrait, recommendedIntensity: 0.32, tags: ["暖调", "肤色", "柔光"]),
        makePreset(id: "cool-clear", name: "冷静清透", detail: "微冷阴影与克制饱和度", style: .coolClear,
                   group: .natural, recommendedIntensity: 0.30, tags: ["微冷", "清透", "克制"]),
        makePreset(id: "golden-hour", name: "金色时刻", detail: "柔和的琥珀高光", style: .goldenHour,
                   group: .landscape, recommendedIntensity: 0.30, tags: ["暖光", "日落", "高光"]),
        makeCreativePreset(id: "fresh-portrait", name: "清新人像", detail: "轻提通透感，温和照顾肤色", look: .freshPortrait,
                           group: .portrait, recommendedIntensity: 0.34, tags: ["肤色", "清透", "轻柔"]),
        makeCreativePreset(id: "creamy-soft", name: "奶油柔光", detail: "柔化反差并收住亮部，带少量暖意", look: .creamySoft,
                           group: .portrait, recommendedIntensity: 0.32, tags: ["柔光", "低反差", "暖调"]),
        makeCreativePreset(id: "teal-orange-film", name: "青橙电影", detail: "阴影微青、亮部微暖，保持克制", look: .tealOrange,
                           group: .cinematic, recommendedIntensity: 0.30, tags: ["青橙", "电影", "色彩分离"]),
        makeCreativePreset(id: "faded-vintage", name: "复古褪色", detail: "抬起黑位、收低饱和并柔和暖调", look: .fadedVintage,
                           group: .cinematic, recommendedIntensity: 0.30, tags: ["复古", "褪色", "低饱和"]),
        makeCreativePreset(id: "quiet-forest", name: "静谧森林", detail: "轻柔强调绿植色相，压低过亮反差", look: .quietForest,
                           group: .landscape, recommendedIntensity: 0.34, tags: ["森林", "自然绿", "风光"]),
        makeCreativePreset(id: "coastal-light", name: "海岸微光", detail: "清理蓝青色层次并为日照添一点暖意", look: .coastalLight,
                           group: .landscape, recommendedIntensity: 0.32, tags: ["海岸", "蓝青", "日照"]),
        makeCreativePreset(id: "silver-salt", name: "银盐黑白", detail: "清晰的灰阶基底，可与原色按强度混合", look: .silverSalt,
                           group: .monochrome, recommendedIntensity: 0.38, tags: ["黑白", "银盐", "中间调"]),
        makeCreativePreset(id: "soft-monochrome", name: "柔和黑白", detail: "柔和的灰阶基底，轻抬黑位并收住高光", look: .softMonochrome,
                           group: .monochrome, recommendedIntensity: 0.36, tags: ["黑白", "柔和", "抬黑"]),
        makeCreativePreset(id: "japanese-airy", name: "日系通透", detail: "高调轻盈、阴影微青与通透肤色", look: .japaneseAiry,
                           group: .portrait, recommendedIntensity: 0.35, tags: ["日系", "高调", "清透", "肤色"]),
        makeCreativePreset(id: "hk-cinema", name: "复古港风", detail: "浓郁琥珀高光与青绿阴影，怀旧电影质感", look: .hkCinema,
                           group: .cinematic, recommendedIntensity: 0.32, tags: ["港风", "复古", "胶片", "琥珀"]),
        makeCreativePreset(id: "kodak-gold", name: "柯达金胶片", detail: "温暖明媚的金黄调与沉稳暖调暗部", look: .kodakGold,
                           group: .cinematic, recommendedIntensity: 0.34, tags: ["柯达", "金黄", "暖调", "胶卷"]),
        makeCreativePreset(id: "morandi-muted", name: "莫兰迪灰调", detail: "克制低饱和、优雅灰阶与柔和大地色", look: .morandiMuted,
                           group: .natural, recommendedIntensity: 0.30, tags: ["莫兰迪", "灰调", "低饱和", "克制"]),
        makeCreativePreset(id: "moody-oil", name: "暗调油画", detail: "戏剧性明暗对比，浓郁阴影与微光高光", look: .moodyOil,
                           group: .landscape, recommendedIntensity: 0.30, tags: ["暗调", "油画", "氛围", "浓郁"]),
        makeCreativePreset(id: "high-contrast-bw", name: "高对比黑白", detail: "深邃黑位与纯净高光，纪实张力十足", look: .highContrastBW,
                           group: .monochrome, recommendedIntensity: 0.36, tags: ["黑白", "高反差", "纪实", "纯粹"])
    ]

    public static var builtIns: [LUTPreset] { builtInStorage }

    private enum PresetStyle { case neutral, softFilm, warmLight, coolClear, goldenHour }

    private static func makePreset(id: String, name: String, detail: String, style: PresetStyle,
                                   group: LUTPresetGroup, recommendedIntensity: Double,
                                   tags: [String]) -> LUTPreset {
        let dimension = 17
        let denominator = Float(dimension - 1)
        var table: [Float] = []
        table.reserveCapacity(dimension * dimension * dimension * 4)

        for blueIndex in 0..<dimension {
            let blue = Float(blueIndex) / denominator
            for greenIndex in 0..<dimension {
                let green = Float(greenIndex) / denominator
                for redIndex in 0..<dimension {
                    let red = Float(redIndex) / denominator
                    var color = SIMD3(red, green, blue)
                    let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
                    let gray = SIMD3<Float>(repeating: luminance)

                    switch style {
                    case .neutral:
                        color = gray + (color - gray) * 0.98
                        color = (color - SIMD3<Float>(repeating: 0.5)) * 1.015 + SIMD3<Float>(repeating: 0.5)
                    case .softFilm:
                        color = gray + (color - gray) * 0.92
                        let toe = 0.035 * (1 - luminance) * (1 - luminance)
                        let shoulder = 0.045 * luminance * luminance
                        color += SIMD3<Float>(repeating: toe - shoulder)
                    case .warmLight:
                        let warmth = 0.025 + 0.035 * luminance
                        color += SIMD3<Float>(warmth, warmth * 0.12, -warmth * 0.72)
                    case .coolClear:
                        let coolness = 0.018 + 0.025 * (1 - luminance)
                        color += SIMD3<Float>(-coolness * 0.72, 0, coolness)
                    case .goldenHour:
                        let warmth = 0.015 + 0.045 * luminance * luminance
                        color += SIMD3<Float>(warmth, warmth * 0.18, -warmth * 0.82)
                        color = gray + (color - gray) * 0.96
                    }

                    table.append(min(max(color.x, 0), 1))
                    table.append(min(max(color.y, 0), 1))
                    table.append(min(max(color.z, 0), 1))
                    table.append(1)
                }
            }
        }

        let cube = LUTCube(title: name, size: dimension, domainMin: .zero,
                           domainMax: SIMD3<Float>(repeating: 1), rgba: table)
        return LUTPreset(id: id, name: name, detail: detail, cube: cube, group: group,
                         recommendedIntensity: recommendedIntensity, tags: tags)
    }

    private enum CreativeLook {
        case freshPortrait
        case creamySoft
        case tealOrange
        case fadedVintage
        case quietForest
        case coastalLight
        case silverSalt
        case softMonochrome
        case japaneseAiry
        case hkCinema
        case kodakGold
        case morandiMuted
        case moodyOil
        case highContrastBW
    }

    /// Original creative looks authored for normalized sRGB code values. This
    /// generator is separate from the five legacy recipes so their table values
    /// remain unchanged.
    private static func makeCreativePreset(id: String, name: String, detail: String,
                                           look: CreativeLook, group: LUTPresetGroup,
                                           recommendedIntensity: Double, tags: [String]) -> LUTPreset {
        let dimension = 17
        let denominator = Float(dimension - 1)
        var table: [Float] = []
        table.reserveCapacity(dimension * dimension * dimension * 4)

        for blueIndex in 0..<dimension {
            let blue = Float(blueIndex) / denominator
            for greenIndex in 0..<dimension {
                let green = Float(greenIndex) / denominator
                for redIndex in 0..<dimension {
                    let red = Float(redIndex) / denominator
                    let input = SIMD3(red, green, blue)
                    let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
                    let gray = SIMD3<Float>(repeating: luminance)
                    var color = input

                    switch look {
                    case .freshPortrait:
                        color = gray + (color - gray) * 1.015
                        let midtone = max(0, 1 - abs(luminance - 0.62) / 0.62)
                        let warmth = 0.007 * midtone
                        color += SIMD3<Float>(warmth, warmth * 0.1, -warmth * 0.75)

                    case .creamySoft:
                        color = gray + (color - gray) * 0.93
                        let toe = 0.026 * (1 - luminance) * (1 - luminance)
                        let shoulder = 0.038 * luminance * luminance
                        color += SIMD3<Float>(repeating: toe - shoulder)
                        let warmth = 0.009 * luminance
                        color += SIMD3<Float>(warmth, warmth * 0.2, -warmth * 0.65)

                    case .tealOrange:
                        color = gray + (color - gray) * 1.02
                        color = (color - SIMD3<Float>(repeating: 0.5)) * 1.035
                            + SIMD3<Float>(repeating: 0.5)
                        let shadow = 4 * luminance * (1 - luminance) * (1 - luminance)
                        let highlight = 3 * luminance * luminance * (1 - luminance)
                        color += SIMD3<Float>(-0.018 * shadow + 0.002 * highlight,
                                              0.006 * shadow + 0.003 * highlight,
                                              0.018 * shadow - 0.010 * highlight)

                    case .fadedVintage:
                        let fadedLuminance = 0.045 + 0.91 * luminance
                        color = SIMD3<Float>(repeating: fadedLuminance)
                            + (color - gray) * 0.88
                        let warmth = 0.012 * luminance
                        color += SIMD3<Float>(warmth, warmth * 0.25, -warmth * 0.7)

                    case .quietForest:
                        color = gray + (color - gray) * 1.035
                        let greenAffinity = max(green - max(red, blue), 0)
                        color += SIMD3<Float>(-0.008 * greenAffinity,
                                              0.045 * greenAffinity,
                                              0.003 * greenAffinity)

                    case .coastalLight:
                        color = gray + (color - gray) * 1.025
                        let blueAffinity = max(blue - max(red, green), 0)
                        color += SIMD3<Float>(-0.006 * blueAffinity,
                                              0.009 * blueAffinity,
                                              0.045 * blueAffinity)
                        let sun = max((luminance - 0.48) / 0.52, 0)
                        let warmth = 0.015 * sun * sun
                        color += SIMD3<Float>(warmth, warmth * 0.32, -warmth * 0.8)

                    case .silverSalt:
                        let monochrome = 0.012 + 0.98 * luminance
                        color = SIMD3<Float>(repeating: monochrome)

                    case .softMonochrome:
                        let monochrome = 0.035 + 0.90 * luminance
                            + 0.02 * luminance * (1 - luminance)
                        color = SIMD3<Float>(repeating: monochrome)

                    case .japaneseAiry:
                        let airyLuma = 0.035 + 0.95 * luminance + 0.02 * (1 - luminance) * (1 - luminance)
                        color = SIMD3<Float>(repeating: airyLuma) + (color - gray) * 0.94
                        let shadow = (1 - luminance) * (1 - luminance)
                        let midtone = max(0, 1 - abs(luminance - 0.58) / 0.58)
                        color += SIMD3<Float>(-0.004 * shadow + 0.008 * midtone,
                                              0.003 * shadow + 0.005 * midtone,
                                              0.012 * shadow - 0.004 * midtone)

                    case .hkCinema:
                        color = gray + (color - gray) * 1.04
                        color = (color - SIMD3<Float>(repeating: 0.5)) * 1.03 + SIMD3<Float>(repeating: 0.5)
                        let shadow = 3 * luminance * (1 - luminance) * (1 - luminance)
                        let highlight = 3 * luminance * luminance * (1 - luminance)
                        color += SIMD3<Float>(-0.010 * shadow + 0.012 * highlight,
                                              0.008 * shadow + 0.006 * highlight,
                                             -0.012 * shadow - 0.008 * highlight)

                    case .kodakGold:
                        color = gray + (color - gray) * 1.03
                        let toe = 0.015 * (1 - luminance) * (1 - luminance)
                        color += SIMD3<Float>(repeating: toe)
                        let warmth = 0.008 + 0.010 * luminance
                        color += SIMD3<Float>(warmth, warmth * 0.25, -warmth * 0.70)

                    case .morandiMuted:
                        color = gray + (color - gray) * 0.84
                        let toe = 0.025 * (1 - luminance) * (1 - luminance)
                        let shoulder = 0.02 * luminance * luminance
                        color += SIMD3<Float>(repeating: toe - shoulder)
                        let earthy = 0.005 * (1 - abs(luminance - 0.5) * 2)
                        color += SIMD3<Float>(earthy, earthy * 0.1, -earthy * 0.2)

                    case .moodyOil:
                        color = gray + (color - gray) * 1.04
                        let shadowDrop = 0.025 * (1 - luminance) * (1 - luminance)
                        color -= SIMD3<Float>(repeating: shadowDrop)
                        let amber = 0.014 * luminance * luminance
                        color += SIMD3<Float>(amber, amber * 0.25, -amber * 0.70)

                    case .highContrastBW:
                        var bw = luminance
                        bw = (bw - 0.5) * 1.20 + 0.5
                        color = SIMD3<Float>(repeating: min(max(bw, 0), 1))
                    }

                    table.append(min(max(color.x, 0), 1))
                    table.append(min(max(color.y, 0), 1))
                    table.append(min(max(color.z, 0), 1))
                    table.append(1)
                }
            }
        }

        let cube = LUTCube(title: name, size: dimension, domainMin: .zero,
                           domainMax: SIMD3<Float>(repeating: 1), rgba: table)
        return LUTPreset(id: id, name: name, detail: detail, cube: cube, group: group,
                         recommendedIntensity: recommendedIntensity, tags: tags)
    }
}

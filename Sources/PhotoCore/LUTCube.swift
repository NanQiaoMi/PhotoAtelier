import Foundation

public struct LUTPreset: Identifiable {
    public let id: String
    public let name: String
    public let detail: String
    public let cube: LUTCube

    public init(id: String, name: String, detail: String, cube: LUTCube) {
        self.id = id
        self.name = name
        self.detail = detail
        self.cube = cube
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

    private init(title: String, size: Int, domainMin: SIMD3<Float>,
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
        var rows: [Float] = []
        var rowCount = 0
        var hasStartedData = false

        for (zeroBasedLine, originalLine) in text.split(omittingEmptySubsequences: false,
                                                          whereSeparator: \.isNewline).enumerated() {
            var line = String(originalLine)
            if zeroBasedLine == 0, line.first == "\u{FEFF}" {
                line.removeFirst()
            }
            line = removingInlineComment(from: line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            let lineNumber = zeroBasedLine + 1
            let tokens = line.split(whereSeparator: \.isWhitespace)
            guard let first = tokens.first else { continue }
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

            case "DOMAIN_MIN", "DOMAIN_MAX":
                guard !hasStartedData, tokens.count == 4 else {
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

            case "LUT_1D_SIZE", "LUT_1D_INPUT_RANGE", "LUT_3D_INPUT_RANGE":
                throw invalid(lineNumber, "只支持带 DOMAIN_MIN/MAX 的 3D LUT；不支持 \(directive)。")

            default:
                guard dimension != nil else {
                    throw invalid(lineNumber, "请先声明 LUT_3D_SIZE。")
                }
                guard tokens.count == 3 else {
                    throw invalid(lineNumber, "标准 3D .cube LUT 每行必须正好包含 3 个 RGB 分量；不支持非标准 alpha 列。")
                }
                let values = try parseFiniteScalars(tokens, line: lineNumber)
                guard values.allSatisfy({ (-16...16).contains($0) }) else {
                    throw invalid(lineNumber, "RGB LUT 输出必须在 -16...16 之间。")
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
        makePreset(id: "neutral", name: "自然", detail: "轻微柔和反差，保留中性色", style: .neutral),
        makePreset(id: "soft-film", name: "柔和电影", detail: "抬起暗部并压低高光", style: .softFilm),
        makePreset(id: "warm-light", name: "暖光", detail: "温暖的中高光与自然肤色", style: .warmLight),
        makePreset(id: "cool-clear", name: "冷静清透", detail: "微冷阴影与克制饱和度", style: .coolClear),
        makePreset(id: "golden-hour", name: "金色时刻", detail: "柔和的琥珀高光", style: .goldenHour)
    ]

    public static var builtIns: [LUTPreset] { builtInStorage }

    private enum PresetStyle { case neutral, softFilm, warmLight, coolClear, goldenHour }

    private static func makePreset(id: String, name: String, detail: String, style: PresetStyle) -> LUTPreset {
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
        return LUTPreset(id: id, name: name, detail: detail, cube: cube)
    }
}

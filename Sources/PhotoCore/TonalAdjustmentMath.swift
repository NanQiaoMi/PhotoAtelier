import Foundation

/// Transfers requested zone changes independently of the user's LUT and masks.
enum TonalAdjustmentMath {
    static let fields: [WritableKeyPath<TonalCurveSettings, Double>] = [
        \.blacksEV, \.shadowsEV, \.midtonesEV, \.highlightsEV, \.whitesEV
    ]

    static func adding(_ delta: TonalCurveSettings?, to baseline: TonalCurveSettings?) -> TonalCurveSettings? {
        guard let delta else { return baseline }
        var value = baseline ?? .init()
        for field in fields { value[keyPath: field] = bound(value[keyPath: field] + delta[keyPath: field]) }
        return value
    }

    static func difference(from baseline: TonalCurveSettings?, to candidate: TonalCurveSettings?) -> TonalCurveSettings? {
        guard baseline != nil || candidate != nil else { return nil }
        let start = baseline ?? .init(), end = candidate ?? .init()
        var value = TonalCurveSettings()
        for field in fields { value[keyPath: field] = end[keyPath: field] - start[keyPath: field] }
        return value
    }

    static func interpolate(from baseline: TonalCurveSettings?, to requested: TonalCurveSettings?,
                            fraction: Double) -> TonalCurveSettings? {
        if fraction == 0 { return baseline }
        if fraction == 1 { return requested }
        guard baseline != nil || requested != nil else { return nil }
        let start = baseline ?? .init(), end = requested ?? .init()
        var value = TonalCurveSettings()
        for field in fields {
            value[keyPath: field] = start[keyPath: field] + (end[keyPath: field] - start[keyPath: field]) * fraction
        }
        return value
    }

    static func resolve(proposal: TonalCurveSettings?, current: TonalCurveSettings?,
                        reference: TonalCurveSettings?) -> TonalCurveSettings? {
        // Turning off the new control is an explicit user override.
        guard let current else { return nil }
        let now = current, previous = reference ?? .init()
        var value = proposal ?? .init()
        for field in fields {
            value[keyPath: field] = bound(value[keyPath: field] + now[keyPath: field] - previous[keyPath: field])
        }
        return value
    }

    private static func bound(_ value: Double) -> Double { min(3, max(-3, value)) }
}

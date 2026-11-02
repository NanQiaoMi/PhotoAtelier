import SwiftUI
import PhotoCore

struct TonalCurvePanel: View {
    @ObservedObject var model: AppModel

    private var isEnabled: Bool {
        model.adjustments.tonalCurve != nil
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { model.adjustments.tonalCurve != nil },
            set: { enabled in
                model.adjustments.tonalCurve = enabled ? TonalCurveSettings() : nil
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Toggle("亮度分区", isOn: enabledBinding)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.system(size: 10))
                Spacer(minLength: 4)
                Button("重置分区") {
                    model.adjustments.tonalCurve = TonalCurveSettings()
                }
                .buttonStyle(.plain)
                .font(.system(size: 9))
                .foregroundColor(AtelierPalette.muted)
                .disabled(!isEnabled)
            }

            VStack(spacing: 3) {
                AdjustmentSlider(title: "黑调", value: valueBinding(\.blacksEV), range: -3...3, suffix: " EV")
                AdjustmentSlider(title: "阴影", value: valueBinding(\.shadowsEV), range: -3...3, suffix: " EV")
                AdjustmentSlider(title: "中间调", value: valueBinding(\.midtonesEV), range: -3...3, suffix: " EV")
                AdjustmentSlider(title: "高光", value: valueBinding(\.highlightsEV), range: -3...3, suffix: " EV")
                AdjustmentSlider(title: "白调", value: valueBinding(\.whitesEV), range: -3...3, suffix: " EV")
            }
            .disabled(!isEnabled)
            .opacity(isEnabled ? 1 : 0.45)

            DisclosureGroup("亮度分区说明") {
                Text("按画面亮度范围调整，不会识别或分割具体物体。纯黑仍为黑，不会凭空恢复丢失的细节。相邻分区受单调曲线限制以避免明暗反转；实际效果请以预览为准。")
                    .font(.system(size: 9))
                    .foregroundColor(AtelierPalette.muted)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
            .font(.system(size: 9))
        }
    }

    private func valueBinding(_ keyPath: WritableKeyPath<TonalCurveSettings, Double>) -> Binding<Double> {
        Binding(
            get: { model.adjustments.tonalCurve?[keyPath: keyPath] ?? 0 },
            set: { newValue in
                var settings = model.adjustments.tonalCurve ?? TonalCurveSettings()
                settings[keyPath: keyPath] = newValue
                model.adjustments.tonalCurve = settings
            }
        )
    }
}

public struct TonalDeltaSummary: View {
    public let delta: TonalCurveSettings

    public init(delta: TonalCurveSettings) {
        self.delta = delta
    }

    public var body: some View {
        Text(summary)
            .font(.system(size: 9))
            .foregroundColor(AtelierPalette.muted)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var summary: String {
        [
            ("黑调", delta.blacksEV),
            ("阴影", delta.shadowsEV),
            ("中间调", delta.midtonesEV),
            ("高光", delta.highlightsEV),
            ("白调", delta.whitesEV)
        ]
        .map { "\($0.0) \(String(format: "%+.2f EV", $0.1))" }
        .joined(separator: " · ")
    }
}

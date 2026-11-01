import SwiftUI
import PhotoCore

struct LensPicker: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    private var matches: [LensProfileSummary] {
        let all = LensCorrection.shared.profiles
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return Array(all.prefix(100)) }
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace)
        return Array(all.filter { profile in
            let text = (profile.maker + " " + profile.name).lowercased()
            return terms.allSatisfy { text.contains($0) }
        }.prefix(150))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("选择镜头配置").font(.system(size: 19, weight: .medium))
                    Text(LensCorrection.shared.availabilityDescription).font(.system(size: 10)).foregroundColor(AtelierPalette.muted)
                }
                Spacer()
                Button("完成") { dismiss() }
            }
            TextField("搜索品牌、镜头型号或焦段，例如 Canon 24-70", text: $query)
                .textFieldStyle(.roundedBorder)
            Button {
                model.adjustments.lensProfileID = nil
                dismiss()
            } label: {
                Label("自动识别 · 仅在拍摄信息可靠且配置唯一时应用", systemImage: "sparkle.magnifyingglass")
                    .font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.bordered)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(matches) { profile in
                        Button {
                            model.adjustments.lensProfileID = profile.id
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(profile.name).font(.system(size: 11, weight: .medium))
                                    Text("\(profile.maker)  ·  标定裁切系数 \(String(format: "%.2f", profile.cropFactor))")
                                        .font(.system(size: 9)).foregroundColor(AtelierPalette.muted)
                                }
                                Spacer()
                                if model.adjustments.lensProfileID == profile.id {
                                    Image(systemName: "checkmark.circle.fill").foregroundColor(AtelierPalette.accent)
                                }
                            }.padding(11).frame(maxWidth: .infinity, alignment: .leading)
                                .background(AtelierPalette.raised.opacity(0.65)).clipShape(RoundedRectangle(cornerRadius: 5))
                        }.buttonStyle(.plain)
                    }
                }
            }
            Text("列表显示前 \(matches.count) 项，可搜索缩小范围。配置应与镜头和相机传感器匹配；缺少拍摄信息时请在面板中填写实际焦距与裁切系数。")
                .font(.system(size: 10)).foregroundColor(AtelierPalette.muted).lineSpacing(5)
        }.padding(24).frame(width: 600, height: 570).background(AtelierPalette.panel).preferredColorScheme(.dark)
    }
}

import SwiftUI
import PhotoCore

struct RegionalSuggestionsPanel: View {
    @ObservedObject var model: AppModel
    let editLocals: () -> Void

    private var isBusy: Bool {
        model.batchRunning || model.previewBusy || model.scanning || model.selectedPhoto == nil
            || (model.automaticRecipe != nil && (model.analysisBusy || model.analysis == nil || model.analysisError != nil))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("局部光线建议", systemImage: "viewfinder")
                .font(.system(size: 11, weight: .medium))

            Text("建议根据当前照片的位置与亮度范围生成，描述的是候选区域，不代表识别出了具体物体。请先查看依据与注意事项，再确认是否建立蒙版。")
                .font(.system(size: 9))
                .foregroundColor(AtelierPalette.muted)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)

            if model.regionalSuggestions.isEmpty {
                Text("完成照片分析后，有依据的局部光线建议会显示在这里。")
                    .font(.system(size: 10))
                    .foregroundColor(AtelierPalette.muted)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(model.regionalSuggestions.prefix(3))) { suggestion in
                        RegionalSuggestionCard(
                            suggestion: suggestion,
                            isBusy: isBusy,
                            apply: {
                                if model.applyRegionalSuggestion(suggestion.id) { editLocals() }
                            }
                        )
                    }
                }
            }

            Text("采用后，蒙版会加入当前配方，并供所选文件夹的批处理共用。照片构图不同，请逐张复核蒙版范围。")
                .font(.system(size: 9))
                .foregroundColor(AtelierPalette.muted)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AtelierPalette.raised.opacity(0.5))
        .cornerRadius(6)
    }
}

private struct RegionalSuggestionCard: View {
    let suggestion: RegionalAdjustmentSuggestion
    let isBusy: Bool
    let apply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(suggestion.title)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(AtelierPalette.accent)
                .fixedSize(horizontal: false, vertical: true)

            Text(suggestion.evidence)
                .font(.system(size: 9))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            Text(suggestion.caution)
                .font(.system(size: 9))
                .foregroundColor(AtelierPalette.muted)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: apply) {
                Label("建立可编辑蒙版", systemImage: "plus.viewfinder")
                    .font(.system(size: 9))
            }
            .buttonStyle(.plain)
            .foregroundColor(AtelierPalette.accent)
            .disabled(isBusy)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AtelierPalette.panel.opacity(0.75))
        .cornerRadius(5)
    }
}

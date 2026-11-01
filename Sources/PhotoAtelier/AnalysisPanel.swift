import SwiftUI
import PhotoCore

struct AnalysisPanel: View {
    @ObservedObject var model: AppModel
    let editParameters: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("照片分析", systemImage: "viewfinder")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Button("重新分析") { model.reanalyze() }.font(.system(size: 9))
                    .disabled(model.selectedPhoto == nil || model.analysisBusy)
            }
            if model.analysisBusy {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.mini)
                    Text("正在读取像素与拍摄信息，并进行本机内容识别…")
                        .font(.system(size: 10)).foregroundColor(AtelierPalette.muted)
                }
            }
            if let error = model.analysisError {
                Text(error).font(.system(size: 10)).foregroundColor(.orange)
            }
            if let analysis = model.analysis {
                analysisDetails(analysis)
            } else if !model.analysisBusy {
                Text("选择一张照片后，分析曝光、通道偏色、拍摄信息与可识别内容，再比较下方的三种处理结果。")
                    .font(.system(size: 11)).foregroundColor(AtelierPalette.muted).lineSpacing(6)
            }
        }
    }

    private func analysisDetails(_ analysis: PhotoAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(analysis.summary).font(.system(size: 11)).lineSpacing(5)
            metrics(analysis.metrics)
            if let colorScene = analysis.colorScene {
                colorSceneDetails(colorScene, content: analysis.content)
            }
            if !analysis.content.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    heading("本机内容识别")
                    ForEach(analysis.content) { label in
                        HStack(alignment: .firstTextBaseline) {
                            Text(label.label).lineLimit(2)
                            Spacer()
                            Text(String(format: "%.0f%%", label.confidence * 100))
                                .foregroundColor(AtelierPalette.muted)
                        }.font(.system(size: 10)).help(label.source)
                    }
                    Text("识别分数仅表示模型置信度，可能误判。")
                        .font(.system(size: 9)).foregroundColor(AtelierPalette.muted)
                }
            }
            VStack(alignment: .leading, spacing: 11) {
                heading("问题依据与处理方向")
                ForEach(analysis.issues) { issue in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(issue.title).font(.system(size: 11, weight: .medium))
                            .foregroundColor(issue.severity == .high ? .orange : AtelierPalette.accent)
                        Text(issue.evidence).font(.system(size: 10)).foregroundColor(AtelierPalette.muted)
                        Text(issue.direction).font(.system(size: 10))
                    }.lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                        .padding(11).frame(maxWidth: .infinity, alignment: .leading)
                        .background(AtelierPalette.raised.opacity(0.6)).cornerRadius(6)
                }
            }
            if let selected = model.automaticRecipe,
               let proposal = analysis.proposals.first(where: { $0.id == selected.styleID }) {
                VStack(alignment: .leading, spacing: 9) {
                    Label("已采用 · \(proposal.title)", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11)).foregroundColor(AtelierPalette.accent)
                    Text(proposal.rationale).font(.system(size: 10)).lineSpacing(4)
                    Text(proposal.confidenceBasis).font(.system(size: 9)).foregroundColor(AtelierPalette.muted)
                    if let safety = proposal.safety { safetyDetails(safety) }
                    Button("继续微调参数", action: editParameters).font(.system(size: 11))
                    Text("批处理按每张照片重新分析，再叠加当前手动微调。LUT、几何与蒙版按当前配方应用。")
                        .font(.system(size: 9)).foregroundColor(AtelierPalette.muted).lineSpacing(4)
                    Button("改为统一手动参数") { model.useManualParameters() }.font(.system(size: 9))
                }
            } else {
                Text("点击照片下方的方案卡片采用结果，再到“基础”和“局部”细调。")
                    .font(.system(size: 10)).foregroundColor(AtelierPalette.accent).lineSpacing(5)
            }
            Text("方案沿用用户选择的白平衡模式与手动冷暖，已开启的自动白平衡仍会调整颜色。依据评分不表示照片一定更好。阈值检查仅覆盖自动基础增量，后续手调、LUT 和局部叠加请继续前后对比。")
                .font(.system(size: 9)).foregroundColor(AtelierPalette.muted).lineSpacing(4)
            DisclosureGroup("拍摄与文件信息") {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(analysis.metadata) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.label).font(.system(size: 9)).foregroundColor(AtelierPalette.muted)
                            Text(item.value).font(.system(size: 10)).textSelection(.enabled)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(.top, 12)
            }.font(.system(size: 10))
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(analysis.unsupportedReadings.enumerated()), id: \.offset) { _, text in
                    Text(text).font(.system(size: 9)).foregroundColor(AtelierPalette.muted)
                }
            }.lineSpacing(4)
            Button("保存详细分析 JSON") { model.saveAnalysis() }.font(.system(size: 10))
        }
    }

    private func safetyDetails(_ value: AutomaticSafetyReport) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            heading("自动基础增量检查")
            metric("自动曝光增量", String(format: "%+.2f EV", value.exposureDeltaEV))
            metric("保留建议强度", String(format: "%.0f%%", value.retainedFraction * 100))
            metric("新增高光越界 / 黑位", String(format: "%.2f%% / %.2f%%",
                value.introducedHighlightFraction * 100, value.introducedShadowFraction * 100))
            Text(value.summary).font(.system(size: 9)).lineSpacing(3)
            Text(value.scope).font(.system(size: 9)).foregroundColor(AtelierPalette.muted).lineSpacing(3)
        }.padding(10).background(AtelierPalette.raised.opacity(0.5)).cornerRadius(5)
    }

    private func metrics(_ value: PhotoAnalysisMetrics) -> some View {
        VStack(spacing: 9) {
            metric("中位线性亮度", String(format: "%.3f", value.medianLuminance))
            metric("接近显示白位样本", String(format: "%.1f%%", value.nearWhiteFraction * 100))
            metric("接近纯黑像素", String(format: "%.1f%%", value.nearBlackFraction * 100))
            metric("可用近中性样本", String(format: "%.1f%%", value.neutralSampleFraction * 100))
            metric("亮度跨度估计", String(format: "%.1f EV", value.dynamicRangeStops))
        }.padding(12).background(AtelierPalette.raised.opacity(0.6)).cornerRadius(6)
    }

    private func colorSceneDetails(_ value: ColorSceneProfile,
                                  content: [PhotoContentLabel]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            heading("整体色彩感觉")
            Text(value.summary).font(.system(size: 10)).lineSpacing(4)
            VStack(spacing: 7) {
                metric("暖色 / 冷色", String(format: "%.0f%% / %.0f%%",
                                               value.warmFraction * 100,
                                               value.coolFraction * 100))
                metric("中性色 / 高彩度", String(format: "%.0f%% / %.0f%%",
                                                   value.neutralFraction * 100,
                                                   value.saturatedFraction * 100))
                metric("暗部 / 亮部", String(format: "%.0f%% / %.0f%%",
                                               value.darkFraction * 100,
                                               value.brightFraction * 100))
                let spread = value.colorDiversity < 0.30 ? "较集中"
                    : (value.colorDiversity < 0.68 ? "适中" : "覆盖较广")
                metric("色相分布", spread)
            }
            let representative = representativeRegions(from: value.regions)
            let representativeIDs = Set(representative.map(\.id))
            let remaining = value.regions.filter {
                $0.coverage > 0 && !representativeIDs.contains($0.id)
            }
            if !representative.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    heading("重点观察位置")
                    ForEach(representative) { region in regionDetails(region) }
                }
            }
            if !remaining.isEmpty {
                DisclosureGroup("查看其他 \(remaining.count) 个区域") {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(remaining) { region in regionDetails(region) }
                    }.padding(.top, 8)
                }.font(.system(size: 10))
            }
            let sceneLabels = content.prefix(3).map(\.label)
            let sceneContext = sceneLabels.isEmpty
                ? "位置提示概括画面不同位置的色彩与明暗。"
                : "画面线索：\(sceneLabels.joined(separator: "、"))。"
            Text("\(sceneContext)区域提示不代表主体或物体的边界。")
                .font(.system(size: 9)).foregroundColor(AtelierPalette.muted).lineSpacing(3)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AtelierPalette.raised.opacity(0.38)).cornerRadius(6)
    }

    private func representativeRegions(from regions: [ColorSceneRegion]) -> [ColorSceneRegion] {
        let visible = regions.filter { $0.coverage > 0 }
        guard !visible.isEmpty else { return [] }

        let darkest = visible.sorted {
            if $0.luminance != $1.luminance { return $0.luminance < $1.luminance }
            return $0.id < $1.id
        }.first
        let mostSaturated = visible.sorted {
            if $0.saturation != $1.saturation { return $0.saturation > $1.saturation }
            return $0.id < $1.id
        }.first
        let brightest = visible.sorted {
            if $0.luminance != $1.luminance { return $0.luminance > $1.luminance }
            return $0.id < $1.id
        }.first

        var chosen: [ColorSceneRegion] = []
        func appendIfNew(_ region: ColorSceneRegion?) {
            guard let region, !chosen.contains(where: { $0.id == region.id }) else { return }
            chosen.append(region)
        }
        appendIfNew(darkest)
        appendIfNew(mostSaturated)
        appendIfNew(brightest)

        let targetCount = min(3, visible.count)
        if chosen.count < targetCount {
            appendIfNew(visible.first { $0.id == "region.1.1" })
        }
        if chosen.count < targetCount {
            let byCoverage = visible.sorted {
                if $0.coverage != $1.coverage { return $0.coverage > $1.coverage }
                return $0.id < $1.id
            }
            for region in byCoverage where chosen.count < targetCount {
                appendIfNew(region)
            }
        }
        return chosen
    }

    private func regionDetails(_ region: ColorSceneRegion) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(region.title).font(.system(size: 10, weight: .medium))
                Spacer()
                Text(String(format: "画面 %.0f%%", region.coverage * 100))
                    .font(.system(size: 9)).foregroundColor(AtelierPalette.muted)
            }
            Text(region.summary).font(.system(size: 9)).foregroundColor(AtelierPalette.muted)
            Text(region.direction).font(.system(size: 9)).lineSpacing(3)
        }.fixedSize(horizontal: false, vertical: true)
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AtelierPalette.raised.opacity(0.45)).cornerRadius(5)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundColor(AtelierPalette.muted)
            Spacer()
            Text(value).monospacedDigit()
        }.font(.system(size: 10))
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.system(size: 10, weight: .semibold)).foregroundColor(.white.opacity(0.85))
    }
}

struct AnalysisProposalShelf: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("处理方案").font(.system(size: 10, weight: .semibold))
                Text("按当前照片分析 · 点击采用后可微调")
                    .font(.system(size: 9)).foregroundColor(AtelierPalette.muted)
                Spacer()
            }
            if let analysis = model.analysis {
                HStack(spacing: 10) {
                    ForEach(analysis.proposals) { proposal in
                        proposalCard(proposal)
                    }
                }
            } else {
                HStack {
                    if model.analysisBusy { ProgressView().controlSize(.small) }
                    Text(model.analysisBusy ? "正在生成有依据的自动方案…" : "打开照片，比较三种自动处理方向")
                        .font(.system(size: 11)).foregroundColor(AtelierPalette.muted)
                }.frame(maxWidth: .infinity, minHeight: 115)
            }
        }.padding(.horizontal, 22).padding(.vertical, 15)
            .background(AtelierPalette.panel.opacity(0.65))
    }

    private func proposalCard(_ proposal: AutoAdjustmentProposal) -> some View {
        Button { model.applyProposal(proposal.id) } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    Rectangle().fill(AtelierPalette.raised)
                    if let image = model.proposalPreviews[proposal.id] {
                        Image(nsImage: image).resizable().scaledToFit()
                    } else { ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity) }
                    if model.automaticRecipe?.styleID == proposal.id {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(AtelierPalette.accent).padding(7)
                    }
                }.frame(height: 94).clipped().cornerRadius(5)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(model.automaticRecipe?.styleID == proposal.id ? AtelierPalette.accent : .clear, lineWidth: 1.5))
                Text(proposal.title).font(.system(size: 10, weight: .medium)).lineLimit(1)
                Text(String(format: "总补偿 %+.2f EV · 依据 %.0f", proposal.settings.exposureEV, proposal.confidence * 100))
                    .font(.system(size: 8)).foregroundColor(AtelierPalette.muted).lineLimit(1)
                if let safety = proposal.safety {
                    Text(String(format: "自动 %+.2f EV · 强度 %.0f%%", safety.exposureDeltaEV, safety.retainedFraction * 100))
                        .font(.system(size: 8)).foregroundColor(AtelierPalette.muted).lineLimit(1)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(.plain).help(proposal.rationale).disabled(model.batchRunning || model.analysisBusy)
    }
}

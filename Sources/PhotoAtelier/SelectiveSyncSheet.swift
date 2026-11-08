import SwiftUI

/// P2-K: Modal sheet for selective adjustment synchronization across multiple selected photos.
struct SelectiveSyncSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("选择性同步调整参数")
                        .font(.system(size: 14, weight: .semibold))
                    Text("将当前选中的调色与精修设置同步至已选的 \(model.selectedIDs.count) 张照片，未勾选的模块将保留目标照片原有设置。")
                        .font(.system(size: 11))
                        .foregroundColor(AtelierPalette.muted)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(AtelierPalette.muted)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            // Quick Preset Bar
            HStack(spacing: 8) {
                Text("快捷模板:")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(AtelierPalette.muted)

                Button("全选") { model.syncOptions = .allAdjustments }
                    .buttonStyle(.bordered).controlSize(.small)
                Button("清空") { model.syncOptions = .none }
                    .buttonStyle(.bordered).controlSize(.small)
                Button("人像精修") { model.syncOptions = .portraitStudio }
                    .buttonStyle(.bordered).controlSize(.small)
                Button("风光调色") { model.syncOptions = .landscapeOutdoor }
                    .buttonStyle(.bordered).controlSize(.small)
                Button("仅色彩风格") { model.syncOptions = .colorGradingOnly }
                    .buttonStyle(.bordered).controlSize(.small)

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.4))

            Divider()

            // Scrollable Options Grid
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 16) {

                    // Group 1: 色彩与曝光
                    GroupBox(label: Label("基础光影与色彩", systemImage: "slider.horizontal.3").font(.system(size: 12, weight: .semibold))) {
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle("基础光影 (曝光/对比度/高光/阴影/饱和度)", isOn: $model.syncOptions.basicTone)
                            Toggle("白平衡 (色温 / 色调)", isOn: $model.syncOptions.whiteBalance)
                            Toggle("色调与 RGB 曲线", isOn: $model.syncOptions.tonalCurves)
                            Toggle("8色相 HSL 微调", isOn: $model.syncOptions.hsl)
                            Toggle("色彩分级 (高光/阴影三色轮)", isOn: $model.syncOptions.colorGrading)
                            Toggle("3D 风格滤镜 (LUT 与色彩空间)", isOn: $model.syncOptions.lut)
                            Toggle("色彩协调 (Color Harmony)", isOn: $model.syncOptions.colorHarmony)
                        }
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))
                        .padding(.vertical, 4)
                    }

                    // Group 2: 人像美颜与微整形
                    GroupBox(label: Label("人像美颜与微整形", systemImage: "person.crop.circle.dashed").font(.system(size: 12, weight: .semibold))) {
                        VStack(alignment: .leading, spacing: 6) {
                            Group {
                                Toggle("基础人像精修 (中性灰/平整/祛斑/美白/亮眼/肤色统一)", isOn: $model.syncOptions.portraitRetouch)
                                Toggle("多人分人属性感知与独立精修 (男女童老分组/独立参数/肤色统一)", isOn: $model.syncOptions.multiPerson)
                                Toggle("面部骨相液化 (7种脸型预设/高颅顶/下巴/五官微整)", isOn: $model.syncOptions.facialReshape)
                                Toggle("面部五区专项祛皱与去油光 (黑眼圈/眼袋/法令纹/抬头纹/哑光)", isOn: $model.syncOptions.facialZonal)
                                Toggle("明眸眼神光与牙齿美学精修 (眼镜去反光/眼白去红血丝/6款眼神光/牙齿污渍与珐琅质光泽)", isOn: $model.syncOptions.eyeTeeth)
                                Toggle("双眼皮雕刻与卧蚕立体塑形 (4款双眼皮/去双眼皮贴反光/卧蚕高光与阴影)", isOn: $model.syncOptions.eyelidAegyoSal)
                            }
                            Group {
                                Toggle("人像妆容精修 (唇色/眉毛/腮红/眼影/眼线/美瞳/高光)", isOn: $model.syncOptions.makeup)
                                Toggle("秀发质感精修 (发缝填充/秀发光泽/柔顺/去碎发)", isOn: $model.syncOptions.hair)
                                Toggle("智能发色统一与白发消除 (去白发银丝/发色斑驳统一/7款沙龙发色)", isOn: $model.syncOptions.hairColor)
                                Toggle("智能面部唇毛与胡青消除、特征痣管理 (去唇毛/去胡青/胡茬平滑/特征痣保留与消除)", isOn: $model.syncOptions.facialHair)
                                Toggle("智能面部微表情与微笑唇形立体微雕 (微笑嘴角上扬/微笑宽度/唇角对称/幼态人中缩短/丰唇/唇峰珠光立体)", isOn: $model.syncOptions.expression)
                                Toggle("智能眼型微雕与眼位平衡 (开内眼角/开外眼角眼尾下至/圆润猫眼/眼位倾斜/眼距微调/中庭比例缩短/双眼对称)", isOn: $model.syncOptions.eyeShape)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))
                        .padding(.vertical, 4)
                    }

                    // Group 3: 身体、衣物与背景
                    GroupBox(label: Label("身体、衣物与环境", systemImage: "tshirt").font(.system(size: 12, weight: .semibold))) {
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle("智能全身身形与姿态塑形 (天鹅颈/直角肩/全身瘦身/细腰/长腿增高/瘦手臂/背景保护)", isOn: $model.syncOptions.bodyReshape)
                            Toggle("智能衣物褶皱平整", isOn: $model.syncOptions.clothing)
                            Toggle("身体与手部美肤 (颈纹淡化/手背青筋/身体磨皮/肤色统一)", isOn: $model.syncOptions.bodySkin)
                            Toggle("影棚纯色背景修复 (折痕消除/污渍清理/色调统一)", isOn: $model.syncOptions.backdrop)
                            Toggle("智能天空识别与氛围置换 (湛蓝天色/晚霞/5种预设/环境光照匹配)", isOn: $model.syncOptions.skyEnhancement)
                            Toggle("智能宠物写真美化 (毛发蓬松/明眸/鼻吻/去黄净白)", isOn: $model.syncOptions.petEnhancement)
                        }
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))
                        .padding(.vertical, 4)
                    }

                    // Group 4: 镜头与特殊效果
                    GroupBox(label: Label("镜头效果与风格质感", systemImage: "camera.aperture").font(.system(size: 12, weight: .semibold))) {
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle("镜头光学 (暗角/横向色差校正)", isOn: $model.syncOptions.lensAndVignette)
                            Toggle("智能大光圈景深虚化与光斑雕刻 (4款光圈形状/高光光斑爆发/边缘防溢色)", isOn: $model.syncOptions.bokehBlur)
                            Toggle("胶片颗粒与柔光高光 (Grain & Bloom)", isOn: $model.syncOptions.creativeEffects)
                        }
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))
                        .padding(.vertical, 4)
                    }

                    // Group 5: 构图与局部笔刷 (保护性项目，默认关闭)
                    GroupBox(label: Label("局部笔迹与构图（跨图应用易错位，建议谨慎勾选）", systemImage: "exclamationmark.triangle").font(.system(size: 12, weight: .semibold))) {
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle("局部调整蒙版 (笔刷/渐变/径向蒙版)", isOn: $model.syncOptions.localMasks)
                            Toggle("瑕疵修复笔刷 (仿制/修补笔迹)", isOn: $model.syncOptions.repairBrush)
                            Toggle("几何裁剪与旋转透视 (Crop & Rotation)", isOn: $model.syncOptions.geometry)
                            Toggle("证件照背景替换与尺寸裁切", isOn: $model.syncOptions.certificatePhoto)
                        }
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))
                        .padding(.vertical, 4)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .frame(maxHeight: 460)

            Divider()

            // Footer
            HStack {
                Text("选中的参数将一次性覆盖写入目标照片，支持 Cmd+Z 一键撤销。")
                    .font(.system(size: 10))
                    .foregroundColor(AtelierPalette.muted)

                Spacer()

                Button("取消") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)

                Button {
                    let targets = model.selectedIDs.isEmpty ? (model.selectedID.map { [$0] } ?? []) : Array(model.selectedIDs)
                    model.syncAdjustments(
                        source: model.adjustments,
                        sourceLUT: model.selectedLUT,
                        targetIDs: targets,
                        options: model.syncOptions,
                        actionTitle: "同步调整设置"
                    )
                    dismiss()
                } label: {
                    Text("同步至已选的 \(model.selectedIDs.count) 张照片")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(AtelierPalette.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.selectedIDs.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 580, height: 600)
    }
}

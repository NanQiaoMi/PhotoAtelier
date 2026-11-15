import Foundation
import PhotoCore
import SwiftUI

// MARK: - Portrait Categories

/// High-level scenario categories for portrait retouching.
public enum PortraitCategory: String, CaseIterable, Identifiable {
    case quickStyles = "quick"   // 🌟 智能速修
    case skin = "skin"           // 🧖‍♀️ 极润美肤
    case bone = "bone"           // 💎 骨相光影
    case features = "features"   // 👁️ 五官微雕
    case makeup = "makeup"       // 💄 美妆秀发
    case body = "body"           // 👗 身形服饰

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .quickStyles: return "智能速修"
        case .skin: return "极润美肤"
        case .bone: return "骨相光影"
        case .features: return "五官微雕"
        case .makeup: return "美妆秀发"
        case .body: return "身形服饰"
        }
    }

    public var icon: String {
        switch self {
        case .quickStyles: return "sparkles"
        case .skin: return "hand.sparkles"
        case .bone: return "cube.transparent"
        case .features: return "face.dashed"
        case .makeup: return "paintpalette"
        case .body: return "figure.stand"
        }
    }
}

// MARK: - Portrait Module Types

/// Granular retouching modules that can be individually inspected, bypassed (👁️), or reset (⟲).
public enum PortraitModuleType: String, CaseIterable, Identifiable {
    // 1. 极润美肤 (Skin & Complexion)
    case skinRetouch        // 基础磨皮与质感
    case facialZonal        // 五区去皱与去油光 (P2-H)
    case skinToneUnify      // 面部肤色统一
    case bodySkin           // 身体与手部美肤 (P2-G)

    // 2. 骨相光影 (3D Bone & Contour)
    case facialBoneContour  // 全脸骨相立体光影与折叠度 (P2-Z)
    case facialContour      // 太阳穴丰盈与颧骨微雕 (P2-X)
    case jawChinReshape     // 下颌角收窄与立体下巴 (P2-W)

    // 3. 五官微雕 (Features Sculpting)
    case noseReshape        // 鼻部精致微雕与立体鼻梁高光 (P2-V)
    case eyebrowReshape     // 眉形微雕与野生眉毛流感 (P2-Y)
    case eyeShape           // 眼型微雕与眼位平衡 (P2-U)
    case eyelidAegyoSal     // 双眼皮贴修饰与卧蚕立体塑形 (P2-P)
    case eyeTeeth           // 眼神光/去反光/牙齿美白 (P2-N)
    case expression         // 微笑嘴角与唇形微雕 (P2-T)

    // 4. 美妆秀发 (Makeup & Hair)
    case makeup             // 经典彩妆 (唇色/腮红/眼影/睫毛/修容)
    case hairRefine         // 秀发柔顺/发缝/光泽
    case hairColor          // 智能发色与白发消除 (P2-R)
    case facialHair         // 唇毛胡青与特征痣 (P2-S)

    // 5. 身形服饰 (Body & Clothing)
    case bodyReshape        // 全身身形姿态美化 (P2-O)
    case clothing           // 衣物平整祛皱 (P2-F)
    case bokehBlur          // 全景景深光斑虚化 (P2-Q)

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .skinRetouch: return "质感磨皮"
        case .facialZonal: return "五区祛皱与去油光"
        case .skinToneUnify: return "肤色统一"
        case .bodySkin: return "身体与手部美肤"
        case .facialBoneContour: return "骨相光影与折叠度"
        case .facialContour: return "太阳穴与颧骨轮廓"
        case .jawChinReshape: return "下颌角与下巴塑形"
        case .noseReshape: return "鼻部微雕与高光"
        case .eyebrowReshape: return "野生眉与眉形微雕"
        case .eyeShape: return "眼型微雕与眼位平衡"
        case .eyelidAegyoSal: return "双眼皮与立体卧蚕"
        case .eyeTeeth: return "眼神光与牙齿美白"
        case .expression: return "微笑表情与唇形微雕"
        case .makeup: return "立体彩妆精修"
        case .hairRefine: return "秀发柔顺与发缝填充"
        case .hairColor: return "发色统一与白发消除"
        case .facialHair: return "唇毛胡青与特征痣"
        case .bodyReshape: return "全身姿态与骨骼塑形"
        case .clothing: return "衣物平整与祛皱"
        case .bokehBlur: return "景深虚化与光斑"
        }
    }

    public var shortTitle: String {
        switch self {
        case .skinRetouch: return "磨皮"
        case .facialZonal: return "五区祛皱"
        case .skinToneUnify: return "肤色统一"
        case .bodySkin: return "身体美肤"
        case .facialBoneContour: return "骨相折叠度"
        case .facialContour: return "外轮廓"
        case .jawChinReshape: return "下颌下巴"
        case .noseReshape: return "鼻部微雕"
        case .eyebrowReshape: return "野生眉"
        case .eyeShape: return "眼型微雕"
        case .eyelidAegyoSal: return "双眼皮卧蚕"
        case .eyeTeeth: return "眼神牙齿"
        case .expression: return "微笑唇形"
        case .makeup: return "彩妆"
        case .hairRefine: return "秀发发缝"
        case .hairColor: return "发色"
        case .facialHair: return "唇毛胡青"
        case .bodyReshape: return "全身塑形"
        case .clothing: return "衣物祛皱"
        case .bokehBlur: return "景深光斑"
        }
    }

    public var icon: String {
        switch self {
        case .skinRetouch: return "wand.and.stars"
        case .facialZonal: return "waveform.path.ecg"
        case .skinToneUnify: return "circle.lefthalf.filled"
        case .bodySkin: return "hand.raised.fill"
        case .facialBoneContour: return "cube.transparent"
        case .facialContour: return "oval.portrait"
        case .jawChinReshape: return "arrow.down.right.and.arrow.up.left"
        case .noseReshape: return "triangle"
        case .eyebrowReshape: return "line.diagonal"
        case .eyeShape: return "eye"
        case .eyelidAegyoSal: return "eye.circle"
        case .eyeTeeth: return "sparkle"
        case .expression: return "mouth"
        case .makeup: return "paintpalette"
        case .hairRefine: return "comb"
        case .hairColor: return "paintbrush.pointed"
        case .facialHair: return "mustache"
        case .bodyReshape: return "figure.stand"
        case .clothing: return "tshirt"
        case .bokehBlur: return "camera.metering.spot"
        }
    }

    public var category: PortraitCategory {
        switch self {
        case .skinRetouch, .facialZonal, .skinToneUnify, .bodySkin:
            return .skin
        case .facialBoneContour, .facialContour, .jawChinReshape:
            return .bone
        case .noseReshape, .eyebrowReshape, .eyeShape, .eyelidAegyoSal, .eyeTeeth, .expression:
            return .features
        case .makeup, .hairRefine, .hairColor, .facialHair:
            return .makeup
        case .bodyReshape, .clothing, .bokehBlur:
            return .body
        }
    }

    /// Checks if this module has any non-neutral settings configured.
    public func isActive(in settings: AdjustmentSettings) -> Bool {
        switch self {
        case .skinRetouch:
            guard let p = settings.portrait else { return false }
            return p.blemishStrength > 0 || p.skinSmoothing > 0
                || p.dodgeBurn > 0 || p.structure > 0 || p.texture > 0 || p.gloss > 0
        case .facialZonal:
            return settings.facialZonal?.isNeutral == false
        case .skinToneUnify:
            return (settings.portrait?.skinToneUnify ?? 0) > 0
        case .bodySkin:
            return settings.bodySkin?.isNeutral == false
        case .facialBoneContour:
            return settings.facialBoneContour?.isNeutral == false
        case .facialContour:
            return settings.facialContour?.isNeutral == false
        case .jawChinReshape:
            return settings.jawChinReshape?.isNeutral == false
        case .noseReshape:
            return settings.noseReshape?.isNeutral == false
        case .eyebrowReshape:
            return settings.eyebrowReshape?.isNeutral == false
        case .eyeShape:
            return settings.eyeShape?.isNeutral == false
        case .eyelidAegyoSal:
            return settings.eyelidAegyoSal?.isNeutral == false
        case .eyeTeeth:
            return settings.eyeTeeth?.isNeutral == false
        case .expression:
            return settings.expression?.isNeutral == false
        case .makeup:
            return settings.makeup?.isNeutral == false
        case .hairRefine:
            guard let p = settings.portrait else { return false }
            return p.hairGapFilling > 0 || p.hairGloss > 0 || p.hairDarkening > 0 || p.hairSmoothing > 0 || p.flyawayRemoval > 0
        case .hairColor:
            return settings.hairColor?.isNeutral == false
        case .facialHair:
            return settings.facialHair?.isNeutral == false
        case .bodyReshape:
            return settings.bodyReshape?.isNeutral == false
        case .clothing:
            return settings.clothing?.isNeutral == false
        case .bokehBlur:
            return settings.bokehBlur?.isNeutral == false
        }
    }
}

// MARK: - Curated Portrait Studio Presets

public struct PortraitPreset: Identifiable, Equatable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let icon: String
    public let description: String
    public let tags: [String]

    public static let builtIns: [PortraitPreset] = [
        PortraitPreset(
            id: "high_fashion_bone",
            title: "高级折叠骨相",
            subtitle: "立体紧凑 · 杂志封面感",
            icon: "cube.transparent",
            description: "增强面部折叠度收紧侧颜，雕刻 T区与双侧C区珍珠高光，收敛颧骨与下颌角，打造超模立体骨相。",
            tags: ["折叠度", "T区高光", "修容", "收下颌"]
        ),
        PortraitPreset(
            id: "cool_supermodel",
            title: "清冷超模微雕",
            subtitle: "眼尾微提 · 根根野生眉",
            icon: "sparkles",
            description: "微调眼尾走向与下至，注入高密度根根分明野生眉毛流感，冷调修容中和发暖油光，展现清冷高级气场。",
            tags: ["野生眉", "眼尾下至", "冷调修容", "发丝深邃"]
        ),
        PortraitPreset(
            id: "soft_youthful",
            title: "自然幼态少女",
            subtitle: "短中庭 · 饱满卧蚕苹果肌",
            icon: "face.smiling",
            description: "纵向微调缩短中庭眼距，充盈饱满太阳穴与苹果肌，雕刻水滴鼻尖与立体卧蚕，嘴角微翘柔美幼态。",
            tags: ["短中庭", "立体卧蚕", "饱满苹果肌", "微笑嘴角"]
        ),
        PortraitPreset(
            id: "studio_clarity",
            title: "商业影棚精修",
            subtitle: "双频质感 · 纯净明眸美牙",
            icon: "camera.metering.spot",
            description: "中性灰光影平整抚平油光与泪沟，眼白去红血丝注入八角柔光眼神光，珐琅质牙齿净白，商业成片直出。",
            tags: ["质感磨皮", "去油光泪沟", "眼神光", "牙齿净白"]
        ),
        PortraitPreset(
            id: "masculine_sculpt",
            title: "男士硬朗雕塑",
            subtitle: "下颌轮廓 · 剃须胡青净化",
            icon: "figure.stand",
            description: "硬朗雕塑下颌边缘与颏部阴影，定向中和剃须后冷调胡青颗粒，消除面部瑕疵同时完好保留原生胡须与特征痣。",
            tags: ["硬朗下颌", "去胡青", "男士肤质", "保留特征痣"]
        )
    ]
}

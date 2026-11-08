# P2-R 实施计划：智能发色统一、白发消除与自然换发色 (Smart Hair Color Harmonization & Gray Hair Removal)

## 1. 目标与范围

依据 `docs/pixelcake-gap-analysis.md` §3.3/§4.7 与 `docs/research/pixelcake-matrix.md` §4.7（发色：去白发、发色统一、一键换发色），交付原生离线、GPU 加速的发色修整与换色引擎：
1. **去白发 / 银发消除 (`grayHairRemoval`)**：针对中老年写真、父母合影与成熟商务肖像中的零星银丝白发，智能定位高亮无彩灰白丝缕，取样周边基底发色进行自适应柔和着色与压暗，彻底避免黑头盔式的粗暴涂抹感；
2. **发色统一 (`hairHarmonization`)**：针对户外阳光曝晒发梢发黄、染发退色发段分层、发质枯燥暗淡问题，计算主要发丝色彩均值，将斑驳杂乱区域平滑收敛至统一发色；
3. **自然换发色 / 调色 (`HairTone`)**：支持 7 款经典沙龙发色预设（原色、自然黑茶、优雅栗棕、深摩卡棕、醇厚红酒、冷灰亚麻、暖蜜金棕），搭配发色强度与明度微调，保留高频发丝纹理与高光反差；
4. **头发区域语义提取与保护 (`makeHairMask`)**：结合人脸关键点解剖拓扑（额头、鬓角、颅顶）与人物语义分割，精准约束在头发区域，严格保护面部皮肤、眉毛、眼睛与背景；
5. **多人多脸独立覆盖支持**：接入 `PersonPortraitProfile.hairColorOverride`，支持男女老少差异化发色配置；
6. **配方升级至 Version 25**：非中性 `hairColor` 强制升级至配方版本 25；
7. **UI 与批量选择性同步**：在 `PortraitRetouchPanel.swift` 增加专有控制组，并在 `SelectiveSyncSheet.swift` 增加独立同步项。

---

## 2. 验收标准清单 (Checklist)

- [ ] `HairColorSettings` 具备完备边界校验（0...1，-0.5...0.5）与中性判断；
- [ ] 7 款经典发色预设色彩映射物理合理，色彩平滑自然；
- [ ] 去白发算法精准压暗高亮银丝，保留天然发丝高光；
- [ ] 发色统一消除色差斑驳，过渡平滑无阶梯；
- [ ] 严格保护额头、五官与背景不被发色污染；
- [ ] 配方版本 25 门禁与未来版本拦截测试通过；
- [ ] 选择性同步、重置与多人分人覆盖行为正确；
- [ ] 单元测试全绿，全量测试套件零失败；
- [ ] Universal 双架构构建与应用包校验通过。

---

## 3. 技术设计

### 3.1 数据模型 (`Sources/PhotoCore/Models.swift`)
```swift
public enum HairTone: String, Codable, CaseIterable, Sendable {
    case original        // 保持原色
    case naturalBlack    // 自然黑茶
    case chestnutBrown   // 优雅栗棕
    case mochaDark       // 深摩卡棕
    case burgundyRed     // 醇厚红酒
    case coolLinen       // 冷灰亚麻
    case honeyGold       // 暖蜜金棕
}

public struct HairColorSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var grayHairRemoval: Double       // 0...1 (去白发强度)
    public var hairHarmonization: Double      // 0...1 (发色统一收敛度)
    public var hairTone: HairTone             // 目标发色
    public var hairToneStrength: Double      // 0...1 (发色调色强度)
    public var hairLuminanceAdjust: Double   // -0.5...0.5 (发色明度微调)
}
```

### 3.2 核心着色器 (`Sources/PhotoCore/HairColorEngine.swift`)
- 专用 Core Image GPU `CIColorKernel` 着色器：
  - 计算发丝局部亮度、饱和度与色相；
  - 白发判定条件：`luma > hairMedianLuma + 0.15 && saturation < 0.18`；
  - 目标发色调制：在 OKLab / 感知色彩空间中施加目标色度，保持原有高频发丝纹理与反光梯度。

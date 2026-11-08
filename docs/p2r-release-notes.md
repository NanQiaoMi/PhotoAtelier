# P2-R 发布说明：智能发色统一、白发消除与自然换发色 (Smart Hair Color Harmonization, Gray Hair Removal & Natural Hair Recoloring)

## 概述

在商业人像摄影、婚纱礼服、家庭全家福与高端肖像后期中，秀发色彩是影响人物视觉年龄与画面精致感的关键要素（对齐 PixelCake 官方能力矩阵 §3.3/§4.7 与 `docs/research/pixelcake-matrix.md` §4.7）。在中老年长辈写真中，零星散乱的白发银丝常常破坏画面稳重感；在户外旅拍与时尚写真中，强日光曝晒常导致发梢枯黄、退色分层与斑驳色块；此外，客户常常期望尝试不同沙龙发色以搭配服装。

传统的发色处理往往面临三大行业痛点：
1. **白发消除生硬假黑 (Unnatural Black Helmet)**：粗暴压暗或仿制图章涂抹，导致头发丧失微观毛流质感与天然高光，形成塑料假发感；
2. **斑驳色差过渡断层 (Mottled Color Banding)**：退色发梢与深色发根之间色彩跳跃，全图调色容易将正常发色调偏；
3. **换发色丢失立体光影 (Loss of Specular Highlights)**：整块贴色破坏了原本头发受光产生的天使光环高光与暗部层次。

本次更新交付 **P2-R 智能发色统一、白发消除与自然换发色系统 (Smart Hair Color Harmonization, Gray Hair Removal & Natural Hair Recoloring)**：
1. **去白发 / 银发消除 (`grayHairRemoval`)**：精准定位发丛中高亮度、低饱和的银白发丝微结构，智能采样周边基底发色进行自适应柔和着色与压暗，保留发丝原生高频纹理与高光反差；
2. **发色统一 (`hairHarmonization`)**：智能分析毛发主色调与中位饱和度，检测发梢枯黄、退色与日晒偏色区域，将其平滑收敛至统一基准色调；
3. **7 大经典沙龙发色调色 (`HairTone`)**：
   - **保持原色 (`.original`)**：维持原本天然发色；
   - **自然黑茶 (`.naturalBlack`)**：乌黑亮丽、质感深沉；
   - **优雅栗棕 (`.chestnutBrown`)**：温暖柔和、经典百搭；
   - **深摩卡棕 (`.mochaDark`)**：沉稳醇厚、浓郁气质；
   - **醇厚红酒 (`.burgundyRed`)**：暖调微醺、时尚典雅；
   - **冷灰亚麻 (`.coolLinen`)**：清冷雾感、高级混血；
   - **暖蜜金棕 (`.honeyGold`)**：阳光通透、活力吸睛；
4. **明度与浓度微调**：提供发色调色强度 (`hairToneStrength`) 与发色明度微调 (`hairLuminanceAdjust`)，确保高光亮而不曝、阴影深而不死；
5. **头部解剖学拓扑与人物语义保护**：精准约束在颅顶、鬓角与主要发丛，严格保护额头、五官与衣服背景不被污染；
6. **多人多脸独立覆盖支持**：接入 `PersonPortraitProfile.hairColorOverride`，男女老少可分别配置不同发色；
7. **配方升级至 Version 25**：非中性 `hairColor` 强制受 Recipe Version 25 门禁保护；
8. **批量选择性同步**：在 `AdjustmentSyncOptions` 与 `SelectiveSyncSheet.swift` 增加独立同步开关。

---

## 核心技术与数据结构变更

### 1. 数据模型 (`Sources/PhotoCore/Models.swift`)
- **`HairTone` 枚举**：7 种经典沙龙发色定义与目标 RGB 标定。
- **`HairColorSettings` 结构体**：
  - `enabled: Bool`：主开关；
  - `grayHairRemoval: Double` (0...1，默认 0.0)：去白发强度；
  - `hairHarmonization: Double` (0...1，默认 0.0)：发色统一强度；
  - `hairTone: HairTone`：目标沙龙发色；
  - `hairToneStrength: Double` (0...1，默认 0.0)：发色调色强度；
  - `hairLuminanceAdjust: Double` (-0.5...0.5，默认 0.0)：发色明度微调。
- **`HairColorReport`**：记录执行状态、人脸数量、白发消除/统一/调色分别应用情况及提示信息。
- **`AdjustmentSettings` 扩充**：`public var hairColor: HairColorSettings? = nil`。
- **`PersonPortraitProfile` 扩充**：`public var hairColorOverride: HairColorSettings? = nil`。
- **`ProcessingReport` 扩充**：`public var hairColor: HairColorReport? = nil`。
- **`Recipe.validateVersion()`**：支持范围升级为 `1...25`，非中性 `hairColor` 强制要求版本 25。

### 2. 核心算法引擎 (`Sources/PhotoCore/HairColorEngine.swift`)
- **头发解剖学空间权重**：基于 `facePixelRect` 动态计算颅顶弧度、额头截断与耳际鬓角空间分布；
- **白发判定与平滑着色**：结合亮度与非色度特征判定银白发丝，取样健康基底发色无缝融合；
- **发色离群值收敛着色器**：色度差分与发梢枯黄抑制；
- **光照保持型沙龙发色着色器**：依据发丝原生明度动态调节着色亮度，完美保留天然发丝高光；
- **多人多脸独立覆盖**：`applyPerPerson` 支持多人分人不同发色方案。

### 3. 主引擎管线集成 (`Sources/PhotoCore/PhotoEngine.swift`)
- 在单人/全局人像渲染管线中执行 `HairColorEngine.apply`；
- 在多人分人循环中集成 `HairColorEngine.applyPerPerson`；
- 配方版本计算器 `requiredRecipeVersion` 支持版本 25 检测。

### 4. 批量同步与 UI 交互 (`Sources/PhotoCore/AdjustmentSync.swift` & `Sources/PhotoAtelier/`)
- `AdjustmentSyncOptions` 增加 `hairColor: Bool = true`；
- `SelectiveSyncSheet.swift` 在「人像美颜与微整形」增加同步开关；
- `AppModel.swift` 增加发色状态管理、开关与重置方法；
- `PortraitRetouchPanel.swift` 新增「发色统一与白发消除」独立控制组。

---

## 验证与测试

1. **单元测试 (`Tests/PhotoCoreTests/HairColorTests.swift`)**：
   - 默认配置中性检测与无损跳过；
   - 参数边界防护与范围自动收敛；
   - 银白发丝压暗着色测试；
   - 斑驳发梢枯黄收敛统一测试；
   - 7 种沙龙发色逐一渲染测试；
   - 配方版本 25 门禁控制与未来版本拦截；
   - 选择性同步合并与重置行为验证；
   - 多人人脸独立配置覆盖测试。
2. **回归测试**：全量执行 687 项单元测试，全部 0 failure 通过。
3. **应用构建验证**：构建 Universal (x86_64 + arm64) macOS 二进制应用包，通过 `verify_app.py` 完整性校验。

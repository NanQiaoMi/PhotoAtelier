# P2-N 发布说明：智能眼神光、眼镜去反光、眼白去红血丝与牙齿美学精修 (Smart Eye Clarity & Aesthetic Teeth Refinement)

## 概述

在商业人像精修中，眼神与笑容是决定人物第一印象、神采与亲和力的关键。传统修图痛点包括：
1. **眼镜反光干扰**：佩戴眼镜的被摄者极易在镜片表面产生白色反光斑块或泛白雾化，遮挡瞳孔与眼神；
2. **眼白充血与浊黄**：疲劳导致的红血丝、微血管和眼白偏黄无法自动消除，影响纯净神采；
3. **眼神空洞缺乏生机**：平光或背光拍摄时缺乏立体眼神光，虹膜平淡无层次；
4. **牙齿假白与瑕疵**：传统全局牙齿美白容易导致牙齿死板假白、缺乏天然半透明珐琅质光泽，且牙面烟茶渍、食物微残渣或边缘口红印无法自动净化；同时可能过度漂白牙龈，破坏健康的粉红牙龈对比。

本次更新交付 **P2-N 智能眼神光、眼镜去反光、眼白去红血丝与牙齿美学精修系统 (Smart Eye Clarity, Eyeglass Anti-Glare, Sclera Bloodshot Removal & Aesthetic Teeth Restoration)**：
1. **眼镜镜片去反光 (Eyeglass Anti-Glare)**：在镜片推断区域检测高明度反光斑，结合周围虹膜与肤色平滑重建中和，消除镜片白雾；
2. **眼白去红血丝与浊色净化 (Sclera Bloodshot Removal)**：精准定位眼白区域，识别红色微血管与黄色浊斑，利用保边滤波净化眼白底色；
3. **虹膜明眸与眼神光雕刻 (Iris Clarity & Catchlight Rendering)**：瞳孔中心自适应定位，程序化矢量光栅化 6 款摄影级眼神光斑（自然单点、时尚环形、方形柔光箱、双侧条形光、经典蝶形、璀璨星芒），支持平滑混合与高光光泽叠加；
4. **牙齿污斑净化与珐琅质微光 (Teeth Stain Removal & Enamel Sheen)**：牙面孤立色斑/唇红印记平抚，牙龈粉红区域边界保护，迎光面重注入天然珐琅质半透明光泽；
5. **多人分组与分人独立配置**：完整支持多人场景（P2-M），支持针对新郎、新娘、儿童、长辈分别配置专属眼神光与牙齿清洁强度；
6. **参数选择性复制与批量同步**：完整接入 `SelectiveSyncSheet` 与 `AdjustmentSyncEngine`；
7. **配方版本升级至 21**：非中性 `eyeTeeth` 字段受 Recipe Version 21 门禁保护；历史配方 100% 保持无损向下兼容。

---

## 核心技术与数据结构变更

### 1. 数据模型 (`Sources/PhotoCore/Models.swift`)
- **`EyeCatchlightPattern` 枚举**：
  ```swift
  public enum EyeCatchlightPattern: String, Codable, CaseIterable, Identifiable {
      case off
      case naturalPoint   // 自然单点光
      case ringLight      // 时尚环形光
      case softboxSquare  // 方形柔光箱
      case dualStrip      // 双侧条形光
      case butterfly      // 经典蝶形光
      case starburst      // 璀璨星芒光
  }
  ```
- **`EyeTeethRefinementSettings`**：
  - `enabled: Bool`
  - `eyeglassGlareReduction: Double` (0...1)
  - `scleraBloodshotRemoval: Double` (0...1)
  - `irisClarity: Double` (0...1)
  - `catchlightPattern: EyeCatchlightPattern`
  - `catchlightStrength: Double` (0...1)
  - `catchlightScale: Double` (0.5...2.0)
  - `teethStainRemoval: Double` (0...1)
  - `enamelSheen: Double` (0...1)
  - `gingivaProtection: Double` (0...1)
- **`AdjustmentSettings` 扩充**：`public var eyeTeeth: EyeTeethRefinementSettings? = nil`。
- **`PersonPortraitProfile` 扩充**：`public var eyeTeethOverride: EyeTeethRefinementSettings? = nil`，并在 4 大角色默认预设中提供最佳实践。
- **`Recipe.validateVersion()`**：支持版本 21，并对非中性 `eyeTeeth` 设置增加门禁保护。

### 2. 核心算法引擎 (`Sources/PhotoCore/EyeTeethRefinement.swift`)
- **`EyeTeethRefinementEngine`**：
  - 采用 Core Image & Metal 加速 CIColorKernel：
    - `eyeRefinementKernel`：在巩膜区域抑制红血丝偏沉并提纯黄浊，在虹膜区做 S 曲线纹理增强与暗边缘环强化，在反光区压低高光白雾；
    - `teethRefinementKernel`：在牙齿表面提亮被黄茶渍/烟渍抑制的蓝通道，消除溢出唇膏印，迎光面重塑半透明珐琅质微高光，并通过牙龈蒙版确保粉红牙龈不被漂白；
    - `catchlightBlendKernel`：基于左右眼瞳孔定位，程序化矢量光栅化 6 款影棚级眼神光光斑，以加色/柔和滤色混合叠加。

### 3. 主引擎管线集成 (`Sources/PhotoCore/PhotoEngine.swift`)
- 在主渲染管线中执行眼部与牙齿美学精修；
- 在多人模式中依次应用各人物的专属配置；
- 记录 `EyeTeethRefinementReport` 并计入批处理清单。

### 4. 批量同步与快捷工具 (`Sources/PhotoCore/AdjustmentSync.swift` & `SelectiveSyncSheet.swift`)
- `AdjustmentSyncOptions` 扩充 `eyeTeeth: Bool = true`；
- 多选同步面板新增「明眸眼神光与牙齿美学精修」复选框。

### 5. UI 交互体验 (`Sources/PhotoAtelier/PortraitRetouchPanel.swift` & `AppModel.swift`)
- 「人像」面板新增「明眸眼神光与牙齿美学」模块：
  - 开关控件、重置按钮、状态说明；
  - 眼镜去反光、眼白去红血丝、虹膜明眸深邃滑杆；
  - 眼神光模板选择 Picker（自然单点、时尚环形、方形柔光箱、双侧条形光、经典蝶形、璀璨星芒）与强度/尺寸微调滑杆；
  - 牙渍唇膏净化、珐琅质自然微光、牙龈粉润保护滑杆；
  - 联动分人选择胶囊栏，选人后所有滑杆自动映射至该人物。

---

## 验证与测试

- **单元测试覆盖** (`Tests/PhotoCoreTests/EyeTeethRefinementTests.swift`)：
  - `testDefaultSettingsAreNeutral`: 验证中性设置不改变像素。
  - `testValidationRejectsOutOfRange`: 验证参数范围校验。
  - `testCatchlightOverlayPatternGeneration`: 验证全部 6 款眼神光矢量光斑生成。
  - `testScleraBloodshotRemoval`: 验证红血丝与微血管有效淡化。
  - `testEyeglassGlareSuppression`: 验证眼镜镜片高光反光有效压平。
  - `testTeethStainRemovalAndEnamelSheen`: 验证牙面茶渍净化与珐琅质高光重塑。
  - `testRecipeVersion21Validation`: 验证 Recipe Version 21 门禁保护。
  - `testSelectiveSyncEyeTeeth`: 验证选择性同步复制与合并。
  - `testMultiPersonEyeTeethProfileOverride`: 验证分人配置覆盖与管线应用。
- **全量测试套件回归**：
  - 647 个测试全部通过（0 失败）。
- **Universal 原生打包校验**：
  - 成功生成 `x86_64` + `arm64` 双架构 Universal 原生应用并通过 `verify_app.py` 签名校验。

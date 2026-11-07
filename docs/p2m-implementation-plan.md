# P2-M: 多人脸属性感知与分组独立精修 实现计划

## 1. 目标与背景
在商业摄影（婚纱合影、全家福、商务团队照、儿童亲子照）中，画面中往往同时存在多位不同性别、年龄的人物：
- **新娘 / 女性**：需要细腻均匀的高精磨皮、红润气色、立体修容与自然妆容；
- **新郎 / 男性**：需要低强度平整、坚决保留胡须发茬结构与硬朗骨骼轮廓，免除口红眼影等女性化妆容；
- **儿童 / 婴儿**：原生婴儿肌极度娇嫩，禁止高强度磨皮与去瑕疵（避免把自然的婴儿胎脂感抹成假塑料皮），免妆容；
- **长辈 / 老人**：保留自然岁月肌理与眼神骨相，减淡老年斑与深重暗沉，避免蜡像硅胶感；
- **全员肤色统一 (Multi-Person Skin Tone Unification)**：解决合影中因皮脂反光、男女天生色差或布光角度导致的一黑一白、偏青偏黄脱节问题。

## 2. 变更分级 (Rule 3.1)
**大型变更**：
- 新增功能与新模块：多人脸独立语义蒙版拆分、本地启发式人口属性感知（性别/年龄角色）、分人独立修图管线、多人肤色协调统一算法；
- 跨模块改动：`PhotoCore`（`Models`, `FaceSemanticAnalysis`, `PortraitRefinement`, `MakeupEngine`, `PhotoEngine`, `PhotoSelection`）与 `PhotoAtelier`（`AppModel`, `PortraitRetouchPanel`, `ContentView`）；
- 配方版本升级至 20（`Recipe.validateVersion`）；
- 预计新增/修改 ≥3 个非测试源文件，改动 ≥150 行。

## 3. 架构设计与实现步骤

### 3.1 数据模型扩展 (`Sources/PhotoCore/Models.swift`)
1. 定义人口角色枚举：
   ```swift
   public enum PersonDemographicRole: String, Codable, CaseIterable, Identifiable {
       case femaleAdult = "femaleAdult"   // 女性 / 新娘
       case maleAdult = "maleAdult"       // 男性 / 新郎
       case child = "child"               // 儿童 / 婴儿
       case elder = "elder"               // 长辈 / 老人
       case unassigned = "unassigned"     // 通用 / 未指定
   }
   ```
2. 定义单人精修独立配置：
   ```swift
   public struct PersonPortraitProfile: Identifiable, Codable, Equatable {
       public var id: UUID
       public var faceIndex: Int?         // 针对特定检测人脸序号 (0, 1, ...) 或 nil（角色模板）
       public var role: PersonDemographicRole
       public var enabled: Bool
       public var portraitOverride: PortraitRefinementSettings?
       public var makeupOverride: MakeupSettings?
       public var facialZonalOverride: FacialZonalRefinementSettings?
   }
   ```
3. 定义多人精修全局设置：
   ```swift
   public struct MultiPersonSettings: Codable, Equatable {
       public var enabled: Bool
       public var unifySkinTone: Double              // 0...1 肤色统一强度
       public var toneReference: PortraitToneReference
       public var roleDefaults: [PersonDemographicRole: PersonPortraitProfile]
       public var customProfiles: [PersonPortraitProfile]
       public var isNeutral: Bool
   }
   ```
4. 在 `AdjustmentSettings` 中添加 `public var multiPerson: MultiPersonSettings? = nil`。
5. 升级 `Recipe.validateVersion`，当 `multiPerson` 非中性时要求配方版本 20。

### 3.2 人脸独立语义提取与属性感知 (`Sources/PhotoCore/FaceSemanticAnalysis.swift`)
1. `FaceSemanticAnalyzer.perFaceMasks(...) -> [FaceSemanticMaskSet]`：
   - 为检测到的每张人脸独立计算 `FaceSemanticMaskSet`（skin, teeth, sclera, iris, lips, brows）。
   - 保留全图合并 `masks(in:landmarks:)`，保证向后兼容。
2. `FaceSemanticAnalyzer.estimateDemographics(face:in:) -> PersonDemographicRole`：
   - 100% 离线、私有，零外部模型依赖。
   - 启发式特征提取：
     - 下颌及下唇下部胡须/青茬暗度与方差分析（CIELab $L^*$, $b^*$ 差异）-> 判断男性；
     - 嘴唇饱和度与红色度（$a^*$）相对周围肤色差异 -> 判断女性红唇/气色；
     - 面部宽高比与眼-下巴纵向紧凑度比例（婴儿/儿童眼大且下庭紧凑短小）-> 判断儿童；
     - 额头与法令区域高频纹理与折痕方差 -> 判断长辈。

### 3.3 图像渲染引擎管线集成 (`Sources/PhotoCore/PortraitRefinement.swift` & `PhotoEngine.swift`)
1. `MultiPersonPortraitEngine`：
   - 多人肤色统一：
     - 采样每张人脸皮肤的加权平均 CIELab 颜色；
     - 计算目标参考色（最亮肤色、中位肤色或指定人脸肤色）；
     - 使用保真度平滑色彩转移矩阵，在每张人脸的皮肤区域应用差值混合（权重 = `unifySkinTone * skinMask`）。
   - 分人独立渲染：
     - 针对每张人脸，匹配其 `customProfiles[faceIndex]` 或对应 `roleDefaults[role]` 或全局兜底设置；
     - 分别执行局部人像磨皮、五区提拉除皱与妆容渲染，合成至全局图像缓冲中。

### 3.4 选择性复制与批量同步扩展 (`Sources/PhotoCore/PhotoSelection.swift`)
- 在 `AdjustmentGroup` 中添加 `.multiPerson` 分组，支持在多图批量选择性复制粘贴中单独复制或保留多人人像配置。

### 3.5 AppModel 与用户界面 (`Sources/PhotoAtelier/`)
1. `AppModel`:
   - 维护 `@Published var detectedFaces: [FaceLandmarkSet]` 与 `@Published var detectedDemographics: [PersonDemographicRole]`；
   - 维护当前选中的人员索引 `@Published var selectedPersonIndex: Int?`；
   - 提供分人属性切换与覆盖配置方法。
2. `PortraitRetouchPanel.swift`:
   - 当画面存在多张人脸时展示多人分人控制区：
     - 人员标签选择胶囊栏：`[全部人员] [人物 1 ♀ 新娘] [人物 2 ♂ 新郎] ...`；
     - 属性切换下拉与快捷角色应用（"新郎保留胡须免妆"、"儿童柔嫩保护"、"新娘高精精修"）；
     - "多人肤色统一" 滑杆与基准选择器（中位/最亮）。

### 3.6 验证与测试
- 编写 `Tests/PhotoCoreTests/MultiPersonPortraitTests.swift` 全面覆盖：
  1. 单人与多人独立 Mask 提取及互斥性测试；
  2. 离线属性感知启发式准确度测试；
  3. 分人独立磨皮/妆容差异化渲染效果测试；
  4. 多人肤色统一色彩偏移与收敛测试；
  5. 配方版本 20 门禁与旧版本兼容测试；
  6. 选择性参数同步测试。
- 执行 `swift test -j 2`、打包 Universal app、`verify_app.py`。

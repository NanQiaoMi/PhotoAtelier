# P2-M 发布说明：多人脸属性感知与分组独立精修 (Multi-Person Face Identification & Group Retouching)

## 概述

在商业合影、婚纱婚礼（新郎新娘）、亲子家庭、毕业合影等多人人像场景中，统一应用相同磨皮与妆容往往会导致画面失真：
- **男士/新郎**：被误施加口红、腮红或过度磨皮导致胡须阴影淡化、面部失去阳刚质感；
- **儿童**：本就细腻娇嫩的婴童皮肤若施加成人磨皮，会导致面部细节严重涂抹、缺乏真实感；
- **长辈**：过度的祛皱与磨皮会抹平自然生动的岁月沉淀与表情结构；
- **新娘/女性**：需要高精度微孔磨皮、立体五区修容及精致五官上妆；
- **多人肤色不均**：由于站位受光不均或天生肤色差异，多人合照极易出现肤色割裂。

本次更新交付 **P2-M 商业级多人脸属性感知与分组独立精修系统**：
1. **多人物独立语义分割**：基于 Vision 地标与颜色自适应聚类，为画面中每个人物（0..<N）生成完全独立的非重叠五官与面部蒙版集（`FaceSemanticMaskSet`）。
2. **启发式人群属性感知 (Demographic Roles)**：
   - 支持 5 类角色定义：`femaleAdult`（女性/新娘）、`maleAdult`（男性/新郎）、`child`（儿童/幼童）、`elder`（长辈）、`unassigned`（通用）。
   - 纯本地原生算法：结合面部比例、下巴胡须阴影（CIELab 亮度/色度落差）、嘴唇自然红润度（$a^*$）与眼周/额头结构特征自动判定，毫秒级完成，零外部大模型依赖。
   - 支持一键手动修正角色。
3. **分人独立精修与针对性预设**：
   - 每个人物可独立设置人像基础精修（磨皮/美白/明眸/祛瑕疵）、面部五区专项祛皱（黑眼圈/眼袋/法令纹/抬头纹/去油光/双下巴）与精致彩妆（唇色/眉色/腮红/眼影/高光/修容/睫毛/眼线）。
   - 提供 4 大专业预设：「男士免妆/保留胡须」、「儿童自然肤质保护」、「长辈自然神采」、「女性/新娘精修」。
4. **多人肤色统一算法 (Multi-Person Skin Tone Unification)**：
   - 跨人物皮肤色相与明度对齐，支持以最白、最深、全员平均或指定关键人物为基准，在保留各自阴影对比的前提下自然消除环境色偏与受光差异。
5. **直观交互与选择性同步**：
   - 「人像」面板新增「多人分组精修」胶囊栏（`[全部人员] [人物 1 ♀ 女性/新娘] [人物 2 ♂ 男性/新郎]`），选人后所有调节滑杆自动映射至该人物。
   - `SelectiveSyncSheet` 与 `AdjustmentSyncEngine` 完整支持分人参数独立复制与批量同步。
6. **配方版本升级至 20**：
   - 非中性多人设置严格受 Recipe Version 20 门禁保护；历史配方（v1~v19）100% 保持原有联合处理路径，实现无损向下兼容。

---

## 核心技术与数据结构变更

### 1. 数据模型 (`Sources/PhotoCore/Models.swift`)
- **`PersonDemographicRole` 枚举**：
  ```swift
  public enum PersonDemographicRole: String, Codable, CaseIterable {
      case unassigned   // 通用 / 未指定
      case femaleAdult  // 女性 / 新娘
      case maleAdult    // 男性 / 新郎
      case child        // 儿童 / 幼童
      case elder        // 长辈
  }
  ```
- **`PersonPortraitProfile` 独立配置结构体**：
  - 封装各人物的角色分配、是否启用覆盖、独立 `PortraitRefinementSettings`、`FacialZonalRefinementSettings` 与 `MakeupSettings`。
  - 内置 `defaultProfile(for role:)` 提供行业级最佳实践预设。
- **`MultiPersonSettings`**：
  - `enabled: Bool`
  - `unifySkinTone: Double` (0...1)
  - `toneReference: PortraitToneReference` (.average / .brightest / .darkest / .person(index))
  - `demographicDefaults: [PersonDemographicRole: PersonPortraitProfile]`
  - `individualProfiles: [Int: PersonPortraitProfile]`
- **配方版本控制**：
  - `Recipe.validateVersion()` 支持至版本 20。
  - 含有非中性 `multiPerson` 字段时强制要求 `version >= 20`。

### 2. 人脸独立感知与分人语义分割 (`Sources/PhotoCore/FaceSemanticAnalysis.swift`)
- **`FaceSemanticAnalyzer.perFaceMasks`**：
  - 一次性光栅化整图颜色与面部地标后，按单个人脸几何边界分别裁切并提取无冲突的语义蒙版集（`skinMask`、`lipsMask`、`teethMask`、`eyesMask`）。
- **`FaceSemanticAnalyzer.estimateDemographicRole`**：
  - 提取面部五官关键区域：下巴须根区（lower chin）、嘴唇区（lips）、面颊区（cheeks）与额头区（forehead）。
  - 在 CIELab 空间测量：
    - 须根阴影特征：下巴相对于额头/面颊的亮度阶跃与色度偏沉；
    - 唇红特征：嘴唇 $a^*$ 通道红润度相对于面部肤色的对比度；
    - 面部比例特征：眼唇纵横比与面部几何紧凑度，有效区分幼童与成年人。
  - 纯本地启发式算法，极速且无需额外网络或权重。

### 3. 主引擎管线集成 (`Sources/PhotoCore/PhotoEngine.swift`)
- 在主渲染管线中执行分人精修：
  - 当检测到多人（`faces.count > 1`）且开启 `multiPerson.enabled` 时，管线自动切换至多通道分人精修分支；
  - 依次对每个人物应用其专属配置（未独立指定时继承该角色的 demographicDefault 或全局设置）；
  - 精修包括：人像肤质平整与祛瑕疵、五区专项祛皱（黑眼圈/眼袋/法令纹/抬头纹/双下巴/去油光）、五官精致彩妆；
  - 最后应用多人皮肤色调统一（`skinToneUnify`）。

### 4. 批量同步与快捷工具 (`Sources/PhotoCore/AdjustmentSync.swift` & `SelectiveSyncSheet.swift`)
- `AdjustmentSyncOptions` 扩充 `multiPerson: Bool = true`；
- 支持在多选同步面板勾选「多人分人属性感知与独立精修」，可安全将新郎/新娘独立调校复制至同批次照片。

### 5. UI 交互体验 (`Sources/PhotoAtelier/PortraitRetouchPanel.swift` & `AppModel.swift`)
- 自动检测画面人物数量并在面板顶部展示「多人分组精修」卡片；
- 人物选择胶囊栏：点击即可在「全部人员」与单个「人物 1 / 人物 2 ...」之间秒级切换；
- 选定单人后：
  - 顶部显示该人物的推断角色，并提供下拉菜单供用户随时修正；
  - 一键应用角色专属预设；
  - 下方所有磨皮、五区和妆容调节器自动切换并绑定至该人物的独立配置。

---

## 验证与测试

- **单元测试覆盖** (`Tests/PhotoCoreTests/MultiPersonPortraitTests.swift`)：
  - `testDefaultProfilesForAllDemographicRoles`: 验证 5 大角色预设的强度与保护开关。
  - `testDemographicRoleEstimationFemaleAndMale`: 验证女性与男性面部胡须与唇色特征识别准确度。
  - `testDemographicRoleEstimationChild`: 验证儿童面部比例特征识别。
  - `testPerFaceMasksSeparation`: 验证多人面部语义蒙版完全非重叠与相互隔离。
  - `testMultiPersonSkinToneUnification`: 验证跨人脸皮肤亮度与色差拉平。
  - `testPerPersonPortraitRefinementPipeline`: 验证分人精修完整流程（女性施加腮红磨皮、男性保持胡须与无妆）。
  - `testRecipeVersion20Validation`: 验证 Recipe Version 20 严格版本门禁与中性字段穿透。
  - `testSelectiveSyncMultiPerson`: 验证分人配置的选择性参数复制与批量同步。
- **全量回归测试**：
  - 执行 `swift test -j 2`：**638 个测试全部通过（0 失败，耗时 222s）**。
- **打包与安装包结构校验**：
  - `bash Scripts/build_app.sh --universal`：成功生成包含 `x86_64` 与 `arm64` 双架构的 Universal 原生应用。
  - `python3 Scripts/verify_app.py build/PhotoAtelier.app`：通过 4 个动态库签名、55 个 XML 镜头配置文件与可移植路径校验。

# P2-O 实施计划：智能全身身形姿态美化与骨骼点塑形

## 1. 目标与背景

在商业人像与婚纱写真、全家福及商务全身照中，全身身形美化与体态姿态调整是摄影后期核心高频需求（对应 PixelCake 官方能力矩阵 §4.6 全身美型）。传统后期依赖修图师手动使用液化画笔反复推拉，极易导致背景门窗线条弯曲、左右不对称、肌肉比例失真等问题。

本里程碑交付 **P2-O 智能全身身形姿态美化与骨骼点塑形系统 (Smart Body Reshaping & Skeleton Posture Refinement)**：
1. **100% 离线原生检测**：基于 macOS 原生 `VNDetectHumanBodyPoseRequest` 实时检测人体 14 处关键骨骼关节（颈部、肩、肘、腕、躯干根部、髋、膝、踝），结合 `VNGeneratePersonSegmentationRequest` 人物抠图蒙版；
2. **解剖学形变场映射 (`WarpField`)**：在解剖学骨骼节点与躯干中轴线上构建平滑双侧高斯位移场，精准实现天鹅颈、直角肩、躯干纤细、细腰收腹、腿部拉长与瘦手臂；
3. **背景形变锚定保护 (Background Protection)**：利用人物分割蒙版与边缘渐变，将形变严格约束在人体轮廓及其过渡带内，防止背景竖线/地平线/影棚道具产生扭曲；
4. **多人独立分配与预设**：无缝对接 P2-M 多人画像体系（`PersonPortraitProfile.bodyReshapeOverride`），支持新娘/新郎/模特独立身形配置；
5. **配方版本控制**：升级配方版本门禁至 22（`Recipe.validateVersion()` 升级至 v22）。

---

## 2. 交付物与功能清单

### 2.1 数据模型扩展 (`Sources/PhotoCore/Models.swift`)
- 新增 `BodyReshapeSettings`：
  - `enabled: Bool`（主开关）
  - `swanNeck: Double`（0...1，默认 0：天鹅颈拉长与纤细）
  - `trapeziusContraction: Double`（0...1，默认 0：直角肩/斜方肌收敛平整）
  - `bodySlimming: Double`（0...1，默认 0：整体身形纤细与躯干内收）
  - `waistCinching: Double`（0...1，默认 0：细腰收腹/沙漏曲线）
  - `legLengthening: Double`（0...1，默认 0：腿部比例拉长与增高）
  - `armSlimming: Double`（0...1，默认 0：瘦手臂/大臂向内收敛）
  - `backgroundProtection: Double`（0...1，默认 0.8：背景形变锚定保护）
- 新增 `BodyReshapeReport`：
  - `applied: Bool`
  - `skeletonsDetected: Int`
  - `note: String?`
- `AdjustmentSettings` 增加 `bodyReshape: BodyReshapeSettings?`。
- `PersonPortraitProfile` 增加 `bodyReshapeOverride: BodyReshapeSettings?`。
- `ProcessingReport` 增加 `bodyReshape: BodyReshapeReport?`。
- `Recipe.validateVersion()` 门禁上限升至 22，非中性 `bodyReshape` 要求版本 22。

### 2.2 核心算法引擎 (`Sources/PhotoCore/BodyReshapeEngine.swift`)
- **骨骼点提取 (`HumanBodySkeleton`)**：
  - 封装 `VNDetectHumanBodyPoseRequest` 结果，提取 `neck`, `root`, `leftShoulder`, `rightShoulder`, `leftElbow`, `rightElbow`, `leftWrist`, `rightWrist`, `leftHip`, `rightHip`, `leftKnee`, `rightKnee`, `leftAnkle`, `rightAnkle`；
  - 置信度过滤与坐标系归一化对齐（Bottom-Left）。
- **解剖学向量位移场光栅化**：
  - 天鹅颈：颈部向两侧内收，颈中点向上适度平移；
  - 直角肩：斜方肌最高处下压收敛，肩峰轻微向外上平展；
  - 瘦身/细腰：躯干中轴线双侧相对向内水平位移，腰部形成向心收腹峰值；
  - 长腿增高：骨盆髋部以下纵向渐进递增拉伸，膝盖与踝关节平滑下拉；
  - 瘦手臂：肩-肘段外侧向内收敛。
- **背景保护与蒙版衰减**：
  - 提取或复用人物分割蒙版，对背景区域的位移场按 `backgroundProtection` 强度进行距离衰减或直接置零，保护背景直线不发生弯曲。
- **Core Image GPU 栅格渲染**：
  - 通过 `WarpField.apply(to:)` 在 GPU 上一次性完成几何重采样。

### 2.3 渲染管线集成 (`Sources/PhotoCore/PhotoEngine.swift`)
- 在几何液化阶段紧随面部液化之后（或作为统一身形几何管线）应用 `BodyReshapeEngine`；
- 支持单人全局配置及多人 `multiPerson` 分别重载；
- 记录 `BodyReshapeReport` 及必要警告提示。

### 2.4 参数同步与批量设置 (`AdjustmentSync.swift` & `SelectiveSyncSheet.swift`)
- `AdjustmentSyncOptions` 增加 `bodyReshape: Bool = true`；
- 选择性同步浮层增加「身形美化」勾选项。

### 2.5 UI 面板集成 (`PortraitRetouchPanel.swift` & `AppModel.swift`)
- `PortraitRetouchPanel.swift` 新增「全身身形与姿态塑形」功能区；
- 包含天鹅颈、直角肩、整体瘦身、细腰、长腿、瘦手臂、背景保护等滑杆及一键重置；
- 支持多人画像切换联动。

### 2.6 测试与质量保证
- 新增 `Tests/PhotoCoreTests/BodyReshapeTests.swift`；
- 升级历史测试中的未来版本检测断言（由 22 升至 23）；
- 全量单元测试回归与 Universal 架构编译验证。

---

## 3. 验收标准（可勾选）

- [ ] `BodyReshapeSettings` 正确编解码，中性设置（全部为 0 或 `enabled == false`）不改变任何图像像素；
- [ ] 能在合成测试人体姿态图上正确识别骨骼关节并生成平滑连续的 `WarpField`；
- [ ] 天鹅颈、直角肩、整体瘦身、细腰、长腿、瘦手臂滑杆正向调节均产生正确的解剖方位位移；
- [ ] 开启背景保护（`backgroundProtection > 0`）时，背景非人体区域的位移显著衰减，避免门窗框变形；
- [ ] 非中性 `bodyReshape` 配方受到 Recipe Version 22 门禁保护；
- [ ] `AdjustmentSync` 与选择性同步面板支持身形参数同步与合并；
- [ ] 多人场景下支持按人物或角色（新郎/新娘）独立配置身形参数；
- [ ] `swift test -j 2` 全量测试通过且 0 失败；
- [ ] Universal macOS 应用构建通过并通过 `verify_app.py` 完整性校验；
- [ ] Git 流程严格遵循 Rule 3（基线 `fa4f3ec`、分支 `feat/p2o-body-reshaping-posture`、`--no-ff` 合并、分支删除）。

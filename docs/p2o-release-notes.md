# P2-O 发布说明：智能全身身形姿态美化与骨骼点塑形 (Smart Body Reshaping & Skeleton Posture Refinement)

## 概述

在商业人像与婚纱写真、全家福及商务全身照中，身形美化与体态姿态调整是摄影后期极其重要的核心高频需求（对齐 PixelCake 官方能力矩阵 §4.6 全身美型）。传统后期依赖修图师手动使用液化画笔反复推拉，极易导致背景门窗线条弯曲、左右不对称、肌肉比例失真等问题。

本次更新交付 **P2-O 智能全身身形姿态美化与骨骼点塑形系统 (Smart Body Reshaping & Skeleton Posture Refinement)**：
1. **100% 离线原生检测**：基于 macOS 原生 `VNDetectHumanBodyPoseRequest` 实时检测人体 14 处关键骨骼关节（颈部、肩、肘、腕、躯干根部、髋、膝、踝）；
2. **解剖学形变场映射 (`WarpField`)**：在解剖学骨骼节点与躯干中轴线上构建平滑双侧高斯位移场，精准实现天鹅颈、直角肩、躯干纤细、细腰收腹、腿部拉长与瘦手臂；
3. **背景形变锚定保护 (Background Protection)**：利用骨骼胶囊包络柱与边缘渐变，将形变严格约束在人体轮廓及其过渡带内，防止背景竖线/门窗框/地平线/影棚道具产生扭曲；
4. **多人独立分配与预设**：无缝对接 P2-M 多人画像体系（`PersonPortraitProfile.bodyReshapeOverride`），支持新娘/新郎/模特独立身形配置；
5. **参数选择性复制与批量同步**：完整接入 `SelectiveSyncSheet` 与 `AdjustmentSyncEngine`；
6. **配方版本升级至 22**：非中性 `bodyReshape` 字段受 Recipe Version 22 门禁保护；历史配方 100% 保持无损向下兼容。

---

## 核心技术与数据结构变更

### 1. 数据模型 (`Sources/PhotoCore/Models.swift`)
- **`BodyReshapeSettings`**：
  - `enabled: Bool`：主开关
  - `swanNeck: Double` (0...1)：天鹅颈（收细颈部横向宽度并微拉伸）
  - `trapeziusContraction: Double` (0...1)：直角肩（下压收敛斜方肌鼓包，平整肩峰）
  - `bodySlimming: Double` (0...1)：整体身形纤细（沿脊柱中轴线平滑内收躯干轮廓）
  - `waistCinching: Double` (0...1)：细腰收腹（腰部黄金分割点向心收拢，塑造优雅沙漏身材）
  - `legLengthening: Double` (0...1)：长腿增高（从骨盆髋部以下渐进向下延伸下肢比例）
  - `armSlimming: Double` (0...1)：瘦手臂（向肱骨中轴收拢大臂外侧宽度，消除蝴蝶袖）
  - `backgroundProtection: Double` (0...1，默认 0.8)：背景形变锚定保护系数
- **`BodyReshapeReport`**：记录执行状态、检测到的骨骼数量与调试说明。
- **`AdjustmentSettings` 扩充**：`public var bodyReshape: BodyReshapeSettings? = nil`。
- **`PersonPortraitProfile` 扩充**：`public var bodyReshapeOverride: BodyReshapeSettings? = nil`。
- **`ProcessingReport` 扩充**：`public var bodyReshape: BodyReshapeReport? = nil`。
- **`Recipe.validateVersion()`**：支持版本 22，非中性 `bodyReshape` 要求配方版本 22。

### 2. 核心算法引擎 (`Sources/PhotoCore/BodyReshapeEngine.swift`)
- **`HumanBodySkeleton`**：封装 Vision 人体姿态关节关键点，提供解剖部位坐标与置信度过滤。
- **`BodyReshapeEngine`**：
  - `detectSkeletons(in:)`：通过原生 Vision 异步检测图像中的全部人体骨架；
  - `generateWarpField(...)`：根据解剖骨骼点计算天鹅颈、直角肩、躯干内收、细腰、长腿、瘦手臂的高斯位移向量，并在 GPU 上结合 `WarpField` 生成平滑拉伸场；
  - `attenuateOutsideEnvelope(...)`：在人体骨骼胶囊包络外平滑衰减位移场，实现严格的背景保护；
  - `apply(...)`：执行端到端处理，中性或未检测到人体时零开销跳过并保持原图无损。

### 3. 主引擎管线集成 (`Sources/PhotoCore/PhotoEngine.swift`)
- 在主渲染管线中执行全身身形美化；
- 完整支持多人独立精修（`multiPerson`），允许对不同被摄者设置不同身形参数；
- 统一门禁检查与配方版本计算支持版本 22。

### 4. 批量同步与 UI 交互 (`Sources/PhotoCore/AdjustmentSync.swift` & `Sources/PhotoAtelier/`)
- `AdjustmentSyncOptions` 增加 `bodyReshape: Bool = true`；
- `SelectiveSyncSheet.swift` 增加身形微调复选框；
- `AppModel.swift` 增加身形参数绑定、重置与角色联动；
- `PortraitRetouchPanel.swift` 新增「智能全身身形与姿态微调」控制面板。

---

## 验证与测试

1. **单元测试 (`Tests/PhotoCoreTests/BodyReshapeTests.swift`)**：
   - 测试中性配置无损返回；
   - 测试各项参数数值边界校验；
   - 测试骨骼点 JSON 编解码往返；
   - 测试天鹅颈、直角肩、瘦身、细腰、长腿、瘦手臂形变场向量方向正确性；
   - 测试背景保护锚定衰减；
   - 测试选择性同步合并逻辑；
   - 测试配方版本 22 门禁保护；
2. **全量回归测试**：
   - 历史测试前向版本断言升级至 23；
   - 全量测试套件通过（655+ passed, 0 failures）。

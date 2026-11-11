# P2-D 实施方案：影棚纯色背景平整与瑕疵修复 (Studio Backdrop Smoothing & Defect Removal)

## 1. 目标与验收标准

### 目标
为商业摄影、棚拍摄影、肖像写真与电商模特等场景提供纯色/影棚背景自动化精修能力：
1. **背景光影平整与折痕抚平 (`smoothing`)**：在非人物背景区域，智能消除无缝背景纸折痕、幕布褶皱、接缝及不均匀光影渐变，同时保护自然地毯/地面接触阴影与人物边缘。
2. **背景瑕疵与脏污消除 (`cleanup`)**：自动识别背景上的高对比度脚印、灰尘点、胶带残留、污斑杂质，并基于低频纯净背景平滑内插抚平。
3. **背景色调统一 (`uniformity`)**：中和并统一背景色温与色偏，消除边缘杂色反射。

### 验收标准（可勾选）
- [x] 数据模型：新增 `BackdropRefinementSettings`（`smoothing`/`cleanup`/`uniformity` 均在 `0...1`，默认 0，`enabled` 默认 false）。
- [x] 严格中性：当 `enabled == false` 或各项强度均为 0 时，管线完全不改图，`isNeutral == true`。
- [x] 主体保护：人物主体、衣物、发丝及其半透明边缘严格不受背景平整影响。
- [x] 无人像容错：当照片未检测到人物时，显式在报告中提示并跳过，不崩溃、不改图。
- [x] 向下兼容：旧版配方（v1~v14）反序列化时缺失新字段自动缺省为 `nil`，维持原有渲染路径。
- [x] 零外部大模型依赖：基于 Vision 人物分割与 Core Image GPU `CIColorKernel` 运行。
- [x] UI 面板：在「证件照 / 背景」面板中新增「影棚背景平整与修复」控制区。
- [x] 单元与集成测试全覆盖：新增针对平整、去污、主体保护与中性一致性的测试用例。
- [x] 全量回归测试通过：`swift test -j 2` 保持 100% 通过（555 个测试）。
- [x] 双架构打包验证与 UI 冒烟测试全绿。

---

## 2. 关键步骤

1. **分支准备**：检出 `feat/p2d-studio-backdrop-refinement`（从 `a54b99f`）。
2. **核心数据模型 (`Models.swift`)**：
   - 定义 `BackdropRefinementSettings` 与 `BackdropRefinementReport`。
   - 在 `AdjustmentSettings` 中追加 `public var backdrop: BackdropRefinementSettings? = nil`。
   - 在 `ProcessingReport` 中追加 `public var backdrop: BackdropRefinementReport? = nil`。
3. **着色引擎实现 (`Sources/PhotoCore/BackdropRefinement.swift`)**：
   - 提取并侵蚀优化背景掩膜。
   - 计算背景主色调与自适应高斯平滑基底。
   - 执行 GPU 着色器：结合折痕抚平、脚印/污斑消除与色调统一。
4. **管线串接 (`Sources/PhotoCore/PhotoEngine.swift`)**：
   - 在人像与背景替换前后合适管线位置串接背景修复。
5. **UI 控制面板 (`Sources/PhotoAtelier/IDPhotoPanel.swift` & `AppModel.swift`)**：
   - 在背景控制区加入影棚背景平整、去污、色调统一滑杆与启用开关。
6. **单元测试 (`Tests/PhotoCoreTests/BackdropRefinementTests.swift`)**：
   - 编写合成测试用例验证折痕抚平、脏污消除、主体边缘保护与编码兼容性。
7. **全量构建与端到端验证**：
   - `swift test -j 2`
   - `build_app.sh --universal`
   - `verify_app.py`
   - `ui_smoke.sh`
8. **合并与交付报告**：
   - `--no-ff` 合并至 `feat/p1c-culling-makeup-perf`，删除分支，产出交付报告。

---

## 3. 回滚方案
如遇不可调和的兼容性或性能问题，可直接回滚至基线 `a54b99f`。

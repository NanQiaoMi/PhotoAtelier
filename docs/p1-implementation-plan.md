# P1 实施计划（第一批）：调色工具扩展 / 面部液化美型 / 水印导出

**制定日期**：2026-11-04
**目标分支**：`feat/p1-color-beauty`（从 P0 验收提交 `2af5ccd` 切出；`main` @ `837ec59` 为祖先）
**基线验证**：P0 分支最终验收全绿——`make check` 326 tests / 0 failures、`build_app.sh` exit 0、重建包 `ui_smoke.sh` 6 页签 / 8 截图 PASS、最终树 benchmark PASS（证据见 [P0 交付说明](p0-release-notes.md)）
**上位文档**：[差距分析](pixelcake-gap-analysis.md)｜[P0 计划](p0-implementation-plan.md)

---

## 1. 目标与范围

本批 P1 只做三块**用户价值高、可在本地实现**的能力，继续不引入第三方运行时依赖、不联网、不读取用户私人照片：

| 编号 | 功能 | 补齐的差距 |
|---|---|---|
| P1-1 | 调色工具扩展核心：HSL 8 色相、RGB/亮度曲线、颜色分级（三色轮）、镜头暗角 + 横向色差 | 调色工具数量与专业度（像素蛋糕 100+ 工具） |
| P1-2 | 面部液化/美型核心：7 种脸型预设、瘦脸/大眼/鼻/嘴/下巴、手动液化画笔、背景直线保护 | 人像美型（当前完全缺失） |
| P1-3 | 水印导出核心：文字/图片水印、位置/透明度/缩放/旋转、双版本输出 | 交付能力（当前无） |
| P1-4 | 质量适配：benchmark/ui_smoke 适配新 UI 与新能力，最终验收脚本 | 工程可验证性 |
| P1-5 | 调色集成：配方 v11 门禁、管线接入、调色页签/面板、测试 | 功能可用性 |
| P1-6 | 液化集成：配方 v11、管线接入、人像页签液化区、画布画笔交互、撤销集成、测试 | 功能可用性 |
| P1-7 | 水印集成：导出设置/面板、批处理双版本、清单记录、测试 | 功能可用性 |

**非目标（本批不做）**：证件照/换背景、修复画笔/仿制图章、妆容、头发/衣物/天空/宠物、本地客户交付页、AI 挑图、性能优化（并行/Metal 重写）、云协作/多端、生成式 AI。这些留给后续批次。

---

## 2. 基线与提交策略

- 基线：`feat/p0-gap-closure` @ `2af5ccd`（已通过 P0 全量验收）。
- 执行分支：`feat/p1-color-beauty`；不直接修改 `main`；不主动 fetch/pull；不推送远端。
- 提交信息 `<type>(<scope>): <summary>`；每波通过 Lead gate 后提交；显式路径暂存，禁止 `git add -A`。
- 用户已有改动保持原样；产物写 `artifacts/`（gitignored）。

---

## 3. 完成定义（Goal DoD）

1. P1-1…P1-7 全部经独立 reviewer 批准、Lead gate 通过并提交到 `feat/p1-color-beauty`。
2. `make check` 全绿（含新增测试）；`bash Scripts/build_app.sh` 成功并通过包校验。
3. 新功能均有：参数模型（Codable）、配方 v11 兼容策略、测试覆盖、应用级可运行证据。
4. README 与 `docs/p1-release-notes.md` 更新；算法边界与未验证项如实标注。
5. 重建包 `ui_smoke.sh` 通过（新页签/面板）；最终树 benchmark 通过。
6. 不夸大：合成图测试不描述为真实画质验收；真实照片审美评审单独标注「未执行/待授权样片」。

---

## 4. 处理管线与配方版本

**新管线顺序（v11）**：

```
全局几何（旋转/透视/自动水平/Lensfun 畸变）
→ 液化/美型（几何变形，位移场）
→ 基础影调（曝光/WB/五区 EV/对比/饱和/高光/阴影）
→ 调色工具（曲线 → HSL → 颜色分级）
→ 镜头效果（暗角/横向色差）
→ 人像修复 v1（祛瑕疵/中性灰高低频/牙齿/眼白/肤色统一）
→ AI 追色
→ 局部蒙版/细节
→ LUT
→ 输出色域映射
```

- 液化在基础影调之前：它改变几何，后续所有内容分析（人像蒙版、局部蒙版归一化坐标）都基于变形后的图像；配方中蒙版坐标按变形后图像归一化，不跟踪液化参数变化（改液化后需复核蒙版，文档标注）。
- 配方版本 **v11**：`colorTools`、`liquify`、`watermark` 等新字段要求 v11；旧 v1–v10 配方缺字段保持原像素路径；非中性新字段出现在旧版本配方中由 `validateVersion` 拒绝，不静默降级。保存含新字段的配方时自动升级 v11。
- 批量清单记录逐张实际应用的调色/液化/水印状态。

---

## 5. 工作分解与验收

### P1-1 调色工具扩展核心（新文件，无既有实现修改）

- **范围**：`Sources/PhotoCore/ColorTools.swift`（新）、`ColorCurves.swift`（新）、`ColorGrading.swift`（新）、`LensEffects.swift`（新）、`Tests/PhotoCoreTests/ColorToolsTests.swift`（新）。
- **内容**：
  1. `HSLSettings`：8 色相带（红/橙/黄/绿/青/蓝/紫/洋红），每带 hueShift(−180…180°)、saturation(−1…1)、luminance(−1…1)；色相带平滑权重（余弦/高斯），中性色保护（低彩度不染），输出限幅。在 OKLab/OKLCh 空间实现（复用现有 OutputGamut 思路）。
  2. `CurveSettings`：RGB 三通道 + 亮度曲线；控制点 2–16 个，单调三次插值（PCHIP）保证无过冲；CPU 生成 256/1024 LUT；应用在显示编码 sRGB（线性→编码→曲线→解码），文档明确语义。
  3. `ColorGradingSettings`：阴影/中间调/高光三色轮（hue/sat/lum）+ 全局偏色 + balance；按亮度平滑权重混合；中性保护与限幅。
  4. `LensEffectsSettings`：暗角（amount/midpoint/feather/roundness）+ 横向色差（红/蓝径向缩放，幅度小）；CIWarpKernel/CIColorKernel 实现。
  5. 提供纯函数/引擎 API，便于单测与集成。
- **测试**：恒等（全中性=像素不变）；曲线端点/单调/无过冲；HSL 带选择性（只动目标色相带、邻近带平滑）；中性保护；分级中性恒等；暗角径向对称、中心不变；CA 只移通道不移几何；确定性；NaN/越界防护。
- **DoD**：只新增 5 个文件；`swift build` exit 0；`swift test --filter ColorToolsTests` 全绿；报告含命令/退出码/边界。

### P1-2 面部液化/美型核心（新文件）

- **范围**：`Sources/PhotoCore/LiquifyWarp.swift`（新）、`FaceReshape.swift`（新）、`Tests/PhotoCoreTests/LiquifyWarpTests.swift`（新）。
- **内容**：
  1. `WarpField`：低分辨率位移网格（如 128×128 float2）+ 控制点/笔迹光栅化（高斯/余弦衰减）+ 幅度限幅 + 平滑；提供 `displacementMap` 与 `apply(image:)`（CIWarpKernel 采样位移图）。
  2. `FaceReshapeSettings`：7 种脸型预设（经典/幼态/英气/少年/圆脸/长脸/方脸，映射到轮廓/眼/鼻/嘴/下巴参数）+ 瘦脸/小脸/大眼/鼻翼/嘴唇/下巴滑杆；由 `FaceSemanticAnalysis` 地标计算位移场（轮廓内收、眼睛外扩、鼻子收窄、嘴唇宽度、下巴长度），幅度上限。
  3. 手动液化笔迹：push/rebuild/smooth 三种模式（点列 + 半径 + 强度），可叠加到位移场；重建/平滑用于局部回退。
  4. 背景直线保护：位移幅度上限 + 场平滑 + 边界衰减（不能保证所有直线，但限制明显弯曲）。
- **测试**：恒等位移=像素不变；位移有界；脸型参数方向（瘦脸轮廓向内、大眼向外）；手动笔迹局部影响范围；网格/直线偏移度量阈值；确定性；NaN 防护。
- **DoD**：只新增 3 个文件；`swift build` exit 0；`swift test --filter LiquifyWarpTests` 全绿；报告含命令/退出码/边界（不是商业级美型）。

### P1-3 水印渲染核心（新文件）

- **范围**：`Sources/PhotoCore/WatermarkRenderer.swift`（新）、`Tests/PhotoCoreTests/WatermarkTests.swift`（新）。
- **内容**：`WatermarkSettings`（文字/图片二选一、位置 9 宫格+自定义偏移、透明度、缩放、旋转、可选阴影/描边）；CoreText/NSAttributedString → CGImage → CIImage 叠加；图片水印支持 PNG/JPEG 路径与透明度；输出尺寸自适应；提供 `render(on:canvasExtent:)` 与「双版本」辅助（带/不带水印）。
- **测试**：位置/缩放/透明度像素断言；文字水印非空且不越界；图片水印 alpha 正确；双版本差异；空文字/缺失图片明确报错；确定性。
- **DoD**：只新增 2 个文件；`swift build` exit 0；`swift test --filter WatermarkTests` 全绿；报告含命令/退出码/边界（字体依赖系统、非排版工具）。

### P1-4 质量适配（依赖 P1-5/P1-6/P1-7）

- **范围**：`Scripts/benchmark.swift`、`Scripts/ui_smoke.sh`。
- **内容**：ui_smoke 适配新页签/面板（调色页签、人像液化区、导出水印区），动态枚举页签、导入合成夹具、截图；benchmark 增加调色/液化/水印耗时记录；脚本边界注释更新；最终验收命令与证据路径写入报告。
- **DoD**：重建包上 `bash Scripts/ui_smoke.sh` exit 0（页签数/截图符合新 UI）；benchmark 编译/运行 exit 0；报告含命令/退出码/证据路径；不修改应用源码。

### P1-5 调色集成（依赖 P1-1）

- **范围**：`Sources/PhotoCore/Models.swift`、`PhotoEngine.swift`、`Sources/PhotoAtelier/AppModel.swift`、`ContentView.swift`、`ColorToolsPanel.swift`（新）、`Tests/PhotoCoreTests/ColorCompatibilityTests.swift`、`EngineTests.swift`。
- **内容**：`AdjustmentSettings.colorTools`（HSLSettings/CurveSettings/ColorGradingSettings/LensEffectsSettings）；Recipe v11 门禁与自动升级；PhotoEngine 管线接入（顺序见 §4）；右栏新增「调色」页签（或基础页折叠区，需与现有 6 页签布局协调）；AppModel 预览 token；测试：中性恒等、v10 拒绝非中性新字段、v11 往返、旧配方像素路径不变、管线顺序（调色先于 LUT、后于基础）。
- **DoD**：build + 定向测试全绿；UI 面板快照/应用自检；不改 P1-1 之外核心算法文件语义。

### P1-6 液化集成（依赖 P1-2、P1-5）

- **范围**：`Sources/PhotoCore/Models.swift`、`PhotoEngine.swift`、`Sources/PhotoAtelier/AppModel.swift`、`ContentView.swift`、`PortraitRetouchPanel.swift`、`Tests/PhotoCoreTests/ColorCompatibilityTests.swift`、`PortraitRetouchTests.swift`。
- **内容**：`AdjustmentSettings.liquify`（FaceReshapeSettings + 手动笔迹列表）；Recipe v11 门禁；PhotoEngine 在全局几何后应用位移场；「人像」页签新增液化区（脸型预设、滑杆、手动液化画笔开关/半径/强度/模式），画布支持笔迹绘制（复用现有 mask 交互基础设施）；撤销/重做接入；批量逐张应用（人脸地标逐图检测）；测试：配方往返、门禁、管线位置、恒等、批量记录。
- **DoD**：build + 定向测试 + 应用自检（快照）；笔迹交互未自动化需如实标注。

### P1-7 水印集成（依赖 P1-3、P1-6）

- **范围**：`Sources/PhotoCore/Models.swift`、`PhotoIO.swift`、`BatchProcessor.swift`、`Sources/PhotoAtelier/ContentView.swift`、`Tests/PhotoCoreTests/IOTests.swift`、`BatchTests.swift`、`ColorCompatibilityTests.swift`。
- **内容**：`ExportSettings.watermark`（WatermarkSettings）；Recipe v11 门禁；PhotoExporter 在编码前叠加；BatchProcessor 支持「同时导出带/不带水印两版」与清单记录；导出面板新增水印区（文字/图片、位置、透明度、缩放、旋转、双版本开关）；测试：双版本文件存在且差异、位置/透明度、原子写入/不覆盖回归、v10 拒绝。
- **DoD**：build + 定向测试全绿；导出面板快照/应用自检；不引入新依赖。

---

## 6. 波次与依赖

| 波次 | 工作项 | 说明 |
|---|---|---|
| A | P1-1、P1-2、P1-3 | 三个核心只新增文件，写范围互斥 |
| B | P1-5（依赖 P1-1） | 调色集成（共享 Models/PhotoEngine/ContentView） |
| C | P1-6（依赖 P1-2、P1-5） | 液化集成（共享文件，串行） |
| D | P1-7（依赖 P1-3、P1-6） | 水印集成（共享文件，串行） |
| E | P1-4（依赖 P1-5/P1-6/P1-7） | 质量适配与最终验收准备 |
| F | Lead 最终验收 | 全量 make check、build_app、ui_smoke、benchmark、文档、提交、gate |

并行约束：同一波次写范围不得重叠；worker 只跑 `swift build` 与本项定向 `swift test --filter`；全量测试由 Lead 在每波结束执行。

---

## 7. 质量门禁与证据

- 每个工作项：`swift build` exit 0；定向测试 exit 0；报告含真实命令、退出码、引用输出、未验证项；独立 reviewer 批准后才能进入下一波。
- Lead gate：每波结束在稳定树上跑全量 `make check`；失败不得带红合并。
- 最终验收：`make check`、`bash Scripts/build_app.sh`、`codesign --verify --deep --strict`、`python3 Scripts/verify_app.py`、重建包 `bash Scripts/ui_smoke.sh`、最终树 benchmark；全部退出 0 才可完成 Goal。
- 文档：README 更新（调色页签/液化/水印/配方 v11/限制），新增 `docs/p1-release-notes.md`；`docs/p1-implementation-plan.md` 状态表更新。

---

## 8. 风险与缓解

| 风险 | 影响 | 缓解 |
|---|---|---|
| HSL/曲线/分级色彩学实现偏差 | 偏色/断层 | 中性恒等、单调、带选择性、限幅测试；真实照片评审留待授权样片 |
| 液化导致背景弯曲/面部畸变 | 坏片 | 位移上限、场平滑、边界衰减、手动回退（重建/平滑）、恒等测试；明确定位为启发式 v1 |
| 液化改变几何导致蒙版错位 | 既有蒙版失效 | 文档标注「改液化后需复核蒙版」；管线顺序固定；配方 v11 门禁 |
| 水印字体/图片依赖系统 | 跨机差异 | 只用系统字体与本地图片；缺失文件显式报错；测试合成图 |
| 共享文件串行集成耗时 | 进度 | 波次串行设计；核心与集成分离；Lead 每波 gate |
| 新页签/面板破坏既有 UI | 回归 | ui_smoke 适配 + 快照 + 撤销集成；每波应用自检 |
| 配方 v11 兼容破坏 | 旧配方漂移 | v11 门禁 + 旧配方像素回归测试；缺字段保持旧路径 |

---

## 9. 后续（本批之外）

- P1 第二批：证件照/换背景、修复画笔/仿制图章、妆容、本地客户交付页、AI 挑图、性能优化。
- P2：头发/衣物/宠物/天空、联机拍摄、RAW 引擎/AI 降噪、生成式、多端/云。
- 真实照片审美验收：需用户提供授权样片集后单独执行。

---

## 10. 执行状态（待更新）

| 工作项 | 状态 | 说明 |
|---|---|---|
| P1-1 调色核心 | pending | |
| P1-2 液化核心 | pending | |
| P1-3 水印核心 | pending | |
| P1-4 质量适配 | pending | |
| P1-5 调色集成 | pending | |
| P1-6 液化集成 | pending | |
| P1-7 水印集成 | pending | |

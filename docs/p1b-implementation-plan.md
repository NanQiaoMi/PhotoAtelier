# P1-B 实施计划：证件照/换背景 / 修复画笔 / 本地客户交付页

**制定日期**：2026-11-04
**目标分支**：`feat/p1b-retouch-delivery`（从 P1 验收提交 `2ea97cb` 切出；`main` @ `837ec59` 为祖先）
**基线验证**：P1 分支最终验收——`make check` 398 tests / 0 failures、`build_app.sh` exit 0、重建包 ui_smoke 7 页签/12 截图 PASS（含一次 AX 瞬时错误，已记录）、benchmark PASS（见 [P1 交付说明](p1-release-notes.md)）
**上位文档**：[差距分析](pixelcake-gap-analysis.md)｜[P1 计划](p1-implementation-plan.md)

---

## 1. 目标与范围

本批继续补齐差距分析中的 P1 剩余高价值能力，仍坚持本地、离线、不读取用户私人照片、不引入第三方运行时依赖：

| 编号 | 功能 | 补齐的差距 |
|---|---|---|
| B1 | 证件照/换背景核心：人物抠图边缘细化、纯色/图片背景替换、阴影合成、证件照尺寸/裁剪预设、打印排版网格 | 像素蛋糕「纯净背景再现 / 证件照换背景换衣/排版」 |
| B2 | 修复画笔/仿制图章核心：heal（修补）/clone（仿制）笔迹、羽化、来源偏移、笔迹模型 | 像素蛋糕手动污点修复/修补/仿制图章 |
| B3 | 本地客户交付页核心：静态 HTML 相册（缩略图+大图预览）+ 接触表 PDF，完全离线、隐私元数据剥离 | 像素蛋糕「选片/交付」的本地替代（不做云） |
| B4 | 证件照/换背景集成：配方 v12、管线接入、证件照页签/面板、尺寸与排版 UI、批量 | 功能可用性 |
| B5 | 修复画笔集成：配方 v12、管线接入、画布笔迹、撤销、批量 | 功能可用性 |
| B6 | 交付页集成：导出流程入口、设置、批量清单记录、隐私校验 | 功能可用性 |
| B7 | 质量加固与适配：ui_smoke 重试/证据绑定（app mtime+sha256）、新 UI 区段、benchmark 新阶段 | 工程可验证性 + 修复 P1 遗留 flakiness |
| S1 | P1 遗留文档修正：`WarpStroke` 注释「短边比例」→ 逐轴椭圆语义 | 文档一致性 |

**非目标（本批不做）**：妆容、头发/衣物/宠物/天空、AI 挑图、云协作/多端、生成式 AI、RAW 引擎、性能深度优化（并行/Metal 重写）、商业级人像模型。这些留给后续批次。

---

## 2. 基线与提交策略

- 基线：`feat/p1-color-beauty` @ `2ea97cb`（P1 全量验收通过）。
- 执行分支：`feat/p1b-retouch-delivery`；不直接修改 `main`；不主动 fetch/pull；不推送远端。
- 提交信息 `<type>(<scope>): <summary>`；每波通过 Lead gate 后提交；显式路径暂存，禁止 `git add -A`。
- 用户已有改动保持原样；产物写 `artifacts/`（gitignored）。

---

## 3. 完成定义（Goal DoD）

1. B1–B7 与 S1 全部经独立 reviewer 批准、Lead gate 通过并提交到 `feat/p1b-retouch-delivery`。
2. `make check` 全绿（含新增测试）；`bash Scripts/build_app.sh` 成功并通过包校验。
3. 新功能均有：参数模型（Codable）、配方 v12 兼容策略、测试覆盖、应用级可运行证据。
4. README 与 `docs/p1b-release-notes.md` 更新；算法边界与未验证项如实标注。
5. 重建包 `ui_smoke.sh` 通过（新 UI 区段），且脚本具备失败重试与 app 证据绑定；最终树 benchmark 通过。
6. 不夸大：合成图测试不描述为真实画质验收；真实照片审美评审单独标注「未执行/待授权样片」。
7. **UI 冒烟打扰控制**：ui_smoke 会启动应用窗口；本批只在每波末尾/最终验收各跑一次，避免反复弹窗打扰用户。

---

## 4. 处理管线与配方版本

**新管线顺序（v12）**：

```
基础影调（曝光/WB/五区 EV/对比/饱和/高光/阴影）
→ 全局几何（旋转/透视/自动水平/Lensfun 畸变）
→ 液化/美型
→ 调色工具（曲线 → HSL → 颜色分级）
→ 镜头效果（暗角/横向色差）
→ 修复画笔/仿制图章（手动像素修补）
→ 人像修复 v1
→ AI 追色
→ 背景替换/证件照（人物抠图 + 背景 + 阴影；几何裁剪）
→ 局部蒙版/细节
→ LUT
→ 输出色域映射
→ 导出（水印/缩放/模板/交付页）
```

- 修复画笔在人像修复之前：手动修补后的像素再参与人像测量与蒙版。
- 背景替换在追色之后、局部蒙版之前：局部蒙版坐标不变（几何未变），但背景颜色已是替换后的值；文档标注「替换背景后需复核依赖背景颜色的局部调整」。
- 配方版本 **v12**：新增 `certificatePhoto`（背景/尺寸/裁剪/阴影）、`repairBrush`（笔迹）等字段要求 v12；旧 v1–v11 配方缺字段保持原像素路径；非中性新字段出现在旧版本配方中由 `validateVersion` 拒绝，不静默降级；保存含新字段的配方自动升级 v12。
- 交付页设置（标题/列数/是否含水印）存入 `ExportSettings`（可选字段，非中性要求 v12）；交付页生成结果写入批量清单。
- 批量清单 schema 继续演进（v3 → v4），记录逐张背景替换/修复画笔/交付页状态。

---

## 5. 工作分解与验收

### B1 证件照/换背景核心（新文件）

- **范围**：`Sources/PhotoCore/PersonMatting.swift`（新）、`BackgroundReplacement.swift`（新）、`IDPhotoLayout.swift`（新）、`Tests/PhotoCoreTests/PersonMattingTests.swift`（新）、`IDPhotoLayoutTests.swift`（新）。
- **内容**：
  1. 人物 matting：Vision `VNGeneratePersonSegmentationRequest` + 边缘细化（引导滤波/羽化）+ alpha 置信；无人物时显式返回空并报错。
  2. 背景替换：纯色（红/蓝/白/灰/自定义 HEX）或本地图片背景；前景/背景边界羽化、去色边（decontamination）；可选阴影合成（椭圆/软阴影，参数可调）。
  3. 证件照：尺寸预设（一寸 25×35mm、二寸 35×49mm、小一寸 22×32mm、大一寸 33×48mm、小二寸 35×45mm，300 DPI 对应像素），头部高度/水平居中的裁剪计算（基于人脸框），背景色预设。
  4. 打印排版：纸张尺寸（5 寸/6 寸/A4）、DPI、行列数、间距、边距，生成排版几何（供集成渲染 PDF/JPEG）。
  5. 纯函数 API + 测试夹具（合成人形/色块/人脸框），不依赖 Vision 检测即可单测核心几何与合成。
- **测试**：背景纯色/图片替换像素断言、边界羽化、阴影存在、尺寸/DPI 像素计算、裁剪头部比例、排版网格几何、无人物显式错误、确定性。
- **DoD**：只新增 5 个文件；`swift build` exit 0；`swift test --filter PersonMattingTests` / `IDPhotoLayoutTests` 全绿；报告含命令/退出码/边界。

### B2 修复画笔/仿制图章核心（新文件）

- **范围**：`Sources/PhotoCore/RepairBrush.swift`（新）、`Tests/PhotoCoreTests/RepairBrushTests.swift`（新）。
- **内容**：`RepairStroke`（点列、半径、羽化、强度、模式 heal|clone、clone 来源偏移、id）；heal 用邻域纹理修补（频率分离/局部 patch 中值，通用非皮肤专用）；clone 用来源区域偏移采样 + 羽化；笔迹光栅化为 alpha 掩膜并合成；提供 `apply(to:strokes:)` 纯 API；笔迹可撤销（数据层）。
- **测试**：heal 后缺陷对比下降、clone 复制来源区域、笔迹边界不越界、羽化平滑、空笔迹恒等、确定性、NaN 防护。
- **DoD**：只新增 2 个文件；build + `--filter RepairBrushTests` 全绿；报告含命令/退出码/边界。

### B3 本地客户交付页核心（新文件）

- **范围**：`Sources/PhotoCore/DeliveryGallery.swift`（新）、`Tests/PhotoCoreTests/DeliveryGalleryTests.swift`（新）。
- **内容**：`DeliverySettings`（标题、列数、缩略图尺寸、是否带水印、是否生成接触表 PDF）；生成静态 HTML（内嵌 CSS、相对路径缩略图/大图、无外部链接/无网络请求）；缩略图与预览图由调用方提供（渲染层生成）；接触表 PDF 用 CoreGraphics 绘制网格（纸张/边距/标题）；隐私：不写 GPS/相机序列号、剥离元数据。
- **测试**：HTML 文件生成/结构/图片数量/无 http(s) 外链；PDF 页数/尺寸；确定性；空相册明确报错；隐私字符串检查。
- **DoD**：只新增 2 个文件；build + `--filter DeliveryGalleryTests` 全绿；报告含命令/退出码/边界（非云、非选片系统）。

### S1 P1 文档修正（独立小项）

- **范围**：`Sources/PhotoCore/LiquifyWarp.swift`（仅注释）。
- **内容**：`WarpStroke.radius` 注释从「短边比例」改为「按宽/高分别解释的椭圆半径（radiusX=radius×宽，radiusY=radius×高）」，与 P1-6 overlay/实现一致。
- **DoD**：仅注释改动；`swift build` exit 0；报告含命令/退出码。

### B4 证件照/换背景集成（依赖 B1）

- **范围**：`Sources/PhotoCore/Models.swift`、`PhotoEngine.swift`、`Sources/PhotoAtelier/AppModel.swift`、`ContentView.swift`、`IDPhotoPanel.swift`（新）、`Tests/PhotoCoreTests/ColorCompatibilityTests.swift`、`EngineTests.swift`。
- **内容**：`AdjustmentSettings.certificatePhoto`（背景色/图片、阴影、尺寸预设、裁剪偏移/缩放、排版）接入 Models + Recipe v12 门禁/保存自动升级；PhotoEngine 在追色之后、局部之前应用背景替换与裁剪（裁剪改变画布尺寸需重算 extent/蒙版坐标，文档标注）；右栏新增「证件照」页签（或人像页区段）含背景色板/图片导入/阴影/尺寸/排版预览；预览 token；批量逐张检测人物并在清单记录。
- **测试**：v12 门禁/往返、中性恒等、管线位置、无人物显式跳过/错误、旧配方像素路径不变、批量记录。
- **DoD**：build + 定向测试 + 应用自检快照；不修改 B1 核心语义。

### B5 修复画笔集成（依赖 B2、B4）

- **范围**：`Sources/PhotoCore/Models.swift`、`PhotoEngine.swift`、`Sources/PhotoAtelier/AppModel.swift`、`ContentView.swift`、`PhotoCanvas.swift`、`PortraitRetouchPanel.swift`（或新 RepairPanel）、`Tests/PhotoCoreTests/ColorCompatibilityTests.swift`、`PortraitRetouchTests.swift`。
- **内容**：`AdjustmentSettings.repairBrush`（笔迹列表）接入 Models + Recipe v12；PhotoEngine 在镜头效果之后、人像之前应用；画布新增「修复」画笔模式（heal/clone、半径/强度/羽化、clone 源偏移），笔迹整笔撤销、预览 token；无笔迹恒等；批量记录。
- **测试**：v12 门禁/往返、管线位置、恒等、批量记录；画布真实笔迹交互未自动化如实标注。
- **DoD**：build + 定向测试 + 应用自检快照；不破坏既有 mask/liquify 交互。

### B6 交付页集成（依赖 B3、B5）

- **范围**：`Sources/PhotoCore/Models.swift`、`PhotoIO.swift`、`BatchProcessor.swift`、`Sources/PhotoAtelier/AppModel.swift`、`ContentView.swift`、`Tests/PhotoCoreTests/IOTests.swift`、`BatchTests.swift`、`ColorCompatibilityTests.swift`。
- **内容**：`ExportSettings.deliveryPage`（可选：标题/列数/缩略图尺寸/水印/接触表）；导出流程新增「导出客户交付页」动作（选择独立输出目录、生成 HTML + 缩略图 + 接触表 PDF）；批量清单 v4 记录交付页路径与设置；隐私校验（无 GPS/相机序列号、无外链）；不覆盖/原子写入保持。
- **测试**：HTML/PDF 生成、清单记录、隐私检查、原子/不覆盖、v11 拒绝非中性交付设置、v12 往返。
- **DoD**：build + 定向测试 + 应用自检；GUI 点选未自动化如实标注。

### B7 质量加固与适配（依赖 B4/B5/B6）

- **范围**：`Scripts/ui_smoke.sh`、`Scripts/benchmark.swift`。
- **内容**：
  1. ui_smoke 失败重试（1–2 次，递增等待）并记录 `appExecutableMTime`/`appExecutableSHA256` 与 commit；新增证件照/修复画笔/交付入口区段截图与断言；页签动态枚举（≥7）。
  2. benchmark 新增 matting/background replacement、repair brush、delivery HTML+PDF 阶段；schemaVersion 3；边界更新。
  3. 减少弹窗打扰：脚本只在明确调用时运行；不自动重复启动应用。
- **DoD**：`bash -n` exit 0；重建包上 ui_smoke exit 0（含新 UI 区段）并记录 app 哈希；benchmark 编译/运行 exit 0；报告含命令/退出码/证据路径。

---

## 6. 波次与依赖

| 波次 | 工作项 | 说明 |
|---|---|---|
| A | B1、B2、B3、S1 | 三个核心只新增文件 + 注释修正，写范围互斥 |
| B | B4（依赖 B1） | 证件照集成（共享 Models/PhotoEngine/UI） |
| C | B5（依赖 B2、B4） | 修复画笔集成（共享文件，串行） |
| D | B6（依赖 B3、B5） | 交付页集成（共享文件，串行） |
| E | B7（依赖 B4/B5/B6） | 质量加固与适配 |
| F | Lead 最终验收 | 全量 make check、build_app、重建包 ui_smoke（仅一次）、benchmark、文档、提交、gate |

并行约束：同一波次写范围不得重叠；worker 只跑 `swift build` 与本项定向 `swift test --filter`；全量测试由 Lead 在每波结束执行。**UI 冒烟只在波次 E 与最终验收各跑一次，避免弹窗打扰用户。**

---

## 7. 质量门禁与证据

- 每个工作项：`swift build` exit 0；定向测试 exit 0；报告含真实命令、退出码、引用输出、未验证项；独立 reviewer 批准后才能进入下一波。
- Lead gate：每波结束在稳定树上跑全量 `make check`；失败不得带红合并。
- 最终验收：`make check`、`bash Scripts/build_app.sh`、`codesign --verify --deep --strict`、`python3 Scripts/verify_app.py`、重建包 `bash Scripts/ui_smoke.sh`（一次）、最终树 benchmark；全部退出 0 才可完成 Goal（若 ui_smoke 出现 AX 偶发错误，按 B7 的重试策略重试一次，并在报告中记录）。
- 文档：README 更新（证件照/修复画笔/交付页/配方 v12/限制），新增 `docs/p1b-release-notes.md`；`docs/p1b-implementation-plan.md` 状态表更新。

---

## 8. 风险与缓解

| 风险 | 影响 | 缓解 |
|---|---|---|
| 抠图边缘在发丝/半透明/复杂背景上不稳 | 换背景假 | 边缘细化 + 羽化 + 去色边；无人物/低置信显式报错；明确定位启发式 v1，不宣称商业级抠图 |
| 背景替换后蒙版/局部调整错位 | 局部效果异常 | 管线固定「背景替换在局部之前」；文档标注需复核背景相关局部；测试覆盖 |
| 修复画笔 heal 质量不足 | 修补痕迹 | 频率分离 + 邻域纹理中值；笔迹可撤销；提供 clone 兜底；合成测试边界 |
| 交付页隐私泄漏 | 合规风险 | 只生成静态本地文件、无外链/无网络；剥离元数据；测试断言无 GPS/序列号/http |
| 证件照裁剪改变画布尺寸 | 蒙版/几何坐标失效 | 裁剪在背景替换后统一处理 extent 与蒙版归一化；文档标注；测试覆盖 |
| ui_smoke AX flakiness 复发 | 验收假阴性 | B7 重试 + app 哈希绑定；最终验收只跑一次并记录 |
| 共享文件串行集成耗时 | 进度 | 波次串行；核心/集成分离；Lead 每波 gate |

---

## 9. 后续（本批之外）

- P1 第三批：妆容、AI 挑图/选片基础、性能优化（并行批处理/预览延迟）、项目库/历史面板。
- P2：头发/衣物/宠物/天空、联机拍摄、RAW 引擎/AI 降噪、生成式、多端/云。
- 真实照片审美验收：需用户提供授权样片集后单独执行。

---

## 10. 执行状态（待更新）

| 工作项 | 状态 | 说明 |
|---|---|---|
| B1 证件照/换背景核心 | pending | |
| B2 修复画笔核心 | pending | |
| B3 交付页核心 | pending | |
| B4 证件照集成 | pending | |
| B5 修复画笔集成 | pending | |
| B6 交付页集成 | pending | |
| B7 质量加固 | pending | |
| S1 P1 文档修正 | pending | |

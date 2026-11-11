# P0 功能补齐实施计划（Goal 执行版）

**制定日期**：2026-11-03
**目标分支**：`feat/p0-gap-closure`（从 `7f2dcae` 切出；`main` 是其祖先）
**基线验证**：`make check` 退出码 0（246 tests / 0 failures，日志 `/tmp/pa_check.log`）；应用启动与主界面渲染已实测
**上位文档**：[像素蛋糕差距分析与补齐路线](pixelcake-gap-analysis.md)

---

## 1. 目标与范围

本 Goal 只做差距分析中的 **P0 核心**，目标是把光屿从「调色/局部工具」推进到「具备商业修图主力功能的本地工作站」：

| 编号 | 功能 | 对应差距 |
|---|---|---|
| W1 | HEIC/HEIF/WebP 输入 + AVIF 识别、拖放导入、单文件/多选导入 | 格式与导入摩擦 |
| W2 | 撤销/重做（参数、蒙版、配方载入），带快捷键与合并拖动 | 基础体验（无撤销） |
| W3 | 人脸语义蒙版（皮肤/眼白/虹膜/唇/牙齿/眉） | 人像精修地基 |
| W4 | 人像修复 v1：祛瑕疵、中性灰/高低频、牙齿美白、眼白提亮、面部肤色统一 | 人像精修核心 |
| W5 | 人像 UI + 配方 v10 + 批量/清单集成 | 功能可用性 |
| W6 | AI 追色核心（参考图色彩匹配，OKLab 分位数映射） | AI 色彩 |
| W7 | AI 追色 UI + 配方/批处理集成 | 功能可用性 |
| W8 | 导出增强：缩放、文件名模板、HEIC 输出 | 交付能力 |
| W9 | 性能基准脚本 + UI 冒烟脚本 | 工程可验证性 |

**非目标（本 Goal 不做）**：P1/P2 的液化美型、证件照/换背景、妆容、头发/衣物/宠物、天空、联机拍摄、云协作、生成式 AI、跨平台、自研 RAW 引擎、水印（降级到 P1）。
**理由**：这些要么依赖专用模型/后端，要么工作量与风险超出可验收范围；先完成高频核心并保持代码可维护。

---

## 2. 基线、分支与提交策略

- 基线：`main` @ `837ec59`（祖先）→ 本次执行分支 `feat/p0-gap-closure` 从最新已验证提交 `7f2dcae` 切出。
- 所有实现提交只落在 `feat/p0-gap-closure`；不直接修改 `main`；每个工作波次通过 Lead 的 gate 后提交一次。
- 提交信息：`feat(scope): summary` / `fix(scope): summary` / `test(scope): summary`；一次提交对应一个可独立回滚的意图。
- 不主动 fetch/pull；不推送远端（除非用户明确要求）。
- 用户已有文件保持原样；只暂存本次任务的路径（`git add <paths>`，禁止 `git add -A`）。

---

## 3. Goal 完成定义（DoD）

全部满足才可标记 Goal 完成：

1. W1–W9 全部经独立 reviewer 批准、Lead gate 通过并提交到 `feat/p0-gap-closure`。
2. `make check` 全绿：构建 + 全部单元测试（含新增测试）。
3. `bash Scripts/build_app.sh` 成功产出 `.app` 并通过包校验（沿用现有脚本门禁）。
4. 新功能均有：参数模型（Codable）、旧配方兼容策略、测试覆盖、应用级可运行证据。
5. 文档更新：README 能力/限制段落、`docs/p0-implementation-plan.md` 状态表、必要时新增算法边界文档。
6. 性能基准脚本可重复运行并输出 JSON；UI 冒烟脚本可重复运行并产出截图/断言。
7. 全程遵守「不夸大」：合成图测试不描述为真实画质验收；真实照片效果评审单独标注「未执行/待用户提供授权样片」。

---

## 4. 工作分解与验收

### W1 格式与导入地基

- **范围**：`Sources/PhotoCore/PhotoIO.swift`、`Sources/PhotoCore/PhotoSelection.swift`（新）、`Sources/PhotoAtelier/AppModel.swift`、`Sources/PhotoAtelier/ContentView.swift`、`Tests/PhotoCoreTests/IOTests.swift`、`Tests/PhotoCoreTests/PhotoSelectionTests.swift`（新）。
- **内容**：
  1. `rasterExtensions` 增加 `heic/heif/avif/webp`；沿用 ImageIO 解码与 ICC/方向归一；多页/动画仍明确拒绝。
  2. 新增纯函数 `PhotoSelection.resolve(fileURLs:)`：校验本地文件、支持格式、去重、排序、计算公共根目录，返回 `(root, items)`；供单文件/多选导入使用。
  3. App 增加「打开照片…」（文件/文件夹、可多选）与 `.onDrop` 导入：目录 → `loadFolder`；文件 → `openSelection`；已打开目录内追加 = 二次导入（去重）。
  4. 导入失败逐项报告，不静默丢弃；原图不变。
- **测试**：HEIC 生成后读取（ImageIO 写 HEIC 在本机已验证可用）；内嵌 1×1 WebP base64 解码；AVIF 扩展名识别 + 不可解码时的明确错误路径；扫描包含新格式；选区解析（单文件/多选/混合目录/重复/不支持）；多页拒绝不回归。
- **DoD**：`swift build` 退出 0；相关 `swift test --filter` 全绿；新增/修改文件仅限上述范围；README 改动需求写入报告由 Lead 汇总。

### W2 撤销/重做

- **范围**：`Sources/PhotoCore/UndoHistory.swift`（新）、`Sources/PhotoAtelier/AppModel.swift`、`Sources/PhotoAtelier/ContentView.swift`、`Sources/PhotoAtelier/PhotoAtelierApp.swift`、`Tests/PhotoCoreTests/UndoHistoryTests.swift`（新）。
- **内容**：
  1. `UndoHistory`：容量上限（如 50）、`push`、`undo`、`redo`、合并规则（同一编辑键 0.5s 内合并）、新编辑清空 redo；快照为 `AdjustmentSettings` + 选中 LUT id/输入空间（Equatable/Codable）。
  2. AppModel 接入：滑块/开关变更（0.5s 合并）、LUT 切换、蒙版增删改、配方载入、重置操作均产生可撤销步；撤销/重做后刷新预览与分析基线。
  3. 菜单 `撤销 ⌘Z` / `重做 ⇧⌘Z`（`PhotoAtelierApp.swift`），带可用状态。
- **测试**：UndoHistory 单元测试（基本/合并/容量/redo 清空/连续性）；快照相等性；不涉及 UI 的回归。
- **DoD**：`swift build` 退出 0；`swift test --filter UndoHistoryTests` 全绿；应用可编译运行（报告记录实际启动命令与结果）。

### W3 人脸语义蒙版核心

- **范围**：`Sources/PhotoCore/FaceSemanticAnalysis.swift`（新）、`Tests/PhotoCoreTests/FaceSemanticTests.swift`（新）。
- **接口**（先定义、后实现，W4 按此对接）：
  ```swift
  public struct FaceLandmarkSet: Equatable { /* 轮廓/眼/眉/鼻/外唇/内唇/瞳孔，图像归一化坐标 */ }
  public struct FaceSemanticMaskSet { public let skin, teeth, sclera, iris, lips, brows: CIImage? ... }
  public enum FaceSemanticAnalyzer {
      public static func masks(image: CIImage, faceBounds: CGRect, landmarks: FaceLandmarkSet, maxDimension: Int) -> FaceSemanticMaskSet
      public static func detect(in image: CIImage, maxFaces: Int) -> [FaceLandmarkSet] // Vision，测试可跳过
  }
  ```
- **内容**：Vision 地标 → 多边形区域；Lab/YCbCr 颜色分类（牙齿=内唇内低饱和高亮、眼白=眼区低饱和高亮减虹膜、皮肤=轮廓内肤色、虹膜=眼内中低亮高饱和）；边缘引导滤波羽化；按最长边 512 的分辨率输出软蒙版；无脸/低置信 → 空集。
- **测试**：构造合成地标 + 合成色块（肤色/眼白/虹膜/牙齿/唇）验证掩码内外；蒙版范围/羽化/确定性；空输入安全返回；不依赖 Vision 检测（真实人脸路径另记「未在单测覆盖」）。
- **DoD**：`swift build` + `swift test --filter FaceSemanticTests` 绿；不修改其他文件。

### W4 人像修复引擎 v1（依赖 W3）

- **范围**：`Sources/PhotoCore/BlemishRemoval.swift`（新）、`Sources/PhotoCore/FrequencySeparation.swift`（新）、`Sources/PhotoCore/PortraitRefinement.swift`（新）、`Sources/PhotoCore/LocalDetailProcessing.swift`、`Sources/PhotoCore/PhotoEngine.swift`、`Sources/PhotoCore/Models.swift`、`Sources/PhotoCore/AutomaticProcessing.swift`、`Tests/PhotoCoreTests/PortraitRetouchTests.swift`（新）。
- **设置**（`AdjustmentSettings.portrait: PortraitRefinementSettings?`）：
  - `blemishStrength`（0–1）、`keepSpots`（保留痣/斑模式）、`dodgeBurn`（光影平整 0–1）、`structure`（立体 0–1）、`texture`（纹理保留 0–1）、`gloss`（光泽 0–1）、`teethWhiten`、`eyeBrighten`、`skinToneUnify`（0–1）、`skinToneReference`（auto/median/brightest）。
  - 非中性字段要求配方 v10；`validateVersion` 增加门禁；旧配方保持像素兼容。
- **内容**：
  1. 祛瑕疵：皮肤蒙版内 band-pass（DoG）残差检测（median+k·MAD、面积/对比过滤），高低频分离修复（替换高频缺陷为邻域中值），强度/保留模式/单次限幅；眼眉唇牙区排除。
  2. 中性灰/高低频：低频引导模糊 + 高频残差；平整/立体/纹理/光泽独立控制；亮度限幅沿用现有 ±0.12 EV 级别约束。
  3. 牙齿美白：牙齿蒙版内提升 L、降低 b\*，边缘羽化，ΔE 限制。
  4. 眼白提亮：眼白蒙版内压红/提亮，保护虹膜与高光。
  5. 面部肤色统一：逐脸皮肤 Lab 统计 → 参考脸（中位/最亮）→ 受限 tone 映射；多人覆盖。
  6. 管线顺序：全局基础/五区 → 人像修复 → 局部细节/蒙版 → LUT → 输出色域（写入文档与代码注释）。
- **测试**：合成皮肤 + 人造暗斑：检出/修复后局部对比下降、非缺陷区变化受限；眼/唇/牙区域外像素不变；牙齿黄斑去黄且不越界；多脸肤色收敛；设置全 0 = 恒等；配方 v9 拒绝非中性人像字段、v10 往返；批量无脸图跳过并在报告中记录。
- **DoD**：`swift build` + 相关测试全绿；无 UI 改动。

### W5 人像 UI 与配方/批量集成（依赖 W4、W2）

- **范围**：`Sources/PhotoAtelier/PortraitRetouchPanel.swift`（新）、`Sources/PhotoAtelier/AppModel.swift`、`Sources/PhotoAtelier/ContentView.swift`、`Sources/PhotoAtelier/SmokeHarness.swift`、`Tests/PhotoCoreTests/BatchTests.swift`、`Tests/PhotoCoreTests/ColorCompatibilityTests.swift`（配方版本兼容）。
- **内容**：右栏新增「人像」页签；检测人脸数量/置信提示；各滑杆、保留模式、参考肤色选择；「轻度精修起点」「归零」按钮；无脸时禁用并说明限制；预览刷新走现有 token 机制；配方 v10 保存/载入；批量逐张应用并在清单记录「人像：应用/无脸跳过」；扩展 smoke 自检渲染该面板截图（合成图不检测人脸，只验证 UI 渲染与状态）。
- **测试**：配方 v10 往返、v9 拒绝人像字段、批量清单字段、旧测试回归；smoke 截图产物路径写入报告。
- **DoD**：`make check` 全绿（本项由 Lead 最终跑全量，worker 至少跑相关测试与 build）；smoke 可运行。

### W6 AI 追色核心

- **范围**：`Sources/PhotoCore/ReferenceColorMatch.swift`（新）、`Tests/PhotoCoreTests/ReferenceColorMatchTests.swift`（新）。
- **接口**：
  ```swift
  public struct ReferenceColorProfile: Codable, Equatable { /* OKLab 分位数统计 + algorithmVersion */ }
  public enum ReferenceColorMatcher {
      public static func profile(reference: CIImage, sampleLimit: Int) throws -> ReferenceColorProfile
      public static func apply(_ profile: ReferenceColorProfile, to image: CIImage, strength: Double) throws -> CIImage
  }
  ```
- **内容**：双边/加权采样 → OKLab 的 L/a/b 分位数映射（单调、平滑、限幅）；strength 0–1 混合；肤色/中性保护（复用现有思路）；不引入外部依赖。
- **测试**：同图追色近似恒等（ΔE 阈值）；合成冷暖偏移图向参考分布收敛；strength=0 恒等；极端参考不产生 NaN/越界；确定性（同输入同输出）。
- **DoD**：`swift build` + `swift test --filter ReferenceColorMatchTests` 绿；不改 PhotoEngine/Models（集成留给 W7）。

### W7 AI 追色 UI 与配方/批量集成（依赖 W6、W5）

- **范围**：`Sources/PhotoCore/PhotoEngine.swift`、`Sources/PhotoCore/Models.swift`、`Sources/PhotoCore/ReferenceColorMatch.swift`、`Sources/PhotoAtelier/AppModel.swift`、`Sources/PhotoAtelier/ContentView.swift`、`Sources/PhotoAtelier/ReferenceColorPanel.swift`（新）、`Tests/PhotoCoreTests/BatchTests.swift`、`Tests/PhotoCoreTests/ColorCompatibilityTests.swift`。
- **内容**：设置 `AdjustmentSettings.referenceColor: ReferenceColorSettings?`（profile + strength + 是否仅人像皮肤）；参考图导入（文件）、缩略预览、清除；应用阶段在基础/人像之后、LUT 之前；配方 v10 存储 profile；批处理逐张应用同 profile 并在清单记录；默认关闭。
- **测试**：编码/解码、v9 门禁、strength、批量记录、旧测试回归；UI 面板快照。
- **DoD**：build + 相关测试 + 面板快照。

### W8 导出增强（依赖 W7，避免 ContentView 冲突）

- **范围**：`Sources/PhotoCore/Models.swift`、`Sources/PhotoCore/PhotoIO.swift`、`Sources/PhotoCore/BatchProcessor.swift`、`Sources/PhotoAtelier/ContentView.swift`、`Tests/PhotoCoreTests/IOTests.swift`、`Tests/PhotoCoreTests/BatchTests.swift`。
- **内容**：`ExportSettings` 新增可选 `resize`（none/longEdge/percent）、`fileNameTemplate`、格式 `.heic`；HEIC 用 ImageIO 编码（本机已验证可写）；缩放用 Lanczos；模板 token `{name}`、`{suffix}`、`{index}`；配方 v10 门禁（非中性导出扩展字段）；批量清单记录实际导出参数；保持原子写入与不覆盖语义。
- **非目标**：水印、打印排版（P1）。
- **测试**：缩放大小的像素断言；模板展开；HEIC 写-读回验证；v9 配方默认行为不变；不覆盖/原子安装回归。
- **DoD**：build + 相关测试全绿。

### W9 性能基准 + UI 冒烟脚本

- **范围**：`Scripts/benchmark.swift`（新）、`Scripts/ui_smoke.sh`（新）、`docs/p0-implementation-plan.md`（状态表仅 Lead 更新）。产物写入 `artifacts/`（gitignored）。
- **内容**：
  1. 基准：固定合成语料（长边 1024/4032/8192、JPEG/PNG/HEIC）测导入、分析、预览首帧、批量导出吞吐、峰值 RSS；输出 JSON；与基线阈值对比（首次只记录，不设失败门槛，避免伪精度）。
  2. UI 冒烟：用 `open -a` + AppleScript（System Events 可用，本机已验证）打开应用、切换页签、截图；断言进程存活与截图存在；不读取用户照片（使用 `artifacts/demo/input` 合成目录）。
- **DoD**：两个脚本可在本机重复运行并输出 JSON/截图；报告记录命令与退出码。

---

## 5. 波次与依赖（Lead 用 team_flow_plan 建模）

| 波次 | 工作项 | 说明 |
|---|---|---|
| A | W1、W3、W6、W9 | 写范围互斥；W1 改 UI/IO，W3/W6 只加新文件，W9 只加脚本 |
| B | W2（依赖 W1）、W4（依赖 W3） | W2 改 AppModel/ContentView；W4 改 PhotoCore/Models，互斥 |
| C | W5（依赖 W2、W4） | 人像 UI/配方/批量 |
| D | W7（依赖 W5、W6） | AI 追色 UI/配方/批量 |
| E | W8（依赖 W7） | 导出增强（复用 ContentView） |
| F | Lead 最终验收 | 全量 `make check`、`build_app.sh`、基准、文档、提交、gate |

**并行约束**：同一波次内写范围不得重叠；SwiftPM 构建目录共享，worker 只跑 `swift build` 与本项 `swift test --filter`，全量测试由 Lead 在每波结束执行。

---

## 6. 配方版本与兼容策略

- 当前版本 v9；本 Goal 引入 v10：人像修复字段（W4）与 AI 追色字段（W7）、导出扩展字段（W8）均要求 v10。
- 规则：
  - v1–v9 配方必须保持像素兼容（缺字段 → 不启用新处理）。
  - 非中性的 v10 新字段出现在旧版本配方中 → `validateVersion` 拒绝，不得静默降级。
  - 批量清单内嵌配方快照并记录逐张实际应用的人像/追色状态。
- 测试覆盖：`ColorCompatibilityTests` 增加 v10 往返与 v9 拒绝；批量测试增加新字段门禁。

---

## 7. 质量门禁与证据

每个工作项：
1. `swift build` 退出 0（worker 提供命令与退出码）。
2. 本项 `swift test --filter <相关测试>` 退出 0，摘录用例名。
3. 报告含：变更文件、行为说明、边界/风险、未验证项；不夸大。
4. 独立 reviewer 检查真实文件与证据，verdict 通过后才能进入下一波。
5. Lead gate：每波结束跑 `make check`（全量），失败即回退/修复，不得带红合并。
6. 每波通过后 Lead 提交（显式路径），提交后跑一次 `git status` 确认只含预期文件。

最终验收（波次 F）：
- `make check`、`bash Scripts/build_app.sh`、`codesign --verify --deep --strict build/PhotoAtelier.app`（沿用脚本）、`python3 Scripts/verify_app.py build/PhotoAtelier.app` 全部退出 0。
- 运行 `Scripts/benchmark.swift` 与 `Scripts/ui_smoke.sh`，产出 JSON/截图。
- 用合成图跑一次 `--self-test` 应用级自检（若 W5 扩展了 smoke，断言数增加）。
- README 更新：支持格式、撤销、人像、AI 追色、导出扩展、限制与「未做真实照片审美验收」声明。

---

## 8. 风险与缓解

| 风险 | 影响 | 缓解 |
|---|---|---|
| 人像算法效果达不到商业级 | 用户预期落空 | 明确定位「本地保守修图 v1」；强度可调/可关闭/手动擦回候选；合成测试 + 真实样片评审留待用户提供；不宣称等同像素蛋糕 |
| Vision 地标/颜色分类在深肤色、妆面、遮挡下不稳 | 误伤 | 置信度门禁、空集回退、蒙版预览、区域排除（眼眉唇牙）、单次限幅 |
| 共享 `.build` 并发构建/测试 | 阻塞/超时 | 同波次写范围互斥；worker 只跑 build + 定向测试；Lead 串行全量 |
| 配方兼容破坏 | 旧配方漂移 | v10 门禁 + 回归测试；缺字段保持旧路径 |
| UI 改动引入预览性能/状态 bug | 卡顿/错误 | 复用现有 preview token/后台队列；每波快照与冒烟；性能基准 |
| 撤销栈内存/合并粒度 | 卡顿或误撤销 | 快照仅参数（非图像）；容量上限；拖动合并 0.5s；单元测试 |
| HEIC/AVIF 编解码依赖系统 | 平台差异 | 以 ImageIO 能力探测；失败明确报错；测试按本机能力；文档标注 macOS 13 边界 |
| AI 追色过火/偏色 | 画质投诉 | 限制强度、域外/肤色保护、前后对比、无参考不改图 |

---

## 9. 记录与追踪

- 团队看板：`team_flow_plan` 建立 W1–W9 工作项与依赖；每波 `team_flow_gate` 通过后更新本文状态表（Lead 维护）。
- 本文状态表在最终验收时填写：每项「已批准 / 提交 hash / 测试证据 / 备注」。
- 证据产物统一放 `artifacts/p0-<date>/`（gitignored），代码与测试进仓库。

## 10. 后续（本 Goal 之外）

- P1：液化美型、证件照/换背景、妆容/修复画笔、调色工具扩展（HSL/曲线/分级）、本地交付页、水印、AI 挑图。
- P2：头发/衣物/宠物/天空、联机拍摄、RAW 引擎、生成式、多端/云。
- 真实照片审美验收：需要用户提供授权样片集后单独执行。

---

## 11. 执行状态（2026-11-04 更新）

| 工作项 | 状态 | 说明与证据 |
|---|---|---|
| W1 格式与导入 | ✅ approved | HEIC/HEIF/WebP/AVIF 候选、拖放/多选/二次导入；`artifacts/w1-verification/`；F1/F2 nit 已在 W2 修复 |
| W2 撤销/重做 | ✅ approved | UndoHistory 16/16 + 应用自检；菜单 ⌘Z/⇧⌘Z；`artifacts/w2-verify/` |
| W3 人脸语义蒙版 | ✅ approved | FaceSemanticTests 6/6 |
| W4 人像修复引擎 | ✅ approved | PortraitRetouchTests 7/7；配方 v10 门禁；合成图边界测试 |
| W5 人像 UI/配方/批量 | ✅ approved | 人像页签、v10 保存/载入、批量清单；APP_SMOKE PASS 35 checks；`artifacts/w5-verify/` |
| W6 AI 追色核心 | ✅ approved | ReferenceColorMatchTests 14/14 |
| W7 AI 追色 UI/配方/批量 | ✅ approved | 追色页签、skinOnly、批量清单；APP_SMOKE PASS 36 checks；`artifacts/w7-verify/` |
| W8 导出增强 | ✅ approved | resize/模板/HEIC；IOTests 17/17、BatchTests 11/11；F1 边缘像素缺陷已修 |
| W9 基准与 UI 冒烟 | ✅ approved | `artifacts/p0-20261103/{benchmark,ui-smoke}/`；重建 bundle 上 5 页签/7 截图 PASS |
| S1 配方 v10 边界回归 | ✅ approved | LocalMaskTests 19/19、SceneAdaptiveTests 15/15 |
| S2 人像 UI 状态诚实性 | ✅ approved | maxFaces=4、皮肤覆盖阈值、v10 自动升级断言；`artifacts/p0-20261103/verify-s2/` |
| S3 追色评审遗留修复 | ✅ approved | skinOnly 覆盖阈值单点化、v10 automatic 分支、来源名/测量竞态；ColorCompatibilityTests 25/25 |

**最终验收结果（2026-11-04，全部实测）**：

| 检查 | 命令 | 退出码 | 关键输出 |
|---|---|---|---|
| 全量构建与测试 | `make check` | 0 | `Executed 326 tests, with 0 failures`（151.06s） |
| Release 打包与签名 | `bash Scripts/build_app.sh` | 0 | 4 个签名 x86_64 dylib、55 XML、许可集合、portable paths 全部通过 |
| 包校验 | `codesign --verify --deep --strict build/PhotoAtelier.app` / `python3 Scripts/verify_app.py build/PhotoAtelier.app` | 0 / 0 | 严格签名与包内容校验通过 |
| UI 冒烟（重建包） | `bash Scripts/ui_smoke.sh` | 0 | `PASS: 6 tabs switched, 8 screenshots`；页签：分析/基础/局部/人像/追色/导出 |
| 性能基准（最终树） | `swiftc … Scripts/benchmark.swift` + 运行 | 0 / 0 | `benchmark: PASS`；9/9 批量导出，peak RSS 3768.5MB，JSON 在 `artifacts/p0-20261103/benchmark/benchmark.json` |
| 应用级自检 | `.build/debug/PhotoAtelier --self-test artifacts/demo/input …` | 0 | `APP_SMOKE PASS · 36 checks` + `PORTRAIT_CONTRACT_SELF_CHECK PASS`（人像/追色面板快照） |

**提交**：`b12f14f feat(p0): add HEIC import, undo/redo, face masks, portrait v1, reference color and QA tooling`；`88ac11d feat(p0): add reference color tab, export resize/template/HEIC and UI honesty fixes`（均在 `feat/p0-gap-closure`）。

**仍保留的诚实边界**：真实照片人像/追色审美验收未执行；UI 完整交互未自动化（ui_smoke 主路径）；AVIF 有效解码/HEIC GUI 点选未自动化；Apple Silicon 未实测；benchmark 为 debug 对象 + 合成语料。

# P1-C 实施计划：AI 挑图/选片 / 妆容 / 性能（并行批处理）

**制定日期**：2026-11-04
**目标分支**：`feat/p1c-culling-makeup-perf`（从 P1-B 验收提交 `152c9d1` 切出；`main` @ `837ec59` 为祖先）
**基线验证**：P1-B 分支最终验收——`make check` 458 tests / 0 failures、`build_app.sh` exit 0、重建包 ui_smoke 8 页签/14 截图 PASS（单次启动）、benchmark PASS（见 [P1-B 交付说明](p1b-release-notes.md)）
**上位文档**：[差距分析](pixelcake-gap-analysis.md)｜[P1-B 计划](p1b-implementation-plan.md)

---

## 1. 目标与范围

本批补齐差距分析 P1 的第三组能力：本地 AI 挑图/选片、妆容、性能（并行批处理 + 预览延迟基线）。仍坚持本地、离线、不读取用户私人照片、不引入第三方运行时依赖：

| 编号 | 功能 | 补齐的差距 |
|---|---|---|
| C1 | AI 挑图/选片核心：模糊/曝光/闭眼/连拍分组质量分析 + 推荐保留 | 像素蛋糕「AI 挑图/废片过滤/连拍优选」 |
| C2 | 妆容核心：唇色/眉色/腮红/眼影（基于人脸语义蒙版）+ 配方 v13 | 像素蛋糕「妆容/唇彩/眉形」 |
| C3 | 性能核心：有界并发批处理 + 取消/进度 + 基准测量 | 像素蛋糕「批量吞吐/预览延迟」 |
| C4 | 挑图集成：评级（0–5 星）/废片标记/筛选/自动挑图/导出跳过 | 功能可用性 |
| C5 | 妆容集成：配方 v13、管线接入、人像页妆容区、批量 | 功能可用性 |
| C6 | 性能集成：批量并行导出、进度/取消、预览延迟改善、benchmark 对比 | 可量化性能 |
| C7 | 质量适配：ui_smoke 新 UI 区段、benchmark 新阶段（schemaVersion 4）、证据绑定保持 | 工程可验证性 |

**非目标（本批不做）**：头发/衣物/宠物/天空、联机拍摄、RAW 引擎、生成式 AI、云协作/多端、完整选片系统（不做云相册/客户打分）、专业妆容笔刷（眼线/睫毛/美瞳）、GPU 内核重写。这些留给后续批次。

---

## 2. 基线与提交策略

- 基线：`feat/p1b-retouch-delivery` @ `152c9d1`（P1-B 全量验收通过）。
- 执行分支：`feat/p1c-culling-makeup-perf`；不直接修改 `main`；不主动 fetch/pull；不推送远端。
- 提交信息 `<type>(<scope>): <summary>`；每波通过 Lead gate 后提交；显式路径暂存，禁止 `git add -A`。
- 用户已有改动保持原样；产物写 `artifacts/`（gitignored）。
- **UI 冒烟打扰控制**：ui_smoke 会启动应用窗口；本批只在波次末尾/最终验收各跑一次，避免反复弹窗。

---

## 3. 完成定义（Goal DoD）

1. C1–C7 全部经独立 reviewer 批准、Lead gate 通过并提交到 `feat/p1c-culling-makeup-perf`。
2. `make check` 全绿（含新增测试）；`bash Scripts/build_app.sh` 成功并通过包校验。
3. 新功能均有：参数模型（Codable）、配方 v13 兼容策略（妆容；挑图评级为会话状态 + 导出清单记录）、测试覆盖、应用级可运行证据。
4. README 与 `docs/p1c-release-notes.md` 更新；算法边界与未验证项如实标注。
5. 重建包 `ui_smoke.sh` 通过（新 UI 区段）；最终树 benchmark 通过（schemaVersion 4，含挑图/妆容/并行批处理阶段）。
6. 性能项有**前后对比证据**（并行批处理 vs 串行、预览延迟），并如实说明测量环境（debug 对象/合成语料/本机 Intel）。
7. 不夸大：合成图测试不描述为真实画质验收；真实照片审美评审单独标注「未执行/待授权样片」。

---

## 4. 处理管线与配方版本

**新管线顺序（v13）**：

```
基础影调 → 全局几何 → 液化/美型 → 调色工具 → 镜头效果
→ 修复画笔 → 人像修复 v1 → 妆容（唇/眉/腮红/眼影）→ AI 追色
→ 背景替换/证件照 → 局部蒙版/细节 → LUT → 输出色域映射 → 导出
```

- 妆容在人像修复之后、追色之前：妆容基于人脸蒙版与肤色，追色会统一整体色彩关系；文档标注。
- 挑图为**会话级**功能：评级/废片标记/质量报告存在 `PhotoItem`（内存），不写配方；批量导出可选「跳过废片/未选」，manifest 记录选择状态与质量报告摘要。
- 配方版本 **v13**：新增 `makeup` 字段要求 v13；旧 v1–v12 配方缺字段保持原像素路径；非中性新字段出现在旧版本配方中由 `validateVersion` 拒绝；保存含妆容的配方自动升级 v13。
- 性能：批量导出支持有界并发（默认 4，可配置 1–8），保持输出命名/清单顺序与失败隔离；取消可中断；预览请求合并/取消在途渲染。

---

## 5. 工作分解与验收

### C1 AI 挑图/选片核心（新文件）

- **范围**：`Sources/PhotoCore/QualityAnalysis.swift`（新）、`Sources/PhotoCore/BurstGrouping.swift`（新）、`Tests/PhotoCoreTests/QualityAnalysisTests.swift`（新）、`BurstGroupingTests.swift`（新）。
- **内容**：
  1. `QualityAnalyzer`：模糊（灰度 Laplacian/Tenengrad 方差，归一化）、曝光（近黑/近白裁剪比例、平均亮度、对比度）、闭眼（Vision 地标眼高/眼宽比或人眼开合启发式，可注入地标单测）、综合评分与推荐（keep/review/reject）。
  2. `BurstGrouping`：按拍摄时间（EXIF，可注入）与感知哈希/缩略图相似度分组，组内按清晰度/闭眼排序推荐。
  3. 纯函数 + 合成夹具测试（模糊/清晰、过曝/欠曝、闭眼/睁眼地标、连拍时间序列），不依赖真实照片。
- **DoD**：只新增 4 个文件；build exit 0；`--filter QualityAnalysisTests` / `--filter BurstGroupingTests` 全绿；报告含命令/退出码/边界（启发式、非商业 AI 挑图）。

### C2 妆容核心（新文件）

- **范围**：`Sources/PhotoCore/MakeupEngine.swift`（新）、`Tests/PhotoCoreTests/MakeupEngineTests.swift`（新）。
- **内容**：`MakeupSettings`（lip 色/强度、brow 色/密度、cheek 色/强度/半径、eyeshadow 色/强度；中性=全关）；基于 `FaceSemanticAnalysis` 的唇/眉/皮肤掩码与羽化；在 OKLab/线性空间按肤色保护混合；提供纯 API 与 `validate()`；不重建结构、不改变几何。
- **测试**：中性恒等；唇/眉/腮红/眼影区域选择性（目标区变化、非目标区受限）；颜色/强度边界；多脸；确定性；NaN 防护。
- **DoD**：只新增 2 个文件；build + `--filter MakeupEngineTests` 全绿；报告含命令/退出码/边界（启发式 v1、非专业妆容）。

### C3 性能核心（新文件）

- **范围**：`Sources/PhotoCore/ParallelBatch.swift`（新）、`Tests/PhotoCoreTests/ParallelBatchTests.swift`（新）。
- **内容**：`ParallelBatch` 有界并发执行器（maxConcurrency 1–8、保持输入顺序、失败隔离、取消支持、进度回调）；`Measure` 辅助（耗时统计，供 benchmark/测试）；纯 Swift concurrency，不阻塞主线程。
- **测试**：并发上限（探针计数）、顺序保持、失败隔离、取消、空输入、确定性结果顺序；性能对比串行 vs 并行（合成任务，记录加速比）。
- **DoD**：只新增 2 个文件；build + `--filter ParallelBatchTests` 全绿；报告含命令/退出码/加速比数据与测量边界。

### C4 挑图集成（依赖 C1）

- **范围**：`Sources/PhotoCore/Models.swift`（导出跳过选项）、`PhotoSelection.swift`、`Sources/PhotoAtelier/AppModel.swift`、`ContentView.swift`、`Sources/PhotoCore/BatchProcessor.swift`、`Tests/PhotoCoreTests/{PhotoSelectionTests,BatchTests,QualityAnalysisTests}.swift`。
- **内容**：`PhotoItem` 增加 `rating`（0–5）、`isRejected`、`qualityReport`；AppModel 自动挑图（后台分析、进度、取消）、评级/废片快捷键与筛选（全部/保留/废片/推荐）；左侧列表显示星标/废片/质量徽标；导出设置「跳过废片/未选」；BatchProcessor 跳过并记录清单；会话状态不写配方。
- **测试**：评级/筛选/跳过逻辑、批量跳过清单记录、自动挑图结果映射；GUI 点选未自动化如实标注。
- **DoD**：build + 定向测试 + 应用自检快照；不破坏既有导入/导出/撤销。

### C5 妆容集成（依赖 C2、C4）

- **范围**：`Sources/PhotoCore/Models.swift`、`PhotoEngine.swift`、`Sources/PhotoAtelier/AppModel.swift`、`ContentView.swift`、`PortraitRetouchPanel.swift`、`Tests/PhotoCoreTests/{ColorCompatibilityTests,PortraitRetouchTests,EngineTests}.swift`。
- **内容**：`AdjustmentSettings.makeup` 接入 Models + Recipe v13 门禁/保存自动升级；PhotoEngine 在人像修复后、追色前应用；「人像」页新增妆容区（唇/眉/腮红/眼影颜色与强度、无脸禁用、重置）；预览 token；批量记录；无脸显式跳过。
- **测试**：v13 门禁/往返、中性恒等、管线位置、无脸跳过、旧配方像素路径不变、批量记录。
- **DoD**：build + 定向测试 + 应用自检快照；不修改 C2 核心语义。

### C6 性能集成（依赖 C3、C5）

- **范围**：`Sources/PhotoCore/BatchProcessor.swift`、`Sources/PhotoAtelier/AppModel.swift`、`ContentView.swift`、`Sources/PhotoCore/PhotoEngine.swift`（预览取消/分析降采样）、`Tests/PhotoCoreTests/{BatchTests,IOTests}.swift`。
- **内容**：批量导出接入 `ParallelBatch`（默认并发 4，UI 可调 1–8），保持命名/清单顺序与失败隔离、取消可中断、进度显示；预览在途请求取消/合并（避免旧 token 覆盖新预览）；分析降采样不改变结果语义；benchmark 增加串行/并行对比阶段（C7）。
- **测试**：并行与串行输出字节一致、顺序/清单一致、取消无半成品、失败隔离；预览取消逻辑（可测部分）。
- **DoD**：build + 定向测试；报告含真实并发加速数据（benchmark）与环境边界；不降低输出正确性。

### C7 质量适配（依赖 C4/C5/C6）

- **范围**：`Scripts/ui_smoke.sh`、`Scripts/benchmark.swift`。
- **内容**：ui_smoke 新增挑图（星标/筛选）、妆容区段、批量并发设置区段截图与断言；保持重试/app 哈希绑定；benchmark schemaVersion 4：新增 qualityAnalysis、makeup、parallelBatch（串行 vs 并行）阶段与对比数据；边界更新。
- **DoD**：`bash -n` exit 0；重建包上 ui_smoke exit 0（新 UI 区段）；benchmark 编译/运行 exit 0；报告含命令/退出码/证据路径；不修改应用源码。

---

## 6. 波次与依赖

| 波次 | 工作项 | 说明 |
|---|---|---|
| A | C1、C2、C3 | 三个核心只新增文件，写范围互斥 |
| B | C4（依赖 C1） | 挑图集成（共享 AppModel/ContentView/BatchProcessor） |
| C | C5（依赖 C2、C4） | 妆容集成（共享 Models/PhotoEngine/UI） |
| D | C6（依赖 C3、C5） | 性能集成（共享 BatchProcessor/AppModel/UI） |
| E | C7（依赖 C4/C5/C6） | 质量适配 |
| F | Lead 最终验收 | 全量 make check、build_app、重建包 ui_smoke（一次）、benchmark、文档、提交、gate |

并行约束：同一波次写范围不得重叠；worker 只跑 `swift build` 与本项定向 `swift test --filter`；全量测试由 Lead 在每波结束执行。

---

## 7. 质量门禁与证据

- 每个工作项：`swift build` exit 0；定向测试 exit 0；报告含真实命令、退出码、引用输出、未验证项；独立 reviewer 批准后才能进入下一波。
- Lead gate：每波结束在稳定树上跑全量 `make check`；失败不得带红合并。
- 最终验收：`make check`、`bash Scripts/build_app.sh`、`codesign --verify --deep --strict`、`python3 Scripts/verify_app.py`、重建包 `ui_smoke.sh`（一次）、最终树 benchmark（含并行对比）；全部退出 0 才可完成 Goal。
- 文档：README 更新（挑图/妆容/性能/配方 v13/限制），新增 `docs/p1c-release-notes.md`；`docs/p1c-implementation-plan.md` 状态表更新。

---

## 8. 风险与缓解

| 风险 | 影响 | 缓解 |
|---|---|---|
| 启发式质量分析误判（模糊/闭眼/曝光） | 挑图不准 | 阈值保守 + 推荐 review 而非直接删；用户可覆盖；明确定位 v1，不宣称商业 AI 挑图 |
| 妆容颜色溢出/不自然 | 坏片 | 掩码羽化 + 肤色保护 + 强度上限；中性恒等；合成测试；真实照片审美未验收 |
| 并行批处理引入输出差异/顺序错乱 | 交付错误 | 并行与串行逐字节一致测试；顺序保持；失败隔离；取消清理 |
| 预览取消竞态 | 显示旧图 | token 代际校验 + 取消在途请求；测试可测部分 |
| 评级为会话状态，重启丢失 | 用户困惑 | 文档明确「本批不持久化」；后续可加 catalog/侧车 |
| 共享文件串行集成耗时 | 进度 | 波次串行；核心/集成分离；Lead 每波 gate |
| ui_smoke 弹窗打扰 | 体验 | 只在波次末尾/最终验收运行；重试钩子避免重复启动 |

---

## 9. 后续（本批之外）

- P1 第四批：项目库/历史面板、持久化评级/选片侧车、客户交付页增强、更多妆容（眼线/睫毛/美瞳）、RAW 引擎、AI 降噪。
- P2：头发/衣物/宠物/天空、联机拍摄、生成式、多端/云。
- 真实照片审美验收：需用户提供授权样片集后单独执行。

---

## 10. 执行状态（待更新）

| 工作项 | 状态 | 说明 |
|---|---|---|
| C1 AI 挑图核心 | pending | |
| C2 妆容核心 | pending | |
| C3 性能核心 | pending | |
| C4 挑图集成 | pending | |
| C5 妆容集成 | pending | |
| C6 性能集成 | pending | |
| C7 质量适配 | pending | |

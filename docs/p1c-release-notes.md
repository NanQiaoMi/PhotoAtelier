# P1-C 功能交付说明：AI 挑图/选片 / 妆容 / 性能（并行批处理）

**日期**：2026-11-04
**分支**：`feat/p1c-culling-makeup-perf`（基线 `152c9d1`，计划提交 `77948f7`，实现提交见文末）
**上位计划**：[P1-C 实施计划](p1c-implementation-plan.md)｜**上一批**：[P1-B 交付说明](p1b-release-notes.md)

本批补齐差距分析 P1 的第三组能力：本地 AI 挑图/选片、妆容、性能（并行批处理 + 预览延迟）。全部本地运行、不联网、不读取用户私人照片、不引入第三方运行时依赖；算法为启发式 v1，**不宣称与商业 AI 挑图/专业妆容等同**。

---

## 1. 功能清单

### 1.1 AI 挑图 / 选片（C1 / C4）

左侧照片列表与导出面板新增挑图能力：

| 能力 | 说明 | 边界 |
|---|---|---|
| 质量分析 | 模糊（Laplacian/Tenengrad 方差）、曝光（近黑/近白裁剪、平均亮度/对比度）、闭眼（人脸地标眼高/眼宽启发式）、综合评分与 keep/review/reject 推荐 | 启发式 v1，非商业 AI 挑图；阈值保守，建议人工复核 |
| 连拍分组 | 按拍摄时间窗 + 缩略图感知哈希相似度分组，组内按清晰度/闭眼排序推荐 | 依赖 EXIF 拍摄时间；无时间信息时退化为单张 |
| 自动挑图 | 后台分析当前文件夹，标记推荐保留/废片，显示进度、可取消 | 结果为建议，不删除文件；可手动覆盖 |
| 评级 / 废片 | 0–5 星评级、废片标记；快捷键 **Option+1–5** 评级、**Option+X** 废片 | 会话状态，**不写配方、不持久化**（重启丢失，后续可加侧车/项目库） |
| 筛选 | 全部 / 推荐 / 保留 / 废片；左侧列表显示星标、废片、质量徽标 | 推荐筛选已排除废片（含自动 keep 后手动废片） |
| 导出跳过 | 导出设置「跳过废片 / 未选」；批量清单记录跳过项与原因 | 跳过不影响已导出文件与失败隔离 |

### 1.2 妆容（C2 / C5）

「人像」页新增妆容区（不新增页签）：

| 能力 | 说明 | 边界 |
|---|---|---|
| 唇色 / 眉色 / 腮红 / 眼影 | 颜色 + 强度（眉为密度、腮红含半径）；基于人脸语义蒙版羽化混合 | 启发式 v1，非专业妆容（无眼线/睫毛/美瞳）；真实照片审美未验收 |
| 肤色保护 | 按肤色/亮度保护混合，避免死白/溢色；输出可能 >1 线性，由下游追色/LUT clamp | 极端饱和色可能不自然 |
| 无脸处理 | 无脸/无地标时控件禁用并说明，不静默改图；有脸但无有效掩码时 applied=false + note | 侧脸/遮挡可能检测失败 |
| 配方 v13 | 妆容字段需 v13；旧 v1–v12 配方像素路径不变；保存自动升级 | 中性（全默认）不写字段 |
| 管线位置 | 人像修复之后、AI 追色之前 | 妆容参与追色/局部/LUT 的色彩关系 |

### 1.3 性能（C3 / C6）

| 能力 | 说明 | 边界 |
|---|---|---|
| 批量并行导出 | 有界并发（默认 4，UI 可调 1–8），保持输出命名/清单顺序、失败隔离、取消无半成品 | 全分辨率 Core Image 渲染受内存/GPU 限制，加速比温和 |
| 预览取消/合并 | 最新预览优先（PreviewRequestGate），旧 token 不覆盖新预览 | 极端快速拖动时可能少渲染中间帧（预期行为） |
| 分析降采样 | 分析采样最长边 1024，不改变结果语义 | 高分辨率细节判定仍以原尺寸检查为准 |
| 测量 | benchmark schemaVersion 4：qualityAnalysis / makeup / parallelBatch（串行 vs 并行）阶段 | debug 对象 + 合成语料 + 本机 Intel；非 release 吞吐 |

---

## 2. 管线顺序与配方 v13

**最终管线顺序（v13）**：

```
基础影调 → 全局几何 → 液化/美型 → 调色工具 → 镜头效果
→ 修复画笔 → 人像修复 v1 → 妆容（唇/眉/腮红/眼影）→ AI 追色
→ 背景替换/证件照 → 局部蒙版/细节 → LUT → 输出色域映射 → 导出
```

- 配方版本 **v13**：新增 `makeup` 字段要求 v13；旧 v1–v12 配方缺字段保持原像素路径；非中性新字段出现在旧版本配方中由 `validateVersion` 拒绝，不静默降级；保存含妆容的配方自动升级 v13。
- 挑图评级/废片/质量报告为**会话状态**，不写配方、不持久化；批量清单记录跳过项与质量摘要。
- 批量导出默认并发 4（1–8 可调），清单/命名顺序与串行一致。

---

## 3. 验证与证据

| 检查 | 结果 | 证据 |
|---|---|---|
| `make check` | 退出码 0，**521 tests / 0 failures**（154.5s） | `/tmp/p1c_final_check.log` |
| `bash Scripts/build_app.sh` | 退出码 0，4 签名 dylib / 55 XML / 许可 / portable paths 通过；`codesign --verify --deep --strict` 与 `python3 Scripts/verify_app.py` 均 exit 0 | 最终构建日志 |
| 重建包 `UI_SMOKE_FORCE_FAIL_ATTEMPTS=2 bash Scripts/ui_smoke.sh` | **待解锁会话后单次运行**（预期 exit 0、8 页签、18 截图、7 个 scrolled 区段）；两次授权运行分别因脚本 matcher 过严（已修）与会话锁屏（-1719）失败，均如实记录 | `artifacts/p1c-c7-verify/ui-smoke/` |
| 最终树 benchmark | 编译/运行 exit 0，`benchmark: PASS`；schemaVersion 4；qualityAnalysis 7110ms/9、makeup 33745ms/9、parallelBatch serial 3985ms vs parallel(4) 3551ms=1.12x（另 C6 真实批量导出实测 3.49x/3.39x，方法不同勿混用）；peak RSS 6671MB | `artifacts/p1c-c7-verify/benchmark-final/benchmark.json` |
| 定向测试 | QualityAnalysis 11、BurstGrouping、MakeupEngine 10、ParallelBatch 10、PhotoSelection 15、Batch 23+、ColorCompatibility 39、Engine 36、PortraitRetouch 17 等 | 各工作项报告 |
| 应用自检 | `APP_SMOKE PASS · 36 checks` + `PORTRAIT_CONTRACT_SELF_CHECK PASS`（makeupVersion=13） | `--self-test` 证据目录 |

**未验证项（不得当作已验收）**：
1. 真实照片的挑图准确率/妆容审美/性能吞吐（需用户授权样片与 release 构建后单独验收）。
2. GUI 点选（星标/筛选/自动挑图按钮/妆容颜色选择）与真实键盘快捷键（Option+数字）未自动化；ui_smoke 只覆盖主路径与面板渲染。
3. 评级/废片不持久化（重启丢失）为本批已知限制。
4. 全分辨率妆容/并行导出在 24MP+ 的真实内存/GPU 表现未基准；benchmark 为 debug 对象 + 合成语料 + 本机 Intel。
5. Apple Silicon 原生构建与运行（依赖仍 x86_64）。
6. 已知非阻塞 nit：参数注释渲染、低强度+空掩码 applied 口径、阈值分支缺专属测试（S3 评审记录）。

---

## 4. 文件地图

- 挑图核心：`Sources/PhotoCore/{QualityAnalysis,BurstGrouping}.swift`；集成：`Models/PhotoSelection/BatchProcessor/AppModel/ContentView`
- 妆容核心：`Sources/PhotoCore/MakeupEngine.swift`；集成：`Models/PhotoEngine/AppModel/ContentView/PortraitRetouchPanel`
- 性能核心：`Sources/PhotoCore/ParallelBatch.swift`；集成：`BatchProcessor/PhotoEngine/AppModel/ContentView`
- 测试：`Tests/PhotoCoreTests/`（新增 4 个测试文件 + 既有文件扩展）
- 质量工具：`Scripts/benchmark.swift`、`Scripts/ui_smoke.sh`（C7 适配）

---

*本说明与代码同时提交；证据产物在 `artifacts/`（gitignored，不入库）。*

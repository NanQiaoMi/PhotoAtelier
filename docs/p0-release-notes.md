# P0 功能交付说明（导入 / 撤销 / 人像 / 追色 / 导出 / 质量工具）

**日期**：2026-11-04
**分支**：`feat/p0-gap-closure`（基线 `7f2dcae`，文档提交 `a160fcd`，实现提交见文末）
**上位计划**：[P0 实施计划](p0-implementation-plan.md)｜**差距分析**：[像素蛋糕差距分析](pixelcake-gap-analysis.md)

本批交付对应差距分析中的 P0 核心：把光屿从「调色/局部工具」推进到「具备商业修图主力功能的本地工作站」。全部功能本地运行、不联网、不读取用户私人照片；算法为启发式 v1，**不宣称与商业 AI 精修等同**。

---

## 1. 功能清单

### 1.1 导入与格式（W1）

- 新增输入格式：**HEIC / HEIF / WebP**（候选制，能否解码取决于本机 ImageIO）；**AVIF** 加入候选扩展名，能否解码同样取决于系统解码器，不支持时给出明确错误。
- 「打开照片…」支持**文件与文件夹混合多选**；支持**拖放**文件/文件夹到窗口。
- 已打开目录内再次导入 = **二次导入追加**（按路径去重，相对路径重定基），逐项报告无法导入的文件。
- 多页 TIFF / 动画 PNG / HEIC 序列仍明确拒绝（单页静态照片约定不变）。
- 已知边界：AVIF 有效解码未在自动化测试中覆盖（DoD 只要求扩展名识别 + 失败路径）；Finder 拖放/系统面板多选的真实 UI 交互未自动化，纯函数 `PhotoSelection.resolve` 已覆盖选择/去重/公共根规则。

### 1.2 撤销 / 重做（W2）

- 菜单 **撤销 ⌘Z / 重做 ⇧⌘Z**，覆盖参数、LUT 切换、蒙版操作、配方载入、重置。
- 同一滑杆拖动 0.5 秒内合并为一步；新编辑清空重做栈；容量上限 50 步；快照为参数而非图像，避免内存膨胀。
- 已知边界：`exportSettings` 不参与撤销快照（配方载入后导出设置不回滚）；GUI 撤销点击未自动化（由单元测试 + 应用自检覆盖）。

### 1.3 人像修复 v1（W3/W4/W5）

右栏新增「人像」页签（分析/基础/局部/**人像**/追色/导出）。检测到人脸后可用：

| 能力 | 说明 | 边界 |
|---|---|---|
| 祛斑祛痘 | 皮肤蒙版内 band-pass 检测 + 高低频修复，强度可调、可「保留痣/斑」 | 启发式检测，不保证检出所有瑕疵；眼眉唇牙区域排除 |
| 中性灰 / 高低频 | 光影平整、立体、纹理、光泽独立控制；单次亮度限幅 | 不生成纹理，不能恢复已丢失信息 |
| 牙齿美白 | 牙齿蒙版内提升明度、降低黄度，羽化 + ΔE 限制 | 闭嘴/遮挡时跳过；不做牙齿排齐/修复 |
| 眼白提亮 | 眼白蒙版内压红/提亮，保护虹膜与高光 | 依赖地标质量 |
| 面部肤色统一 | 多人脸皮肤 Lab 统计 → 参考脸（中位/最亮）受限映射 | 不做全身肤色统一、不按肤色标准改人 |
| 轻度精修起点 | 一键保守参数（可撤销） | 不是自动美化 |

- 无脸/低置信时控件禁用并显示「未检测到可用人脸」，不静默改图。
- 人脸语义蒙版由 Vision 地标 + Lab/YCbCr 颜色分类 + 边缘羽化生成；最多处理前 4 张脸（UI 与管线一致）。
- 已知边界：合成图无人脸，真实人像启用态/滑杆拖动预览与真实照片审美验收未执行；深肤色、妆面、遮挡、侧脸表现需实拍复核。

### 1.4 AI 追色 v1（W6/W7）

右栏新增「追色」页签：导入参考图（样片）→ 在 **OKLab** 空间对 L/a/b 做分位数映射（17 档、分段单调、限幅）→ 以可调强度应用到客片。

- 支持「仅皮肤区域」模式（Vision 皮肤蒙版混合；无脸显式跳过，不回退全图）。
- 应用阶段在**基础/人像之后、局部/LUT 之前**；无参考或强度 0 时完全跳过，保持 v1–v9 像素路径不变。
- 批处理逐张应用同一 profile 并在清单记录 `ReferenceColorReport`。
- 已知边界：全局分布匹配，不是语义分割/风格理解；SDR 夹取会裁掉 >1 高光余量；真实照片审美验收未执行；性能未单独基准化。

### 1.5 导出增强（W8）

- 输出尺寸：**长边像素 / 百分比**（百分比 1–400）；Lanczos 缩放，缩放前 clamp + 目标整数裁剪，避免边缘降质。
- 文件名模板：`{name}`、`{suffix}`、`{index}`（非法模板在创建输出目录前报错）。
- 新增 **HEIC** 输出（ImageIO，白底合成 + 品质参数）；保持原子写入、绝不覆盖、失败隔离。
- 批量清单 `exportSummary` 记录实际导出参数（含隐私开关）。
- 非目标：水印、打印排版（P1）。

### 1.6 质量工具（W9）

- `Scripts/benchmark.swift`：合成语料（1024/4032/8192 × JPEG/PNG/HEIC）测导入、分析、预览代理、批量导出与峰值 RSS，输出 JSON（首次只记录、不设伪精度阈值）。
- `Scripts/ui_smoke.sh`：open + AppleScript（AX 动态菜单/页签 + 键盘兜底）打开合成夹具、切换全部页签、窗口截图，输出 JSON 与截图。
- 已知边界：合成语料非真实画质验收；benchmark 链接 debug 对象；预览是 headless 代理；ui_smoke 非完整交互测试。

---

## 2. 处理管线与配方

- 管线顺序（新配方）：**全局基础/几何 → 人像修复 → AI 追色 → 局部蒙版/细节 → LUT → 输出色域映射**。
- 配方版本 **v10**：新增 `portrait`、`referenceColor` 与导出扩展字段（HEIC/resize/模板）要求 v10；旧 v1–v9 配方缺字段时保持原像素路径；非中性新字段出现在旧版本配方中会被 `validateVersion` 拒绝，不静默降级。
- 保存含人像/追色/导出扩展的配方时自动升级到 v10；自定义 LUT 仍只记录路径（跨机器需一并复制 LUT）。

---

## 3. 验证与证据

| 检查 | 结果 | 证据 |
|---|---|---|
| `make check`（构建 + 全量测试） | 退出码 0，全部通过 | 见最终验收日志 |
| 新增定向测试 | FaceSemanticTests、PortraitRetouchTests、ReferenceColorMatchTests、UndoHistoryTests、PhotoSelectionTests、IOTests、BatchTests、ColorCompatibilityTests 等 | 各工作项报告与 `artifacts/` |
| `bash Scripts/build_app.sh` | 退出码 0，包校验通过 | 构建日志 |
| `bash Scripts/ui_smoke.sh` | 退出码 0，页签/截图 | `artifacts/p0-20261103/ui-smoke/` |
| `Scripts/benchmark.swift` | 退出码 0，JSON 记录 | `artifacts/p0-20261103/benchmark/` |
| 应用级自检 | `APP_SMOKE PASS`（含人像/追色面板快照） | `--self-test` 证据目录 |

**未验证项（不得当作已验收）**：
1. 真实照片的人像/追色审美与画质评审（需要用户提供授权样片后单独执行）。
2. 真实鼠标/键盘/系统文件面板的完整交互自动化（ui_smoke 只覆盖主路径）。
3. AVIF 有效解码（无本地授权夹具）；HEIC GUI 点选导出未自动化（编码/读回由真实文件单测覆盖）。
4. Apple Silicon 原生构建与运行（本机为 Intel；依赖仍为 x86_64）。
5. 追色/skinOnly Vision 性能基准；benchmark 为 debug 对象、合成语料。

---

## 4. 文件地图

- 导入：`Sources/PhotoCore/PhotoIO.swift`、`PhotoSelection.swift`、`Sources/PhotoAtelier/AppModel.swift`、`ContentView.swift`
- 撤销：`Sources/PhotoCore/UndoHistory.swift`、`Sources/PhotoAtelier/{AppModel,ContentView,PhotoAtelierApp}.swift`
- 人像：`Sources/PhotoCore/{FaceSemanticAnalysis,PortraitRefinement,BlemishRemoval,FrequencySeparation,LocalDetailProcessing,PhotoEngine,Models}.swift`、`Sources/PhotoAtelier/PortraitRetouchPanel.swift`
- 追色：`Sources/PhotoCore/{ReferenceColorMatch,PhotoEngine,Models}.swift`、`Sources/PhotoAtelier/ReferenceColorPanel.swift`
- 导出：`Sources/PhotoCore/{Models,PhotoIO,BatchProcessor}.swift`、`Sources/PhotoAtelier/ContentView.swift`
- 质量工具：`Scripts/benchmark.swift`、`Scripts/ui_smoke.sh`
- 测试：`Tests/PhotoCoreTests/`（新增 6 个测试文件 + 既有文件扩展）

---

*本说明与代码同时提交；证据产物在 `artifacts/`（gitignored，不入库）。*

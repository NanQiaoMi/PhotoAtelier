# 光屿 · Photo Atelier 开发交接文档

**日期**：2026-11-05
**仓库**：`/Users/mimi/project/ai调色`
**适用对象**：后续接手的开发者 / AI Agent
**目的**：记录本轮（P0→P1-C + 布局修复）做过的操作、修改、验证方式与坑，保证后续开发能独立复现与继续。

---

## 1. 仓库与分支现状

| 分支 | HEAD | 内容 |
|---|---|---|
| `main` | `837ec59 chore: baseline` | 稳定基线（未直接改动） |
| `feat/p0-gap-closure` | `2af5ccd` | P0：导入/撤销/人脸语义蒙版/人像 v1/追色/导出增强/QA 脚本 |
| `feat/p1-color-beauty` | `2ea97cb` | P1：调色工具扩展/液化美型/水印导出 |
| `feat/p1b-retouch-delivery` | `152c9d1` | P1-B：证件照/换背景、修复画笔/仿制、本地客户交付页 |
| `feat/p1c-culling-makeup-perf` | `fb22674` | P1-C：AI 挑图/妆容/并行批处理；含 ui_smoke 加固（`8dc9d01`、`fb22674`） |
| **`fix/inspector-layout`（当前工作分支）** | `90e95c2` | 右侧检查器页签 + LUT 风格架布局修复（本轮用户请求） |

- 当前所有功能分支**仅本地**，未推送远端；`main` 未合并任何功能分支（项目规则：功能分支 + 本地验证，未获授权不推送/合并）。
- 工作区应保持干净；`artifacts/`、`build/`、`.build/` 均在 `.gitignore` 中，**不要提交**。
- 提交规范：`<type>(<scope>): <summary>`，显式路径 `git add`，禁止 `git add -A`。

---

## 2. 构建 / 运行 / 测试速查

```bash
# 构建（debug）
swift build -j 2          # 或 make build

# 全量测试
swift test -j 2           # 或 make test
make check                # build + test（项目标准检查入口）

# Release 打包（含 Lensfun 校验、签名、包内容校验）
bash Scripts/build_app.sh # 产物 build/PhotoAtelier.app

# 启动应用
open build/PhotoAtelier.app

# 包校验（签名/依赖/许可/可移植路径）
python3 Scripts/verify_app.py build/PhotoAtelier.app
codesign --verify --deep --strict build/PhotoAtelier.app
```

依赖准备：`Scripts/build_app.sh` 内部会调用 `python3 Scripts/prepare_lensfun.py --verify`，从固定 wheel 提取 Lensfun 原生库与离线镜头库（不安装 Python 运行时、不联网下载任意依赖）。若 `.dependencies/lensfun` 缺失，先执行该脚本或直接 `build_app.sh`。

---

## 3. 测试 / 验证工具

### 3.1 单元与集成测试

- 测试目标：`Tests/PhotoCoreTests`（SwiftPM test target，只依赖 `PhotoCore`）。
- 常用过滤：
  ```bash
  swift test -j 2 --filter ColorCompatibilityTests
  swift test -j 2 --filter EngineTests
  swift test -j 2 --filter BatchTests
  ```
- 跳过个别慢测：`swift test -j 2 --skip "ColorCompatibilityTests.testMaximumDimensionLUTAddressesLastNode"`。

### 3.2 应用级自检（创建自己的 SwiftUI 视图，不驱动其他 app）

```bash
.build/debug/PhotoAtelier --self-test <输入图目录> <输出目录> <证据目录>
# 变体：
--portrait-self-test / --native-inspection-self-test / --style-self-test
```

- 输入：合成夹具（`Scripts/make_demo.swift` 可生成 `artifacts/demo/input`）。
- 输出：导出图片、`APP_SMOKE PASS · N checks`、契约断言（如 `PORTRAIT_CONTRACT_SELF_CHECK`、`makeupVersion=13`）。
- 证据目录在 `artifacts/`（gitignored）。

### 3.3 UI 冒烟 `Scripts/ui_smoke.sh`

```bash
bash Scripts/build_app.sh          # 必须先构建 bundle
bash Scripts/ui_smoke.sh [输出目录] # 默认 artifacts/p1c-c7-verify/ui-smoke/
# 可选：
PHOTO_ATELIER_APP=/path/to/PhotoAtelier.app bash Scripts/ui_smoke.sh
UI_SMOKE_FORCE_FAIL_ATTEMPTS=2 UI_SMOKE_FAST=1 bash Scripts/ui_smoke.sh <out>
```

- 行为：启动 `build/PhotoAtelier.app` → 打开合成夹具 → 动态枚举页签 → 逐页签截图 → 对 P1/P1-B/P1-C 折叠区段滚动截图 → 写 `ui-smoke.json`（`status`、`tabCount`、`screenshots`、`scrolledSections`、`attempt`、`appExecutableMTime/SHA256`、`commit`）。
- 失败自动重试 ≤3 次（10s/20s 递增）；`UI_SMOKE_FORCE_FAIL_ATTEMPTS=n` 是**测试钩子**：前 n 次强制失败且不启动应用，用于验证重试策略而不反复弹窗。
- `UI_SMOKE_FAST=1`：跳过 AX 文本断言、用键盘（End/PageDown）滚动，仅截图/页签/哈希证据；用于屏幕可能随时锁定的最终验收。
- 已知坑：AX 树在窗口繁忙时会超时/挂起；已加 12s `alarm` 超时与键盘滚动回退；仍可能偶发 `-1719`（窗口不可用）、`SCROLL_ERROR`、`NOT_VISIBLE`。这些是**脚本/环境问题**，不是应用缺陷。遇到时先看 `run.log`，不要连续重跑刷窗口。

### 3.4 Benchmark `Scripts/benchmark.swift`

```bash
swift build -j 2
BIN="$(swift build --show-bin-path)"
swiftc -I "$BIN" -I "$BIN/CLensfunBridge.build" Scripts/benchmark.swift \
  "$BIN"/PhotoCore.build/*.o "$BIN"/CLensfunBridge.build/CLensfunBridge.c.o \
  -o artifacts/p1c-c7-verify/benchmark/benchmark
artifacts/p1c-c7-verify/benchmark/benchmark [OUTPUT_JSON] [WORK_DIR]
```

- `schemaVersion 4`：P0 阶段 + P1（调色/镜头效果、液化、水印）+ P1-B（matting/background、repairBrush、deliveryPage）+ P1-C（qualityAnalysis、makeup、parallelBatch 串行 vs 并行）。
- 数字是 **debug 对象 + 合成语料 + 本机负载** 的管道成本，**不是 release 吞吐、不是真实画质验收**；不同阶段方法不同（如 C6 真实批量导出 3.49x vs benchmark 合成 pipeline 1.1–1.3x），引用时不要混用。

### 3.5 真实照片验证（本轮布局任务使用）

- 真实图片位置：`/Users/mimi/Desktop/图片/`（13 张，用户授权仅本地验证）。
- **只读导入**，不复制、不提交、不写入仓库；证据截图在 `artifacts/`（gitignored）。
- 新增两个仅测试用 CLI 入口（正常启动无影响）：
  ```bash
  .build/debug/PhotoAtelier --open-folder "/Users/mimi/Desktop/图片" --initial-tab 1
  ```
  - `--open-folder <path>`：启动后直接 `AppModel.loadFolder`，避免驱动 NSOpenPanel 的 AX 自动化（中文路径 + Go-to-folder 易误选父目录）。
  - `--initial-tab <0...7>`：指定初始检查器页签（0 分析/1 基础/2 局部/3 人像/4 追色/5 导出/6 调色/7 证件照），便于按页签截图。
- 截图方法：AppleScript 取窗口 `position/size` → `screencapture -x -R"x,y,w,h" out.png`；截图前必须激活应用（否则会截到其他窗口）。
- **隐私**：真实照片不得复制进仓库、证据不得提交；交接/评审时只描述、不嵌入图片。

---

## 4. 已交付功能与配方版本

### 4.1 批次概览

| 批次 | 内容 | 关键提交 |
|---|---|---|
| P0 | HEIC/HEIF/WebP 导入、拖放/多选；撤销/重做；人脸语义蒙版；人像修复 v1；AI 追色；导出缩放/模板/HEIC；benchmark + ui_smoke | `b12f14f`、`88ac11d`、`2af5ccd` |
| P1 | 调色工具扩展（HSL 8 带/RGB+亮度曲线/颜色分级/镜头暗角+CA）；面部液化美型（7 预设/6 滑杆/手动画笔/背景保护）；水印导出（文字/图片/9 宫格/双版本 `_nowatermark`） | `9920976`、`eae85ef`、`6fe5578`、`f852053`、`2ea97cb` |
| P1-B | 证件照/换背景（人物抠图/背景/阴影/尺寸/裁剪/打印排版）；修复画笔/仿制图章；本地客户交付页（静态 HTML 相册 + 接触表 PDF，离线/无外链/隐私剥离） | `bc69b59`、`6790241`、`ab098e8`、`a2361c7`、`152c9d1` |
| P1-C | AI 挑图/选片（质量分析/自动挑图/评级/废片/筛选/导出跳过）；妆容（唇/眉/腮红/眼影）；性能（有界并行批处理/预览取消/分析降采样） | `75c65d9`、`1ddf0cf`、`73ea89e`、`8dc9d01`、`fb22674` |

### 4.2 处理管线顺序（v13 最终口径）

```
基础影调（曝光/WB/五区 EV/对比/饱和/高光/阴影）
→ 全局几何（旋转/透视/自动水平/Lensfun 畸变）
→ 液化/美型
→ 调色工具（曲线 → HSL → 颜色分级）
→ 镜头效果（暗角/横向色差）
→ 修复画笔/仿制图章
→ 人像修复 v1
→ 妆容（唇/眉/腮红/眼影）
→ AI 追色
→ 背景替换/证件照（裁剪）
→ 局部蒙版/细节
→ LUT
→ 输出色域映射
→ 导出（水印/缩放/模板/交付页）
```

- 顺序约束写在 `PhotoEngine.process` 注释与各批 release notes 中；改动顺序会破坏旧配方像素路径，必须同步回归测试。
- v1–v9 旧路径保持像素兼容；新非中性字段需要对应版本门禁（v10/v11/v12/v13），保存时自动升级；旧配方缺字段走旧路径。

### 4.3 配方版本

| 版本 | 新增字段 |
|---|---|
| v10 | 人像修复、AI 追色、导出扩展（HEIC/缩放/模板） |
| v11 | 调色工具、镜头效果、液化/美型、水印 |
| v12 | 证件照/换背景、修复画笔、客户交付页 |
| v13 | 妆容 |

---

## 5. 代码地图

```
Sources/PhotoCore/          # 纯算法/管线（无 UI），测试目标只依赖它
  PhotoEngine.swift         # 主渲染管线（顺序、validate、report）
  Models.swift              # AdjustmentSettings/Recipe/ExportSettings/各 Report
  PhotoIO.swift             # 解码/编码/原子写入/元数据剥离/导出
  BatchProcessor.swift      # 批量导出、并行并发、清单（manifest v4）
  PhotoSelection.swift      # 文件选择/去重/评级筛选（CullFilter）
  ParallelBatch.swift       # 有界并发执行器（C3/C6）
  QualityAnalysis.swift     # 质量分析（C1）
  BurstGrouping.swift       # 连拍分组（C1）
  MakeupEngine.swift        # 妆容（C2）
  PersonMatting/BackgroundReplacement/IDPhotoLayout.swift
  RepairBrush.swift
  DeliveryGallery.swift
  FaceSemanticAnalysis / PortraitRefinement / LiquifyWarp / FaceReshape
  ColorTools/ColorCurves/ColorGrading/LensEffects
  ReferenceColorMatch / LUT* / OutputGamut / LensCorrection
Sources/PhotoAtelier/       # SwiftUI app
  ContentView.swift         # 主布局：左侧库、预览、presetShelf、右侧 inspector
  AppModel.swift            # 状态、预览 token、批量、挑图、导出
  PhotoEngine 集成面板：AnalysisPanel/Basic/ColorToolsPanel/PortraitRetouchPanel/ReferenceColorPanel/IDPhotoPanel/MaskInspector
  PhotoCanvas.swift         # 画布、液化/修复/蒙版笔迹
  SmokeHarness.swift        # --self-test 入口
Tests/PhotoCoreTests/       # 521 个测试（含各批新增）
Scripts/benchmark.swift     # schemaVersion 4 基准
Scripts/ui_smoke.sh         # UI 冒烟（重试/AX/哈希绑定/fast mode）
Scripts/build_app.sh        # Release 打包
Scripts/verify_app.py       # 包校验
Scripts/prepare_lensfun.py  # Lensfun 原生依赖准备
docs/                       # 各批 release notes / 计划 / 设计 / 差距分析
```

---

## 6. 当前进行中的工作：右侧布局修复（本轮）

### 6.1 问题

真实图片（`/Users/mimi/Desktop/图片/` 13 张，只读导入）在 1400×900 下复现：

1. 右侧检查器 8 个页签横向溢出：Segmented Picker 实测 336pt > 内容宽 278pt，最后一个「证件照」被窗口裁切（`pos=1136,306 size=336×22`，窗口右界 1460，页签右缘 1472）。
2. LUT 风格架标题行溢出：`色彩风格 + LUT COLLECTION + 比较全部 19 种风格` 同行，右侧按钮被裁成「比较全部 19 种风…」；横向滚动无可见 affordance。

### 6.2 设计与改动（已提交 `90e95c2`）

设计文档：[docs/inspector-layout.md](inspector-layout.md)

- `Sources/PhotoAtelier/ContentView.swift`
  - 新增 `InspectorTab` + `InspectorTabBar`（4×2 网格，图标+10.5pt 标签，选中 accent 胶囊/描边），替换原 `Picker(.segmented)`；页签顺序与 `onChange` 清理逻辑不变。
  - `presetShelf` 重构：标题行改为「色彩风格 + 数量徽标 + 紧凑按钮『全部 19 种 ›』」，`ViewThatFits` 窄宽降级为图标按钮；移除占宽的 `LUT COLLECTION` 副标题；卡片 96×60、横向滚动显示滚动条 + 右侧渐隐 + 尾部留白；`ScrollViewReader` 在切换 LUT 时居中。
  - 直方图宽度铺满；页签区上下内边距 18→14pt。
- `Sources/PhotoAtelier/PhotoAtelierApp.swift`
  - 新增测试钩子 `--open-folder <path>`（启动即 `loadFolder`）。
- `ContentView.swift` 另增 `--initial-tab <0...7>`（测试钩子，指定初始页签）。
- 新增 `docs/inspector-layout.md`：问题复现数据、设计规格、验收标准、边界。

### 6.3 验证状态（截至 2026-11-05 13:00）

| 项 | 状态 |
|---|---|
| `swift build -j 2` | exit 0 |
| 修复前基线截图 | 已取得（真实图片 13 张，1400×900；两处裁切可见） |
| 修复后 1400×900「分析」页截图 | 已取得：4×2 页签全部完整可见（`artifacts/layout-real/layout-1400x900.png`） |
| 修复后「基础」页（LUT 风格架）截图 | 已取得：1400×900 与 1120×740 下「色彩风格 19 / 全部 19 种 ›」完整无截断，右侧半卡滚动提示可见（`artifacts/layout-real/tab1-*.png`） |
| 修复后最小窗口 1120×740「证件照」页 | 已取得：8 页签 4×2 网格无裁切（`artifacts/layout-real/tab7-1120x740.png`） |
| 全量测试 | 全量 `make check` 在当前机器负载下卡在既有 128³ LUT 解析测试（见 §7.3）；跳过该测试后 `swift test --skip ...` 结果为 **520 tests / 0 failures，exit 0**（耗时异常长，环境问题）。布局改动只影响 UI 层，PhotoCore 测试不受影响。 |

### 6.4 继续验证的步骤

解锁屏幕后：

```bash
# 修复后「基础」页（LUT 架）1400×900
.build/debug/PhotoAtelier --open-folder "/Users/mimi/Desktop/图片" --initial-tab 1 &
# 激活窗口、设置为 1400x900、截图（见 §3.5 的 AppleScript+screencapture 流程）

# 最小窗口 1120x740 同样截图（基础页、证件照页）
# AX 几何断言：8 个页签 + 「全部 19 种」按钮均落在检查器/中心列矩形内
```

也可复用临时脚本 `/tmp/capture_tab.sh <out> <width> <height> <tab> [input]`（仅本机临时脚本，未提交；内容包括启动、设尺寸、截图、AX dump）。

---

## 7. 已知问题 / 坑（务必先读）

### 7.1 macOS 会话锁屏会阻塞 GUI 验证

- 现象：`CGSSessionScreenIsLocked=1`、`screencapture` 报 `could not create image from display`、AppleScript 取窗口报 `-1719`。
- 影响：`ui_smoke.sh`、真实图片截图全部失败；与代码无关。
- 处理：解锁并保持会话活跃；用 `ioreg -n Root -d1 -a | grep -c CGSSessionScreenIsLocked` 与 `screencapture -x /tmp/probe.png` 先探测。**不要在锁屏下反复重试启动应用**（会打扰用户且无效）。
- 本会话中因此多次失败：ui_smoke 两次授权运行分别遇 matcher 过严/锁屏；布局验证的 LUT 截图也因锁屏未取得。

### 7.2 ui_smoke AX 自动化 flakiness

- AX 树在窗口繁忙时会超时/挂起：已加 12s `alarm` 超时、键盘滚动回退、`UI_SMOKE_FAST=1` 快速模式。
- 失败点可能随机（`NOT_VISIBLE`、`SCROLL_ERROR`、`-1719`）；先看 `run.log`，区分脚本误判 vs UI 缺失，再决定是否修脚本或重跑。
- 证据 JSON 已绑定 app `mtime/SHA256/commit`；最终验收建议用**新输出目录**，避免失败尝试截图混入。

### 7.3 慢测治理完成（128³ LUT 解析）

- **原现象**：`ColorCompatibilityTests.testMaximumDimensionLUTAddressesLastNode` 构造 128³=2,097,152 行 LUT 文本再解析；原 Swift `text.split` + Unicode 字符扫描在调试构建下产生数百万次堆分配，高负载下曾出现 >18min 挂起。
- **治理方案**（已完成并纳入代码库）：
  - `LUTCube.parse` 重构为基于 `text.utf8CString` 字节缓冲区扫描，使用 `strtof` 直接解析数据行数值，避免 210 万行 String 堆分配与 Unicode 索引计算。
  - 在 `testMaximumDimensionLUTAddressesLastNode` 中增加 15s 解析耗时断言（实测 ~9.7s 通过），防止性能劣化回归。
  - 全量 `make check`（521 tests / 0 failures）已在 ~123s 内全绿通过，不再阻塞构建流程。

### 7.4 其他

- `artifacts/`、`build/`、`.build/`、`.agentteam/` 均 gitignored；证据不要提交。
- 真实照片只读、不复制、不提交；最终交付/报告中不嵌入真实照片截图。
- benchmark 数字为 debug 对象 + 合成语料 + 本机负载，不可当 release 吞吐或真实画质验收。
- 评级/废片为**会话状态**，不写配方、不持久化（重启/换库丢失），已在 UI/release notes 标注。
- 应用自检与 ui_smoke 的边界：只覆盖主路径/面板渲染，不覆盖滑杆/曲线/笔迹/GUI 点选等交互。

---

## 8. 未完成 / 立即收尾项

1. **布局修复验收**：✅ 已完成（2026-11-05）：1400×900 与 1120×740 下「基础」「证件照」页真实图片截图均无裁切，8 页签 4×2 网格完整；结果已写入 `docs/inspector-layout.md`。剩余动作：按团队流程把 `fix/inspector-layout` 合并到目标功能分支（需先跑完整 `make check`，建议机器空闲时执行）。
2. **P1-C 最终验收**：`feat/p1c-culling-makeup-perf` 的 11 项均已 approved，`make check`（当时 521/0）、`build_app.sh`、benchmark schemaVersion 4 已通过；唯一缺口是**重建包 ui_smoke 的 exit 0**（因锁屏未取得）。解锁后执行：
   ```bash
   UI_SMOKE_FORCE_FAIL_ATTEMPTS=2 bash Scripts/ui_smoke.sh artifacts/p1c-final/ui-smoke
   ```
   预期 exit 0、8 页签、约 18 张截图、7 个 scrolled 区段、JSON 含 app 哈希/commit。
3. **慢测治理**：✅ 已完成（2026-11-05）：`LUTCube.parse` 重构为快速字节扫描，`testMaximumDimensionLUTAddressesLastNode` 实测 ~9.7s 通过（加设 15s 上限断言），全量 `make check` 521 项测试全绿通过。
4. **ARM / universal 构建**：当前依赖（Lensfun/GLib/PCRE2/libintl）仍为 x86_64，未产出 universal app；Apple Silicon 未实测（见 §7.4）。列为技术债，建议在 P1 收尾前处理（见 §9 P1-G）。

---

## 9. 后续开发计划（Roadmap）

> 路线依据：[像素蛋糕差距分析](pixelcake-gap-analysis.md) §4（P0/P1/P2 分级与价值/可行性/差异化评分）。截至 2026-11-05，**P0 全部、P1 大部分、P1-B、P1-C 已完成**；下表是剩余 P1 收尾 + P2 的详细计划，按依赖与价值排序。

### 9.1 已完成矩阵（用于对照，避免重复开发）

| 差距项 | 状态 | 批次/提交 |
|---|---|---|
| 分发/格式地基（HEIC/HEIF/WebP、拖放/多选、撤销） | ✅ P0 | `feat/p0-gap-closure` |
| 人像 v1（祛斑/中性灰高低频/牙齿/眼白/肤色统一） | ✅ P0 | 同上 |
| AI 追色 v1 | ✅ P0 | 同上 |
| 导出增强（缩放/模板/HEIC/水印双版本/交付页） | ✅ P0/P1-B | `88ac11d`、`ab098e8` |
| 面部液化/美型 | ✅ P1 | `eae85ef` |
| 调色工具扩展（HSL/曲线/分级/暗角+CA） | ✅ P1 | `eae85ef` |
| 水印导出 | ✅ P1 | `6fe5578` |
| 证件照/换背景 | ✅ P1-B | `6790241` |
| 修复画笔/仿制图章 | ✅ P1-B | `6790241` |
| 本地客户交付页（HTML+PDF） | ✅ P1-B | `ab098e8` |
| AI 挑图/选片（质量分析/自动挑图/评级/筛选/导出跳过） | ✅ P1-C | `75c65d9`、`1ddf0cf` |
| 妆容（唇/眉/腮红/眼影） | ✅ P1-C | `75c65d9` |
| 性能（有界并行批处理/预览取消/分析降采样） | ✅ P1-C | `75c65d9`、`1ddf0cf` |
| 项目库 / 历史面板 / 评级持久化 | ✅ P1-D | `feat/p1d-library-persistence` |
| 客户交付增强（多主题/封面大图/离线隐私审计/局域网预览） | ✅ P1-E | `feat/p1e-delivery-enhancement` |
| 妆容与人像精修增强（眼线/睫毛/美瞳/眼神光/高光/修容/v14门禁） | ✅ P1-F | `feat/p1f-makeup-retouch-enhancement` |

### 9.2 剩余 P1（建议按此顺序，2 周左右一个增量）

| 编号 | 项目 | 目标与做法 | 依赖 | 验收 |
|---|---|---|---|---|
| **P1-G** | 性能收尾 + ARM/universal | 24MP 大图批量基准（并行/内存上限）、预览首帧目标、Metal/并行优化（蒙版/LUT/细节 kernel）、Apple Silicon 依赖构建、`lipo -info` 双架构、release 吞吐对比 | C6/C7、P0-6 基准 | 基准对比 P1-C 有可量化改善；输出像素不变；`make check` 全绿；ARM 未实测时明确标注 |
| **P1-H** | 真实照片审美验收体系 | 20–30 张授权样片集（人像/风光/夜景/逆光/高调/暗调）、每功能前后图+人工评分表、固定评审模板；与合成测试分离 | 各功能批 | 评审表随交付归档；不把合成测试当画质验收；样片不入库 |
| **P1-I** | 技术债整理 | 慢测治理（§8.3）、`ui_smoke` AX harness 去 flakiness（更稳的 AX 查询/窗口 id 截图）、证据 JSON 绑定 app commit/hash、文档与实现一致性检查 | 全量 | 全量 `make check` 稳定 <10min；ui_smoke 连续 3 次 exit 0 |

### 9.3 P2（6–12 个月，按需）

| 项目 | 说明 | 前置评估 |
|---|---|---|
| 头发/衣物/宠物 | 发缝/发际线/颅顶/发量/发色；衣物祛皱；宠物美化 | 依赖专用分割模型；需逐项许可/训练数据合规评估；优先用系统 Vision + 自研经典算法 |
| 天空替换 / 纯色背景修复 | 天空分割 + 光照匹配；纯色背景修复（分割 + 频域修复）可先做 | 分割质量与边缘；真实照片评审 |
| 联机拍摄 | `ImageCaptureCore` 或「监视文件夹热导入」；设备兼容复杂 | 先做通用热文件夹；相机型号兼容矩阵 |
| RAW 引擎 / AI 降噪 | 评估 LibRaw（LGPL，动态链接）与 CoreML 降噪模型；RAW 专用高光重建 | 许可/分发合规审查；真机 RAW 样本 |
| 生成式 AI | 本地扩散（Core ML）或云端 API；与「离线隐私」冲突 → 显式可选插件并标注数据去向 | 许可、模型体积、隐私声明 |
| 多端 / 云协作 | 优先 Windows 端 + 简单共享（WebDAV/iCloud Drive 配方同步），不做账号计费 | 独立产品与验收面，投入大 |
| 排版 / 视频 | 不做（与调色/精修主航道无关），导出通用格式交给专业工具 | — |

### 9.4 执行方式与质量门禁（沿用本批流程）

- 每个增量：**计划 → 并行实现（互斥写范围）→ 独立评审 → Lead 质量门禁 → 下一波**；写范围与验收标准先行登记。
- 每波：定向 `swift build`/`swift test --filter`；Lead 在稳定树上跑全量 `make check`；完成项需独立 reviewer 批准。
- 每批收尾：`bash Scripts/build_app.sh`、包校验、重建包 `ui_smoke`（只跑必要次数，避免反复弹窗）、benchmark 对比、README + `docs/pN-release-notes.md` 更新。
- 配方字段变更：同步版本门禁（v14+）、旧配方像素兼容回归、release notes 标注。
- 真实照片：仅授权样片、只读、不入库；评审记录与自动化测试分开。
- 不做/缓做项：云账号计费、排版/视频、未经许可的第三方模型；若引入必须单独立项做合规评估。

---

## 10. 交接检查清单（接手时逐项确认）

- [ ] `git status` 干净、当前分支明确（功能分支，不直接改 `main`）。
- [ ] `.build` 已构建：`swift build -j 2` exit 0。
- [ ] `make check` 或 `swift test` 通过（注意 §7.3 慢测；如跳过须记录命令与原因）。
- [ ] `bash Scripts/build_app.sh` exit 0，`codesign --verify --deep --strict` 与 `python3 Scripts/verify_app.py` exit 0。
- [ ] 需要 UI 验证时，先确认会话解锁（§7.1），再运行 `ui_smoke.sh`（只跑必要次数，避免反复弹窗）。
- [ ] 真实照片验证只用 `--open-folder` 只读导入，不复制/不提交。
- [ ] 改动配方字段/管线顺序时，同步更新 `Models` 版本门禁、兼容测试与 release notes。
- [ ] 交付报告包含：变更文件、分支/提交、验证命令+退出码、已知问题/未验证项、下一步。

---

## 11. 关键命令 / 路径速查

| 用途 | 命令 / 路径 |
|---|---|
| 构建 | `swift build -j 2` |
| 全量测试 | `make check` |
| 定向测试 | `swift test -j 2 --filter <Suite>` |
| 打包 | `bash Scripts/build_app.sh` → `build/PhotoAtelier.app` |
| 包校验 | `python3 Scripts/verify_app.py build/PhotoAtelier.app` |
| 应用自检 | `.build/debug/PhotoAtelier --self-test artifacts/demo/input <out> <evidence>` |
| UI 冒烟 | `bash Scripts/ui_smoke.sh [out]`（先打包；可加 `UI_SMOKE_FAST=1`） |
| 基准 | 见 §3.4；输出默认 `artifacts/p1c-c7-verify/benchmark/benchmark.json` |
| 真实图片验证 | `.build/debug/PhotoAtelier --open-folder "/Users/mimi/Desktop/图片" --initial-tab 1` |
| 证据目录 | `artifacts/`（gitignored，不入库） |
| 架构/管线 | `Sources/PhotoCore/PhotoEngine.swift`、`Models.swift` |
| 主 UI 布局 | `Sources/PhotoAtelier/ContentView.swift` |
| 状态/预览/批量 | `Sources/PhotoAtelier/AppModel.swift` |

---

*本文件随代码提交，供后续开发者/AI Agent 接手查阅；如流程或命令有变化，请同步更新本文件与相关 release notes。*

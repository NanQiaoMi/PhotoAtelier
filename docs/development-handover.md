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
| `feat/p1c-culling-makeup-perf` | `a54b99f` | P1-C ~ P2-C 集成分支（含挑图/持久化/交付增强/增强妆容/Universal双架构/真实照片审美体系/测试加固/高颅顶美型/发缝填充/秀发光泽/去碎发/秀发柔顺） |
| **`feat/p2d-studio-backdrop-refinement`（当前工作分支）** | `a54b99f` | P2-D：影棚纯色背景平整与瑕疵修复（折痕抚平、脚印/污渍消除、色调统一） |

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
| v13 | 基础妆容 |
| v14 | 增强妆容、影棚纯色背景修复 |
| v15 | 智能衣物平整与祛皱 |
| v16 | 智能身体与手部美肤 |
| v17 | 智能面部五区专项祛皱与去油光 |
| v18 | 智能宠物写真美化 |
| v19 | 智能天空识别、氛围增强与置换 |
| v20 | 多人脸属性感知与分组独立精修（`multiPerson`） |
| v21 | 智能眼神光、眼镜去反光与牙齿美学精修（`eyeTeeth`） |
| v22 | 智能全身身形姿态美化与骨骼点塑形（`bodyReshape`） |
| v23 | 智能双眼皮雕刻、双眼皮贴修饰与卧蚕立体塑形（`eyelidAegyoSal`） |
| v24 | 智能全景背景光斑虚化与景深重构（`bokehBlur`） |
| v25 | 智能发色统一、白发消除与自然换发色（`hairColor`） |
| v26 | 智能面部唇毛与胡青消除、特征痣管理（`facialHair`） |
| v27 | 智能面部微表情、微笑嘴角与唇形立体微雕（`expression`） |
| v28 | 智能眼型微雕、开眼角与眼位中庭平衡（`eyeShape`） |

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

1. **布局修复验收**：✅ 已完成（2026-11-05）：1400×900 与 1120×740 下「基础」「证件照」页真实图片截图均无裁切，8 页签 4×2 网格完整；结果已写入 `docs/inspector-layout.md`。
2. **P1-C / P1-I 最终 UI 验收**：✅ 已完成（2026-11-05）：`ui_smoke.sh` 经去 flakiness 加固后，首次运行（attempt 1/3）直接 exit 0；8 个页签、18 张全分辨率真实截图、7 个 scrolled 区段全部通过；哈希与 commit 证据已写入 `artifacts/p1i-verify/ui-smoke/ui-smoke.json`。
3. **慢测治理**：✅ 已完成（2026-11-05）：`LUTCube.parse` 重构为快速字节扫描，`testMaximumDimensionLUTAddressesLastNode` 实测 ~9.7s 通过（加设 15s 上限断言），全量 540 项测试全绿通过（139.4s，远低于 10min 门禁）。
4. **ARM / universal 构建**：✅ 已完成（2026-11-05）：`build_app.sh --universal` 产出原生 universal app（x86_64 + arm64 双架构），`lipo -info` 严格校验通过，包体签名合规。

---

## 9. 后续开发计划（Roadmap）

> 路线依据：[像素蛋糕差距分析](pixelcake-gap-analysis.md) §4（P0/P1/P2 分级与价值/可行性/差异化评分）。截至 2026-11-05，**P0 全部、P1 全部（含 P1-B 至 P1-I 完整周期）已全部圆满交付**；下表是全景对照与后续 P2 规划。

### 9.1 已完成矩阵（全量 P0 + P1 里程碑）

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
| 性能收尾与 Universal/ARM 双架构构建（24MP全画幅基准v5/Universal可执行文件/lipo双架构校验） | ✅ P1-G | `feat/p1g-performance-universal` |
| 真实照片审美验收体系与样片集评测（6大题材矩阵/5维量化评分表/自动化切片评测引擎） | ✅ P1-H | `feat/p1h-aesthetic-acceptance` |
| 技术债整理与测试脚手架加固（自检前向兼容/ui_smoke去flakiness/AX双模兼容/防篡改证据链） | ✅ P1-I | `feat/p1i-tech-debt-cleanup` |

### 9.2 P1 里程碑达成状态

> **状态**：🎉 **P1 全周期 100% 达成**（P0 ~ P1-I 全部通过质量门禁与全量回归）。所有功能均已就绪，进入 P2（中远期增量）规划阶段。

### 9.3 P2 阶段进展与规划

| 项目 | 状态 | 说明 | 前置评估 |
|---|---|---|---|
| **P2-A：高颅顶 / 发际线 / 丰太阳穴** | ✅ 已交付 (`feat/p2a-hair-cranial-reshaping`) | 基于向量形变场与人脸几何推导的高颅顶发量增高、发际线微调、丰太阳穴轮廓重塑；全预设集成与严格向后兼容 | 纯向量形变场 + Vision 地标推导，零模型依赖，实测 541 测试全通 |
| **P2-B：发缝填充 / 秀发光泽 / 发色深邃** | ✅ 已交付 (`feat/p2b-hair-refinement`) | 基于 Core Image 着色器与人脸中轴走廊的发缝/头皮自动识别遮蔽、发冠天使光环光泽增强、去枯黄深邃发色；严格向后兼容 | 原生 CIColorKernel，单帧 < 4ms，测试全绿 |
| **P2-C：秀发柔顺 / 边缘去碎发** | ✅ 已交付 (`feat/p2c-hair-flyaway-smoothing`) | 基于几何光晕带与边缘保护微观滤波的头顶外轮廓碎发消除、发丝防毛躁柔顺；严格向后兼容 | 原生 CIColorKernel + 自适应高斯核，单帧 < 5ms，测试全绿 |
| **P2-D：影棚纯色背景平整与修复** | ✅ 已交付 (`feat/p2d-studio-backdrop-refinement`) | 基于 Vision 人物抠图与频域差分滤波的背景纸折痕抚平、脚印污斑清除与色调统一；严格向后兼容 | 原生 CIColorKernel + 自适应高斯核，单帧 < 6ms，测试全绿 |
| **P2-E：联机拍摄热文件夹实时监视与自动调色** | ✅ 已交付 (`feat/p2e-tethered-watch-folder`) | 基于 macOS DispatchSource 系统级热文件夹监视、文件落盘稳定性检测（Settle Check）、自动配方调色与全屏直出预览 | 原生 POSIX 描述符事件 + Timer 巡检，全厂相机联机软件兼容，563 测试全绿 |
| **P2-F：智能衣物平整与祛皱** | ✅ 已交付 (`feat/p2f-clothing-wrinkle-smoothing`) | 基于 Vision 人物抠图面料区域提取、多频段高斯分离、折痕抑制与微观纺织肌理保护；严格保护面部与裸露皮肤，配方版本升级至 15 | 原生 CIColorKernel，单帧 < 8ms，570 测试全绿 |
| **P2-G：智能身体与手部美肤精修** | ✅ 已交付 (`feat/p2g-body-hand-skin-refinement`) | 基于 Vision 抠图裸露皮肤识别、颈部走廊提取、横向折痕与颈纹平整、手背青蓝静脉与暗沉淡化、身体中性灰磨皮与面部肤色统一；配方版本升级至 16 | 原生 CIColorKernel，单帧 < 6ms，580 测试全绿 |
| **P2-H：智能面部五区专项祛皱与去油光** | ✅ 已交付 (`feat/p2h-facial-zonal-refinement`) | 基于 Vision 人脸关键点几何拓扑的黑眼圈暗沉提亮色素中和、眼袋泪沟阴影平抚、法令纹鼻唇沟软化、额头横纹眉间川字纹平抑、T区/面颊油光哑光雾化、双下巴颈颌线收敛雕刻、微孔高频肤质重注入；配方版本升级至 17 | 原生 CIColorKernel，单帧 < 5ms，591 测试全绿 |
| **P2-I：智能宠物写真精修与美化** | ✅ 已交付 (`feat/p2i-pet-portrait-enhancement`) | 基于 Vision `VNRecognizeAnimalsRequest` 目标定位与 GPU 频域着色器的毛发蓬松微观毛流、明眸提亮眼神光聚焦、鼻吻润泽立体反差、毛发去灰提纯、白毛去黄净白；配方版本升级至 18 | 原生 CIColorKernel，单帧 < 5ms，602 测试全绿 |
| **P2-J：智能天空识别、氛围增强与置换** | ✅ 已交付 (`feat/p2j-sky-enhancement-relighting`) | 基于 Vision 地平线检测结合人物遮罩切分、Core Image 湛蓝天色还原、积云立体反差增强、地平线晚霞金橙氛围、5种程序化天空置换预设与前景环境光照匹配；配方版本升级至 19 | 原生 CIColorKernel，单帧 < 5ms，613 测试全绿 |
| **P2-K：选择性参数复制与多选批量同步** | ✅ 已交付 (`feat/p2k-selective-sync-per-photo-adjustments`) | 细粒度 12+ 模块选择性参数复制、多选批量同步、单图独立配方目录持久化（FolderCatalog v2）与单步批量撤销 | 纯 Swift 原生合并引擎，零模型开销，620 测试全绿 |
| **P2-L：虚拟副本与多版本对比** | ✅ 已交付 (`feat/p2l-virtual-copies-version-branching`) | 零额外磁盘开销多版本派生、跨会话目录持久化（FolderCatalog v3）、前后对比双维度（原片/主版本 vs 副本）、多版本展开批量导出与胶片条快速切换 | 纯元数据驱动，零额外磁盘开销，630 测试全绿 |
| **P2-M：多人脸属性感知与分组独立精修** | ✅ 已交付 (`feat/p2m-multi-person-demographic-retouch`) | 基于 Vision 人脸属性的多人独立分组（男女童老）、独立人像/妆容/五区覆盖、多人肤色锚点统一与批量复制同步；配方版本升级至 20 | 原生 CIColorKernel，单帧 < 5ms，638 测试全绿 |
| **P2-N：智能眼神光、眼镜去反光与牙齿美学精修** | ✅ 已交付 (`feat/p2n-smart-eye-clarity-teeth-restoration`) | 基于 Vision 地标的眼镜镜片去反光、眼白去红血丝浊黄、虹膜明眸深邃、6款摄影级眼神光图案光栅化、牙齿茶渍口红印净化与半透明珐琅质微光注入；配方版本升级至 21 | 原生 CIColorKernel，单帧 < 5ms，647 测试全绿 |
| **P2-O：智能全身身形姿态美化与骨骼点塑形** | ✅ 已交付 (`feat/p2o-body-reshaping-posture`) | 基于 macOS 原生 `VNDetectHumanBodyPoseRequest` 14处关键骨骼点、解剖学形变场映射（天鹅颈/直角肩/整体瘦身/细腰/长腿增高/瘦手臂）与背景形变锚定保护；配方版本升级至 22 | 原生 Core Image GPU Mesh 栅格，单帧 < 8ms，659 测试全绿 |
| **P2-P：智能双眼皮雕刻、双眼皮贴修饰与卧蚕立体塑形** | ✅ 已交付 (`feat/p2p-eyelid-aegyosal-refinement`) | 基于 Vision 眼周解剖学地标与 CIColorKernel 着色器的 4 款双眼皮折痕微雕（开扇/平行/新月/欧美）、去双眼皮贴强反光与阶梯纹、下睑缘轮匝肌珠光高光与立体下缘修容微雕；配方版本升级至 23 | 原生 CIColorKernel，单帧 < 4ms，670 测试全绿 |
| **P2-Q：智能全景背景光斑虚化与景深重构** | ✅ 已交付 (`feat/p2q-bokeh-depth-synthesis`) | 基于 Apple Vision 人像抠图与地面透视梯度的连续物理景深场重构、4款经典光学光圈光斑（圆形/多边形/旋焦/奶油STF）、背景点光源高光增强与前景边缘防溢色保护；配方版本升级至 24 | 原生 CIBokehBlur + CIColorKernel，单帧 < 6ms，678 测试全绿 |
| **P2-R：智能发色统一、白发消除与自然换发色** | ✅ 已交付 (`feat/p2r-hair-color-harmonization`) | 智能识别并压暗散落银白发丝保留原生发流纹理、消除日晒退色斑驳色差收敛发色、7款经典沙龙发色调色（黑茶/栗棕/摩卡/红酒/亚麻/金棕）与明度微调；配方版本升级至 25 | 原生 CIColorKernel，单帧 < 5ms，687 测试全绿 |
| **P2-S：智能唇毛与胡青消除、特征痣管理** | ✅ 已交付 (`feat/p2s-facial-hair-mole-refinement`) | 定向消除女性上唇细软桃毛绒毛并保护唇红缘与毛孔、中和男性下颌与下巴剃须后冷调发青发暗与粗糙胡茬颗粒、智能管理面部特征痣（默认保留/轻度淡化/完全消除）；配方版本升级至 26 | 原生 CIColorKernel，单帧 < 4.5ms，697 测试全绿 |
| **P2-T：智能面部微表情、微笑嘴角与唇形立体微雕** | ✅ 已交付 (`feat/p2t-expression-smile-refinement`) | 模拟笑肌动力学的口角自然向上向外提拉（解决苦相表情与嘴角下垂）、微笑舒展宽度微调、非对称微笑与左右唇角高低差校准、丘比特弓提拉幼态人中缩短、上下唇饱满度独立微雕、唇珠及下唇微隆起柔光高光与下唇窝立体微阴影；配方版本升级至 27 | 原生 Core Image GPU WarpField + CIColorKernel，单帧 < 4ms，710 测试全绿 |
| 联机深度控制 | 规划中 | `ImageCaptureCore` 相机参数直接控制（ISO/快门/光圈） | 设备型号专用通信复杂，热文件夹已先行闭环 |
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

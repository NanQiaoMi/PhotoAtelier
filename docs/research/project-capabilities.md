# 光屿 PhotoAtelier 能力盘点（源码证据版）

**盘点对象**：`/Users/mimi/project/ai调色` —— macOS 13+ 本地照片分析与批量调色应用
**Git 基线**：分支 `codex/portrait-aware-refinement`，HEAD `7f2dcae3a4a87f83348a30fda6a9f3952f2e7a8b`（2026-11-03 22:04 +0800，`feat(portrait): isolate adaptive detail sampling`）
**盘点日期**：2026-11-03
**盘点人**：project-auditor（工作项 W2，verifier 角色）
**用途**：作为「光屿 vs 像素蛋糕」差距矩阵（W1 竞品矩阵 / W3 路线图）的事实底座。本文只陈述本项目实现，不评价竞品。

---

## 0. 盘点方法、证据分级与口径

### 0.1 盘点规模（本次实测）

| 对象 | 数量 | 说明 |
|---|---:|---|
| 算法/IO 源码 | `Sources/PhotoCore/*.swift` 31 个文件 / 10,053 行 | 逐一阅读公开声明与处理入口 |
| UI/harness 源码 | `Sources/PhotoAtelier/*.swift` 23 个文件 / 5,511 行 | 阅读 `AppModel`、`ContentView`、各面板与自检 harness |
| 测试 | `Tests/PhotoCoreTests/*.swift` 26 个文件 / 8,575 行 / **246 个 XCTest 用例** | 本次全量运行通过（见 §13） |
| 设计/边界文档 | `docs/*.md` 16 篇 + `README.md` 82 行 | 抽查关键段落 |
| 历史验收产物 | `artifacts/acceptance-*/` 13 个目录 + `artifacts/evidence/` | 引用 `app-smoke.json`、截图、日志路径 |

### 0.1.1 路径缩写约定（阅读表格前必读）

为避免宽表格重复冗长路径，表内**首次出现用完整路径**，其后同文件用「文件名:行号」缩写；缩写与完整路径的对应关系固定如下，读者可按需还原：

| 表内缩写 | 完整路径 |
|---|---|
| `PhotoIO.swift` / `PhotoEngine.swift` / `Models.swift` / `PhotoAnalysis.swift` / `ColorSceneAnalysis.swift` / `LocalMaskEngine.swift` / `LocalDetailProcessing.swift` / `LUT*.swift` / `BatchProcessor.swift` / `ContentSelection.swift` / `SceneAdaptiveProcessing.swift` / `AutomaticProcessing.swift` / `AutomaticSafety.swift` / `AdaptiveLocalDetail.swift` / `AdaptiveDetailRendering.swift` / `LocalDetailSampling.swift` / `LocalLightGuidance.swift` / `RegionalAdjustmentSuggestions.swift` / `NativeInspection.swift` / `OutputGamut.swift` / `LensCorrection.swift` / `HorizonEstimator.swift` / `TonalCurve.swift` / `FilmLUTCatalog.swift` / `FaceRegionAnalysis.swift` / `ColorHarmony.swift` / `ColorQuality.swift` / `LUTCompatibility.swift` / `CreativeEffects.swift` | `Sources/PhotoCore/<同名文件>` |
| `AppModel.swift` / `ContentView.swift` / `PhotoCanvas.swift` / `MaskInspector.swift` / `StyleBrowserView.swift` / `NativeInspectionView.swift` / 各 `*Panel.swift` / 各 `*SmokeHarness.swift` | `Sources/PhotoAtelier/<同名文件>` |
| `IOTests.swift` / `AnalysisTests.swift` / `BatchTests.swift` / 其它 `*Tests.swift` | `Tests/PhotoCoreTests/<同名文件>` |
| `README:NN` | `README.md` 第 NN 行 |
| `docs/<name>.md:NN` | 仓库内同名文档第 NN 行 |
| `artifacts/...` / `app-smoke #N` | 仓库内验收产物路径；`#N` 为该目录 `app-smoke.json` 的断言序号 |

### 0.2 证据分级（本报告统一口径）

| 级别 | 含义 | 判定方式 |
|---|---|---|
| **L3** | 有应用级自检或真实照片验收记录 | `artifacts/**/app-smoke.json` 断言、实拍报告、截图；**本次未复跑** |
| **L2** | 有自动化测试 | `Tests/PhotoCoreTests` 具体用例；**本次 `swift test` 全量通过** |
| **L1** | 仅代码存在 | 仅能指认源码，无对应测试或验收 |
| **未实现** | 代码与文档均无，或文档明确声明不支持 | grep 反查（无匹配，退出码 1）+ README/docs 明文 |

**口径警告（诚实声明，避免夸大）**：

1. **L2 ≠ 画质验收**：测试绝大多数使用合成图/数值夹具，README:72 明示「合成图只用于重复验证，不代表真实相机画质验收」。
2. **L3 ≠ 交互验收**：应用自检是「应用命令 + 自身 SwiftUI 视图渲染」级别，`app-smoke.json` 的 `note` 明示 *"not a mouse/keyboard interaction test"*。历次 docs 均把真实鼠标键盘、系统文件对话框、退出确认记为**未执行**（CUA 服务 `Sky Computer Use service startup request failed`，见 `docs/validation.md:56`、`docs/portrait-refinement.md:215`、`docs/style-effects.md:82`）。
3. 因此本文不使用「产品级已验收」的说法；最高表述为「有应用级命令自检」。
4. 本次未修改任何实现代码，只在 `docs/research/project-capabilities.md` 写入本报告。

### 0.3 本次实际执行的验证命令

| 命令 | 退出码 | 关键输出 | 归属 |
|---|---:|---|---|
| `swift build -j 2` | 0 | `Build complete! (0.31s)` | 本次运行（类型检查） |
| `swift test -j 2` | 0 | `Executed 246 tests, with 0 failures (0 unexpected) in 102.447 (102.468) seconds` | 本次运行（全量回归） |
| `make check`（Lead 提供日志 `/tmp/pa_check.log`） | 0 | `Executed 246 tests, with 0 failures (0 unexpected) in 126.115 (126.138) seconds` + `EXIT:0` | 本次复核日志存在性与末行 |
| `grep -rh "func test" Tests/PhotoCoreTests/*.swift \| wc -l` | 0 | `247`（含辅助函数 `testCubeText`，真实用例 246） | 本次运行 |
| `git rev-parse HEAD` | 0 | `7f2dcae3a4a87f83348a30fda6a9f3952f2e7a8b` | 本次运行 |
| `grep -rniE "\b(rating\|starRating\|favorite\|keyword\|flagging\|colorLabel)\b" Sources/` | 1 | 无匹配 | 本次运行（反向确认无选片评级） |
| `grep -rniE "\b(heic\|heif\|avif\|webp\|psd\|gif)\b" Sources/` | 1 | 无匹配 | 本次运行（反向确认格式范围） |
| `grep -rniE "undoManager\|registerUndo\|undo\(" Sources/` | 1 | 无匹配 | 本次运行（反向确认无撤销） |
| `grep -rn "onDrop" Sources/` | 1 | 无匹配 | 本次运行（反向确认无拖放导入） |
| `grep -rnE "URLSession\|NSURLConnection\|NWConnection\|CFStream\|WKWebView" Sources/` | 1 | 无匹配 | 本次运行（反向确认无联网代码） |

---

## 1. 能力总览

| 能力域 | 结论 | 状态 | 最强证据 | 详见 |
|---|---|---|---|---|
| 格式支持 | JPEG/PNG/单页 TIFF + 系统 CIRAWFilter 可解 RAW；无 HEIC/AVIF/WebP/PSD/GIF | 🟡 部分实现 | L2 `IOTests` + L3 app-smoke #2/#21/#22 | §2 |
| 分析 | 像素统计 + Vision 人脸/标签 + 九宫格颜色 + 场景策略 + 三方案安全回退 | ✅ 已实现 | L2 `AnalysisTests`/`SceneAdaptiveTests` + L3 app-smoke #3/#4 | §3 |
| 基础调整 | 曝光/白平衡/五区 EV/对比/饱和/高光/阴影 + 旋转/透视/自动水平 | ✅ 已实现 | L2 `EngineTests`/`TonalCurveTests` + L3 app-smoke #12 | §4.1–4.3 |
| 局部调整 | 局部曝光/光色/对比/锐化 + 选区实测 + 建议（不自动改图） | ✅ 已实现 | L2 `LocalMaskTests`/`LocalGuidanceTests` + L3 app-smoke #13/#28–#37 | §4.4–4.5 |
| 蒙版 | 径向/渐变/画笔/亮度范围/颜色范围 + 加/减/交集修边 + 3 类内容候选 | ✅ 已实现 | L2 `LocalMaskTests`/`PortraitDetailTests` + L3 app-smoke #14/#15/#16 | §5 |
| 人像 | 人物/背景/面部皮肤候选 + 保守光影平整/纹理保留/邻域色彩均匀；**无祛痘/美型/妆容/证件照** | 🟡 部分实现 | L2 `AdaptiveDetailTests` 等 + L3 app-smoke #13；docs 明示边界 | §6 |
| 风格/LUT | 13 内置原创 + 5 富士近似 + `.cube` 导入 + 5 输入空间 + 逐图 9 组适配 + 辉光/暗角/颗粒 | ✅ 已实现 | L2 `LUT*`/`CreativeEffectsTests` + L3 app-smoke #7/#8/#18 | §7 |
| 细节 | 局部多尺度细节 + 噪点/纹理方向 + 逐图重测（±0.12 EV 单次上限） | ✅ 已实现 | L2 `AdaptiveDetailTests`/`RegionDetailSamplingTests` | §8 |
| 导出 | JPEG 8-bit / PNG·TIFF 16-bit；sRGB / Display P3；隐私元数据；原子不覆盖 | 🟡 部分实现 | L2 `IOTests` + L3 app-smoke #17/#22/#24 | §9 |
| 批处理 | 串行逐张 + 原子清单 + 坏图隔离 + 取消边界 + 目录隔离 | ✅ 已实现 | L2 `BatchTests` + L3 app-smoke #19/#20/#22–#25 | §10 |
| 配方 | JSON v1–v9，含自动方案/蒙版/细节/颜色保护/逐图适配门禁 | ✅ 已实现 | L2 多文件版本用例 + L3 app-smoke #12/#18 | §11 |
| 选片/协作 | **未实现**（无评级/旗标/关键词/筛选；无云/网络/协作） | ❌ 未实现 | grep 无匹配 + README:3 本地处理 | §12 |

状态图例：✅ 已实现（有测试）｜🟡 部分实现｜❌ 未实现。

---

## 2. 格式支持

### 2.1 输入格式

| 能力 | 状态 | 源码证据 | 测试证据 | 文档/实测证据 | 强度 |
|---|---|---|---|---|---|
| 光栅输入：`jpg/jpeg/jpe/png/tif/tiff` | ✅ | `Sources/PhotoCore/PhotoIO.swift:10-12`（`rasterExtensions`）；`:29-31` 扩展名门禁 | `Tests/PhotoCoreTests/IOTests.swift:35` `testLoadAppliesOrientationAndPreservesEmbeddedColorSpace`；`:187` `testJPEGIsOpaque8BitSRGBWithNormalizedOrientation` | README:3；app-smoke #2 | L2 |
| RAW 候选扫描：39 种扩展名 + `UTType.rawImage` 判定 | ✅ | `PhotoIO.swift:16-21`（`rawExtensions`）；`:304-308`（`isRawCandidate`） | `IOTests.swift:158` `testRasterAndRAWCandidatesScanAndUnsupportedRAWFailsWithoutPreviewFallback` | README:36-37 | L2 |
| RAW 全分辨率解码（系统 `CIRAWFilter`，保留 as-shot 白点与基准曝光，关闭重复曲线/降噪/镜头校正） | ✅ | `PhotoIO.swift:96-185`（`decodeRAW`）；`:51-57` | `AnalysisTests.swift:97` `testRAWDecoderWhitePointIsLabeledAsAnEstimate` | README:36-37；`docs/validation.md:45`（真实 Canon CR2 4272×2848 全尺寸导出）、`:125-130`（RAW 夹具来源）；app-smoke #21/#26/#27 | L3 |
| 只处理单页静态照片；多页 TIFF/动画 PNG 明确拒绝 | ✅（限制） | `PhotoIO.swift:43-45` | — | README:61 | L1 |
| 尺寸上限：单边 ≤ 32768 px 且总像素 ≤ 120 MP，超限明确跳过 | ✅（限制） | `PhotoIO.swift:346-355`（`validateDimensions`） | — | README:60 | L1 |
| 文件夹扫描：可选递归、跳过隐藏文件与符号链接、稳定排序 | ✅ | `PhotoIO.swift:208-263`（`scan`）；`:318-329` | `IOTests.swift:10` `testScanFindsNestedImagesAndSkipsSymbolicLinks` | README:20 | L2 |
| 缩略图（方向正确、最长边受限 1–4096） | ✅ | `PhotoIO.swift:265-297`（`thumbnail`） | `IOTests.swift:10` | README:20 | L2 |
| EXIF 方向归一并写回属性，避免二次旋转 | ✅ | `PhotoIO.swift:23-24`、`:79-91` | `IOTests.swift:35` | README:59 | L2 |
| 嵌入 ICC 经系统色彩管理进入 extended linear sRGB | ✅ | `PhotoEngine.swift:249-259`（`CIContext` 工作空间）；`PhotoIO.swift:8` | `IOTests.swift:35` | README:41 | L2 |
| 镜头校正输入匹配（Lensfun 相机/镜头/焦距/裁切系数） | ✅ | `LensCorrection.swift:23-...`（`LensCorrection`）；`:101`（`correct`） | `LensTests.swift:10`、`:75`、`:96`、`:119` | README:49-50；app-smoke #1/#9 | L3 |

### 2.2 输出格式

| 能力 | 状态 | 源码证据 | 测试证据 | 文档/实测证据 | 强度 |
|---|---|---|---|---|---|
| JPEG（8-bit RGBA8；质量模型允许 0–1、UI 暴露 0.5–1.0；透明区域白底合成） | ✅ | `Models.swift:36-40`、`:266-275`；`PhotoIO.swift:401-405`、`:466-475`；`ContentView.swift:378` | `IOTests.swift:187` | README:27 | L2 |
| PNG / TIFF（16-bit RGBA） | ✅ | `Models.swift:36-40`（标题「16 bit」）；`PhotoIO.swift:406-409` | `IOTests.swift:58` `testPNGAndTIFFExportsAre16BitWithRequestedICCProfile` | README:27；app-smoke #22 | L3 |
| 输出色彩空间：sRGB / Display P3（嵌入对应 ICC） | ✅ | `Models.swift:42-45`；`PhotoIO.swift:379-391`、`:430-435` | `IOTests.swift:58`；`ColorCompatibilityTests.swift:160` | README:41；app-smoke #17 | L3 |
| 隐私元数据：默认剥离；关闭时按白名单保留拍摄参数/GPS 并重写尺寸方向色彩 | ✅ | `Models.swift:266-275`；`PhotoIO.swift:426-438`、`:477-502` | `IOTests.swift:102` `testOptionalMetadataRetentionKeepsSelectedExifButRewritesDimensionsAndColorSpace` | README:59 | L2 |
| 原子安装、绝不覆盖已有文件（`renamex_np` + `RENAME_EXCL`，冲突递增命名） | ✅ | `PhotoIO.swift:440-463`；`BatchProcessor.swift:430-...`（`writeUnique`） | `IOTests.swift:141` `testRepeatedExportNeverOverwritesExistingFile` | README:56 | L2 |
| 目标色域映射（OKLab 保色相/明度压缩 SDR 边界） | ✅ | `OutputGamut.swift:7-72`（`OutputGamutMapper.map`，`:59`） | `ColorCompatibilityTests.swift:160`、`:185` | README:46 | L2 |

### 2.3 格式层面的不支持项（反向 grep 已验证）

- **HEIC / HEIF / AVIF / WebP / PSD / GIF**：`grep -rniE "\b(heic|heif|avif|webp|psd|gif)\b" Sources/` 退出码 1（无匹配）；`PhotoIO.swift:10-12` 只列出 6 种光栅扩展名。→ **未实现**
- **多页 TIFF / 动画 PNG**：主动拒绝，非缺陷（`PhotoIO.swift:43-45`、README:61）。
- **单文件导入 / 拖放导入**：仅目录选择面板（`AppModel.swift:230-237`，`NSOpenPanel` 仅允许目录）；`grep -rn "onDrop" Sources/` 退出码 1。→ **未实现**（导入粒度为「文件夹」）

---

## 3. 分析

| 能力 | 状态 | 源码证据 | 测试证据 | 文档/实测证据 | 强度 |
|---|---|---|---|---|---|
| 像素统计：最长边 384 线性 RGB 采样；P05/P50/P95/P99、近黑/近白/超显示白比例、动态范围、均值、64 桶直方图、饱和度、中性候选通道偏差 | ✅ | `PhotoAnalysis.swift:101-118`（`PhotoAnalyzer`，`:102` `sampleLimit = 384`）；`:22-56`（`PhotoAnalysisMetrics`）；`:252-359`（`measure`） | `AnalysisTests.swift:10`、`:60`；`ColorPipelineTests.swift:85` | README:33 | L2 |
| 本机 Vision：人脸矩形 + 场景/内容标签（含置信度；不可用单独降级，不编造） | ✅ | `PhotoAnalysis.swift:364-...`（`inspectContent`，`:366` `VNDetectFaceRectanglesRequest`、`:374` `VNClassifyImageRequest`）；`:169` | `AnalysisTests.swift:119`；`PortraitDetailTests.swift:188` `testActualVisionDoesNotTurnAnEmptyFrameIntoBackground` | README:34 | L2 |
| 九宫格位置颜色观察（每格亮度/饱和/覆盖/方向；采样最长边 192） | ✅ | `ColorSceneAnalysis.swift:8-43`（`ColorSceneProfile`）；`:45-71`（`ColorSceneRegion`）；`:75-77`（`maximumDimension = 192`）；`:85`（`analyze`） | `ColorSceneTests.swift:10`、`:29`、`:47`、`:69` | README:21；app-smoke #4 | L3 |
| 拍摄元数据：ISO/快门/光圈/焦距/尺寸/位深/ICC/白平衡模式；缺失显式标「未知」 | ✅ | `PhotoAnalysis.swift:397-...`（`makeMetadata`） | `AnalysisTests.swift:88` `testJPEGWithoutCaptureKelvinIsReportedUnknownNotEstimatedFromRGB` | README:35 | L2 |
| 场景/意图评估：10 种意图（自动/人像/风光/夜景/逆光/高调/暗调/柔雾/黑白/保留风格）+ 证据与不确定性 | ✅ | `SceneAdaptiveProcessing.swift:4-22`（`PhotoSceneIntent`）；`:66-...`（`PhotoSceneAssessment`）；`:84`（`SceneAdaptivePlanner.assess`） | `SceneAdaptiveTests.swift:21`、`:59`、`:106`、`:128`、`:216`、`:239`、`:271` | README:22；`docs/scene-adaptive.md`；app-smoke #11 | L3 |
| 三个自动方案（balanced/bright/soft）+ 逐张重算 + 手动差值只叠加一次 | ✅ | `PhotoAnalysis.swift:593`（`choices`）；`AutomaticProcessing.swift:26-49`（`resolve`） | `AutomaticTests.swift:6`、`:34`；`AutomaticSafetyTests.swift:280` | README:22；app-smoke #3/#6 | L3 |
| 自动增量安全回退：以实际渲染的 SDR 越界/黑位比例 0.5% 为门槛逐级减弱 | ✅ | `AutomaticSafety.swift:7-...`（`AutomaticSafetyReport`）；`:27`（`AutomaticSafetyEvaluator`）；`:28`（`maximumIntroducedFraction = 0.005`） | `AutomaticSafetyTests.swift:108`、`:129`、`:246`、`:280`；`TonalCurveTests.swift:300` | README:58；`docs/automatic-safety.md`；app-smoke #5/#20 | L3 |
| 分析结果可另存 JSON | ✅ | `AppModel.swift:729-739`（`saveAnalysis`） | — | README:21 | L1 |
| 人脸区域亮度测量（仅可信框，非皮肤分割/身份识别） | ✅ | `FaceRegionAnalysis.swift:7-58`（`FaceRegionAnalyzer.measure`） | `SceneAdaptiveTests.swift:324`、`:346` | README:34 | L2 |

**分析层面的已知边界（docs 明示）**：规则支持度不是校准正确率（README:34）；不能从成片 RGB 反推拍摄 Kelvin（README:35）；RAW 高光指标基于解码后线性 RGB、不代表 sensel 饱和（README:37、`PhotoAnalysis.swift:166-168`）。

---

## 4. 基础与局部调整

### 4.1 全局基础

| 能力 | 状态 | 源码证据 | 测试证据 | 文档/实测证据 | 强度 |
|---|---|---|---|---|---|
| 曝光（线性光乘法，±8 EV） | ✅ | `PhotoEngine.swift:346-352`；`:263-317`（`validate`，`:264` 曝光 ±8） | `EngineTests.swift:101` `testOneEVDoublesLinearExposure` | README:42 | L2 |
| 色温/色调（±1 归一化 → CITemperatureAndTint） | ✅ | `PhotoEngine.swift:361-363`、`:708-721` | `EngineTests.swift:117` `testPositiveWarmthAddsWarmColorGloballyAndInsideMask` | README:42 | L2 |
| 自动曝光（旧式 ±0.35 EV，显式开关）与自动白平衡（±10% 近中性增益，不足则跳过） | ✅ | `PhotoEngine.swift:339-360`；`:620-692`（`ImageStatistics`） | `EngineTests.swift:134`、`:146`；`AutomaticSafetyTests.swift:45` | README:42 | L2 |
| 对比度/饱和度/高光/阴影（Core Image kernel） | ✅ | `PhotoEngine.swift:16-30`（`localToneKernel`）；`:366-390` | `EngineTests.swift:101`；`ColorPipelineTests.swift:72` | README:23 | L2 |
| 五区 EV（黑调/阴影/中间调/高光/白调，Hermite 单调曲线，纯黑不凭空恢复） | ✅ | `TonalCurve.swift:7-28`（`TonalCurveSettings`）；`:30-...`（引擎，`:152` `apply`） | `TonalCurveTests.swift:30`、`:46`、`:80`、`:110`；`:330` | README:23；`docs/targeted-tones.md`；app-smoke #12 | L3 |
| 饱和度新增色度保护（全局） | ✅ | `PhotoEngine.swift:382-390`（`ColorHarmonyEngine.protect`） | `ColorPipelineTests.swift:72`、`:94` | README:46 | L2 |

### 4.2 几何与镜头

| 能力 | 状态 | 源码证据 | 测试证据 | 文档/实测证据 | 强度 |
|---|---|---|---|---|---|
| 旋转（±45°）与垂直/水平透视（±0.3），安全裁切、保持画布尺寸 | ✅ | `PhotoEngine.swift:280-282`（范围校验）、`:399-407`、`:887`（`rotate`）、`:901`（`applyPerspective`） | `EngineTests.swift:231` `testRotationAndPerspectiveKeepOpaqueImageEdges` | README:48 | L2 |
| 自动水平校正（Hough 显著水平线，不可靠时跳过） | ✅ | `HorizonEstimator.swift:6-60`；`PhotoEngine.swift:396-398`、`:855`（`autoStraighten`） | `EngineTests.swift:249` `testAutoStraightenLevelsARealPixelLineAndKeepsOpaquePixels` | README:48 | L2 |
| Lensfun 标定畸变校正 + 安全缩放（唯一匹配才自动应用；歧义/信息不足跳过；可手动选配置） | ✅ | `LensCorrection.swift:23-...`、`:101`；`PhotoIO.swift:66-71` | `LensTests.swift:10`、`:75`、`:96`、`:119`、`:129` | README:49-50；`docs/lensfun-api.md`；app-smoke #1/#9 | L3 |
| 镜头映射 40 MP 上限（超限保留照片、跳过镜头校正并告警） | ✅（限制） | `LensCorrection.swift:26`（`maximumMapPixels = 40_000_000`） | — | README:50 | L1 |

### 4.3 局部调整

| 能力 | 状态 | 源码证据 | 测试证据 | 文档/实测证据 | 强度 |
|---|---|---|---|---|---|
| 局部曝光/饱和度/暖度/色调/对比/高光/阴影/锐化 + 高光保护 + 色彩保护 | ✅ | `Models.swift:66-135`（`LocalMask` 字段）；`LocalMaskEngine.swift:389`（`apply`）；`PhotoEngine.swift:589-597` | `LocalMaskTests.swift:474`（高光保护）、`:505`（色彩保护）；`EngineTests.swift:165`/`:186`/`:202` | README:24；`docs/masks.md` | L2 |
| 局部调整阶段：LUT 前 / LUT 后（新蒙版默认 LUT 前；旧配方保持 LUT 后） | ✅ | `LocalMaskEngine.swift:49-58`（`MaskStage`）；`PhotoEngine.swift:453-461`、`:504-516` | `LocalMaskTests.swift:366` `testBeforeLookAndAfterLookStagesProduceDifferentPixelsWithSameLUT` | README:47；`docs/masks.md` | L2 |
| 选区固定参考：亮度/颜色范围取自全局+几何后、局部与 LUT 前，避免自我反馈漂移 | ✅ | `PhotoEngine.swift:410-412`、`:564-573`（`maskReferenceImage`） | `LocalMaskTests.swift:231` `testMaskReferenceStaysGlobalOnlyAcrossMultipleLocalMasks` | README:47 | L2 |
| 选区实测与建议（覆盖率、线性分位、P99 通道余量、限幅 ±0.6 EV、纯黑/纯白/暗调分别限制） | ✅ | `LocalMaskEngine.swift:60-83`（`MaskInspection`）、`:515`（`inspect`）；`LocalLightGuidance.swift:28-130` | `LocalGuidanceTests.swift:13`、`:32`、`:62`、`:81`、`:142`；`LocalMaskTests.swift:442` | README:24；`docs/local-guidance.md`；app-smoke #28–#37 | L3 |
| 九宫格局部光线建议（定位网格，点击后建可编辑蒙版，不自动改图） | ✅ | `RegionalAdjustmentSuggestions.swift:17-106`（`RegionalAdjustmentAnalyzer.suggestions`） | `RegionalSuggestionTests.swift:13`、`:33`、`:50`；`LocalGuidanceTests.swift:142` | README:24；app-smoke #28/#29/#31 | L3 |

---

## 5. 蒙版

| 能力 | 状态 | 源码证据 | 测试证据 | 文档/实测证据 | 强度 |
|---|---|---|---|---|---|
| 5 类蒙版：径向 / 渐变 / 画笔 / 亮度范围 / 颜色范围 | ✅ | `Models.swift:47-58`（`MaskKind`）；`LocalMaskEngine.swift:300`（`coverage`） | `EngineTests.swift:165`/`:202`；`LocalMaskTests.swift:212`（亮度范围）、`:305`（颜色范围） | README:24；`docs/masks.md` | L2 |
| 修边合成：加选 / 减选 / 交集（列表顺序、半透明羽化平滑过渡） | ✅ | `LocalMaskEngine.swift:5-15`（`MaskCombineMode`）；`:17-36`（`MaskComponent`） | `LocalMaskTests.swift:183` `testBrushComponentsAddSubtractAndIntersectAtRealPixelBoundaries` | README:24；`docs/masks.md` | L2 |
| 反选、强度（opacity）、启用开关、羽化、可编辑控制点 | ✅ | `Models.swift:66-135`；`LocalMaskEngine.swift:85-...`（`LocalMaskValidator`） | `LocalMaskTests.swift:143`、`:160`、`:322`、`:341`、`:404` | `docs/masks.md` | L2 |
| 实际覆盖预览（含羽化/范围/反选/强度；显示透明度不影响导出） | ✅ | `AppModel.swift:103-106`（`maskOverlayImage`/`maskInspection`）、`:950-1001` | `LocalMaskTests.swift:133`、`:143` | README:24；app-smoke #13/#14 | L3 |
| 内容候选蒙版：人物 / 背景 / 面部皮肤（Vision 人物分割 + 地标/颜色候选；检测不足两者都跳过） | ✅ | `ContentSelection.swift:7-19`（`ContentSelectionTarget`）、`:54-...`（`ContentSelectionAnalyzer.analyze`，`:82`） | `PortraitDetailTests.swift:188`、`:229`、`:256`、`:274` | README:25；`docs/portrait-refinement.md` | L2 |
| 数量/资源上限：≤16 蒙版、≤64 修边组件、总笔迹点 ≤32768；栅格最长边 ≤2048 | ✅（限制） | `PhotoEngine.swift:288-316`；`LocalMaskEngine.swift:300-...` | `LocalMaskTests.swift:544` `testInvalidRangesKindsPointCountsAndDuplicateIDsAreRejected` | README（`docs/masks.md` 兼容边界）；`PhotoEngine.swift:14` | L2 |

---

## 6. 人像

| 能力 | 状态 | 源码证据 | 测试证据 | 文档/实测证据 | 强度 |
|---|---|---|---|---|---|
| 面部皮肤候选（Vision 地标轮廓内、本图脸颊颜色+相对亮度、排除眼眉嘴；最多 16 张脸） | ✅ | `ContentSelection.swift:54-...`（faceSkin 路径，`:104-120` 人物证据门禁） | `PortraitDetailTests.swift:188`、`:256`；`AdaptiveDetailTests.swift:179` | README:25；`docs/portrait-refinement.md:20-35` | L2 |
| 人物/背景候选（人脸/身体检测 + `VNGeneratePersonSegmentationRequest`；低噪声不生成背景反选） | ✅ | `ContentSelection.swift:104-120`（`hasHumanEvidence`、`runPersonSegmentation`） | `PortraitDetailTests.swift:188`、`:229`、`:256` | README:25；app-smoke #13 | L3 |
| 保守人像细节：光影平整 / 细纹理保留 / 邻域色彩均匀（局部、alpha 加权、单次亮度 ±0.12 EV） | ✅ | `LocalDetailProcessing.swift:5`（明确「does not detect blemishes」注释）、`:6-56`（`LocalDetailSettings`）、`:59`（`LocalDetailEngine`）；`docs/portrait-refinement.md:48`（±.12 EV） | `PortraitDetailTests.swift:19`、`:35`、`:61`、`:112`、`:150`、`:163`；`AdaptiveDetailTests.swift:550` | README:25、`:78`；`docs/portrait-refinement.md` | L2 |
| 「轻度精修起点」一键参数（.25/.90/.12），保留已有局部参数 | ✅ | `AppModel.swift:886-925`（`addPortraitRefinement`、`applyNaturalDetailStartingPoint`） | `PortraitDetailTests.swift:163` | README:25 | L1 |
| 逐图人像细节适配（按有效选区实测，方向：自动/皮肤纹理/真实层次/暗部噪点） | ✅ | `AdaptiveLocalDetail.swift:4-24`（`LocalDetailIntent`）、`:59-...`（`AdaptiveLocalDetailAnalyzer.analyze`）；`PhotoEngine.swift:432-452` | `AdaptiveDetailTests.swift:19`、`:179`、`:252`、`:294`、`:354`、`:391`、`:522`、`:616` | README:78-82；app-smoke #13 | L3 |

**人像能力边界（docs 明文，非本报告推断）**：

- 「不含自动祛痘/去痣、美型、身体皮肤分割、发丝解析、骨相塑造、生成纹理，也不声称完整复刻」（`docs/portrait-aware-refinement.md:31`）
- 「尚无自动祛痘、身体/头发专用模型、美型、妆容或生成背景，不等同于完整商业精修」（`docs/portrait-refinement.md:68`）
- 「无法识别痘痣，不是自动祛瑕疵」（README:25）
- 「不含生成式细节恢复、自动祛痘、美型或背景生成」（`docs/adaptive-detail.md:182`）

---

## 7. 风格与 LUT

| 能力 | 状态 | 源码证据 | 测试证据 | 文档/实测证据 | 强度 |
|---|---|---|---|---|---|
| 内置风格库：13 个原创/既有 LUT（5 旧 + 8 新）+「原色」，分 5 类（自然/人像/电影/风光/黑白），可搜索标签 | ✅ | `LUTCube.swift:3-19`（`LUTPresetGroup`）、`:21-46`（`LUTPreset`）、`:331-355`（13 个 `makePreset`/`makeCreativePreset` 调用） | `LUTCatalogTests.swift:18`、`:52`、`:88`、`:130`、`:159`；`LUTTests.swift:67` | README:23；`docs/style-effects.md:1-8`；app-smoke #7 | L3 |
| 5 个署名富士风格近似（Classic Chrome/ASTIA/Classic Neg/ETERNA/ACROS，33³ 内存生成，MIT 署名与固定 commit） | ✅ | `FilmLUTCatalog.swift:23-...`（`FilmLUTCatalog`，`:24` `lutSize = 33`、`:25-34` provenance、`:37` `presets`、`:56` `makeProfiles`） | `FilmLUTCatalogTests.swift:13`、`:40`、`:58`、`:78` | README:23；`docs/adaptive-film-luts.md`；`THIRD_PARTY_NOTICES.md` | L2 |
| 标准 3D `.cube` 解析：RGB 三列、2–128 阶、完整行数、有限数值、`DOMAIN_MIN/MAX` 或 `LUT_3D_INPUT_RANGE`；拒绝 1D/shaper/alpha 第四列 | ✅ | `LUTCube.swift:50-91`（`load`）、`:93-...`（`parse`）、`:59-60`（128 阶/128 MiB 上限） | `LUTTests.swift:5`、`:16`、`:33`、`:39`、`:49`、`:56`；`ColorCompatibilityTests.swift:317`、`:328` | README:44 | L2 |
| 5 种 LUT 输入空间：sRGB / linear sRGB / Display P3+sRGB 曲线 / Rec.709 纯 Gamma 2.4 / Rec.709 摄像机 OETF | ✅ | `Models.swift:23-34`（`LUTColorSpace`）；`PhotoEngine.swift:32-106`（编码/解码 kernel） | `ColorCompatibilityTests.swift:80`、`:135`；`EngineTests.swift:44` | README:43 | L2 |
| LUT 保护：域外平滑降权、亮度保持、肤色/中性保护、色域压缩 | ✅ | `PhotoEngine.swift:187-247`（`lookKernel`）；`:463-501` | `EngineTests.swift:64`、`:85`；`ColorCompatibilityTests.swift:17` | README:45-46 | L2 |
| 显式三线性查表（稀疏表/大表节点保真，避免后端插值差异） | ✅ | `PhotoEngine.swift:155-185`（`lutSampleKernel`）、`:763-796` | `ColorCompatibilityTests.swift:17`、`:35`、`:66` | README:43 | L2 |
| LUT 表格诊断（灰阶染色、亮度反转、域外输出、低采样） | ✅ | `LUTCompatibility.swift:15-56`（`LUTCompatibilityInspector.inspect`） | — | README:45 | L1 |
| 逐图 LUT 适配：识别面部皮肤/题材候选，9 组强度×保护候选试渲染，按约束选择并报告原因 | ✅ | `LUTAdaptation.swift:8-15`（`AdaptiveLUTSettings`）、`:74-96`（报告）、`:105-...`（引擎）、`:180`（`apply`）；`PhotoEngine.swift:491-500` | `LUTAdaptationTests.swift:20`、`:56`、`:124`、`:166`、`:226`、`:265`、`:322`、`:371`、`:388`、`:401` | README:23；`docs/adaptive-film-luts.md`；app-smoke #8 | L3 |
| 质感滤镜：高光辉光 / 柔和暗角 / 胶片颗粒（默认关闭、可一键归零、独立于 LUT 叠加） | ✅ | `CreativeEffects.swift:6-40`（`CreativeEffectsSettings`）、`:156`（`apply`）；`PhotoEngine.swift:519-522` | `CreativeEffectsTests.swift:19`、`:32`、`:46`、`:61`、`:85`、`:112`、`:136`、`:155`、`:197`、`:210` | README:23；`docs/style-effects.md`；app-smoke #7 | L3 |
| 自定义 LUT 导入（后台多选、进度、停止、单文件错误隔离、48 MB 上限、写入本机资料库不覆盖） | ✅ | `AppModel.swift:288-343`（`importLUT`/`importLUTFiles`/`cancelLUTImport`） | `IOTests.swift:158`（同类文件扫描/坏文件隔离） | `docs/style-effects.md:6`；app-smoke #7 | L3 |

**风格/LUT 边界（docs 明文）**：仅接受输入输出同一 RGB 空间+同一传递函数的创意 LUT；Log/ACES/HDR/跨色域不能仅改一个选项直接使用；不从文件名猜用途；不支持 1D shaper/HaldCLUT（README:44、`docs/opensource-research.md:47-50`、`docs/adaptive-film-luts.md`）。

---

## 8. 细节

| 能力 | 状态 | 源码证据 | 测试证据 | 文档/实测证据 | 强度 |
|---|---|---|---|---|---|
| 局部细节控件：光影平整 / 细纹理保留 / 邻域色彩均匀 / 噪点减弱 / 纹理增强 | ✅ | `LocalDetailProcessing.swift:6-56`（`LocalDetailSettings`）、`:59`（`LocalDetailEngine`）、`:542`（`apply`） | `PortraitDetailTests.swift:19`、`:35`、`:61`、`:112`；`AdaptiveDetailTests.swift:522`、`:616` | README:80-82；`docs/adaptive-detail.md` | L2 |
| 逐图/逐选区细节适配：有效覆盖内取样、按面积调整平整尺度、噪点候选估计、歧义时保守停用 | ✅ | `AdaptiveLocalDetail.swift:26-57`（测量/计划）、`:59-...`（`analyze`，最多 9 个 96px 原生分辨率 patch）；`AdaptiveDetailRendering.swift:7`、`:101`（`apply`）；`PhotoEngine.swift:432-452` | `AdaptiveDetailTests.swift:19`、`:55`、`:82`、`:116`、`:136`、`:160`、`:252`、`:294`、`:354`、`:391`、`:422`、`:470` | README:78-82；`docs/adaptive-detail.md`；`docs/portrait-aware-refinement.md` | L2 |
| 选区约束采样（背景不参与平整/噪点估计） | ✅ | `LocalDetailSampling.swift:7-...`（`LocalDetailSamplingPlan`） | `RegionDetailSamplingTests.swift:19`、`:85`、`:116`、`:147`、`:189`、`:245`、`:293`、`:342`、`:378` | `docs/adaptive-detail.md` | L2 |
| 原尺寸检查：64–1024 px 区域，完整原图流程对比「基础」与「当前完整效果」 | ✅ | `NativeInspection.swift:7-42`（`NativeInspectionRegion`）、`:55-132`（`NativeInspectionRenderer.render`）；`AppModel.swift:805-836` | `NativeInspectionTests.swift:11`、`:31`、`:45`、`:67`、`:82`、`:98`、`:150`；`StyleWorkflowTests.swift:113` | README:26；`docs/native-inspection.md`；app-smoke（native-inspection 验收目录） | L3 |
| 细节单次变化限幅（±0.12 EV）、半透明 alpha 加权、SDR 通道余量、扩展线性负值/高光不硬截 | ✅ | `LocalDetailProcessing.swift`（`refineLocalDetail` kernel）；`docs/portrait-refinement.md:48` | `AdaptiveDetailTests.swift:550`、`:669`、`:700`；`PortraitDetailTests.swift:61` | `docs/portrait-refinement.md` | L2 |

**细节边界（docs 明文）**：不能可靠区分皮肤毛孔、胶片颗粒、压缩与织物纹理；无生成式细节恢复；普通预览按缩图测量、原尺寸导出会重测，强度可能不同（`docs/adaptive-detail.md:176-183`、README:82）。

---

## 9. 导出

| 能力 | 状态 | 源码证据 | 测试证据 | 文档/实测证据 | 强度 |
|---|---|---|---|---|---|
| 独立输出目录（输入/输出不得相同或互相包含） | ✅ | `BatchProcessor.swift:29-31`、`:38-41` | `BatchTests.swift:50` `testRejectsInputOutputOverlapBeforeCreatingOutput` | README:54 | L2 |
| 格式/色彩空间/质量/后缀/隐私开关设置 | ✅ | `Models.swift:266-275`（`ExportSettings`）；`ContentView.swift:363-425`（导出面板） | `IOTests.swift:58`、`:102`、`:187` | README:27 | L2 |
| 编码前完整渲染再交给 ImageIO（避免延迟图分块求值差异） | ✅ | `PhotoIO.swift:411-417` | `ColorPipelineTests.swift:49` `testPreviewTargetPixelsAgreeWithSixteenBitExport` | `docs/adaptive-film-luts.md`（TIFF 复读差 0/255） | L2 |
| 原子写入、同名递增、绝不覆盖原片或已有导出 | ✅ | `PhotoIO.swift:440-463`；`BatchProcessor.swift:430-...` | `IOTests.swift:141`；`BatchTests.swift:64` | README:56 | L2 |
| 输出色域映射 + 最终颜色质量报告 | ✅ | `OutputGamut.swift:59`（`map`）；`ColorQuality.swift:7-...`、`:24`（`inspect`） | `ColorCompatibilityTests.swift:160`、`:185`；`ColorPipelineTests.swift:11`、`:36` | README:46、`:57` | L2 |
| 批量导出入口与进度/结果展示 | ✅ | `AppModel.swift:758-803`（`startBatch`/`consume`/`cancelBatch`）；`ContentView.swift:414-427` | `BatchTests.swift:7` | README:27；app-smoke #22 | L3 |

**导出层面的不支持项（代码核对）**：`ExportSettings` 只有 `format/colorSpace/jpegQuality/recursive/suffix/stripMetadata`（`Models.swift:266-275`），**没有**输出缩放、水印、打印配置、批量重命名模板、HEIC/AVIF/PSD/WebP、AdobeRGB/ProPhoto/CMYK。→ **未实现**（`grep -rniE "\b(watermark|resize)\b" Sources/PhotoCore/` 仅命中缩略图 `maxDimension`，非导出功能）。

---

## 10. 批处理

| 能力 | 状态 | 源码证据 | 测试证据 | 文档/实测证据 | 强度 |
|---|---|---|---|---|---|
| 串行逐张处理（限制内存；取消以完整单张为边界，已完成结果保留） | ✅ | `BatchProcessor.swift:9-...`（`run`）、`:66-140`（串行循环） | `BatchTests.swift:7`、`:92` | README:55 | L2 |
| 单张失败写入报告并继续下一张（坏图隔离） | ✅ | `BatchProcessor.swift:77-122`（`autoreleasepool` 内 `catch` 转 `.failure`） | `BatchTests.swift:64` `testBadPhotoIsRecordedAndLaterPhotosStillComplete` | README:55；app-smoke #25 | L3 |
| 每次运行生成 `batch-<UUID>.json` 原子清单：不可变配方快照 + 逐张结果/报告/警告 | ✅ | `BatchProcessor.swift:43-54`、`:474-...`（清单读写） | `BatchTests.swift:7`、`:92`、`:118` | README:57；app-smoke #22/#23 | L3 |
| 逐张自动方案：重新分析完整原图并记录该图实际参数与场景策略 | ✅ | `BatchProcessor.swift:88-99`；`AutomaticProcessing.swift:26-49` | `BatchTests.swift:7`；`AutomaticTests.swift:6`；`SceneAdaptiveTests.swift:447` | README:29、`:58`；app-smoke #19 | L3 |
| 显式 LUT 引用缺失时明确失败，不静默回退 | ✅ | `BatchProcessor.swift:238-...`（`validateRecipeLUT`） | `BatchTests.swift:135` `testExplicitLUTReferenceCannotSilentlyFallBackWhenMissing` | README:29 | L2 |
| 目录解析后重叠复查、符号链接防护、逐输出路径边界检查 | ✅ | `BatchProcessor.swift:24-41`；`PhotoIO.swift:208-263` | `BatchTests.swift:50`；`IOTests.swift:10` | README:54 | L2 |

**批处理边界**：串行是设计选择而非缺陷（README:55）；**没有**并行处理、断点续跑、跨重启队列、后台守护进程。取消在同步 GPU/RAW 解码阶段不能立即中断（`docs/style-effects.md`、`docs/native-inspection.md`）。

---

## 11. 配方

| 能力 | 状态 | 源码证据 | 测试证据 | 文档/实测证据 | 强度 |
|---|---|---|---|---|---|
| JSON 配方保存/载入（含自动方案、意图、五区 EV、蒙版修边、细节、颜色保护、导出设置） | ✅ | `Models.swift:277-328`（`Recipe`）；`AppModel.swift:1090-1131`（`saveRecipe`/`loadRecipe`） | `StyleWorkflowTests.swift:28`；`ColorCompatibilityTests.swift:288` | README:29 | L2 |
| 版本 v1–v9 兼容与门禁：旧版缺新字段保留旧路径；含新功能不能伪装旧版本 | ✅ | `Models.swift:278-279`（`version = 9`）、`:293-327`（`validateVersion`） | `ColorCompatibilityTests.swift:288` `testBatchAcceptsRecipeVersionsOneThroughNineAndRejectsTen`；`LUTAdaptationTests.swift:56`；`StyleWorkflowTests.swift:28`；`AdaptiveDetailTests.swift:762`；`PortraitDetailTests.swift:163`；`TonalCurveTests.swift:267`；`LocalMaskTests.swift:99`；`AutomaticTests.swift:34` | README:29；app-smoke #12/#18 | L3 |
| 批处理清单内嵌不可变配方快照（可追溯当次实际设置） | ✅ | `BatchProcessor.swift:45-54` | `BatchTests.swift:7`、`:92` | README:57 | L2 |
| 自动方案「基线/参考/手动差值只叠加一次」语义 | ✅ | `AutomaticProcessing.swift:26-49`（`resolve`）、`:52-61`（`copyBasicAdjustments`） | `AutomaticTests.swift:6`；`AutomaticSafetyTests.swift:280`；`TonalCurveTests.swift:330` | README:22、`:29` | L2 |

**配方边界**：自定义 LUT 只记录路径/标识，跨机器需一并复制 LUT 文件（README:29、`AppModel.swift:1090-1100`）；旧自动配方重算时采用**当前算法**，不能固定旧算法结果（README:29）。

---

## 12. 限制：未实现与部分实现（逐条对照 README/docs）

> 本节是 W3 差距矩阵的直接输入。每条给出「状态 + 证据位置 + README/docs 原文位置」。
> 「未实现」的判定优先使用 grep 反向验证（退出码 1 = 无匹配）。

### 12.1 完全未实现

| 项 | 证据（反向验证/文档） | 说明 |
|---|---|---|
| 选片 / 评级 / 旗标 / 关键词 / 颜色标签 / 筛选 | `grep -rniE "\b(rating\|starRating\|favorite\|keyword\|flagging\|colorLabel)\b" Sources/` → 退出码 1 | 只有文件列表与单选（`AppModel.swift:53-56`、`ContentView.swift:148`），无挑片工作流 |
| 云同步 / 协作 / 账号 / 分享 / 联网处理 | `grep -rnE "URLSession\|NSURLConnection\|NWConnection\|CFStream\|WKWebView" Sources/` → 退出码 1；README:3「照片处理和内容识别无需联网」 | 纯本地单机应用 |
| 撤销 / 重做 | `grep -rniE "undoManager\|registerUndo\|undo\(" Sources/` → 退出码 1 | 参数与蒙版操作不可回退（可重置/删除单蒙版） |
| 拖放导入 / 单文件导入 | `grep -rn "onDrop" Sources/` → 退出码 1；`AppModel.swift:230-237` 仅目录面板 | 导入粒度为文件夹 |
| HEIC / HEIF / AVIF / WebP / PSD / GIF 输入 | `grep -rniE "\b(heic\|heif\|avif\|webp\|psd\|gif)\b" Sources/` → 退出码 1；`PhotoIO.swift:10-12` | 仅 6 种光栅扩展名 + RAW |
| 自动祛痘/祛斑/去痣、美型/液化/瘦脸、妆容、证件照、换背景、生成式细节恢复 | `docs/portrait-aware-refinement.md:31`；`docs/portrait-refinement.md:68`；`docs/adaptive-detail.md:182`；README:82 | 文档明示不在本版范围 |
| 身体/头发/完整皮肤语义分割 | `docs/portrait-refinement.md:68`、`docs/color-harmony.md:230` | 仅人物/背景/面部候选 |
| Log / ACES / HDR / HaldCLUT / 1D shaper / 跨色域 LUT 工作流 | README:44；`docs/opensource-research.md:47-50`；`docs/adaptive-film-luts.md` | `.cube` 仅同空间同传递函数创意 LUT |
| 镜头暗角 / 横向色差校正 | README:50；`docs/opensource-research.md:54` | 只启用畸变+安全缩放 |
| 专用 RAW 高光重建 / 去马赛克选型 / AI 降噪 / 逐 sensel 分析 | README:37；`PhotoAnalysis.swift:166-168` | 依赖系统 CIRAWFilter 默认解码 |
| LibRaw / rawpy / OpenColorIO / colour-science 集成 | `docs/opensource-research.md:47-50` | 仅调研，未集成 |
| 导出缩放 / 水印 / 打印配置 / 重命名模板 / HEIC 等输出 | `Models.swift:266-275`；`grep -rniE "\b(watermark\|resize)\b" Sources/PhotoCore/` 仅缩略图命中 | 导出参数仅格式/空间/质量/后缀/隐私 |
| AdobeRGB / ProPhoto / CMYK 输出 | `Models.swift:42-45`（仅 sRGB/displayP3） | — |
| 并行批处理 / 断点续跑 / 跨重启队列 | README:55（串行是设计）；`BatchProcessor.swift:66-140` | — |
| 配方自包含（内嵌 LUT 二进制） | README:29 | 只记录 LUT 路径/标识 |
| Apple Silicon / 其他 macOS / 全 RAW 机型验收 | README:7；`docs/validation.md:183` | 仅 Intel x86_64 / macOS 13 已验证 |
| Apple 公证 / 公开发行 | README:16 | 本地临时签名 |
| 真实鼠标键盘 / 系统对话框 / 退出确认的 UI 验收 | `docs/validation.md:56`；`docs/portrait-refinement.md:215`；`docs/style-effects.md:82`；`app-smoke.json` note | CUA 服务不可用，历次记为未执行 |

### 12.2 部分实现

| 项 | 现状 | 缺口 | 证据 |
|---|---|---|---|
| 格式支持 | JPEG/PNG/单页 TIFF + 系统 RAW | RAW 覆盖取决于 macOS 解码器；不支持 HEIC/多页/动画 | README:3、`:36-37`、`:61`；`PhotoIO.swift:10-21` |
| 人像精修 | 选区 + 保守局部细节（平整/纹理/邻域色彩） | 无祛瑕疵、美型、妆容、证件照、身体/头发模型 | `docs/portrait-refinement.md:68`；`docs/portrait-aware-refinement.md:31` |
| 细节处理 | 局部多尺度、逐图重测 | 不能区分毛孔/颗粒/压缩/织物；无生成式恢复 | `docs/adaptive-detail.md:176-183`；README:82 |
| 镜头校正 | Lensfun 畸变 + 安全缩放 | 暗角/横向色差未启用；40 MP 上限 | README:50；`LensCorrection.swift:26` |
| 分析 | 像素统计 + Vision + 规则场景策略 | 规则支持度非校准模型；不反推拍摄 Kelvin；无审美评分 | README:33-35；`PhotoAnalysis.swift:54` |
| 内容选区 | Vision 人物分割 + 地标/颜色候选 | 候选非完整分割；小脸/遮挡/侧脸/妆容影响；不跟踪跨图主体 | README:25；`docs/portrait-refinement.md:20-35` |
| 逐图 LUT 适配 | 9 组候选 + 实测约束 | 启发式保护，不保证审美；只覆盖 LUT 阶段 | README:23、`:45-46`；`docs/adaptive-film-luts.md` |
| 批处理 | 串行 + 原子清单 + 失败隔离 | 无并行/续跑；取消有粒度限制 | README:55；`docs/native-inspection.md` |
| 配方 | v1–v9 + 门禁 | LUT 不内嵌；旧自动配方用当前算法重算 | README:29 |
| 导出 | JPEG 8-bit / PNG·TIFF 16-bit；sRGB/P3 | 无缩放/水印/打印/HEIC/广色域输出 | `Models.swift:266-275` |

---

## 13. 本次验证记录（可复现）

### 13.1 构建与测试

```bash
cd /Users/mimi/project/ai调色
swift build -j 2
# 输出尾部：Build complete! (0.31s)   退出码 0

swift test -j 2
# 输出尾部：
#   Test Suite 'All tests' passed
#   Executed 246 tests, with 0 failures (0 unexpected) in 102.447 (102.468) seconds
# 退出码 0
```

**测试数量核对**：`grep -rh "func test" Tests/PhotoCoreTests/*.swift | wc -l` = 247；其中 `Tests/PhotoCoreTests/AdaptiveDetailTests.swift:919` 的 `private func testCubeText(...)` 是辅助函数，真实 XCTest 用例为 **246**，与运行输出一致。

### 13.2 Lead 提供的应用级验证（本次已复核日志存在与末行）

| 项 | 内容 | 状态 |
|---|---|---|
| `make check` 日志 `/tmp/pa_check.log` | 末行 `EXIT:0`；含 `Executed 246 tests, with 0 failures (0 unexpected) in 126.115 (126.138) seconds` | 已复核 |
| 应用启动 | `open build/PhotoAtelier.app` 后进程存在；截图 `/tmp/pa_screen1.png`（空状态）、`/tmp/pa_analysis.png`（分析页，13 张真实照片工作区）、`/tmp/pa_basic.png`（基础页） | 已复核文件存在；**截图含私人照片，不纳入交付物、不外传** |

### 13.3 历史应用级自检（本次未复跑，仅引用）

- `artifacts/acceptance-film-luts-20261103/evidence-general-final/app-smoke.json`：`"status": "passed"`，37 条断言，`"note": "Application command integration and own-view rendering; not a mouse/keyboard interaction test."`；断言覆盖 Lensfun 加载、文件夹扫描、像素/元数据分析与三方案、九宫格、RAW 全尺寸解码与导出、16-bit P3 TIFF 批处理与清单、坏图隔离、原图哈希不变、蒙版/建议/配方 v9 往返等。
- 同目录截图：`01-empty.png`、`02-analysis.png`、`02-library.png`、`03-mask.png`、`04-export.png`、`05-raw-analysis.png`、`06-regional-suggestions.png` 等 16 张。
- 其它验收目录：`artifacts/acceptance-*/evidence-*/`（13 个 acceptance 目录，含 colors/masks/local-guidance/portrait/adaptive-local/native-inspection/film-luts/style-effects/targeted-tones 等）。
- 打包与签名：`docs/validation.md:33-57` 记录 `bash Scripts/build_app.sh`、`codesign --verify --deep --strict`、`PYTHONOPTIMIZE=1 python3 Scripts/verify_app.py build/PhotoAtelier.app` 均退出 0（历史记录，本次未复跑）。

### 13.4 反向验证（确认「不存在」）

| 检查 | 命令 | 退出码 | 结论 |
|---|---|---:|---|
| 无撤销 | `grep -rniE "undoManager\|registerUndo\|undo\(" Sources/` | 1 | 无匹配 |
| 无选片评级 | `grep -rniE "\b(rating\|starRating\|favorite\|keyword\|flagging\|colorLabel)\b" Sources/` | 1 | 无匹配 |
| 无拖放导入 | `grep -rn "onDrop" Sources/` | 1 | 无匹配 |
| 无联网 API | `grep -rnE "URLSession\|NSURLConnection\|NWConnection\|CFStream\|WKWebView" Sources/` | 1 | 无匹配 |
| 无 HEIC/AVIF/WebP/PSD/GIF | `grep -rniE "\b(heic\|heif\|avif\|webp\|psd\|gif)\b" Sources/` | 1 | 无匹配 |
| 无导出缩放/水印 | `grep -rniE "\b(watermark\|resize)\b" Sources/PhotoCore/` | 0 | 仅命中缩略图 `maxDimension`（`PhotoIO.swift:266-290`），非导出功能 |

---

## 14. 信息缺口与未验证项

1. **真实照片审美验收未复跑**：本次只运行自动化测试与构建；`docs/` 与 `artifacts/` 中的实拍结论是历史记录，本次未重新拍摄或复核图像。
2. **真实 UI 交互未验证**：鼠标/键盘/系统文件对话框/退出确认在历次记录中均未执行（CUA 服务不可用）。Lead 提供的启动截图只能证明「应用可启动并渲染页面」，不证明交互路径。
3. **性能未测量**：本次未测大图（120 MP 边界）、16 个自适应蒙版、批量长时运行的耗时与内存；docs 记录的是历史环境数值（`docs/validation.md`、`docs/native-inspection.md`）。
4. **Apple Silicon / 其他 macOS 版本未验证**：README:7 与 `docs/validation.md:183` 明示仅 Intel x86_64 / macOS 13。
5. **全 RAW 机型覆盖未验证**：只有一款真实 Canon CR2 端到端记录（`docs/validation.md:125-130`），其余为扫描候选与合成夹具。
6. **测试用例映射未逐条核对**：本报告按测试文件与用例名归类能力，未逐行审查每个断言是否覆盖其宣称的全部语义。
7. **竞品对比不在本文范围**：像素蛋糕能力矩阵见 W1 产出 `docs/research/pixelcake-matrix.md`（如尚未生成，以 Lead 最终报告为准）。

### 14.1 本报告结论的三态标注（已验证 / 推断 / 未验证）

| 结论 | 标注 | 依据 |
|---|---|---|
| 能力清单中带 L2 的条目（代码存在且有对应测试，本次 246 用例全绿） | **已验证（代码+测试级）** | §13.1 本次 `swift test` 输出 |
| 带 L3 的条目（历史应用自检/实拍记录） | **已验证（历史应用级，本次未复跑）** | §13.3 `app-smoke.json`、docs 实测章节 |
| 「无撤销/无选片/无联网/无 HEIC/无导出缩放」等缺失项 | **已验证（反向 grep，退出码 1）** | §13.4 |
| 「应用可启动并渲染分析页/基础页」 | **已验证（本次 Lead 截图+进程）** | §13.2 |
| 「鼠标键盘交互路径可用」 | **推断（不可由截图/命令自检证明）** | §14 第 2 条 |
| 「真实照片审美效果达标」 | **未验证（本次未复跑实拍）** | §14 第 1 条 |
| 「大图/多蒙版/长时批处理性能」 | **未验证（仅有历史数值）** | §14 第 3 条 |
| 「Apple Silicon / 其他 macOS / 全 RAW 机型」 | **未验证（README/docs 明示未验收）** | §14 第 4–5 条 |
| 「LUT 数量 13+5、蒙版上限 16/64/32768」 | **已验证（代码常量与调用行计数）** | `LUTCube.swift:331-355`、`FilmLUTCatalog.swift:37`、`PhotoEngine.swift:288-316` |

> 使用本表时请原样保留三态标注：**已验证**（有本次命令或历史可追溯证据）、**推断**（由间接证据推理）、**未验证**（本次与历史均无直接证据）。

---

## 15. 给 W3 差距分析的接口

差距矩阵可直接引用本报告的以下锚点，避免重复取证：

| 差距维度 | 本项目基线（引用位置） | 结论类型 |
|---|---|---|
| 导入/选片 | 仅文件夹导入、无评级筛选（§2.3、§12.1） | 能力缺口 |
| 人像精修 | 有选区+保守细节，无祛痘/美型/妆容/证件照（§6、§12.2） | 部分缺口 |
| 调色/LUT | 内置 13+5、`.cube`、5 空间、逐图适配、质感滤镜（§7） | 已具备 |
| 批量/导出 | 串行批处理+清单+16-bit 输出，无缩放/水印/HEIC（§9、§10） | 部分缺口 |
| 协作/生态 | 纯本地无网络（§12.1） | 能力缺口 |
| 平台/发行 | 仅 Intel 验证、未公证（§12.1） | 交付缺口 |

> 引用本报告时请保留证据级别（L1/L2/L3）与「已验证/部分验证/未验证」标注；不要把 L2 单元测试表述为「产品已验证」，也不要把历史 docs 记录表述为「本次已复跑」。

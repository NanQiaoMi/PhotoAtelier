# 人像、背景与局部纹理精修

> 本文保留 `73dda52` 的 v6 历史验收。当前 v7 逐图细节适配与新验证见 [逐图、逐选区的细节处理](adaptive-detail.md)。

## 目标、范围与出口

用户选择优先完善「人物/背景分开、保留皮肤纹理、局部光色」，并新增三张本机人像供测试。沿用原生 macOS 文件夹批处理、LUT/颜色协调、RAW 解码与非破坏性导出。使用 GPT‑6 Luna / max 子代理分别实现内容选区、细节引擎、独立测试，主代理集成、复核并验证。

本轮验收：

- [x] 人物、背景和面部候选逐张定位，失败/无可靠结果为空，反选和加选不能把失败变为全图。
- [x] 眼、眉、嘴避让，支持原有画笔加选/减选/交集；候选不是精确皮肤分割。
- [x] 多尺度明暗平整、细纹理保留和邻域色彩均匀可调，零强度为原图恒等，不设统一肤色。
- [x] 新字段旧配方兼容，新增行为有配方 v6 门禁；检测图与脸坐标不保存到配方或报告。
- [x] 三张新增人像与十张旧样本实测，完整检查、应用命令流程、RAW 与导出复读见下文证据。
- [ ] 鼠标画笔/缩放/文件对话框/退出确认和人工审美验收。

继续执行用户已经确认的出口：**本地提交并保留功能分支，人工验收后再合并**。原片只读、不上传，不安装模型或依赖；私有路径、照片、索引、临时脚本和日志只在忽略的 `artifacts/acceptance-portrait-20261102/`。

## 功能与处理约定

### 内容选区

「局部 → 人像与背景」有三个入口。创建时曝光、颜色、细节为中性，不先替用户加滤镜。先检查粉色覆盖，必要时手绘修边，再调局部参数。

- **人物**：先用本机 Vision 人脸/身体矩形提供独立检测依据，再运行 `VNGeneratePersonSegmentationRequest` 的 accurate 软分割；要求可见区域内有足量高权重样本。低分割噪声不生成背景反选。每张照片新建 request，避免 stateful 视频请求携带上一张状态。
- **背景**：仅在人物候选有效时求补集。无人物或检测不可用时也为空；不自动把整张图当作可调背景。
- **面部皮肤候选**：Vision 地标面部轮廓内，用本图脸颊颜色与相对亮度筛选，排除眼、眉、嘴区域。无固定肤色阈值或目标白点。最长边 384 的候选栅格轻度柔化，五官排除区预留大于平滑范围的边距。最多评估 16 张脸；小脸、遮挡、侧脸和妆容会影响候选。

Vision 最长边 1024，候选覆盖按最长边 384 的可见像素估计，数值不是校准过的正确概率。失败可尝试一次 CPU 回退，取消在各请求边界检查。Vision 单次请求不能中途打断，故取消并非即时。

蒙版统一映射到全局校正与几何之后、局部及 LUT 之前的参考，灰度 RGB 不透明、人物概率按线性灰读。非零原点先归零再缩放、复位。范围、保护和绘制修边沿用原规则，检测不可用在任何反选/组件运算前返回空。禁用或零不透明度蒙版不触发检测。

预览只缓存一张有界图及其检测结果，键绑定源文件路径/修改时间/大小、镜头解码参数、全局参考设置与目标集合。仅局部滑块改变时复用；换图、全局/几何调整或检测目标改变时重新计算。批处理不使用该缓存，逐张新建检测。切图立即清除旧覆盖、测量与检测状态，避免侧栏暂时显示旧照片的结果。

### 细节与光色

三个滑块均在当前蒙版内，先局部光色，再细节，最后锐化与统一色彩保护：

| 控件 | 含义 |
|---|---|
| 光影平整 | alpha 加权的小尺度/较大尺度 signed-log 亮度分解，减弱中尺度起伏；转换回目标亮度后计算曝光比，保持大明暗关系。 |
| 细纹理保留 | 保留较细亮度频段；强边缘门控进一步降低跨边缘变化。 |
| 邻域色彩均匀 | 取本图邻域色度，不使用统一肤色；保持线性亮度，抑制跨明显颜色边界的平均。 |

「轻度精修起点」为 `.25 / .90 / .12`，保留已有局部参数；有效覆盖不足或预览未完成时不采用。重置局部参数会清除细节，保留选区。

细节引擎单次亮度变化限 **±.12 EV**，色度位移限幅；SDR 源留通道余量，以共同系数保留色度方向，避免逐通道裁切。半透明边缘按 alpha 加权，扩展线性负值/高光不硬截为 0–1。半径按短边比例随预览/导出缩放，极小预览有最小半径。零平整、零均匀度直接返回原图 graph。

这是受约束的局部平整，不能区分痘、痣、雀斑、细纹与需要保留的特征。多个重叠蒙版、曝光/颜色手动极值、后续 LUT 不受这单次 .12 EV 上限约束。局部光线建议仍按实际选区亮度与通道余量决定，有依据才提出；全图/局部颜色协调与目标色域映射继续在末端工作。

### 配方与隐私

新增 `LocalMask.contentSelection`、`detail` 均 optional。配方 v6 保存新操作；读取 1–6。含内容选区或非中性细节的 current、automatic baseline、reference masks 不能包装为 v5。无新功能的旧 v5 可继续使用。旧缺字段蒙版保留原渲染路径。

报告仅保留检测状态、检测脸数、覆盖和警告；不编码蒙版像素、人脸坐标或身份。临时 `ProcessedPhoto.contentSelections` 只用于同一照片处理、检查和覆盖预览共用。批处理清单保留逐张状态，供判断是否实际生成候选。

## 实拍发现与限制

桌面共 13 张图，新增三张包含两张逆光人像和一张正/背面上下拼接图。本轮完成逐张检测、候选导出、轻度与强度对照；主代理查看了人物/背景/面部覆盖及局部结果。具体数值、耗时与最终检查记录见后续表格。

- 初版在三个无近景人物的样本中把约 .05% 的弱概率当作人物，在一张透明插画中也有错误分割。引入独立人脸/身体依据与高权重样本检查后，十张旧样本都跳过，三张新增人像仍有候选。这里只验证本组样本，不保证所有插画或物体都不会误检。
- 两张逆光照主体位置正确，面部候选避开五官，额头/鼻部部分未选入；它是保守候选，需检查修边。
- 拼接图只选中了上半张人物，下半张背面人物遗漏。人物/背景结果仍标候选并提示可能只覆盖部分人物；不同构图、多人、遮挡和发丝需要逐张复核。
- 首轮测试的中尺度平整低于 15% 的既定目标：guide 差被直接当 EV，改为 signed-log 逆变换得到目标亮度后取曝光比；保留原测试断言。新增测试后来通过，没有放宽数值目标。
- 首轮评估对 lazy CIImage 独立作小数尺寸采样，拼接图报出 2 EV 与 .53 的 mask 外差，导出 PNG 的实像素复读不支持该变化。评估器改为复读实际色彩管理导出物，并使用共同整数采样栅格；旧指标保留为失败测量证据，不作为画质结论。

像素蛋糕[官方网站](https://www.pixcakeai.com/)本轮列出的范围包含面部祛瑕疵、中性灰磨皮、身体/头发、妆容、美型、背景清理和生成工具。这里只核实官网自述，没有运行商业软件；本项目本轮实现上述选区与保守细节处理，尚无自动祛痘、身体/头发专用模型、美型、妆容或生成背景，不等同于完整商业精修。

## Git 与变更范围

大型变更：AGENTS.md 3.1 的新增功能、跨模块行为、配方格式变更及超过三个源文件。写入前工作区/暂存区干净，stash 与 remote 为空；没有安装、fetch/pull、推送、PR 或发布。

- 功能分支：`codex/portrait-refinement`。
- 建分支 HEAD / 已验证基线：`f5b0c78ffc88c2a69031b646fe16c2dbc4880b62`，`fix(masks): unify measured local exposure advice`。
- 当前分支由 `git symbolic-ref --short HEAD` 实测；稳定分支为本地 `main`，保持 `837ec592c5428e4e4cd360e91f2592d69321f92d`。
- 仅本地提交，不合并；现有 Core Image kernel 语言 API 已弃用，新细节引擎也沿用该 API，构建有相应警告和既有测试字典类型警告，不影响本次检查退出码。本轮未迁移为 Metal 编译管线。
- 回滚以功能提交的 `git revert` 为单位；上一应用由构建脚本另名保留，不覆盖原片。

变更文件（无删除）：

```text
README.md
Sources/PhotoAtelier/AppModel.swift
Sources/PhotoAtelier/MaskInspector.swift
Sources/PhotoAtelier/SmokeHarness.swift
Sources/PhotoAtelier/PortraitSmokeHarness.swift                 [新增]
Sources/PhotoCore/Models.swift
Sources/PhotoCore/PhotoEngine.swift
Sources/PhotoCore/LocalMaskEngine.swift
Sources/PhotoCore/ContentSelection.swift                        [新增]
Sources/PhotoCore/LocalDetailProcessing.swift                   [新增]
Tests/PhotoCoreTests/PortraitDetailTests.swift                  [新增]
Tests/PhotoCoreTests/ColorCompatibilityTests.swift
Tests/PhotoCoreTests/LocalMaskTests.swift
Tests/PhotoCoreTests/SceneAdaptiveTests.swift
Tests/PhotoCoreTests/TonalCurveTests.swift
Scripts/evaluate_portraits.swift                              [新增]
docs/local-guidance.md
docs/portrait-refinement.md                                   [新增]
```

既有四个测试文件和旧 SmokeHarness 的变化只扩展当前配方版本的期望/拒绝边界；实际旧配方数值含义未改。新增评估脚本只读输入，要求输出目录全新且与输入树不重叠，匿名命名导出；它会在所选输出中写私有源索引，因此应像本轮一样放在忽略目录。

## 验证证据

所有构建/测试在项目根目录执行；独立应用验证在 `/tmp` 执行。以下只记实际命令、退出码与结果。未执行的人工交互与合并后回归在出口处单列。

### 中间检查与修复

| 完整命令 | 退出码 | 结果 |
|---|---:|---|
| `swift test -j 2 --filter 'PortraitDetailTests\|LocalMaskTests\|ColorCompatibilityTests\|SceneAdaptiveTests\|TonalCurveTests' > artifacts/acceptance-portrait-20261102/focused-first.log 2>&1` | 1 | 69 tests / 1 failure，新增平整测试实测 .020827 未小于 .020757，归类本次实现换算问题。 |
| `swift test -j 2 --filter PortraitDetailTests > artifacts/acceptance-portrait-20261102/detail-corrected.log 2>&1` | 0 | 11 tests / 0 failures，修正 signed-log 到 EV 的换算。 |
| `swift test -j 2 --filter PortraitDetailTests > artifacts/acceptance-portrait-20261102/detection-gate-tests.log 2>&1` | 0 | 11 tests / 0 failures，人物有效性门禁。 |
| `swift test -j 2 --filter PortraitDetailTests > artifacts/acceptance-portrait-20261102/portrait-focused-final.log 2>&1` | 1 | 新应用测试 harness 引用了非 public 的 BatchManifest，编译失败；改为本地最小 Decodable，属于本次 harness 问题。 |
| `swift test -j 2 --filter PortraitDetailTests > artifacts/acceptance-portrait-20261102/portrait-focused-second.log 2>&1` | 0 | 13 tests / 0 failures，含实际 Vision 空帧与取消；不把注入蒙版测试叫真实人像检测成功。 |

### 最终快照

首轮 `source-snapshot.json` 冻结 67 项源码、测试、脚本、资源与构建文件。应用真人流程随后发现：CI 变换累计浮点误差令蒙版/参考的独立采样向上取整产生不同尺寸，创建背景时报「内容蒙版与参考图采样尺寸不一致」。这属于本次新增实现问题，首轮 Release 不作为最终交付。

改为两者共用参考 extent 与显式整数网格，并补充带小数原点/尺寸、反相与 alpha 的回归测试。`source-snapshot-corrected.json` 冻结修正后的同 67 项文件，仅 ContentSelection.swift 与 PortraitDetailTests.swift 与首轮不同；后续最终检查、真人重测及 Release 对应此快照。

| 完整命令 | 退出码 | 结果 |
|---|---:|---|
| `make check > artifacts/acceptance-portrait-20261102/check-final.log 2>&1` | 0 | 166 tests / 0 failures，53.543 秒；build 5.62 秒。早于真人流程发现的采样问题。 |
| `bash Scripts/build_app.sh > artifacts/acceptance-portrait-20261102/release-build-final.log 2>&1` | 0 | Release 57.92 秒，包验证通过；这是修正前应用。 |
| `swift test -j 2 --filter PortraitDetailTests > artifacts/acceptance-portrait-20261102/fractional-grid-tests.log 2>&1` | 0 | 修正后 14 tests / 0 failures，含同一小数 extent 上的互补覆盖与不透明 alpha。 |
| `make check > artifacts/acceptance-portrait-20261102/check-corrected.log 2>&1` | 0 | 修正快照 167 tests / 0 failures，71.361 秒，无跳过；build 1.28 秒。当时同时运行真人 Debug 应用，不视为性能基准。 |
| `PROJECT_ROOT='/Users/mimi/project/ai调色' /usr/bin/time -l .build/x86_64-apple-macosx/debug/PhotoAtelier --portrait-self-test artifacts/acceptance-portrait-20261102/portrait-input artifacts/acceptance-portrait-20261102/output-portraits-debug artifacts/acceptance-portrait-20261102/evidence-portraits-debug > artifacts/acceptance-portrait-20261102/portrait-app-smoke-debug.log 2>&1` | 0 | Debug 真人应用命令 15 checks / 3 TIFF；进程 113.94 秒，与完整测试同时运行。 |

### 本机照片评估命令

`PHOTO_INPUT="$HOME/Desktop"`，这是用户授权的本机测试目录；实际文件名与索引不入库。所有新输出目录均在输入树以外，不覆盖已有目录。下面的编译与执行均退出 0。

```bash
swiftc -I .build/x86_64-apple-macosx/debug -I .build/x86_64-apple-macosx/debug/CLensfunBridge.build Scripts/evaluate_photos.swift .build/x86_64-apple-macosx/debug/PhotoCore.build/*.o .build/x86_64-apple-macosx/debug/CLensfunBridge.build/CLensfunBridge.c.o -o artifacts/acceptance-portrait-20261102/evaluate-baseline > artifacts/acceptance-portrait-20261102/baseline-evaluator-build.log 2>&1
/usr/bin/time -l artifacts/acceptance-portrait-20261102/evaluate-baseline "$PHOTO_INPUT" artifacts/acceptance-portrait-20261102/baseline > artifacts/acceptance-portrait-20261102/baseline-evaluation.log 2>&1
swiftc -I .build/x86_64-apple-macosx/debug -I .build/x86_64-apple-macosx/debug/CLensfunBridge.build Scripts/evaluate_photos.swift .build/x86_64-apple-macosx/debug/PhotoCore.build/*.o .build/x86_64-apple-macosx/debug/CLensfunBridge.build/CLensfunBridge.c.o -o artifacts/acceptance-portrait-20261102/evaluate-current > artifacts/acceptance-portrait-20261102/evaluator-current-build.log 2>&1
/usr/bin/time -l artifacts/acceptance-portrait-20261102/evaluate-current "$PHOTO_INPUT" artifacts/acceptance-portrait-20261102/global-verified > artifacts/acceptance-portrait-20261102/global-verified.log 2>&1
swiftc -I .build/x86_64-apple-macosx/debug -I .build/x86_64-apple-macosx/debug/CLensfunBridge.build Scripts/evaluate_portraits.swift .build/x86_64-apple-macosx/debug/PhotoCore.build/*.o .build/x86_64-apple-macosx/debug/CLensfunBridge.build/CLensfunBridge.c.o -o artifacts/acceptance-portrait-20261102/evaluate-portraits > artifacts/acceptance-portrait-20261102/portrait-evaluator-build.log 2>&1
/usr/bin/time -l artifacts/acceptance-portrait-20261102/evaluate-portraits "$PHOTO_INPUT" artifacts/acceptance-portrait-20261102/portrait-first > artifacts/acceptance-portrait-20261102/portrait-first.log 2>&1
swiftc -I .build/x86_64-apple-macosx/debug -I .build/x86_64-apple-macosx/debug/CLensfunBridge.build Scripts/evaluate_portraits.swift .build/x86_64-apple-macosx/debug/PhotoCore.build/*.o .build/x86_64-apple-macosx/debug/CLensfunBridge.build/CLensfunBridge.c.o -o artifacts/acceptance-portrait-20261102/evaluate-portraits-final > artifacts/acceptance-portrait-20261102/portrait-evaluator-final-build.log 2>&1
/usr/bin/time -l artifacts/acceptance-portrait-20261102/evaluate-portraits-final "$PHOTO_INPUT" artifacts/acceptance-portrait-20261102/portrait-verified > artifacts/acceptance-portrait-20261102/portrait-verified.log 2>&1
python3 artifacts/acceptance-portrait-20261102/verify_photos.py > artifacts/acceptance-portrait-20261102/photo-verification.log 2>&1
```

基线冻结在核心改动之前，13 / 13 完成、100.13 秒 / RSS 599,105,536 bytes。当前全局评估 13 / 13、92.77 秒 / RSS 623,669,248 bytes；13 组原图与三方案共 52 张 JPEG 与基线逐字节相同。后续整数网格修正只改变内容选区，不经过这些无内容选区的全局路径，完整检查在修正快照重跑。

首轮内容评估 122.75 秒，包含先前误判与测量问题。收紧检测、改为导出复读后为 71.27 秒 / RSS 506,204,160 bytes；这是包含所有导出的整体工具耗时，不能当作预览交互延迟。三张人像检测约 3.4–4.1 秒，局部参数变化复用一张检测结果，不跨图复用；冷启动/负载变化未作统计基准。

主代理确认旧十图均跳过、三张真人均可生成候选。修正前的导出复读中，面部轻度最大绝对亮度变化为 .092 / .084 / .120 EV，强度压力测试最大约 .121 EV；0 非有限、0 新增越界样本，mask 外最大线性 RGB 差小于 .0006。该值含 16 位编码、半精度与缩放边界误差，**不等于每个全分辨率像素无任何变化或整张图最佳审美**；修正网格后的再次实测见下方最终记录。

### 独立应用流程

所有下列应用命令从 `/tmp` 执行，不依赖项目当前目录，`PROJECT_ROOT` 已移除。第一条回归通过，但真人首次命令失败，故保留其产物并在修正后用全新输出目录重跑。

```bash
env -u PROJECT_ROOT /usr/bin/time -l '/Users/mimi/project/ai调色/build/PhotoAtelier.app/Contents/MacOS/PhotoAtelier' --self-test '/Users/mimi/project/ai调色/artifacts/acceptance-20261101/input' '/Users/mimi/project/ai调色/artifacts/acceptance-portrait-20261102/output-regression' '/Users/mimi/project/ai调色/artifacts/acceptance-portrait-20261102/evidence-regression' > '/Users/mimi/project/ai调色/artifacts/acceptance-portrait-20261102/regression-smoke.log' 2>&1
env -u PROJECT_ROOT /usr/bin/time -l '/Users/mimi/project/ai调色/build/PhotoAtelier.app/Contents/MacOS/PhotoAtelier' --portrait-self-test '/Users/mimi/project/ai调色/artifacts/acceptance-portrait-20261102/portrait-input' '/Users/mimi/project/ai调色/artifacts/acceptance-portrait-20261102/output-portraits' '/Users/mimi/project/ai调色/artifacts/acceptance-portrait-20261102/evidence-portraits' > '/Users/mimi/project/ai调色/artifacts/acceptance-portrait-20261102/portrait-app-smoke.log' 2>&1
```

第一条退出 0，37 checks、3 导出 / 1 预置坏图隔离，应用流程 27.900 秒；第二条退出 1，3 项检查后报采样尺寸不一致，12.009 秒。旧输出/日志未删除或覆盖。报告复读命令 `python3 artifacts/acceptance-portrait-20261102/verify_reports.py artifacts/acceptance-portrait-20261102/output-regression artifacts/acceptance-portrait-20261102/evidence-regression > artifacts/acceptance-portrait-20261102/regression-reports.log 2>&1` 退出 0，验证 v6 / 策略 v2、逐图独立依据、五区增量仅应用一次、P3 最终域外比例 0、蒙版修边保留。

首次签名与包复核也退出 0：`codesign --verify --deep --strict build/PhotoAtelier.app > artifacts/acceptance-portrait-20261102/signature-final.log 2>&1`、`PYTHONOPTIMIZE=1 python3 Scripts/verify_app.py build/PhotoAtelier.app > artifacts/acceptance-portrait-20261102/bundle-final.log 2>&1`。它们只证明当时包结构与签名，不代替后续修正包的验证。

### 修正快照的最终结果

以下命令均退出 **0**：

```bash
bash Scripts/build_app.sh > artifacts/acceptance-portrait-20261102/release-build-corrected.log 2>&1
codesign --verify --deep --strict build/PhotoAtelier.app > artifacts/acceptance-portrait-20261102/signature-corrected.log 2>&1
PYTHONOPTIMIZE=1 python3 Scripts/verify_app.py build/PhotoAtelier.app > artifacts/acceptance-portrait-20261102/bundle-corrected.log 2>&1
swiftc -I .build/x86_64-apple-macosx/debug -I .build/x86_64-apple-macosx/debug/CLensfunBridge.build Scripts/evaluate_portraits.swift .build/x86_64-apple-macosx/debug/PhotoCore.build/*.o .build/x86_64-apple-macosx/debug/CLensfunBridge.build/CLensfunBridge.c.o -o artifacts/acceptance-portrait-20261102/evaluate-portraits-corrected > artifacts/acceptance-portrait-20261102/evaluator-corrected-build.log 2>&1
/usr/bin/time -l artifacts/acceptance-portrait-20261102/evaluate-portraits-corrected "$PHOTO_INPUT" artifacts/acceptance-portrait-20261102/portrait-corrected > artifacts/acceptance-portrait-20261102/portrait-corrected.log 2>&1
python3 artifacts/acceptance-portrait-20261102/verify_photos_corrected.py > artifacts/acceptance-portrait-20261102/photo-verification-corrected.log 2>&1
python3 artifacts/acceptance-portrait-20261102/verify_reports.py artifacts/acceptance-portrait-20261102/output-regression-corrected artifacts/acceptance-portrait-20261102/evidence-regression-corrected > artifacts/acceptance-portrait-20261102/regression-reports-corrected.log 2>&1
swiftc -I .build/x86_64-apple-macosx/debug -I .build/x86_64-apple-macosx/debug/CLensfunBridge.build artifacts/acceptance-portrait-20261102/run_detail_batch.swift .build/x86_64-apple-macosx/debug/PhotoCore.build/*.o .build/x86_64-apple-macosx/debug/CLensfunBridge.build/CLensfunBridge.c.o -o artifacts/acceptance-portrait-20261102/run-detail-batch > artifacts/acceptance-portrait-20261102/detail-batch-build.log 2>&1
PROJECT_ROOT='/Users/mimi/project/ai调色' /usr/bin/time -l artifacts/acceptance-portrait-20261102/run-detail-batch '/Users/mimi/project/ai调色/artifacts/acceptance-portrait-20261102' > artifacts/acceptance-portrait-20261102/detail-batch.log 2>&1
swift artifacts/acceptance-portrait-20261102/verify_exports.swift artifacts/acceptance-portrait-20261102 > artifacts/acceptance-portrait-20261102/export-verification.log 2>&1
```

两条最终应用命令从 `/tmp` 执行，均退出 **0**：

```bash
env -u PROJECT_ROOT /usr/bin/time -l '/Users/mimi/project/ai调色/build/PhotoAtelier.app/Contents/MacOS/PhotoAtelier' --portrait-self-test '/Users/mimi/project/ai调色/artifacts/acceptance-portrait-20261102/portrait-input' '/Users/mimi/project/ai调色/artifacts/acceptance-portrait-20261102/output-portraits-corrected' '/Users/mimi/project/ai调色/artifacts/acceptance-portrait-20261102/evidence-portraits-corrected' > '/Users/mimi/project/ai调色/artifacts/acceptance-portrait-20261102/portrait-app-smoke-corrected.log' 2>&1
env -u PROJECT_ROOT /usr/bin/time -l '/Users/mimi/project/ai调色/build/PhotoAtelier.app/Contents/MacOS/PhotoAtelier' --self-test '/Users/mimi/project/ai调色/artifacts/acceptance-20261101/input' '/Users/mimi/project/ai调色/artifacts/acceptance-portrait-20261102/output-regression-corrected' '/Users/mimi/project/ai调色/artifacts/acceptance-portrait-20261102/evidence-regression-corrected' > '/Users/mimi/project/ai调色/artifacts/acceptance-portrait-20261102/regression-smoke-corrected.log' 2>&1
```

| 检查 | 最终证据 |
|---|---|
| Release | 48.99 秒；4 个签名 x86_64 库、55 XML、许可与加载路径严格通过。上一 app 保留为 `build/PhotoAtelier.previous-20261102-180521.app`。 |
| 真人应用 | **15 checks**，三种内容选区、零参数创建、细节起点、v6 读写/v5 拒绝、切图立即清旧状态、下一张重新定位、重置保留选区、3 TIFF 导出、逐图不同覆盖与原片哈希。应用流程 40.638 秒，进程 41.76 秒 / RSS 952,041,472 bytes。 |
| 原有应用 | **37 checks · 3 exported · 1 isolated**，应用流程 28.397 秒、进程 28.80 秒 / RSS 952,930,304 bytes；RAW 分析、三方案、全尺寸导出及既有蒙版/色域流程均通过。 |
| 非零细节批处理 | 实际载入应用保存的三种语义选区及 `.25 / .9 / .12` 细节配方，3 人像完成；再将同配方用于无人物 Canon RAW，人物/面部明确 noDetection，安全跳过，1 RAW 完成。16.65 秒 / RSS 547,934,208 bytes；清单确认细节参数没有在批处理中丢失。 |
| 导出复读 | 10 TIFF（原流程 3、真人应用 3、非零细节 3、无人物 RAW 1）均 16-bit Display P3、orientation 1、采样有限；两份 RAW 输出均 4272×2848。 |
| 修正后照片评估 | 13 / 13 完成，72.01 秒 / RSS 508,870,656 bytes；10 跳过、3 真人候选；13 原片哈希不变，52 张全局导出与基线一致，67 项源码快照匹配。 |

最终真人导出采样：

| 匿名样本 | 人物覆盖 | 面部候选覆盖 | 轻度面部最大绝对 EV | 压力测试最大绝对 EV |
|---|---:|---:|---:|---:|
| 10 柱旁逆光 | 27.98% | .579% | .0917 | .1205 |
| 11 林间逆光 | 19.84% | .521% | .0836 | .1204 |
| 12 上下拼接 | 7.24% | .206% | .1199 | .1206 |

3 组导出均 0 非有限、0 新增越界采样，mask 外 RGB 最大差 ≤.000489。主代理检查了最终 `portrait-detail-crops-final.png` 的原图/轻度/压力对比，五官、发丝和画面原有冷暖未见明显异常变化，局部变化较轻。拼接图的背面人物漏选仍然存在，不能由这些数值证明完整覆盖。图像、UI 截图和压力测试结果只存于忽略目录，不进入仓库。

独立只读审查覆盖缺人时空选区、CPU 回退门禁、坐标/alpha、同图缓存与跨图失效、配方降级；曾发现侧栏残留旧检测状态，已修正并由应用命令实际切图验证，最终未发现该范围内其他确认性问题。静态审查不代替真实检测与交互。

### 未执行与下一步

- 最终包原生工具调用 `cua.getApp('/Users/mimi/project/ai调色/build/PhotoAtelier.app')` 再次返回 `Sky Computer Use service startup request failed`。真实鼠标画笔、参数拖动、文件对话框和退出确认 **未执行**。应用自身命令/SwiftUI 快照均不算鼠标键盘交互测试。
- `make build` / `make test` 由修正后 `make check` 完整覆盖；`make app` 命令体由最终 `bash Scripts/build_app.sh` 覆盖；`make run` 的原生人工操作未执行，原因如上。没有跳过测试、关闭失败用例或使用 `--no-verify`。
- 无基线失败；本次平整换算、harness 编译和采样网格失败已修复，日志保留。当前遗留是候选分割边界/拼接漏检、有限样本的审美覆盖，以及原生交互未验收。
- 保留功能分支与本地提交，不合并、不删除分支。合并及主分支回归 **未执行**，遵循用户既定人工验收决定。
- 本机打开 `build/PhotoAtelier.app`：先在「局部」选择人物或面部候选，核对覆盖；关闭覆盖后放大看轻度起点，重点试验五官、发丝、多人/拼接、手绘修边和批处理。需要更精确的身体/头发/皮肤分割或祛瑕疵时，应另设模型与验收样本，不能把现有颜色候选改名宣称已经支持。

### 提交前核对

`git diff --cached --check` 首次退出 2，指出本页末尾多一个空行；去除该空行后复跑。`python3 artifacts/acceptance-portrait-20261102/audit_delivery.py > artifacts/acceptance-portrait-20261102/audit-staged.log 2>&1` 首轮退出 0，核对 18 项任务文本文件、67 项最终源码哈希、13 原片哈希、文档链接、无私有源文件名/密钥特征/大文件和 main 未变；文档补记后再次暂存、复跑核对再提交。完整执行结果同时在最终交付消息中列明。

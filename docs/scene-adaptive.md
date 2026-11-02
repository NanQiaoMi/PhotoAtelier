# 按照片证据与用户意图处理

## 目标与验收

本轮目标是让不同题材、拍摄氛围的照片使用不同的处理目标，减少统一中灰曝光公式破坏高调、暗调和柔雾。原片、LUT、镜头/几何与蒙版沿用已有非破坏性管线；不新增依赖、不下载样片。规则是有上限、可解释的启发式，没有经过广泛真实照片的审美校准。

- [x] 题材线索、像素特征、用户意图分别记录；标签冲突或不足时保守回退，显式用户意图优先。
- [x] 高调、暗调、夜景、柔雾、逆光、人像、风光、已有黑白影调使用不同的参数方向；保留已有风格不新增自动基础调整。
- [x] 像素观察卡片与场景方向一致；中位亮度偏离灰参考仅作信息，不被标成必须纠正的缺陷。
- [x] 人像使用可信人脸框内的实际亮度，覆盖坐标方向、非零原点与透明度；不伪造肤色或统一肤色亮度目标。
- [x] 每张批处理重新分析并记录策略、证据、限制；手动微调只携带一次；继续运行原尺寸自动增量检查和原有颜色保护。
- [x] 配方版本 4 保存显式意图，版本 1–3 可读；拒绝把带场景意图的配方标为旧版。
- [x] 最终完整构建/测试 132 项全过、Release 独立运行 26 项应用检查、真实 CR2 全分辨率 16-bit Display P3 TIFF 导出及报告复读，见下方实际记录。
- [ ] 原生鼠标、系统文件夹选择器、退出确认及真实用户照片的审美比较。用户已要求保留提交分支，人工验收后再合并。

## 旧行为与新目标

本轮基线 `e431bf3` 已限制自动增量，完整记录为 117 tests / 0 failures、23 项应用检查和真实 CR2 导出，见 [上轮记录](automatic-safety.md)。仍有一个处理目标问题：多数题材围绕同一中位亮度方向作变化。低亮度不一定欠曝，低对比不一定需要去雾，高彩度或冷暖分离也不能证明滤镜/白平衡有误。

本轮将这个目标改为保留拍摄基调，先解释证据，再提出少量不同方向。测试衡量的是规则边界、像素保持、报告与导出契约；不是模型识别正确率，也不要求每张照片三方案必须看起来不同。基线完整验证引用已有提交记录，本轮未重新声称做过开工时的完整基线测试。

## 题材、像素与意图

所有阈值基于用户现有全局基础参数处理后的线性 RGB；报告里的原图统计另行保留。未用 LUT 或局部结果反向驱动全局自动纠正。

| 方向 | 自动证据或用户选择 | 三方案的处理原则 |
|---|---|---|
| 自然人像 | 可靠 Vision 人脸框；portrait 标签本身不足 | 测量框内亮度；保守地轻提亮/收高光，不增加肤色彩度、不设统一肤色亮度。 |
| 风光层次 | 风光类标签 ≥.55，同时跨度 ≥2.5 EV 且不是近纯灰 | 跨度大时轻收对比；少量提亮需有 P99 余量，仅低彩度彩色图的层次方案可加 ≤.01 彩度。 |
| 夜景 | 夜景标签 ≥.65、P50 <.08、暗部占比 >70% | 保守方案零曝光增量；可读方案最多 +.04 EV / +.015 阴影。ISO ≥1600 时降为 +.02 EV / +.005 阴影。 |
| 暗调 | P50 <.04、暗部占比 >70% | 保留黑背景与灯光；保守方案不向中灰提亮，选项增量与夜景同上。 |
| 高调 | P50 >.60、P05 >.12 | 保留留白；仅提供少量高光层次，不按中灰压暗。 |
| 柔雾 | 跨度 <2.5 EV、P50 .04–.60、P05 >.025、P95 <.85 | 保留低对比；不自动去雾、不加彩度，轻盈选项仅较暗时最多 +.04 EV。 |
| 逆光层次 | 脸框明显暗于亮背景，或宽跨度下有明显明暗分离 | 以少量阴影/高光变化为主，不全局提亮；明确可能是有意剪影。 |
| 已有黑白影调 | 中性色 ≥99.5%、平均彩度 <.005、跨度 ≥3.5 EV，或用户指定 | 不加色；只保留已有黑白关系。彩色输入不会自动变黑白，面板说明限制。 |
| 保留已有风格 | 只接受用户显式选择，不能靠 RGB 证明已经套滤镜 | 三方案曝光、对比、彩度、高光、阴影增量均为零；在自动模式切入时固定当前基础结果。 |
| 未确定题材 | 信息不足、冲突或不满足以上条件 | P50 .10–.35 内不作中灰纠正；区间外只取弱信号、限制在 ±.12 EV，另有层次/柔和选项。 |

自动优先顺序为夜景佐证、逆光人脸、人脸、高调、暗调、柔雾、近黑白、明暗分离、风光、回退。显式意图优先于该顺序，但仍受高光余量、窄范围不加对比、高彩度不再加色及实际渲染约束。

风光标签与跨度的佐证仍然较弱，不是可靠的语义分割。彩色场景、后期氛围或低曝光本身有歧义，应通过原片和三个预览比较，必要时指定保留基调。高 ISO 只是谨慎提暗部的元数据线索，不是实测噪声；本轮未实现降噪。

## 局部测量、白平衡和颜色边界

- 可信人脸框要求 confidence ≥.65；最多测量 16 个，单框归一化面积至少 .003，按框的并集测量，避免重叠双计数。样本最长边 384，使用 alpha 加权的 P50/P95、近白比例与覆盖率。它不是皮肤蒙版，也不保存身份。独立分区图与原图裁剪测试校验 Vision 左下角坐标到 bitmap 顶部行的转换。
- 现有局部蒙版、选区修边、固定范围参考和整体颜色协调继续运行；本轮人脸框用于分析，没有把脸框伪装为精细主体蒙版，也没有新增跨照片主体跟踪。
- 不根据内容标签或冷暖分布自动猜测 Kelvin、纠正白平衡、添加统一暖色。保留用户显式 WB/temperature/tint；如果已开自动 WB，仍沿用其有限通道增益，不能声称像素颜色不变。
- 正向 EV 先受 P99 到 .98 的余量限制；窄范围不自动增加对比，高彩度/黑白/人像不增加彩度。随后在原输入分辨率渲染自动基础方案，按 100% / 75% / 50% / 25% / 0% 一起减弱增量。见 [自动增量检查](automatic-safety.md)。
- 原图曝光相对灰参考的卡片保持为信息级，曝光、近黑/近白、跨度卡片引用当前场景方向，避免高调被建议压暗、保留风格却又被建议纠正。原图统计与当前基础结果的处理方向明确分开。
- 这些检查不覆盖后续任意手调、LUT 或局部叠加的审美结果；原有 LUT 契约、细节/中性/高彩度保护和目标色域映射继续使用，见 [颜色协调](color-harmony.md)。不按题材擅自换 LUT。
- 若 baseline 显式打开旧式 autoExposure，先在原尺寸上求得旧全局曝光，把总 EV 记入有效 baseline 一次，然后关闭该开关再提出增量。保留风格的真实像素等价用例覆盖这一情况，避免关闭开关时丢失已接受曝光或二次叠加。

## 应用与数据兼容

「分析 → 题材与处理意图」可查看方向、规则匹配/保守回退/用户指定、面部框统计和可展开的依据。手动模式切换意图只更新分析与预览；点击方案后用于批处理。自动模式切换会逐张重算已选路线并保留手动差值；选择“保留已有风格”会把当前基础值同时设为 baseline 和 reference，固定当前结果。

`balanced` / `bright` / `soft` 稳定 ID 保留，标题和增量随场景变化。批处理每张重新测量，`analysis.sceneAssessment` 保存 `policyVersion=1`、requestedIntent、category、selectionSource、traits、evidence、uncertainties、subject 和三条计划增量；最终实际增量仍看 `proposalSafety`，实际叠加后参数看 `applied`。计划不会伪装成实际应用值。

`Recipe.version=4`。旧版本 1–3 没有 sceneIntent 时视为逐图判断；旧分析/报告缺 sceneAssessment 时仍可解码。带显式 sceneIntent 的配方不得手工标为 1–3，未知版本拒绝且不创建输出目录。旧手动参数继续读取；旧自动方案重新运行会使用当前算法，不能保证复现旧版渲染。旧应用必须拒绝版本 4。

## 分级、现场与回滚

- 大型变更，符合 AGENTS.md 3.1 的新增模块、跨模块公共行为、配方格式与默认行为变化、至少 3 个源文件及超过 150 行条件。
- 功能分支 `codex/scene-adaptive`；写入前建立，建分支 HEAD / 已验证基线均为 `e431bf3baa7a3fc3e0a589cfa5f5c45423101ecb`。
- 稳定分支 `main` 保留 `837ec592c5428e4e4cd360e91f2592d69321f92d`。无 remote，仅本地；开工工作区、暂存区、stash 为空，无用户改动需要隔离。
- 按用户指定使用 GPT‑6 Luna / max 子代理：仅拥有 `Tests/PhotoCoreTests/SceneAdaptiveTests.swift` 写权限，独立边界测试和只读审查；主代理复核，负责核心、UI、集成与最终验证。
- 按用户既有决定，提交后保留分支，人工验收后再合并。未 fetch/pull、安装、下载、推送、创建 PR 或发布。
- 撤销用 `git revert <本轮提交>`；本轮是独立场景策略意图。配方恢复到旧应用前须处理版本兼容，不能直接降版本忽略字段。打包脚本保留上一版应用，原片及既有输出不覆盖。

## 变更文件

新增：

- `Sources/PhotoCore/SceneAdaptiveProcessing.swift`：方向、证据与有界策略。
- `Sources/PhotoCore/FaceRegionAnalysis.swift`：人脸框亮度测量。
- `Sources/PhotoAtelier/SceneIntentPanel.swift`：意图与依据面板。
- `Tests/PhotoCoreTests/SceneAdaptiveTests.swift`：15 项场景、像素、坐标、分析方向一致性和兼容用例。
- `docs/scene-adaptive.md`：使用边界与本轮验收记录。

修改：

- `Sources/PhotoCore/PhotoAnalysis.swift`：基础结果测量、策略接入、实际方案与旧自动曝光去重。
- `Sources/PhotoCore/AutomaticProcessing.swift`：配方意图与逐张分析记录。
- `Sources/PhotoCore/BatchProcessor.swift`：每张传递意图、统一版本验证。
- `Sources/PhotoCore/Models.swift`：配方版本 4 与降级拒绝。
- `Sources/PhotoAtelier/AppModel.swift`：意图状态、分析失效、切换与读写。
- `Sources/PhotoAtelier/AnalysisPanel.swift`：接入意图面板。
- `Sources/PhotoAtelier/SmokeHarness.swift`：保留风格、恢复逐图、报告三项检查。
- `Tests/PhotoCoreTests/AnalysisTests.swift`、`AutomaticSafetyTests.swift`、`AutomaticTests.swift`、`BatchTests.swift`、`ColorCompatibilityTests.swift`、`LocalMaskTests.swift`：新行为契约和版本 1–4 回归。
- `README.md`、`docs/automatic-safety.md`：当前使用说明与历史快照指向。

旧测试原先要求“暗图必定比亮图提亮”，这会违背保留暗调/高调的新目标，现改为验证两类基调不被归一；逐张微调测试改选有证据产生不同增量的层次方案，仍断言每张独立计算和差值只携带一次。baseline 去重夹具改到新容忍区之外，并显式选择风光，以继续检验已有基础曝光会降低剩余增量。没有删除安全门槛、跳过用例或注释失败测试。

## 实际验证记录

工作目录 `/Users/mimi/project/ai调色`；Swift 5.8.1 / macOS 13.7.8 Intel x86_64。完整日志、快照与临时验证脚本放在忽略的 `artifacts/acceptance-scene-adaptive-20261102/`，不进入提交。

| 完整命令 | 退出码 | 关键输出与证据 |
|---|---:|---|
| `swift artifacts/acceptance-scene-adaptive-20261102/probe_rows.swift` | 0 | 独立确认 bitmap 第 0 行是几何上方：`first=0.8 last=0.1`；`bitmap-row-order.log`。 |
| `swift test -j 2 --filter 'AnalysisTests\|AutomaticTests\|AutomaticSafetyTests\|BatchTests\|LocalMaskTests.testRecipe'` | 1 | `focused-first.log`：新测试 helper 的默认参数错误引用实例成员 metrics/colors，且代理写入与首轮编译重叠，报告 input file modified during build。属于本轮测试/协调错误。 |
| `swift test -j 2 --filter 'SceneAdaptiveTests\|AnalysisTests\|AutomaticTests\|AutomaticSafetyTests\|BatchTests\|LocalMaskTests.testRecipe'` | 0 | 修复 helper 并等写入完成后编译，42 tests / 0 failures，14.728 秒；`focused-second.log`。最终全套覆盖未匹配到的单例过滤。 |
| `make check > artifacts/acceptance-scene-adaptive-20261102/check-final.log 2>&1` | 0 | 131 tests / 0 failures，361.143 秒，包含新增 14 项；编译提示一处无效 try。此快照早于随后分析方向文案一致性修复，不代替最终验证。 |
| `make check > artifacts/acceptance-scene-adaptive-20261102/check-verified.log 2>&1` | 0 | 最终快照 132 tests / 0 failures，160.507 秒，其中场景 15 项全过；构建 68.22 秒、测试编译 46.29 秒。新测试无效 try 已移除；仍有既有 Core Image Kernel API 弃用与测试异构字典类型推断 warning，未抑制。 |
| `bash Scripts/build_app.sh > artifacts/acceptance-scene-adaptive-20261102/release-build.log 2>&1` | 0 | Release 编译 82.61 秒；4 个签名 x86_64 库、55 XML、许可和可迁移加载路径检查通过。上一版保留为 `build/PhotoAtelier.previous-20261102-135635.app`。 |
| `codesign --verify --deep --strict --verbose=2 build/PhotoAtelier.app > artifacts/acceptance-scene-adaptive-20261102/codesign.log 2>&1` | 0 | valid on disk，satisfies its Designated Requirement。 |
| `PYTHONOPTIMIZE=1 python3 Scripts/verify_app.py build/PhotoAtelier.app > artifacts/acceptance-scene-adaptive-20261102/bundle-verify.log 2>&1` | 0 | 优化 Python 模式仍严格检查包内 4 库、55 XML、许可和加载路径，通过。 |
| `env -u PROJECT_ROOT /usr/bin/time -l '/Users/mimi/project/ai调色/build/PhotoAtelier.app/Contents/MacOS/PhotoAtelier' --self-test '/Users/mimi/project/ai调色/artifacts/acceptance-20261101/input' '/Users/mimi/project/ai调色/artifacts/acceptance-scene-adaptive-20261102/output-final' '/Users/mimi/project/ai调色/artifacts/acceptance-scene-adaptive-20261102/evidence-final' > '/Users/mimi/project/ai调色/artifacts/acceptance-scene-adaptive-20261102/release-smoke.log' 2>&1`（工作目录 `/tmp`） | 0 | APP_SMOKE PASS · 26 checks · 3 exported · 1 isolated。自身流程 27.552 秒、进程 real 29.87 秒，最大 RSS 959,852,544 bytes、peak footprint 1,264,300,032 bytes、0 swaps。原片哈希不变，检查含保留风格/恢复逐图、手动 +.5 EV 基线更新、LUT、实际 Lensfun、蒙版修边/颜色取样、P3 目标刷新、真实 RAW 分析及三预览。 |
| `swift artifacts/acceptance-scene-adaptive-20261102/verify_release.swift artifacts/acceptance-scene-adaptive-20261102/output-final > artifacts/acceptance-scene-adaptive-20261102/export-properties.log 2>&1` | 0 | ImageIO 完整解码 3 个 TIFF，16-bit、Display P3、orientation 1；两张 1600×1067，真实 CR2 4272×2848。 |
| `python3 artifacts/acceptance-scene-adaptive-20261102/verify_reports.py artifacts/acceptance-scene-adaptive-20261102/output-final artifacts/acceptance-scene-adaptive-20261102/evidence-final > artifacts/acceptance-scene-adaptive-20261102/reports.log 2>&1` | 0 | v4、26 项流程、蒙版减选与 LUT 前阶段保留；逐张独立场景依据，自动阈值、手动差值只叠加一次、P3 输出域与保留风格零增量均通过。 |
| `python3 artifacts/acceptance-scene-adaptive-20261102/audit_delivery.py > artifacts/acceptance-scene-adaptive-20261102/audit-final.log 2>&1` | 0 | 20 项本轮文件的空白、疑似凭据、大文件与本地文档链接检查；50 项源码指纹与最终验证快照一致。暂存后同样扫描暂存路径与空白。 |

以上失败与 warning 的修正均保留记录；没有跳过用例。随后复核发现旧观察卡片仍可能建议把高调压暗，因此让卡片采用场景方向，中灰偏差只作信息，并补充针对性测试。

最终检查后记录 `Sources/Tests/Scripts/Resources` 共 50 项 SHA-256，后续打包与提交核对同一快照。基线失败：本轮未发现，不把首轮新增测试/协调错误说成无关基线失败。

实际批处理的三张图均回退 `general`，各自依据不同，并未强行选择题材；山谷合成图 / 色阶 / CR2 的自动 EV 分别为 +.12 / .00 / +.12，最终 EV 为 +.32 / +.20 / +.32。这里基线在“保留已有风格”步骤固定为 +.20，后续按报告中的 baseline、proposalSafety、current 和 reference 核对一次叠加关系，未硬编码旧版的差值假设。新增高光越界为 .000031 / 0 / 0，新增黑位均为 0；最终目标域外比例均为 0。这些统计不证明审美最优。

主代理实际查看新包的 `02-scene-intent.png`、`02-analysis.png`、`05-raw-analysis.png`：意图/来源/方向和三方案卡片可见，真实 RAW 预览完成，未发现所查看区域的文字重叠或截断。界面渲染快照与数值检查都不算鼠标交互验收。

项目入口对照：`make build` / `make test` 由最终 `make check` 执行；`make app` 的同一入口 `bash Scripts/build_app.sh` 已执行；无独立 Lint 入口。`make run` / `open` 未另执行，已用 `/tmp` 独立二进制启动自检；系统文件夹选择、退出确认与原生鼠标交互未执行，原因见下方 CUA 故障。无合并，稳定分支合并后回归不适用。

### 人工验收后再合并

- [ ] 在新应用通过系统文件夹选择器打开照片，鼠标切换意图与三方案，再保存/载入 v4 配方，确认选择保留。
- [ ] 使用真实高调、暗调、夜景、人像、柔雾及已调色 JPEG/RAW，比较原片、三预览与导出；尤其检查人脸亮度、黑白关系、冷暖与滤镜强度。
- [ ] 检查不同构图下的局部蒙版；它们不会自动跟踪主体，不能直接把一张的几何选区当作整批的正确选区。
- [ ] 验证取消与退出确认；确认上述人工项后再决定合并。分支保留期间不删除提交或上一版应用。

## 已知问题与下一步

本轮没有用户提供的“调坏”前后样本，没有足量真实人像、夜景、雪景、胶片风格的标注审美集。规则阈值不能被解释为专业修图的普适最优解；自动保留风格识别仍需用户明确选择。真实 CR2 验证只能证明当前相机样本的处理/导出链路，不能代表全部 RAW 型号与不同风格画质。

本轮实际尝试 CUA `getApp`，返回 `Sky Computer Use service startup request failed`。应用自身流程自检和 SwiftUI 快照可继续运行，不能替代鼠标键盘、系统对话框和退出交互验收；未用其他自动化绕过。下一步按高调、暗调、夜景、肤色、柔雾和已调色 JPG/RAW 比较原片与导出，确认后再决定合并，不重复索取风险接受。

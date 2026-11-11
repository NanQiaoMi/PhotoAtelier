# 自动基础调整的保守约束与验证

本页记录 `e431bf3` 的历史验证快照。当前三方案已按照片证据与用户意图区分处理目标，规则、配方版本和最新验证见 [场景与处理意图](scene-adaptive.md)；下述原尺寸增量检查继续使用。

## 目标与验收

用户担心曝光、白平衡和多项参数相互叠加后把照片调坏，目前没有实际问题样本。本轮使用已有 Canon CR2 与可重复的暗调、高调、雾景、稀疏高光和高频亮点夹具，减少过度自动纠正，保留用户选择和原片。数值检查不等同审美验收。

- [x] 新照片默认不自动改曝光或白平衡；三个方案不擅自开启白平衡、不额外加暖。
- [x] 方案依据原有基础参数处理后的图像估计增量，保留 LUT、几何与局部设置；手动模式改变基础参数后重新分析，自动模式的微调差值只携带一次。
- [x] 保守方案曝光增量最多 ±0.25 EV；暗调、高调或窄亮度范围最多 ±0.10 EV；明亮方案额外最多 +0.15 EV、总增量最多 +0.40 EV。
- [x] 自动增加对比度不用于窄亮度范围；三个方案的曝光、对比、彩度、高光、阴影增量一起接受实际渲染检查和回退。
- [x] 相关测试覆盖高光与黑位回退、负通道、细密亮点、透明度、非零原点、显式 WB、旧 JSON、单个原尺寸异常像素与非有限手调拒绝。
- [x] 最终快照完整 `make check`：117 tests / 0 failures。
- [x] Release 包、真实 RAW 独立运行及导出属性复读：23 项应用检查，3 成功 / 1 坏图隔离，原片哈希保持。
- [ ] 原生鼠标、文件夹对话框、退出确认，以及真实用户照片的审美比较。按用户决定，完成前保留功能分支，不合并。

## 为什么要改

基线的三方案曝光建议可达 ±1.5 EV；正向建议仅在近白样本超过 1% 时才受 P99 余量限制。90% Y=.05、8.9% Y=.30、0.6% Y=.70、0.5% Y=1.0 的线性灰分布可以绕过该条件，单按曝光公式把 .70 提至约 1.98。这是源码推导的反例，不冒称本轮已在旧引擎上复现。

基线也会在发现足量近中性候选后自动开启 WB。暖灰 [.21,.20,.19] 符合候选规则，却可能是物体本色或有意暖光。近灰证据不能证明白点错误。旧版建议还依据原图测量后直接加到用户 baseline，可能重复纠正已有曝光。

## 处理规则

### 先保留拍摄与用户意图

新 `AdjustmentSettings` 默认 `autoExposure=false`，`autoWhiteBalance=false`。已有手动配方中的显式值继续读取。RAW 解码仍保留 as-shot 白点和相机基准曝光归一化，不更改 RAW 解码约定。

三个方案关闭额外的引擎自动曝光，沿用 baseline 的 WB 模式、手动温度和色调。若用户已经开启自动 WB，仍按该选择运行有限通道增益；这不意味着输出颜色保持不变。用户显式开启“自动曝光”时仍采用旧式最多 ±0.35 EV 的中灰估计，这个开关不经过三方案的增量检查，界面有说明。

### 根据已经处理的基础图像估计有限变化

保留原图指标用于分析报告；另用 baseline 的基础参数处理最长边 384 的样本后，计算建议方向。排除镜头/几何、LUT 和局部蒙版，不让局部或滤镜反向驱动全局自动纠正。

- 仅使用一半的中位亮度相对 18% 灰方向信号，再限制自动增量，不以中位数定义曝光正确性。
- P50 <.04、P50 >.60 或 P05–P95 <3.5 EV 时收紧至 ±.10 EV，且不自动增加对比度。普通保守方案最多 ±.25 EV。
- 正向曝光始终检查 P99 余量，不再要求近白比例先超过 1%。明亮方案在余量允许时额外最多 .15 EV，受限场景额外最多 .05 EV。
- 普通自动对比增量最多 +.02 / −.05；阴影最多 +.06，高光收回最多 .10（柔和方案），明亮彩度增量最多 .025。它们只是有限偏好，不是照片一定有问题的判断。
- 手动模式下修改基础参数会更新分析；选择自动方向后，批处理逐图重算，再叠加用户微调差值一次。自动模式不把微调反馈成新的 baseline 循环纠正。

### 实际渲染后回退

`AutomaticSafetyEvaluator` 使用与导出相同的全局基础处理路径，分别渲染 baseline 与候选，排除后续手调、LUT、几何和局部蒙版。

新增高光越界按任一对应线性 sRGB 通道从 <1 到 ≥1 计数；新增黑位按 Y 从 >.002 到 ≤.002，或对应通道新低于 −.0001 计数。透明度 ≤.001 忽略，其余以 alpha 加权。与 baseline 比较，不把原有黑白位当作本轮新增。

对大于 192 的输入，先在**本次输入分辨率的基础渲染**上生成阈值图，再作面积归约，避免缩图先平均掉细密亮点。小输入直接读像素计数。原尺寸阈值图用独立 alpha 标记异常可见数据，最小值归约会拒绝单个异常像素；支持当前 half-float 全局处理的有限范围。另有最长边 192 的有限值/可见样本检查。预览图可能已缩小；完整批处理会在原图上重新运行检查。比例受浮点归约精度影响，不是精确传感器剪切检测。

依次尝试自动增量的 100%、75%、50%、25%、0%，选择新增高光和黑位/负通道比例均不超过 .5% 的第一档；所有基础数值增量一起缩减，而非只改曝光。0% 保留用户已有基础参数，仍关闭第二次引擎自动曝光。无可见参考或检查无法完成时报错，不静默宣布安全。

`AutomaticSafetyReport` 记录原建议和最终新增比例、保留强度、实际自动 EV 增量、原因与范围。分析 JSON 的 `proposals[].safety` 及逐张清单的 `analysis.proposalSafety` 均保存；字段可选，旧分析/清单缺失时仍可读。`analysis.applied` 是叠加后实际基础参数，不能把 `proposalSafety` 当作其全部处理的证明。

### 明确边界

检查不能证明曝光、色温、氛围或构图在审美上更合适；不能恢复原片已丢失的高光、黑位或 RAW 感光单元信息；不会自动寻找语义主体边界。

用户原有参数已经过重时，本轮只限制新增自动纠正。后续任意手调及 LUT/局部叠加仍可造成不理想的亮暗或颜色，应继续用前后比较和导出检查。现有颜色协调/目标色域映射仍运行，但不是通用审美保证。对比不同方案时可以保留原片或回到“重置”；不必强制采用任何自动结果。

旧自动配方重算会采用当前算法；如需固定已有结果可切回统一手动参数。没有更改配方版本或静默删除 LUT/蒙版。

## 分级、分支与回滚

- 大型变更：符合用户 AGENTS.md 3.1 新增模块、跨模块公共行为、默认行为变化、至少 3 个非测试源文件及超过 150 行的条件。
- 当前功能分支：`codex/automatic-safety`；建分支 HEAD／已验证基线：`592d06227b3689ec7c1799e78f49a9ad374a3274`。
- 集成分支 `main` 保留 `837ec592c5428e4e4cd360e91f2592d69321f92d`；无 remote，仅本地。开工工作区、暂存区、stash 为空。
- 复用同一基线已有验证记录（103 tests / 0 failures，见颜色协调记录）；本轮未冒称重跑过开工完整基线。没有新增依赖或下载样本。
- GPT‑6 Luna / max 子代理独立撰写边界测试并两次只读复核；核心、UI、集成与最终验证由主代理负责。
- 不执行合并、推送、PR、安装或发布。若需撤销本轮提交，用 `git revert <本轮提交>`；打包脚本保留上一版应用，原片和既有导出不覆盖。

## 实际验证记录

默认工作目录 `/Users/mimi/project/ai调色`。本机 Swift 5.8.1 / macOS 13.7.8 Intel x86_64。完整日志和临时脚本位于忽略的 `artifacts/acceptance-auto-safety-20261102/`；最终产物不入库。

| 完整命令 | 退出码 | 关键输出与证据 |
|---|---:|---|
| `swift test -j 2 --filter 'AutomaticSafetyTests\|AnalysisTests\|AutomaticTests\|BatchTests'`（首轮） | 1 | 24 tests / 1 failure，11.205 秒；新 10 项安全测试全过，旧分析 JSON 精确相等断言失败；`focused-first.log`。 |
| `swift test -j 2 --filter AnalysisTests.testDarkerPixelsReceiveGreaterExposureRecommendation`（诊断） | 1 | 定位到 soft 的 settings/safety EV，.07 → .07000000000000003；`roundtrip-diagnostic.log`。 |
| `swift -e 'import Foundation; let x = 0.07; let data = try JSONEncoder().encode(x); let y = try JSONDecoder().decode(Double.self, from: data); print("encoded=\(String(data: data, encoding: .utf8)!) input=\(x) decoded=\(y) error=\(y-x)")'` | 0 | 独立复现系统 JSON 浮点误差 2.7755575615628914e-17；`foundation-double.log`。 |
| `swift test -j 2 --filter 'AutomaticSafetyTests\|AnalysisTests\|AutomaticTests\|BatchTests'`（第二轮） | 1 | 26 tests / 3 failed assertions，11.673 秒；均在新增半透明夹具；`focused-second.log`。 |
| `swift test -j 2 --filter 'AutomaticSafetyTests\|AnalysisTests\|AutomaticTests\|BatchTests'`（修正夹具预乘） | 0 | 26 tests / 0 failures，11.391 秒；`focused-third.log`。 |
| `swift test -j 2 --filter 'AutomaticSafetyTests\|AnalysisTests\|AutomaticTests\|BatchTests'`（加入原尺寸面积检查与细亮点） | 0 | 27 tests / 0 failures，9.064 秒；`focused-native.log`。384×384 请求新增越界 .5，保留强度 .25，最终新增 0。 |

失败修正均如实保留，未跳过用例：系统浮点误差改为 EV 的 1e-12 数值容差，其余设置/报告字段逐项检查；半透明夹具原先把直 RGB 写入要求预乘的 bitmap，修正为 RGB×alpha 后再检验权重，没有改产品阈值迎合夹具。独立审查提出先缩图可能丢失高频亮点，随后加入阈值先于面积归约的实现及真实像素回归。

原尺寸检查补强后，`swift test -j 2 --filter AutomaticSafetyTests` 返回 0：14 tests / 0 failures，8.651 秒；`focused-invalid.log`，包含仅一个可见 NaN/Inf 的拒绝与不可见异常忽略。此前 `make check` 返回 0：116 tests / 0 failures，56.912 秒，`check-final.log`；首轮 `bash Scripts/build_app.sh` 返回 0，包内库/数据库/许可/签名通过，`release-build.log`。这两个首轮快照早于最终异常像素补强，不能代替最终验证。最终 `make check` 返回 0：117 tests / 0 failures，55.484 秒，构建 1.48 秒；`check-verified.log`。最终 `bash Scripts/build_app.sh` 返回 0：Release 编译 48.58 秒，4 个签名 x86_64 库、55 XML、许可及可迁移加载路径通过；`release-verified-build.log`。上一包保留为 `build/PhotoAtelier.previous-20261102-014238.app`。独立运行结果见下表。基线失败：本轮目前未发现；不把上述新增测试或新输出触发的失败说成无关基线失败。

## 最终快照验证

| 完整命令 | 退出码 | 关键输出与证据 |
|---|---:|---|
| `make check` | 0 | 117 tests / 0 failures，55.484 秒；构建 1.48 秒；`check-verified.log`。 |
| `bash Scripts/build_app.sh` | 0 | Release 48.58 秒；包内库、数据库、许可、签名与可迁移加载路径通过；`release-verified-build.log`。 |
| `env -u PROJECT_ROOT /usr/bin/time -l '/Users/mimi/project/ai调色/build/PhotoAtelier.app/Contents/MacOS/PhotoAtelier' --self-test '/Users/mimi/project/ai调色/artifacts/acceptance-20261101/input' '/Users/mimi/project/ai调色/artifacts/acceptance-auto-safety-20261102/output-final' '/Users/mimi/project/ai调色/artifacts/acceptance-auto-safety-20261102/evidence-final'`（工作目录 `/tmp`） | 0 | APP_SMOKE PASS · 23 checks · 3 exported · 1 isolated。自身流程 30.660 秒、进程 real 32.04 秒，最大 RSS 929,214,464 bytes、peak footprint 1,248,845,824 bytes、0 swaps；`release-smoke.log`。 |
| `codesign --verify --deep --strict build/PhotoAtelier.app` | 0 | 严格签名验证，`signature.log`。 |
| `PYTHONOPTIMIZE=1 python3 Scripts/verify_app.py build/PhotoAtelier.app` | 0 | 4 个签名 x86_64 库、55 XML、精确许可集合与可迁移路径，优化模式仍完整验证；`bundle-verify.log`。 |
| `swift artifacts/acceptance-auto-safety-20261102/verify_release.swift artifacts/acceptance-auto-safety-20261102/output-final` | 0 | ImageIO 完整复读 3 个 TIFF，16-bit、Display P3、orientation 1；两张 1600×1067，真实 CR2 4272×2848；`export-properties.log`。 |
| `python3 artifacts/acceptance-auto-safety-20261102/verify_reports.py artifacts/acceptance-auto-safety-20261102/output-final artifacts/acceptance-auto-safety-20261102/evidence-final` | 0 | 配方 v3、LUT 前蒙版及减选保留；3 张自动增量检查、WB 模式、一次 +.20 EV 微调、目标域内输出与 23 项流程记录均核对；`reports.log`。 |
| `python3 artifacts/acceptance-auto-safety-20261102/audit_delivery.py` | 0 | 13 项变更文件的空白、疑似凭据、大文件和本地文档链接检查；46 项源码指纹与最终验证快照一致；`audit-final.log`。 |
| `git diff --check` | 0 | 无空白错误。 |

长命令使用上表日志文件重定向保留 stdout/stderr；记录的是被测命令的实际退出码。验证脚本与日志只在忽略的 artifacts 中，不进入提交。最终包与完整测试对应同一组 46 项 Sources/Tests/Scripts/Resources 的 SHA-256；文档收尾不更改这些源码。

| 样本 | 自动增量 | 保留强度 | 新增高光 / 黑位或负通道 | 叠加一次 +.20 EV 后 |
|---|---:|---:|---:|---:|
| 山谷合成图 | +.0500 EV | 50% | 0 / 0 | +.2500 EV |
| 色彩与中性阶图 | +.1443 EV | 100% | 0 / 0 | +.3443 EV |
| Canon EOS 1100D CR2 | +.1000 EV | 100% | 0 / 0 | +.3000 EV |

这里的 0 是该三张样本、当前输入和自动基础增量的实测比例，不外推为所有照片的保证。LUT/蒙版叠加后的目标 P3 域外取样为 0，由另一组颜色报告记录；不把它和自动基础增量检查混为一谈。

已实际查看 `02-automatic-safety.png` 与 `05-raw-analysis.png`：已采用方案显示自动增量、保留比例、原建议新增风险和范围；三卡片区分总补偿和自动增量，文字无重叠。真实 RAW 的晨雾、树与道路仍可见，未因窄范围而自动增加对比。这是应用自身视图复核，不能代替用户照片的审美验收或鼠标操作。

既有入口对照：`make build` 与 `make test` 由最终 `make check` 完整覆盖；`make app` 由最终 `bash Scripts/build_app.sh` 覆盖。`make run` 的 Finder 打开与真实交互未执行，原因是本轮无可调用原生 CUA；保留人工验收。合并及合并后 main 回归未执行，遵循用户“保留已提交功能分支，人工验收后再合并”的决定。没有 `--no-verify`，没有跳过用例。最终无未解决自动测试失败。

## 文件清单

新增：

- `Sources/PhotoCore/AutomaticSafety.swift`
- `Tests/PhotoCoreTests/AutomaticSafetyTests.swift`
- `docs/automatic-safety.md`

修改：

- `README.md`
- `Sources/PhotoCore/Models.swift`
- `Sources/PhotoCore/PhotoAnalysis.swift`
- `Sources/PhotoCore/AutomaticProcessing.swift`
- `Sources/PhotoAtelier/AppModel.swift`
- `Sources/PhotoAtelier/AnalysisPanel.swift`
- `Sources/PhotoAtelier/ContentView.swift`
- `Sources/PhotoAtelier/SmokeHarness.swift`
- `Tests/PhotoCoreTests/AnalysisTests.swift`
- `docs/color-harmony.md`

无删除文件。


## 尚未覆盖与使用建议

- 本轮只有现有三张成功样本和可重复边界夹具，没有真实被调坏照片；不能由此推断所有题材都合适。
- 仅 Intel / macOS 13 当前机器验证；Apple Silicon、其他系统版本、其他 RAW 相机变体和长期大批量运行未验收。
- 原生鼠标、系统文件选择、退出确认未执行；当前没有可调用的本机 CUA，应用自身命令与视图快照不能替代人工交互。
- 保留 Core Image source-kernel 的既有系统弃用警告；未隐藏警告或跳过检查。
- 建议首次试用小批量，前后对比三种方案后再调局部和 LUT；不满意可保留原片、重置或使用统一手动参数。用户人工验收前不合并。

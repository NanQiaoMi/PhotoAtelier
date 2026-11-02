# 亮度分区、可编辑局部建议与实拍复测

## 目标、范围与验收

用户要求用提供的真实照片继续调试，增加有针对性的参数。此次沿用本机 SwiftUI / Core Image / Lensfun 管线，不安装依赖、不联网、不上传照片。原片只读，输出、路径索引、数值分析及缩略图放在忽略的 `artifacts/acceptance-targeted-20261102/`。用户提供的桌面样本共 10 张：8 张照片（花卉、海岸、岩石、逆光建筑、夜间桥梁等）与 2 张图形，9 JPG / 1 PNG；未确认是否已后期处理。本批没有真实人像或 RAW，不能用它证明这些题材的画质。

- [x] 五区 EV 中性严格恒等，保 alpha/extent，纯黑不抬；验证强调整的单调与平滑、软件/Metal 和 CPU 数学镜像的一致性。
- [x] 旧配方 1–4 的光线处理路径保留，5 保存五区；拒绝非中性曲线伪装旧版，自动手动差值只应用一次。
- [x] 三方案按亮度证据区分暗亮，04/08 保留明亮基调，03/07 可选择增加阴影可读性，06 保留夜色；原自动越界门槛保持。
- [x] 局部建议按位置/亮度提供依据，不自动应用，采用后可编辑且重复采用不堆叠；亮度范围和坐标经渲染验证。
- [x] 10 张样本无处理失败、无非有限样本，原片哈希不变；实际查看原图、三方案与局部处理结果。
- [x] 项目 `make check`、Release 打包、签名/包验证、独立运行和应用命令流程通过。
- [ ] 原生鼠标、文件选择器、退出确认及用户审美验收；按用户既有决定保留功能分支，验收后再合并。

## 基线问题与处理原理

基线为 `f2d7cb06082989ca01ede1831f3eb3cfc1a33903`。旧阴影/高光系数实际使用 `color += color * parameter * 0.15 * weight`，自动参数多为 .015–.045，对目标区域的 RGB 变化上限约 0.225%–0.675%，很难形成有用的层次选项。泛用中灰逻辑还会将部分高亮照片整体压暗。冻结基线评估器对 10 张图完成原图加三方案测量，`policyVersion=1`，没有用新模块冒充旧版。

新增 `TonalCurveSettings` 的五区值单位为 EV（范围 ±3），在全局旧参数之后、几何/局部/LUT 之前处理线性亮度。五区对应 .0078125、.0625、.18、.6、1 等亮度锚点，保留零亮度与扩展白。先在 log2 结点上作保序投影，再在线性亮度域插值单调 PCHIP；相邻极端数值会互相约束，滑杆不是五个独立硬阈值。RGB 共享亮度增益，保留通道比例与灰中性；不凭空恢复剪切细节，不用加色掩盖亮度问题。最终目标色域映射和已有颜色协调继续运行。

旧曲线的语义不变。旧 JSON 缺 `tonalCurve` 解码为 nil；新建配方为中性曲线，直接绕过渲染。`Recipe.version=5`，读取 1–5；非中性曲线出现在当前参数、自动 baseline 或 reference 任一处时，不得标为版本 1–4。新曲线参与全套自动差值、统一回退和实际报告。关闭分区视为用户选择，不因批处理重新打开，即使 reference 也为 nil。旧自动配方可采用当前算法的其他调整，但缺失/关闭的分区仍保持关闭；在基础页开启分区或显式采用带分区的新方案后，才参与新的曲线处理。

### 三方案的方向

`policyVersion=2` 使用原图基础结果的 P05/P95、明暗比例与原场景方向来决定分区增量。未确定题材的保守方案保留全局亮度，不再按中灰压暗；暗亮方案只在阴影、跨度和暗部占比同时支持时提暗部。高调识别新增明亮中位值与亮部/暗部比例的联合证据，用于保留明亮基调；没有扩大 outdoor 标签来伪装风光识别。逆光提供阴影提升与亮部压缩，高 ISO 的暗调提升更小；白平衡、温度、色调和 LUT 继续由用户选择。

自动基础增量仍在当前输入分辨率上渲染，按 100% / 75% / 50% / 25% / 0% 一起减弱，新增 SDR 越界与黑位/负通道各 ≤0.5%；五区也纳入相同保留比例，实际值保存在 `proposalSafety.tonalDelta` 与 `applied.tonalCurve`。这些检查不约束后续任意手调、蒙版或 LUT 的审美，也不证明原图曝光有误。

### 局部建议的能力范围

在全局校正与几何之后、蒙版/LUT 之前的固定参考上，以最长边 192、alpha 加权的 3×3 网格测量各区 P50/P90。仅在不同区域存在明显亮度差时，返回最多一条阴影与一条亮部建议；均匀暗调和均匀高调没有强迫矫正。返回依据、拟用 EV、亮度范围和局限，不自动应用。

点击采用后生成径向羽化、限亮度范围、LUT 前的可编辑蒙版，默认高光/色彩保护打开。位置按左下坐标转换，并覆盖非零 extent 测试；稳定 ID 令重复采用替换自己的建议蒙版，避免无意叠加。用户仍可用画笔加减选、颜色范围和局部参数精修。网格不是人脸/天空/主体分割，也不是最佳区域检测。整批共用几何蒙版，构图不同必须逐张复核，不提供主体跟踪。

## 实际验证记录

工作目录为项目根目录（独立运行特别注明 `/tmp`）；macOS 13.7.8 / Swift 5.8.1 / Intel x86_64。所有日志、私有源路径索引、图片与临时验证脚本均在忽略的 `artifacts/acceptance-targeted-20261102/`。没有跳过用例或放宽 0.5% 自动阈值。以下是实际执行记录，最终源快照复核另见文末。

### 基线与针对性检查

首次基线评估器编译把模块路径误写为 `debug/Modules`，退出 1、`no such module PhotoCore`。改为 Swift 5.8 实际的 debug 根路径后，以下完整命令退出 0；生成后冻结此基线二进制，随后才重编新核心：

```bash
swiftc -I .build/x86_64-apple-macosx/debug -I .build/x86_64-apple-macosx/debug/CLensfunBridge.build Scripts/evaluate_photos.swift .build/x86_64-apple-macosx/debug/PhotoCore.build/*.o .build/x86_64-apple-macosx/debug/CLensfunBridge.build/CLensfunBridge.c.o -o artifacts/acceptance-targeted-20261102/evaluate-baseline
```

基线运行 `artifacts/acceptance-targeted-20261102/evaluate-baseline "$PHOTO_INPUT" artifacts/acceptance-targeted-20261102/baseline > artifacts/acceptance-targeted-20261102/baseline-evaluation.log 2>&1`，退出 0：10 completed / 0 failures。此处仅将实际私有输入目录脱敏为变量；原始命令保留于忽略的 `baseline-command.txt`，源文件名和路径映射不入库。

| 完整命令 | 退出码 | 真实结果与修正 |
|---|---:|---|
| `swift test -j 2 --filter 'TonalCurveTests\|SceneAdaptiveTests\|AutomaticTests\|AutomaticSafetyTests' > artifacts/acceptance-targeted-20261102/focused-first.log 2>&1` | 1 | 41 tests / 218 failed assertions。新曲线逐像素 log/pow 的微反转、极端曲线单步过大、软件/Metal 白位差异；另有测试把 RGBA 的通道当下一像素。均是本轮新增实现/测试问题。 |
| `swift test -j 2 --filter 'TonalCurveTests\|RegionalSuggestionTests\|SceneAdaptiveTests\|AutomaticTests\|AutomaticSafetyTests' > artifacts/acceptance-targeted-20261102/focused-second.log 2>&1` | 1 | 44 tests / 121 failed assertions。改为线性 PCHIP 后仍有软件除法误差引发微反转；邻近 .25 线性灰位于编码亮度羽化区，原测试错误要求它不变。 |
| `swift test -j 2 --filter 'TonalCurveTests\|RegionalSuggestionTests\|SceneAdaptiveTests\|AutomaticTests\|AutomaticSafetyTests' > artifacts/acceptance-targeted-20261102/focused-third.log 2>&1` | 1 | 44 tests / 17 failures，其中 15 unexpected。精化倒数变量误用 Core Image 保留名 `inverse`，kernel 无法生成；改名后恢复。 |
| `swift test -j 2 --filter 'TonalCurveTests\|RegionalSuggestionTests\|SceneAdaptiveTests\|AutomaticTests\|AutomaticSafetyTests' > artifacts/acceptance-targeted-20261102/focused-fourth.log 2>&1` | 1 | 44 tests / 24 assertions。曲线单调/平滑与局部测试已过，余下均为软件读回路径自身的解预乘精度偏差，见独立实验。 |
| `swift test -j 2 --filter 'TonalCurveTests\|RegionalSuggestionTests\|SceneAdaptiveTests\|AutomaticTests\|AutomaticSafetyTests' > artifacts/acceptance-targeted-20261102/focused-fifth.log 2>&1` | 0 | 44 tests / 0 failures，12.037 秒；新曲线 10 项、局部建议 3 项全部通过。 |

实现先采用结点单调投影与线性域 PCHIP，继而对 kernel 的变量除法做两轮 Newton 倒数精化，以消除软件 JIT 近似倒数对浅曲线的扰动；没有通过放宽灰阶单调/单步门槛掩盖问题。独立实验记录：

- `swift artifacts/acceptance-targeted-20261102/probe_reciprocal.swift > artifacts/acceptance-targeted-20261102/probe-reciprocal.log 2>&1`：退出 132；临时 probe 的函数名 `inverse` 冲突，nil 强制解包失败，仅涉及验证脚本。
- 同一命令将日志改为 `probe-reciprocal-corrected.log`：退出 0；软件 `outputPremultiplied=false` 下，连无 kernel 的 1.0 原样输入也会读回 0.99975586；这不是色调曲线误差。
- `swift artifacts/acceptance-targeted-20261102/probe_premultiplied.swift > artifacts/acceptance-targeted-20261102/probe-premultiplied.log 2>&1`：退出 0；预乘读回保持原输入，普通除法 .33 常量输出仍偏差约 8e-5，精化倒数后约 .32999998–.33000004，与 GPU 对齐。

曲线数学测试据此改为预乘读回、在 Swift 中按 alpha 解预乘，保持原 CPU 镜像相对误差 1e-5，不把系统读回误差混入 kernel 断言。局部范围测试把邻近色块从线性 .25 改成 .40：原值编码约 .537，确实处于上界 .50、softness .15 的过渡区；新值约 .665，在羽化外仍位于径向内，继续验证相反亮度不受影响，断言阈值没有放宽。

### 桌面照片复测

初次新版评估 `iteration-1` 已完成 10 / 0；修复自动关闭状态后重新编译最终评估器并重跑到新目录：

```bash
swiftc -I .build/x86_64-apple-macosx/debug -I .build/x86_64-apple-macosx/debug/CLensfunBridge.build Scripts/evaluate_photos.swift .build/x86_64-apple-macosx/debug/PhotoCore.build/*.o .build/x86_64-apple-macosx/debug/CLensfunBridge.build/CLensfunBridge.c.o -o artifacts/acceptance-targeted-20261102/evaluate-verified > artifacts/acceptance-targeted-20261102/evaluator-verified-build.log 2>&1
artifacts/acceptance-targeted-20261102/evaluate-verified "$PHOTO_INPUT" artifacts/acceptance-targeted-20261102/verified > artifacts/acceptance-targeted-20261102/photos-verified.log 2>&1
python3 artifacts/acceptance-targeted-20261102/verify_photos.py artifacts/acceptance-targeted-20261102/verified > artifacts/acceptance-targeted-20261102/photo-comparison.log 2>&1
```

运行时 `PHOTO_INPUT` 为用户授权的照片目录，其值只保存在本地产物内。以上命令均退出 0：10 inputs / 10 completed / 0 failures，30 个方案与 12 条可选择的局部建议，无非有限样本，10 个原片 SHA-256 与开工一致。三方案原尺寸检查的最大新增高光越界为 .000357628（约 0.0358%）、黑位/负通道为 .000091851（约 0.0092%），均低于 .005；不是全片剪切比例，更不是审美分数。

下表的分区 EV 为最长边 192 采样后，按原图亮度划分 Y<.12 / .12–.55 / ≥.55 的平均亮度比换算；它不同于滑杆结点 EV，不能解释为某个物体的曝光变化。

| 样本 | 旧行为 | 新版实测与查看结论 |
|---|---|---|
| 03 海岸 | bright 各区近 +.06 EV，一起提亮 | bright 暗部 +.3045、中间 −.0238、亮部 −.0269 EV；前景更可读，天空变化较小，balanced 保留原图。 |
| 07 逆光建筑 | bright 暗部仅 +.0088 EV、亮部 −.0045 EV | bright 暗部 +.4252、中间 −.0830、亮部 −.1892 EV；暗建筑与亮天空分别处理，白点/色温不自动变更。 |
| 04 / 08 明亮花卉与花园 | balanced 全图约 −.12 EV | 联合亮度证据归为 highKey，balanced RGB RMS=0；另给有限亮部层次选项，保留选择权。 |
| 06 夜间桥梁 | balanced 原样；bright 全图约 +.04 EV | balanced 仍 RMS=0；bright 暗部 +.3412、亮部 +.0403 EV，保留暗背景与灯光对比，并非把夜色拉到白昼。 |
| 01 / 05 花卉与岩石 | 阴影选项主要是全局 +.06 EV | bright 暗部分别 +.2182 / +.2127 EV；亮部略降，保守方案保持原图。 |
| 09 / 10 图形 | balanced 全图约 −.12 EV | balanced RMS=0，不把明亮背景强迫归一到灰；局部建议仍可能来自图形亮度，需要用户辨别，未当成主体识别。 |

主代理查看了三张四列对比图（10 个原图与三方案）、03 的大图前后、07 的分区方案与单个阴影蒙版、04 的柔和结果。最终复跑的 52 JPEG + 3 contact PNG 与已查看版本逐文件 SHA-256 相同。原文件和路径映射没有放进代码提交。

### 构建、应用与导出

| 完整命令 | 退出码 | 实际结果 |
|---|---:|---|
| `make check > artifacts/acceptance-targeted-20261102/check-final.log 2>&1` | 0 | 145 tests / 0 failures，53.110 秒；随后只读审查补了关闭状态、空目录和覆盖显示修正，不将此轮冒充最终快照。 |
| `make check > artifacts/acceptance-targeted-20261102/check-verified.log 2>&1` | 0 | 145 tests / 0 failures；此轮包含关闭状态修复，早于后续 UI 状态修复。 |
| `make check > artifacts/acceptance-targeted-20261102/check-delivery.log 2>&1` | 0 | 145 tests / 0 failures，88.779 秒；后续只修正 self-test 的浮点读回断言。 |
| `make check > artifacts/acceptance-targeted-20261102/check-final-snapshot.log 2>&1` | 0 | 最终快照：145 tests / 0 failures、无跳过，57.130 秒；build 5.39 秒、测试 build .33 秒。包含全部最终源码与 harness。 |
| `bash Scripts/build_app.sh > artifacts/acceptance-targeted-20261102/release-build.log 2>&1` | 0 | Release 72.62 秒，4 签名库 / 55 XML / 许可及可迁移加载路径通过；第一次应用流程后发现新增 harness 断言过严。 |
| `bash Scripts/build_app.sh > artifacts/acceptance-targeted-20261102/release-build-verified.log 2>&1` | 0 | 最终 Release 编译 26.96 秒；所有包验证通过，上一 app 保留为 `build/PhotoAtelier.previous-20261102-151753.app`。 |
| `codesign --verify --deep --strict --verbose=2 build/PhotoAtelier.app > artifacts/acceptance-targeted-20261102/codesign-verified.log 2>&1` | 0 | valid on disk；satisfies its Designated Requirement。 |
| `PYTHONOPTIMIZE=1 python3 Scripts/verify_app.py build/PhotoAtelier.app > artifacts/acceptance-targeted-20261102/bundle-verify-final.log 2>&1` | 0 | 优化 Python 模式下也严格检查包内 4 库、55 XML、许可、加载路径，通过。 |
| `swift artifacts/acceptance-targeted-20261102/verify_release.swift artifacts/acceptance-targeted-20261102/output-verified > artifacts/acceptance-targeted-20261102/export-properties.log 2>&1` | 0 | ImageIO 完整解码 3 TIFF：16-bit、Display P3、orientation 1；两张 1600×1067，真实 CR2 4272×2848。 |
| `python3 artifacts/acceptance-targeted-20261102/verify_reports.py artifacts/acceptance-targeted-20261102/output-verified artifacts/acceptance-targeted-20261102/evidence-verified > artifacts/acceptance-targeted-20261102/reports.log 2>&1` | 0 | 配方 v5 / 策略 v2，30 项流程、3 完成 / 1 隔离；每张独立依据、全局及五区手动差值恰好一次、P3 最终域外比例 0、蒙版修边保留。 |

最终 app 从 `/tmp` 运行，不依赖开发目录作为当前工作目录。完整命令：

```bash
ATELIER_ROOT="$HOME/project/ai调色"
env -u PROJECT_ROOT /usr/bin/time -l "$ATELIER_ROOT/build/PhotoAtelier.app/Contents/MacOS/PhotoAtelier" --self-test "$ATELIER_ROOT/artifacts/acceptance-20261101/input" "$ATELIER_ROOT/artifacts/acceptance-targeted-20261102/output-verified" "$ATELIER_ROOT/artifacts/acceptance-targeted-20261102/evidence-verified" > "$ATELIER_ROOT/artifacts/acceptance-targeted-20261102/release-smoke-verified.log" 2>&1
```

退出 0：APP_SMOKE PASS · 30 checks · 3 exported · 1 isolated。自身流程 30.161 秒、进程 real 31.22 秒、最大 RSS 946,917,376 bytes、peak footprint 1,275,297,792 bytes、0 swaps。流程包括原有 LUT/Lensfun/颜色范围/P3/RAW、五区微调读写、新建议未自动应用、采用及重复替换、递归关闭后空目录拒绝旧建议。RAW 是已有回归文件，与桌面样本分开。实际导出保留 +.35 阴影 / +.07 中间调等手动曲线，分析报告逐项复读验证，没有靠 UI 数字推断导出已应用。

首次应用运行使用相同命令但目录和日志分别为 `output-final` / `evidence-final` / `release-smoke.log`，退出 1，停在 11 checks：“五区手动微调或配方 v5 读写没有保留实际值”。独立 `swift -e` Codable 实验（`roundtrip-probe.log`，退出 0）确认本机 JSONDecoder 将 .07 读为相差 2 ULP 的 Double，参数没有丢失。harness 改用逐项 1e-12 数值容差并保存 `tonal-recipe.json`；这是本轮测试假设问题，不归类为基线失败。

主代理实际查看最终包的 `03-tonal-controls.png`、`06-regional-suggestions.png`、`06-regional-mask.png`、`05-raw-analysis.png`：五项值、依据/候选量、蒙版实际覆盖、RAW 三方案可见，所查看区域未见文字重叠或截断。快照与应用命令不算原生鼠标/键盘验收。

### 独立复核、限制与待人工验收

Luna / max 只读审查指出的两项实际状态错误已修正并补入验证：nil/nil 曲线也保持关闭；空目录清除旧建议且采用 API 拒绝无照片/扫描中状态。采用蒙版会开启覆盖显示，失败不会强行切换页；共用一张有界参考图供建议与选区检查，避免编辑蒙版时重复建立几何参考。没有无限缓存。

本轮 `await cua.getState()` 仍返回 `Native apps: Error: Sky Computer Use service startup request failed`，无法做系统文件选择器、真实鼠标拖动/画笔及退出确认。未绕过隐私权限。用户已明确要求人工验收后再合并，因此保持未合并出口，不再次要求接受缺项。

- 基线已有失败：本轮未发现。前述数值、临时 probe、UI 状态和 harness 断言失败均已说明归属，不伪称无关。
- 仍有 Core Image 旧 kernel API 弃用、既有测试字典类型推断 warning；未抑制，未新增依赖。
- 规则有边界和可复现像素行为，但本批样本不足以证明所有题材的审美最优；尤其没有桌面人像/RAW 实拍覆盖。局部建议非语义分割，不能替代主体蒙版或跨构图跟踪。
- 下一步是在本机试用最终 app，对提供照片选择方案并用五区、蒙版精修，完成人工交互和审美验收后再决定合并；本轮不推送、不发布。

`python3 artifacts/acceptance-targeted-20261102/audit_delivery.py snapshot > artifacts/acceptance-targeted-20261102/snapshot-verified.log 2>&1` 退出 0，冻结 60 项源码、测试、脚本、资源及构建配置 SHA-256。最终全套、打包与独立 app 使用这一快照，后续文档补记不改变源码。`python3 artifacts/acceptance-targeted-20261102/audit_delivery.py > artifacts/acceptance-targeted-20261102/audit-before-docs.log 2>&1` 退出 0，24 项本轮文件的空白、疑似凭据、大文件、符号链接和本地文档链接检查通过，源快照一致。

提交前 `git diff --cached --check` 和 `python3 artifacts/acceptance-targeted-20261102/audit_delivery.py > artifacts/acceptance-targeted-20261102/audit-staged.log 2>&1` 均退出 0：`24 task files`、`SNAPSHOT MATCH: 60`、`staged=24`。`git diff --cached --name-only` 与下方清单逐项相符，无产物或本机路径索引。稳定分支回归与合并未执行，原因是用户已经要求人工验收后再合并；其余项目既有 build / test / app 入口均执行，未跳过测试或验证 hook。

## Git、交付与回滚

- 大型变更：符合 AGENTS.md 3.1 新模块、渲染基础设施、配方/默认行为与 ≥3 个源文件等条款。先建分支 `codex/targeted-photo-adjustments`；建分支 HEAD / 已验证基线均为 `f2d7cb06082989ca01ede1831f3eb3cfc1a33903`。
- 稳定分支 `main` 保持 `837ec592c5428e4e4cd360e91f2592d69321f92d`；无 remote，仅本地。开工现场干净，未动 stash、未 fetch/pull、安装、下载、推送、PR 或发布。
- 按用户要求使用 GPT‑6 Luna / max 子代理：曲线实现、独立测试、两个新 UI 面板分别拥有独立文件；主代理负责集成、复核、实拍与最终验证。另作只读对抗审查。
- 按用户已确认的出口：本地提交后保留功能分支，人工验收后再合并。回滚用 `git revert <本轮提交>`，不改写历史；旧应用使用前需处理配方版本，不允许直接改 version 忽略新增曲线。打包保留上一版 app，照片原片与已有导出不覆盖。

## 变更文件

新增：

- `Sources/PhotoCore/TonalCurve.swift`、`TonalAdjustmentMath.swift`：曲线数学、渲染、自动手动差值。
- `Sources/PhotoCore/RegionalAdjustmentSuggestions.swift`：可解释的位置亮度建议。
- `Sources/PhotoAtelier/TonalCurvePanel.swift`、`RegionalSuggestionsPanel.swift`：五区调节和采用建议。
- `Tests/PhotoCoreTests/TonalCurveTests.swift`、`RegionalSuggestionTests.swift`：曲线、兼容、自动安全、位置和实际局部渲染。
- `Scripts/evaluate_photos.swift`：只读目录评估、三方案/单个局部输出、分区量化与匿名对比图；拒绝输入输出重叠和已有输出目录。
- `docs/targeted-tones.md`：本轮记录。

修改：

- `Sources/PhotoCore/Models.swift`、`PhotoEngine.swift`、`PhotoAnalysis.swift`、`SceneAdaptiveProcessing.swift`、`AutomaticSafety.swift`、`AutomaticProcessing.swift`：配方 v5、策略 v2、曲线接入与实际报告。
- `Sources/PhotoAtelier/AppModel.swift`、`ContentView.swift`、`AnalysisPanel.swift`、`SmokeHarness.swift`：预览、局部建议采用、界面、实用流程验证。
- `Tests/PhotoCoreTests/SceneAdaptiveTests.swift`、`LocalMaskTests.swift`、`ColorCompatibilityTests.swift`：版本 1–5 兼容；旧版降级和未知版本拒绝仍保留。
- `README.md`、`docs/scene-adaptive.md`：当前操作说明与历史版本边界。

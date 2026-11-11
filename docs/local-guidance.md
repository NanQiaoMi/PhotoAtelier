# 局部曝光建议：真实选区、通道余量与实拍复测

本页保留局部建议阶段的历史验证；后续人像/背景选区、局部纹理处理、配方 v6 与新增真实人像验证见 [人像精修](portrait-refinement.md)。

## 目标与验收

用户要求继续优化针对不同照片、局部和整体关系的处理。本轮只调整建议与采用行为，沿用五区曲线、场景策略 v2、配方 v5 和既有颜色/LUT 管线。没有安装依赖、联网或上传图片；桌面原片只读，私有路径、索引、图片与日志均在忽略的 `artifacts/acceptance-local-guidance-20261102/`。

开工验收项：

- [x] 建议按真实羽化/范围选区的亮度分布与 RGB 通道余量决定，保留局部明暗关系。
- [x] 网格定位样本占比与实际蒙版覆盖率分别显示；同一参考下位置建议与蒙版检查一致。
- [x] 中间调、纯黑/白、暗调、饱和色、alpha、平移 extent 与旧建议 JSON 有行为验证。
- [x] 桌面十图、既有 RAW、完整检查、Release 与独立应用流程完成最终验证。
- [ ] 原生鼠标拖动、画笔、文件选择器、退出确认及人工审美验收。

最后一项继续遵循用户已确认的出口：保留本地提交的功能分支，人工验收后再合并。不会把自身命令测试或 SwiftUI 快照当成人工交互。

## 现状与修正

冻结基线 `9c2043a17c49b7412690b3ec47dfb9aec792d5ad` 的调试对象后，编译独立探针并读取十个桌面样本。样本为 8 张照片与 2 张图形，9 JPG / 1 PNG；未确认是否已后期处理，没有本批真实人像或 RAW。已有 Canon CR2 单独做导出回归。

基线位置建议和蒙版检查使用两种规则：后者将选区向全图中位亮度拉近，且同时给通用高光/阴影值。海岸天空的位置建议为 −0.120 EV，检查后变为 −0.600 EV；逆光建筑天空为 −0.175 → −0.600 EV。仅按亮度判断的暗部提亮还可能越过饱和红/蓝的单通道余量。

### 当前规则

1. 最长边 192 的 3×3 网格只定位候选。按将要创建的径向、羽化、亮度范围、不透明度，在同一全局校正后、局部与 LUT 前的固定参考上重新测量，最长边 384。
2. 按 alpha × 实际覆盖加权，测量选区线性亮度 P05/P50/P95、最大 RGB 通道的 P99，以及全图线性 P50/P95。CPU bitmap 已是非预乘 RGB，不再次除 alpha。
3. 中位亮度低于 .08 且全图明亮区域提供分离依据时，才提出最多 +.60 EV 的可读性选项；暗调全图中位 <.04 且暗部占比 >70% 时，最多 +.12 EV。接近纯黑不声称能恢复细节。正 EV 进一步受 P99 最大通道到 .98 的余量约束。
4. 选区中位 >.50、超过全图中位 1.8 倍且 P95>.65，才提供最多 −.35 EV 的亮部柔化；接近纯白不以压暗冒充恢复。其余情况保留亮度，不向全图中位值归一。
5. 按实际覆盖估算线性曝光混合后的新增通道 ≥1 和亮度 ≤.002 样本比例，超过选区加权 .5% 时按 100/75/50/25/0% 减弱。低于 .03 EV 不提供一键变更。

这是采样层面的建议边界，**不是原尺寸检查或后续手调、其他蒙版、LUT 的保证**，也不是主体分割、缺陷判定、已知真实曝光或最佳审美。P99 余量本身不覆盖所有细亮点；不能恢复已裁掉的信息。广色域到 extended linear sRGB 的通道余量以当前 SDR 工作参考为准，较保守地保留已超参考的颜色；不改动后续目标色域映射。

区域曝光建议只改曝光 EV，保留已有高光、阴影、对比、冷暖等手调。无支持依据时禁用，模型 API 也拒绝覆盖参数。自动方案正在分析、缺失或报错时，旧参考下的建议不能采用；新图分析及重新预览后恢复。重复采用完整的位置建议仍替换自己的稳定 ID 蒙版，不叠加副本。

新增建议字段为 optional，旧 JSON 缺字段可读；蒙版实际渲染、旧配方 1–4 和当前配方 5 的数值含义不变。建议是当前图的可选方向，采用后的蒙版仍按同一配方用于整批，需要逐张复核构图。

## 实拍与性能

同一参考的冻结探针结果：

| 样本与区域 | 基线位置 → 蒙版建议 EV | 当前位置 → 蒙版建议 EV |
|---|---:|---:|
| 03 海岸阴影 | +.516 → +.600 | +.522 → +.522 |
| 03 海岸天空 | −.120 → −.600 | 无足够依据，不提供候选 |
| 05 岩石亮部 | −.193 → −.600 | −.139 → −.139 |
| 07 建筑阴影 | +.573 → +.600 | +.553 → +.553 |
| 07 建筑天空 | −.175 → −.600 | −.126 → −.126 |
| 10 图形亮部 | −.290 → −.047 | 不强迫压暗 |

十图候选从 12 条变为 8 条，不以候选数量作为质量分数。新版先实现测量，再合并重复排序：同机调试版十图探针初轮 58.03 秒 / RSS 151,465,984 bytes，复用亮度排序后 31.19 秒 / RSS 108,470,272 bytes。该探针包含解码、位置候选及重复检查；冻结旧版为 17.16 秒。新增测量仍有成本，这些单次数据不是 Release 延迟或统计基准。优化前后测量 JSON 逐项一致，没有为耗时改变建议阈值。

最终评估完成 10 / 10、30 个全局方案、8 个单独局部候选，所有采样结果有限。原图与三方案共 40 张 JPEG 的 SHA-256 与上一轮已验证产物完全相同，10 张原片哈希未变；同一参考的候选与检查 EV 最大差为 0。主代理查看了 03 海岸的原图/阴影候选，以及 07 建筑的原图、阴影与亮部候选：变化局限于目标位置与亮度范围，未见新增明显色相污染；这是有限样本的目视检查，不推广为普遍审美结论。

## 检查证据

以下命令在项目根目录执行，日志位于本轮忽略的产物目录。`PHOTO_INPUT` 为用户授权的本机桌面照片目录，其实际源路径与文件名不入库。Swift 5.8 的模块 include 路径是 debug 根目录。

```bash
swiftc -I .build/x86_64-apple-macosx/debug -I .build/x86_64-apple-macosx/debug/CLensfunBridge.build artifacts/acceptance-local-guidance-20261102/probe_guidance.swift .build/x86_64-apple-macosx/debug/PhotoCore.build/*.o .build/x86_64-apple-macosx/debug/CLensfunBridge.build/CLensfunBridge.c.o -o artifacts/acceptance-local-guidance-20261102/probe-baseline > artifacts/acceptance-local-guidance-20261102/probe-baseline-build.log 2>&1
artifacts/acceptance-local-guidance-20261102/probe-baseline "$PHOTO_INPUT" artifacts/acceptance-local-guidance-20261102/baseline > artifacts/acceptance-local-guidance-20261102/baseline.log 2>&1
```

以上退出 0，基线十图与 12 条建议完成。下列命令也均退出 0；编译 `probe-current` 后先执行初轮，再编译 `probe-optimized`，没有重新链接或覆盖基线二进制。

```bash
/usr/bin/time -l artifacts/acceptance-local-guidance-20261102/probe-baseline "$PHOTO_INPUT" artifacts/acceptance-local-guidance-20261102/baseline-timed > artifacts/acceptance-local-guidance-20261102/baseline-timed.log 2>&1
swiftc -I .build/x86_64-apple-macosx/debug -I .build/x86_64-apple-macosx/debug/CLensfunBridge.build artifacts/acceptance-local-guidance-20261102/probe_guidance.swift .build/x86_64-apple-macosx/debug/PhotoCore.build/*.o .build/x86_64-apple-macosx/debug/CLensfunBridge.build/CLensfunBridge.c.o -o artifacts/acceptance-local-guidance-20261102/probe-current > artifacts/acceptance-local-guidance-20261102/probe-current-build.log 2>&1
/usr/bin/time -l artifacts/acceptance-local-guidance-20261102/probe-current "$PHOTO_INPUT" artifacts/acceptance-local-guidance-20261102/current-measurements > artifacts/acceptance-local-guidance-20261102/current-measurements.log 2>&1
swiftc -I .build/x86_64-apple-macosx/debug -I .build/x86_64-apple-macosx/debug/CLensfunBridge.build artifacts/acceptance-local-guidance-20261102/probe_guidance.swift .build/x86_64-apple-macosx/debug/PhotoCore.build/*.o .build/x86_64-apple-macosx/debug/CLensfunBridge.build/CLensfunBridge.c.o -o artifacts/acceptance-local-guidance-20261102/probe-optimized > artifacts/acceptance-local-guidance-20261102/probe-optimized-build.log 2>&1
/usr/bin/time -l artifacts/acceptance-local-guidance-20261102/probe-optimized "$PHOTO_INPUT" artifacts/acceptance-local-guidance-20261102/optimized-measurements > artifacts/acceptance-local-guidance-20261102/optimized-measurements.log 2>&1
```

| 完整命令 | 退出码 | 关键输出与归属 |
|---|---:|---|
| `swift test -j 2 --filter 'LocalGuidanceTests\|RegionalSuggestionTests\|LocalMaskTests' > artifacts/acceptance-local-guidance-20261102/focused-first.log 2>&1` | 1 | 30 tests / 1 failure：新增区域测试的背景 .25 不满足既有 darkest<.22 定位门槛，无法取出候选。属于新测试假设问题。 |
| `swift test -j 2 --filter 'LocalGuidanceTests\|RegionalSuggestionTests\|LocalMaskTests' > artifacts/acceptance-local-guidance-20261102/focused-second.log 2>&1` | 0 | 30 tests / 0 failures，3.071 秒。测试背景改为 .20；未改生产门槛或放宽断言。 |
| `swift test -j 2 --filter 'LocalGuidanceTests\|RegionalSuggestionTests\|LocalMaskTests' > artifacts/acceptance-local-guidance-20261102/focused-quantiles.log 2>&1` | 0 | 30 tests / 0 failures，2.133 秒，含共用分位数排序。 |

### 全套与照片

```bash
swiftc -I .build/x86_64-apple-macosx/debug -I .build/x86_64-apple-macosx/debug/CLensfunBridge.build Scripts/evaluate_photos.swift .build/x86_64-apple-macosx/debug/PhotoCore.build/*.o .build/x86_64-apple-macosx/debug/CLensfunBridge.build/CLensfunBridge.c.o -o artifacts/acceptance-local-guidance-20261102/evaluate-optimized > artifacts/acceptance-local-guidance-20261102/evaluator-optimized-build.log 2>&1
/usr/bin/time -l artifacts/acceptance-local-guidance-20261102/evaluate-optimized "$PHOTO_INPUT" artifacts/acceptance-local-guidance-20261102/verified > artifacts/acceptance-local-guidance-20261102/photos-final.log 2>&1
python3 artifacts/acceptance-local-guidance-20261102/verify_photos.py > artifacts/acceptance-local-guidance-20261102/photo-comparison.log 2>&1
```

以上均退出 0。评估 82.42 秒，包括原尺寸分析、48 JPEG、3 contact PNG；不是单张预览延迟。

| 完整命令 | 退出码 | 关键输出 |
|---|---:|---|
| `make check > artifacts/acceptance-local-guidance-20261102/check-final.log 2>&1` | 0 | 153 tests / 0 failures，54.894 秒，build 8.62 秒；早于最后增加重扫门禁。 |
| `make check > artifacts/acceptance-local-guidance-20261102/check-final-snapshot.log 2>&1` | 0 | 最终快照 153 tests / 0 failures，52.099 秒，无跳过；build 8.16 秒，测试 build .30 秒。 |
| `bash Scripts/build_app.sh > artifacts/acceptance-local-guidance-20261102/release-build.log 2>&1` | 0 | Release 49.25 秒及包验证通过；早于最后增加重扫门禁，不冒充最终 app。 |

最后的补充是由代码路径确认的重扫期间入口缺口：旧检查结果尚可见时，蒙版建议缺少 scanning 条件。模型和按钮现均拒绝，应用流程在已存在有效建议和不同手动 EV 的条件下实际触发重扫，验证参数不被覆盖。全套对最终源码重新执行，所有 PhotoCore 照片测量代码与已评估快照一致。

### 最终应用与导出

| 完整命令 | 退出码 | 关键输出 |
|---|---:|---|
| `bash Scripts/build_app.sh > artifacts/acceptance-local-guidance-20261102/release-final-snapshot.log 2>&1` | 0 | 最终 Release 23.04 秒；4 个签名 x86_64 库、55 XML、许可与可迁移加载路径通过；上一 app 保存在 `build/PhotoAtelier.previous-20261102-163754.app`。 |
| `codesign --verify --deep --strict --verbose=2 build/PhotoAtelier.app > artifacts/acceptance-local-guidance-20261102/codesign-final.log 2>&1` | 0 | valid on disk；satisfies its Designated Requirement。 |
| `PYTHONOPTIMIZE=1 python3 Scripts/verify_app.py build/PhotoAtelier.app > artifacts/acceptance-local-guidance-20261102/bundle-verify-final.log 2>&1` | 0 | 优化 Python 模式下包内 4 库、55 XML、许可及加载路径仍严格通过。 |
| `swift artifacts/acceptance-local-guidance-20261102/verify_release.swift artifacts/acceptance-local-guidance-20261102/output-final > artifacts/acceptance-local-guidance-20261102/export-properties-final.log 2>&1` | 0 | 完整解码 3 TIFF：16-bit、Display P3、orientation 1；两张 1600×1067，CR2 4272×2848。 |
| `python3 artifacts/acceptance-local-guidance-20261102/verify_reports.py artifacts/acceptance-local-guidance-20261102/output-final artifacts/acceptance-local-guidance-20261102/evidence-final > artifacts/acceptance-local-guidance-20261102/reports-final.log 2>&1` | 0 | 37 项应用流程、3 完成 / 1 预置坏图隔离；配方 v5 / 策略 v2，逐张独立依据、五区差值恰好一次、P3 最终域外比例 0、蒙版修边保留。 |

在 `/tmp` 为工作目录的完整应用命令：

```bash
ATELIER_ROOT="$HOME/project/ai调色"
env -u PROJECT_ROOT /usr/bin/time -l "$ATELIER_ROOT/build/PhotoAtelier.app/Contents/MacOS/PhotoAtelier" --self-test "$ATELIER_ROOT/artifacts/acceptance-20261101/input" "$ATELIER_ROOT/artifacts/acceptance-local-guidance-20261102/output-final" "$ATELIER_ROOT/artifacts/acceptance-local-guidance-20261102/evidence-final" > "$ATELIER_ROOT/artifacts/acceptance-local-guidance-20261102/release-smoke-final.log" 2>&1
```

退出 0：`APP_SMOKE PASS · 37 checks · 3 exported · 1 isolated`。流程 29.210 秒，进程 real 30.63 秒、RSS 956,100,608 bytes、peak footprint 1,261,076,480 bytes、0 swaps。沿用原有 30 项流程，新增 7 项：同参考测量一致、一键保留非零高光/阴影、无依据保留手调、自动分析忙碌拒绝两种采用、真实换图清除旧依据、新图分析后恢复、重扫拒绝旧蒙版建议。忙碌分支用受控 `analysisBusy` 状态验证，换图与重新分析使用实际队列；两种证据不混写。

主代理查看最终包的 `06-regional-suggestions.png` 与 `07-local-measurements.png`：网格 11.1% 与真实覆盖约 7.8% 分开、依据/按钮/局部参数可读，所查看面板未见文字截断。快照来自自身视图渲染，不算原生鼠标或键盘验收。

### 入口、快照与未执行范围

- `make check` 对应既有 `swift build -j 2` 与 `swift test -j 2`，均实际执行；Release、签名、资源验证及独立 app 入口也实际执行。没有跳过用例、验证 hook 或放宽预算。
- `python3 artifacts/acceptance-local-guidance-20261102/audit_delivery.py snapshot > artifacts/acceptance-local-guidance-20261102/snapshot-final.log 2>&1` 退出 0，冻结最终 62 项源码、测试、脚本、资源与构建配置。最后全套及 app 使用此快照，后续只有文档补记。初次快照另保留，不覆盖旧证据。
- `python3 artifacts/acceptance-local-guidance-20261102/audit_delivery.py > artifacts/acceptance-local-guidance-20261102/audit-working.log 2>&1` 退出 0：11 项任务文件，未检出疑似凭据、大文件、符号链接、尾部空白或失效本地文档链接，62 项源快照匹配；此时 staged=0。
- 提交前 `git diff --cached --check`、`python3 artifacts/acceptance-local-guidance-20261102/audit_delivery.py > artifacts/acceptance-local-guidance-20261102/audit-staged-final.log 2>&1`、`python3 artifacts/acceptance-local-guidance-20261102/verify_photos.py > artifacts/acceptance-local-guidance-20261102/photo-comparison-delivery.log 2>&1` 均退出 0：仅下列 11 项任务文件暂存，62 项源快照匹配，十张原片和 40 张全局图哈希再次确认未变。
- 基线已有检查失败：本轮未发现。本次首次专项的新增测试输入问题已修复并保留失败日志。打包过程中 install_name_tool 提醒会使旧签名失效，随后按脚本重新签名并验证；既有 Core Image kernel API 弃用仍未迁移，不抑制警告。
- 稳定分支合并及合并后回归**未执行**：用户要求人工验收后再合并。原生人工交互**未执行**：服务启动失败。其余已确认的自动验收项完成；没有把待人工验收称为通过。

## Git、文件与回滚

- 大型变更，符合 AGENTS.md 3.1 的新增模块、跨模块公共行为、≥3 源文件与净增 ≥150 行条款。
- 写入前从干净工作区建立 `codex/local-guidance-refinement`。建分支 HEAD / 已验证基线均为 `9c2043a17c49b7412690b3ec47dfb9aec792d5ad`。稳定分支 `main` 保持 `837ec592c5428e4e4cd360e91f2592d69321f92d`；没有 remote，仅本地，未动 stash 或其他功能分支。
- 使用 GPT‑6 Luna / max 子代理：一名只读审查，另一名独占新增测试文件；主代理负责实现、集成与实际验证。审查指出一键建议不应清除已有高光/阴影值，已修正并加入非零手调的应用流程检查；主代理复核后采纳。
- 原生服务重试 `await cua.rewriteDocumentation();` 后执行 `await cua.getState();`，返回 `Native apps: Error: Sky Computer Use service startup request failed`。人工交互未执行，保持未合并出口，不重复要求接受验证缺项。
- 本地提交后保留功能分支；人工验收后再决定合并。回滚用 `git revert <本轮提交>`；打包脚本保留上一 app，不覆盖原片或既有输出。不 fetch/pull、安装、推送、创建 PR 或发布。

变更文件（无删除）：

- 新增 [LocalLightGuidance.swift](../Sources/PhotoCore/LocalLightGuidance.swift)：选区测量和曝光建议。
- 修改 [LocalMaskEngine.swift](../Sources/PhotoCore/LocalMaskEngine.swift)、[RegionalAdjustmentSuggestions.swift](../Sources/PhotoCore/RegionalAdjustmentSuggestions.swift)：统一依据、实际覆盖及兼容字段。
- 修改 [AppModel.swift](../Sources/PhotoAtelier/AppModel.swift)、[MaskInspector.swift](../Sources/PhotoAtelier/MaskInspector.swift)、[RegionalSuggestionsPanel.swift](../Sources/PhotoAtelier/RegionalSuggestionsPanel.swift)：采用门禁、保留手调、依据与按钮。
- 修改 [SmokeHarness.swift](../Sources/PhotoAtelier/SmokeHarness.swift)：真实换图、非零手调、无依据及采用一致性流程。
- 新增 [LocalGuidanceTests.swift](../Tests/PhotoCoreTests/LocalGuidanceTests.swift)：8 项行为测试。
- 修改 [README.md](../README.md)、[targeted-tones.md](targeted-tones.md)，新增本文件：操作说明与本轮证据；历史测量不改写。

限制与下一步：规则有明确边界，未做广泛人像与复杂光源的审美校准。选区测量不理解灯光意图或物体身份。下一步在本机打开最终 app，用提供的照片选择方向、关覆盖比较、再精修参数，并完成人工交互验收。

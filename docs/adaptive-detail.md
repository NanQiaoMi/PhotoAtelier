# 逐图、逐选区的细节处理

## 目标、基线与验收

本轮延续用户的人像与内容精修目标，新增按每张照片有效选区测量的细节适配。基线 `73dda52b79f638265e921c0dd62328cd7d7f0660` 已有逐图人物/背景/面部候选、场景影调与细节平整，但批处理沿用固定手动细节值，未测量局部噪点候选或提供受保护的细纹理增强。

- [x] 同一意图配方用于不同信号分布，产生独立测量与处理参数。
- [x] 有效蒙版、透明度、非零原点、空选区与取消处理正确；局部结果不反馈给下一选区的测量。
- [x] 减弱合成噪点时保留强边缘；增强已有结构时不在平坦、死黑或剪切白平面里生成纹理。
- [x] 新细节阶段总亮度变化相对细节输入限 ±0.12 EV，保留 alpha 与扩展色值，SDR 不新增越界；该上限不约束用户另加的曝光、独立锐化或其他手动蒙版的叠加。
- [x] v7 完整保存；v1–6 可读，旧配方的中性新控件不改旧像素路径；禁止把新功能标为 v6。
- [x] 完整项目检查、Release 包、独立应用命令、原尺寸人像和 RAW 回归、用户授权实拍复测。
- [ ] 真实鼠标、系统对话框与人工审美验收。按用户既有决定，保留功能分支，人工验收后再合并。

## 使用

在「局部」中选择“整图细节适配”；或者创建面部候选/手绘等蒙版后启用“逐图测量并适配细节”。选择处理方向与总强度，展开依据查看本图实测数据和实际参数。

| 方向 | 行为 |
|---|---|
| 按区域实测 | 面部候选走皮肤；较暗且有噪点候选走暗部；其他走真实层次。不是额外的物体识别器。 |
| 皮肤纹理优先 | 保守平整中尺度起伏、保留细纹；结构多时减弱平整。只有面部候选或用户手绘/径向局部允许自动平整，整图/整个人物/背景不当作皮肤。 |
| 真实层次优先 | 有结构证据、低噪点候选时轻微增强；已有纹理越密、强边缘越多，增强越弱，有歧义时不自动增强。 |
| 暗部噪点优先 | 减弱小幅变化，不自动锐化、不改变基础曝光或提亮黑背景。 |

启用适配时，采用本图解析出的细节参数，手动细节参数暂存；关闭适配后恢复手动值。自适应细节统一在局部曝光/光色及 LUT 之前执行，即使该蒙版其余光色选择 LUT 后。重叠候选从同一参考生成，差值按有效覆盖归一化，不将前一个结果当作下一个输入。其他局部曝光、光色和独立锐化仍按用户设置执行。重置局部调整同时关闭适配，但保留选区。强度 0 采用中性细节，不叠加暂存的手动细节。

## 测量与处理

以镜头/几何和全局基础调整后的参考图为依据，在所有局部与 LUT 之前测量。有效覆盖含修边、亮度/颜色范围和不透明度；不存在的语义选区始终为空。先用最长边 96 的覆盖缩图定位九宫格中的候选位置，再读取最多九个 96×96 的当前参考像素块，噪点估计不对像素块再次缩放。每个 2×2 样本要求四像素的覆盖都不低于覆盖峰值的一半、有效 alpha 不低于 .1；统计按 alpha 与相对覆盖加权。降低整体不透明度不会突然关闭测量，实际输出仍按原不透明度混合。小覆盖可能样本不足，不被擅自放大。

在线性亮度平方根域计算 Haar 高频残差，用低梯度、非近黑/近白区域的稳健中位偏差估计噪点候选；另测量色度残差、结构与强边缘比例。这个估计混有压缩、颗粒、毛孔与细密图案，不能当作传感器噪声或缺陷概率。缺少足量低梯度区域、对角高频明显存在歧义时，全部自动细节控件归零。取样点、脸坐标、像素与蒙版不写入配方或报告。

渲染沿用旧的多尺度中间明暗平整，再以固定 1/2 当前源像素邻域做小幅高频减弱和已有结构增强；强边缘与色差提供保护，亮度和色度变化有界，不独立裁切 RGB 通道。启用新阶段时，最终共同差值限幅以细节输入为准，总亮度限制 ±.12 EV。新两个控件归零时返回旧图像处理路径。

预览图本身有尺寸上限，因此预览噪点统计代表预览参考，不代表原图噪声。原尺寸导出重新测量，并写入各自的 `ProcessingReport.localDetails`，保存策略版本、意图、样本、实际设置和渲染阈值。细节强度可能与缩图预览不同，应复核原尺寸输出。这一限制已在面板展示，不把缩图测量声称为原图噪声测量。

近黑和近白比例是显示参照；不能证明传感器截断或可恢复范围。大面积接近黑/白时返回中性细节。降低已有剪切白或死黑的亮度不等于恢复信息；本功能不生成纹理、不识别痘痣、不美型、不替换背景，与像素蛋糕的完整商用能力仍有差距。

## 兼容、现场和回滚

大型变更，符合用户 AGENTS.md 3.1 的新增功能、跨模块、配方格式、渲染基础设施变化及至少三个非测试源文件条件。写入前建立分支 `codex/adaptive-local-refinement`，建分支 HEAD 和已验证基线均为 `73dda52b79f638265e921c0dd62328cd7d7f0660`。本地稳定分支 `main` 保持 `837ec592c5428e4e4cd360e91f2592d69321f92d`。开工现场与暂存区干净，无 stash 和 remote；只做本地提交，按用户既有决定人工验收后再合并。

按用户要求使用 GPT‑6 Luna / max 子代理，文件写范围分别为 `LocalDetailProcessing.swift`、新增 `AdaptiveDetailTests.swift`；另一代理只读审查。主代理负责测量、策略、集成、UI、实拍和最终核验，不并发 SwiftPM 构建。未安装依赖、下载模型、上传照片、fetch/pull、推送、PR 或发布。原片只读，实拍私有索引与日志在忽略的 `artifacts/acceptance-adaptive-local-20261103/`。

配方版本 7 新增可选 `LocalMask.detailAdaptation` 和两个默认 0 的细节控件。current、automatic baseline、reference 任一含适配或非零新控件，都拒绝标为 v1–6。旧 v6 手动细节仍有效，新报告字段为 optional。旧自动方案重算仍采用当前策略，不能声称复现旧自动结果。回滚用本轮提交的 `git revert`；不降版本丢弃配置，不覆盖原片；构建脚本另名保留上一应用。

## 实际验证记录

工作目录 `/Users/mimi/project/ai调色`，独立应用命令另标 `/tmp`。日志和私有源索引保留在忽略目录，未纳入提交。

| 完整命令 | 退出码 | 结果 |
|---|---:|---|
| `make check > artifacts/acceptance-adaptive-local-20261103/baseline-check.log 2>&1` | 0 | 基线 167 tests / 0 failures，66.945 秒。 |
| `swift build -j 2 > artifacts/acceptance-adaptive-local-20261103/build-first.log 2>&1` | 0 | 初次核心/UI 编译，33.06 秒；早于最终总亮度限幅与应用流程新增检查，不代替最终验证。 |
| `make check > artifacts/acceptance-adaptive-local-20261103/check-final.log 2>&1` | 2 | 191 tests / 1 failure；新增 24 项均通过，版本测试复用已存在的 output-7 目录导致断言失败，见下文。 |
| `make check > artifacts/acceptance-adaptive-local-20261103/check-verified.log 2>&1` | 0 | 修复版本测试夹具后 191 tests / 0 failures，103.620 秒。 |
| `make check > artifacts/acceptance-adaptive-local-20261103/check-delivery.log 2>&1` | 0 | 191 tests / 0 failures，88.723 秒；build 7.30 秒，test build .78 秒。新增 24 项覆盖测量、歧义、噪点/纹理、强边、平面、alpha、范围、重叠、顺序、版本与取消。 |
| `make check > artifacts/acceptance-adaptive-local-20261103/check-snapshot.log 2>&1` | 0 | 最终源码，191 tests / 0 failures，75.339 秒；build 5.32 秒，test build .34 秒。最后一次变更仅修正验收面板快照的窗口外观，核心测量/渲染未变。 |
| `swiftc -I .build/x86_64-apple-macosx/debug -I .build/x86_64-apple-macosx/debug/CLensfunBridge.build Scripts/evaluate_adaptive_details.swift .build/x86_64-apple-macosx/debug/PhotoCore.build/*.o .build/x86_64-apple-macosx/debug/CLensfunBridge.build/CLensfunBridge.c.o -o artifacts/acceptance-adaptive-local-20261103/evaluate-adaptive-verified > artifacts/acceptance-adaptive-local-20261103/evaluator-verified-build.log 2>&1` | 0 | 编译最终核心的实拍评估程序。 |
| `/usr/bin/time -l artifacts/acceptance-adaptive-local-20261103/evaluate-adaptive-verified "$HOME/Desktop/图片" artifacts/acceptance-adaptive-local-20261103/native-final > artifacts/acceptance-adaptive-local-20261103/native-final.log 2>&1` | 0 | 13/13，0 failures；67.58 秒，包含读图、原尺寸测量/处理、两份 PNG、复读与采样，非独立性能基准。 |
| `swiftc -I .build/x86_64-apple-macosx/debug -I .build/x86_64-apple-macosx/debug/CLensfunBridge.build Scripts/evaluate_portraits.swift .build/x86_64-apple-macosx/debug/PhotoCore.build/*.o .build/x86_64-apple-macosx/debug/CLensfunBridge.build/CLensfunBridge.c.o -o artifacts/acceptance-adaptive-local-20261103/evaluate-legacy-verified > artifacts/acceptance-adaptive-local-20261103/legacy-verified-build.log 2>&1` | 0 | 编译原有固定细节评估程序。 |
| `/usr/bin/time -l artifacts/acceptance-adaptive-local-20261103/evaluate-legacy-verified "$HOME/Desktop/图片" artifacts/acceptance-adaptive-local-20261103/legacy-final > artifacts/acceptance-adaptive-local-20261103/legacy-final.log 2>&1` | 0 | 同 13 张原片，13 completed / 0 failures，119.38 秒。 |
| `python3 artifacts/acceptance-adaptive-local-20261103/compare_legacy.py > artifacts/acceptance-adaptive-local-20261103/legacy-compare-corrected.log 2>&1` | 0 | 以两轮记录的原片 SHA-256 对齐匿名 ID；53 张旧流程 PNG 逐字节一致，新 JSON 配方版本/报告允许变化。 |
| `swiftc -I .build/x86_64-apple-macosx/debug -I .build/x86_64-apple-macosx/debug/CLensfunBridge.build artifacts/acceptance-adaptive-local-20261103/run_adaptive_raw.swift .build/x86_64-apple-macosx/debug/PhotoCore.build/*.o .build/x86_64-apple-macosx/debug/CLensfunBridge.build/CLensfunBridge.c.o -o artifacts/acceptance-adaptive-local-20261103/run-adaptive-raw > artifacts/acceptance-adaptive-local-20261103/raw-runner-build-corrected.log 2>&1` | 0 | 修正临时脚本可选 manifest URL 的解包后编译。 |
| `/usr/bin/time -l artifacts/acceptance-adaptive-local-20261103/run-adaptive-raw artifacts/acceptance-20261101/input artifacts/acceptance-adaptive-local-20261103/output-adaptive-raw > artifacts/acceptance-adaptive-local-20261103/raw-adaptive.log 2>&1` | 0 | 真实 CR2；原尺寸逐图 plan，4272×2848 / 16-bit Display P3 TIFF 复读，原片哈希不变；11.99 秒。 |

项目入口由 `make check` 覆盖 build/test；Release 使用 `bash Scripts/build_app.sh`；项目无独立 Lint。未合并，稳定分支合并后回归不适用。

### 最终包与独立应用验收

以下应用命令实际从 `/tmp` 执行，并移除 `PROJECT_ROOT`；其余命令从项目根执行。最终包为 `build/PhotoAtelier.app`，打包脚本另名保留了先前的应用，没有删除旧包。命令集成与自己的视图渲染已验证；真实鼠标和系统对话框保持未验收。

| 完整命令 | 退出码 | 关键输出/结果 |
|---|---:|---|
| `bash Scripts/build_app.sh > artifacts/acceptance-adaptive-local-20261103/release-snapshot.log 2>&1` | 0 | Release build 38.33 秒；4 signed x86_64 dylibs、55 XML profiles、exact licenses、portable load paths；Built and verified。 |
| `codesign --verify --deep --strict build/PhotoAtelier.app > artifacts/acceptance-adaptive-local-20261103/codesign-snapshot.log 2>&1` | 0 | 无错误输出。 |
| `PYTHONOPTIMIZE=1 python3 Scripts/verify_app.py build/PhotoAtelier.app > artifacts/acceptance-adaptive-local-20261103/bundle-verify-snapshot.log 2>&1` | 0 | App bundle verified；优化模式下仍执行显式完整性检查。 |
| `env -u PROJECT_ROOT '/Users/mimi/project/ai调色/build/PhotoAtelier.app/Contents/MacOS/PhotoAtelier' --portrait-self-test '/Users/mimi/project/ai调色/artifacts/acceptance-portrait-20261102/portrait-input' '/Users/mimi/project/ai调色/artifacts/acceptance-adaptive-local-20261103/output-portraits-snapshot' '/Users/mimi/project/ai调色/artifacts/acceptance-adaptive-local-20261103/evidence-portraits-snapshot' > '/Users/mimi/project/ai调色/artifacts/acceptance-adaptive-local-20261103/portrait-self-test-snapshot.log' 2>&1` | 0 | PORTRAIT_APP_SMOKE PASS · 21 checks；48.182 秒，3 张原尺寸人像 TIFF，逐图 plan、manual 暂存/强度零/重置、换图清除、v7/v6 检查；最终面板快照文字可读，已目视复核。 |
| `env -u PROJECT_ROOT '/Users/mimi/project/ai调色/build/PhotoAtelier.app/Contents/MacOS/PhotoAtelier' --self-test '/Users/mimi/project/ai调色/artifacts/acceptance-20261101/input' '/Users/mimi/project/ai调色/artifacts/acceptance-adaptive-local-20261103/output-regression-snapshot' '/Users/mimi/project/ai调色/artifacts/acceptance-adaptive-local-20261103/evidence-regression-snapshot' > '/Users/mimi/project/ai调色/artifacts/acceptance-adaptive-local-20261103/regression-self-test-snapshot.log' 2>&1` | 0 | APP_SMOKE PASS · 37 checks · 3 exported · 1 isolated；75.474 秒，包含真实 CR2 分析、三方案、LUT/色域、Lensfun、蒙版、坏文件隔离。 |
| `swiftc artifacts/acceptance-adaptive-local-20261103/verify_exports.swift -o artifacts/acceptance-adaptive-local-20261103/verify-exports-final > artifacts/acceptance-adaptive-local-20261103/verify-exports-final-build.log 2>&1` | 0 | 编译最终导出复读检查。 |
| `artifacts/acceptance-adaptive-local-20261103/verify-exports-final artifacts/acceptance-adaptive-local-20261103 -snapshot > artifacts/acceptance-adaptive-local-20261103/export-verify-snapshot.log 2>&1` | 0 | EXPORT PASS：7 TIFF files fully decoded；全部 16-bit Display P3、orientation 1，采样有限值。两份 CR2 衍生 TIFF 均 4272×2848；三张人物图均保留源尺寸。 |
| `swiftc -I .build/x86_64-apple-macosx/debug -I .build/x86_64-apple-macosx/debug/CLensfunBridge.build artifacts/acceptance-adaptive-local-20261103/make_review_sheets.swift .build/x86_64-apple-macosx/debug/PhotoCore.build/*.o .build/x86_64-apple-macosx/debug/CLensfunBridge.build/CLensfunBridge.c.o -o artifacts/acceptance-adaptive-local-20261103/make-review-sheets > artifacts/acceptance-adaptive-local-20261103/review-sheets-build.log 2>&1` | 0 | 编译本地对比拼图程序。 |
| `artifacts/acceptance-adaptive-local-20261103/make-review-sheets artifacts/acceptance-adaptive-local-20261103 artifacts/acceptance-portrait-20261102/portrait-input artifacts/acceptance-adaptive-local-20261103/output-portraits-snapshot > artifacts/acceptance-adaptive-local-20261103/portrait-review-snapshot.log 2>&1` | 0 | Review sheets written；已查看三组整图对比与原尺寸 TIFF 的面部裁剪对比。 |
| `python3 artifacts/acceptance-adaptive-local-20261103/acceptance_audit.py > artifacts/acceptance-adaptive-local-20261103/acceptance-audit.log 2>&1` | 0 | ACCEPTANCE AUDIT PASS；交叉检查最终测试、13 图指标、53 旧 PNG、21/37 应用检查、逐图 plan、7 TIFF 和应用 SHA-256。 |
| `python3 artifacts/acceptance-adaptive-local-20261103/verify_delivery.py > artifacts/acceptance-adaptive-local-20261103/audit-final.log 2>&1` | 0 | 73 项源码/构建资源哈希匹配测试快照，13 原片哈希不变；20 个交付文件通过私有源名/凭据/大文件扫描，文档链接有效，main 未变，工作区/暂存区 diff 无空白错误。 |
| `git diff --check` | 0 | 无空白错误输出。 |

原生交互工具再次执行 `await cua.rewriteDocumentation();` 后，`await cua.getApp('/Users/mimi/project/ai调色/build/PhotoAtelier.app');` 仍返回 `Sky Computer Use service startup request failed`，无 shell 退出码。没有改用系统事件脚本模拟鼠标；按用户既定出口保留功能分支供人工验收。

| 项目已有入口 | 执行状态 |
|---|---|
| `make build` / `swift build -j 2` | 已由最终 `make check` 执行，退出 0。 |
| `make test` / `swift test -j 2` | 已由最终 `make check` 执行，退出 0，无过滤。 |
| `make app` | 未单独调用该别名；其唯一脚本 `bash Scripts/build_app.sh` 已直接执行并通过。 |
| `make run` | 未调用；应用已用绝对路径独立启动验收命令。真实 GUI 交互受 CUA 服务启动失败阻断，留待人工。 |
| 独立 Lint / 类型检查命令 | 项目未配置；Swift 编译包含类型检查，未新增依赖或伪造入口。 |
| main 合并后回归 | 未执行；用户要求人工验收后再合并，main 保持原哈希。 |

### 迭代中发现并修复

1. `focused-first.log`：首轮 46 tests / 1 failure。低对比度相干结构在过高的固定梯度底线下被漏计；降低底线，仍同时使用实测噪点阈值限制，保留原断言。
2. 独立审查发现测量在局部光色/LUT前、实际细节却在其后的阶段脱节；改成共同参考、细节先行和重叠覆盖归一化。补 +2EV/非线性LUT顺序及重叠回归。
3. 整图无语义目标可能误走皮肤平整；限制为面部候选或明确的手绘/径向局部。覆盖门槛改为相对峰值，避免不透明度低于 .5 时适配突然失效；统计按 alpha/相对覆盖加权。
4. `focused-corrected.log` 的新增零覆盖测试闭包触发 Swift 5.8 类型推断超时，连带 XCTUnwrap 泛型错误；已对自有 swift-test 发 SIGINT 停止重复的编译诊断，退出 130。拆成明确的 Double/Float 中间项及 RGBA 闭包类型后重新跑完整测试，不跳过用例。
5. 实拍首轮 `native-evaluation/` 为 13/13，采样 0 非有限、0 新增越界，最大亮度差约 .08294 EV；但多张已清晰照片的增强达到同一 .18 值。改为结构支持准入，再按已有纹理密度和强边缘连续减弱，暗部且有噪点证据时优先降噪；该首轮不作为最终交付结果。
6. 旧实拍路径已由用户整理到桌面“图片”目录。按内容哈希重新定位，同 13 张原片，内容均与上轮相同；私有索引不入库。
7. `focused-final.log`：57 tests / 7 assertions。亮度范围夹具使用显示参照，.4 排除了 linear .32，修正为 .7 并检查两侧实际覆盖；相关格纹不满足独立噪点条件，改成固定 UInt32 avalanche hash 的噪点夹具。另发现纯白偏移和宽边缘光晕，继续修渲染，未删除保护断言。
8. `focused-verified.log`：其余 23 个新增测试已过，白平面/边缘压力测试仍有 36 个断言失败。增加 Gaussian 整个支持域的 morphology 强边保护及 flat identity；`probe-protected.log` 中 combined white 精确为 1，灰阶阶跃只剩 RGBAh 量化值 .2199707 / .7197266，不再产生两侧光晕。该用例后续单项及最终全套通过。
9. `check-final.log`：配方接受范围已改为 v1–7，但未知 v8 的测试仍指向已创建的 output-7。修正测试名和目标为 output-8，保留“拒绝未知版本前不得创建目录”的断言；`check-verified.log`、`check-delivery.log` 全绿。这是本轮测试夹具错误，不列为基线失败。
10. 临时 RAW 脚本首次编译退出 1：`summary.manifestURL` 是 optional；显式 guard 解包后退出 0。初次旧像素对比脚本退出 1：旧私有索引只有 id/source，没有 sha256；改为关联两轮独立保存的源哈希表后 53 张一致。两个失败日志保留，未改产品绕过检查。
11. 首次独立应用人像 21 checks、全流程 37 checks 均通过，7 张 TIFF 复读也通过；但独立细节面板的验收快照未挂到窗口，透明背景和缺少外观导致文字颜色不可靠。修正该验收函数，增加真实 NSWindow/darkAqua 和面板背景；再做完整检查、重新打包与独立应用验收，最终结果见后续记录。未用错误快照作为 UI 通过的证据。

中间过滤测试的完整过滤命令未保留，以上诊断日志只说明修复过程，不作为最终验收证据；最终 `make check` 没有过滤、跳过或注释用例。基线检查全绿，无确认的基线失败。

### 实拍结果与复核范围

13 张本机样本含 12 JPG 和 1 PNG，包含风景、建筑、逆光/普通人像、夜景及图形素材；其中 3 张人物图另跑独立应用流程。这是有限样本集，不代表所有相机或场景。统一采用 `.automatic / strength .6`，下表为各图整图选区的真实解析值，非按文件名指定参数。

| 样本 | 方向 | 噪点减弱 | 纹理增强 |
|---|---|---:|---:|
| photo-01 | 真实层次 | .00985 | .07566 |
| photo-02 | 真实层次 | 0 | .08072 |
| photo-03 | 真实层次 | 0 | .07521 |
| photo-04 | 真实层次 | 0 | .09355 |
| photo-05 | 真实层次 | .01096 | .07005 |
| photo-06 | 真实层次 | 0 | .11735 |
| photo-07 | 真实层次 | 0 | .07333 |
| photo-08 | 真实层次 | 0 | .09504 |
| photo-09 | 暗部噪点 | .17599 | 0 |
| photo-10 | 真实层次 | 0 | .07494 |
| photo-11 | 真实层次 | 0 | .05106 |
| photo-12 | 真实层次 | .01107 | .07320 |
| photo-13 | 真实层次 | .01559 | .09049 |

photo-09 是带暗背景的图形素材；选择暗部方向只说明其像素统计满足条件，不能表述为“识别出真实拍摄噪声”。对需要保留的颗粒/插画质感，应选择中性细节或降低强度。

`native-final/metrics.json`：384px 复读采样共 0 非有限、0 新增越界，13 图最大绝对亮度差 .04133 EV，RGB RMS .000077–.000506。测量在原尺寸参考上进行；PNG 对比导出最长边 1920，原样本均未超过该限制。指标不涵盖原尺寸每个像素，也不把“有变化”当作“审美更好”。三张 `native-comparison-*.png` 已目视复核：整体色调基本保持，未见明显新增光晕、色块和纹理涂抹；仍待用户在原尺寸查看。

三张人物子集的面部候选独立测得 5768 / 6920 / 2228 个像素样本，采用皮肤方向，平整为 .06732 / .07945 / .09624，细纹理保留均 .95；第三张噪点减弱 .01896，其余两张 0。没有为整张人像统一磨皮。面部裁剪前后对比仍保留眼眉、发丝、表情和原有纹理，变化较轻；低分辨率 JPEG 的模糊与压缩不能凭此恢复。

## 变更文件

新增 6 个文件：

- `Sources/PhotoCore/AdaptiveLocalDetail.swift`：覆盖内取样、实测依据与逐图参数策略。
- `Sources/PhotoCore/AdaptiveDetailRendering.swift`：共同参考、重叠差值归一化。
- `Sources/PhotoAtelier/AdaptiveDetailControls.swift`：方向、强度与本图依据面板。
- `Tests/PhotoCoreTests/AdaptiveDetailTests.swift`：24 项测量/渲染/集成边界测试。
- `Scripts/evaluate_adaptive_details.swift`：只读原片、匿名衍生图与逐图指标。
- `docs/adaptive-detail.md`：本报告。

修改 14 个文件：

- `Sources/PhotoCore/LocalDetailProcessing.swift`：噪点减弱、现有纹理增强、总亮度与边缘保护，保留旧路径。
- `Sources/PhotoCore/LocalMaskEngine.swift`：配置验证、适配与手动细节互斥、覆盖保护合成。
- `Sources/PhotoCore/Models.swift`：optional 适配/报告、配方 v7 与禁止静默降级。
- `Sources/PhotoCore/PhotoEngine.swift`：每图重测、统一细节顺序、保护选区语义。
- `Sources/PhotoAtelier/AppModel.swift`：整图入口、报告生命周期、重置/手动切换。
- `Sources/PhotoAtelier/MaskInspector.swift`：适配面板与五项手动细节控件。
- `Sources/PhotoAtelier/PortraitSmokeHarness.swift`：人像独立应用与原尺寸逐图计划验收。
- `Sources/PhotoAtelier/SmokeHarness.swift`：v7 既有全流程回归。
- `Tests/PhotoCoreTests/ColorCompatibilityTests.swift`：v1–7 接受与 v8 前置拒绝。
- `Tests/PhotoCoreTests/LocalMaskTests.swift`：版本读写回归。
- `Tests/PhotoCoreTests/SceneAdaptiveTests.swift`：场景配方版本回归。
- `Tests/PhotoCoreTests/TonalCurveTests.swift`：默认版本断言。
- `README.md`：新版使用入口、适配范围与配方兼容。
- `docs/portrait-refinement.md`：标记历史验收版本并链接本轮。

无删除文件。构建产物、照片、源路径索引、日志与临时验收脚本不进入版本库。

## 已知限制与下一步

- 缩图预览和原尺寸导出会重测，统计及强度可能不同；需原尺寸人工复核，尚无可缩放的原图取样预览。
- Vision 人物/面部候选可能漏检或覆盖不准；眼眉嘴保护不等于可靠的瑕疵分割。多人、遮挡、极端肤色/光线覆盖不足，仍需手绘修边。
- 噪点候选不能可靠区分皮肤毛孔、胶片颗粒、织物或插画纹理；无证据时停用仍可能漏处理，不保证所有图片达到最佳审美。
- 未测量超大图、16 个自适应蒙版同时启用的性能；人像 morphology 会随图尺寸扩大，多个选区存在重复构图开销。
- 沿用 Core Image Kernel Language，构建有 macOS 10.14 起的弃用警告；本轮新增核同样使用该接口，没有屏蔽警告。当前验证仅此台 x86_64 Mac，不代表 Apple Silicon 真机或所有 RAW 型号。
- CUA 启动仍失败（`Sky Computer Use service startup request failed`），真实鼠标键盘、系统文件选择器、退出确认与人工审美未执行。独立应用命令和面板快照不替代这些验收。
- 不含生成式细节恢复、自动祛痘、美型或背景生成，未达到像素蛋糕完整功能等同。已损失的高光/死黑信息不能恢复。

按用户既有决定，本轮出口为**本地功能分支 + 提交 + 可执行验证 + 人工试用包**；人工验收后再考虑合并，当前不合并、不删除分支，不声称完成主分支合并后回归。下一步在原尺寸检查面部纹理、发丝、衣料、噪点/颗粒和蒙版边缘，并完成文件选择、取消和退出的实际交互。

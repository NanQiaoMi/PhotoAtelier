# 原尺寸局部检查

## 目标与验收

本轮延续按照片、局部内容和实测依据处理的目标，补上导出前的原尺寸复核。基线 `ca85d5a022992ba7bcbc41346ea9ee9fd604dd5e` 已有逐图细节适配；普通预览最长边为 1500 像素，细节测量与完整原图可能不同。

验收结果与命令见下文。人工交互仍遵循用户既定出口：保留功能分支，人工验收后再合并。

- [x] 非零原点、四角、分数范围、小图与非法输入处理正确。
- [x] 原尺寸局部与同参数完整渲染匹配，重叠蒙版、非线性 LUT 和旋转不先裁输入。
- [x] 完整原图测量与导出相同，不能被 1500 像素预览或局部裁剪代替。
- [x] 改强度、改曝光、快速重选、换图、活动中关闭/重开及开始导出不发布旧结果。
- [x] 完整 198 项检查、Release 包与签名验证。
- [x] 真实 CR2 最终双空间复测、既有人像/全流程回归与九份 TIFF 完整复读。
- [ ] 真实鼠标、系统对话框和人工审美验收；保留分支供人工验收。

## 使用与比较含义

1. 在预览工具栏点「原尺寸检查」。
2. 点击导航图定位面部、发丝、衣料、暗部或蒙版边缘，选择 512 / 768 / 1024 像素区域。
3. 当前版本的对比滑杆左侧为“基础调整后（无局部 / LUT / 滤镜）”，右侧为“当前完整效果”。基础侧已包含同样的解码、镜头、几何及全局调整，不能当作未经调整的原片。
4. 当前选中蒙版启用逐图细节适配时，可以在窗口内调整适配强度；查看实际平整、纹理保留、色调均匀、噪点减弱及纹理增强值，展开测量依据与边界。
5. 其他参数在「返回调整」后修改；重新打开可检查新结果。开始批量导出会关闭并作废检查。

一个源像素对应一个屏幕物理像素，图片按屏幕 `displayScale` 换算点尺寸，可滚动查看。导航图仅用于定位。检查图采用当前导出空间的 8 位色彩管理图像，不包含 JPEG 压缩、16 位量化或其他导出编码差异。

## 完整原图流程

`PhotoLoader.load → 完整原图分析（自动模式）→ automatic.resolve → PhotoEngine.process → 输出区域渲染`。

- RAW 使用既有完整 `CIRAWFilter` 路径，镜头校正先作用于全图；没有先裁输入，也没有把缩略图或内嵌 JPEG 当原图。
- 自动方案采用与 `BatchProcessor` 相同的分析和求值顺序；完整原图得出的实际全局及细节参数独立展示，不写回当前手调值。普通预览可能不同。
- 全局统计、Vision 候选、局部覆盖和最多九个原像素测量块仍看到完整照片；只在最后渲染最多 1024×1024 像素的比较区域，另有最长边 360 的导航图。
- 区域坐标单独定义为几何完成后输出图的左上原点；支持非零 CI 原点，在整数像素内部夹紧边界。没有修改既有蒙版坐标约定。
- 渲染使用 `deferred: false` 并读取、复制 CGImage provider 数据；比较区域先多读取周围 8 像素，再在独立栅格上裁回请求范围，避免 RAW 在局部请求边界产生解码差异。内部缓冲最多 1040×1040，返回区域仍最多 1024×1024；完整 LoadedPhoto / RAW / CI graph 不随结果进入界面，结束时清理上下文缓存。

## 取消、调度与兼容

每次请求带 token 和 generation。改参数、换照片、重选位置、关闭检查及开始批处理会清除旧结果；迟到的任务不能发布。解码、分析和一次 Core Image 像素渲染是同步阶段，取消不能立刻中断，阶段结束后检查 token。

检查、预览解码和批量导出共用一条串行处理队列，避免取消后的旧完整图尚未释放，新的解码又开始。`busy` 表示当前请求是否等待结果；`workerActive` 直到同步任务退出才清除。新的任务异步排队，不阻塞主线程。普通缩图分析沿用已有有界预览队列，不新增完整源图缓存。

配方仍为 v7，没有持久化格式变更，没有改变原有调色算法或导出像素路径。大型变更依据用户 AGENTS.md 3.1 的新增功能、渲染基础设施及至少三个非测试源文件条件。分支为 `codex/native-detail-inspection`，建分支 HEAD 与已验证基线均为 `ca85d5a022992ba7bcbc41346ea9ee9fd604dd5e`；稳定分支 `main` 保持 `837ec592c5428e4e4cd360e91f2592d69321f92d`。

开工现场干净，无暂存、stash 或 remote，只做本地提交。按要求使用 GPT‑6 Luna / max 子代理，分别独占新增核心测试、验收脚本及性能基准，另设只读审查；主代理复核与集成。不并发 SwiftPM 构建，不安装依赖、下载模型、上传照片、fetch/pull、推送、创建 PR 或发布。

回滚使用本轮提交的 `git revert`；构建脚本另名保留上一应用，可先用旧包试用，不覆盖原片。

## 多蒙版性能测量

真实 CR2 为 4272×2848，候选参数相同、径向蒙版位置不同。以下为单轮、实际读取像素 provider 的结果，不是 Release 应用端到端耗时。

| 蒙版数 | 完整渲染 | 中心 1024² 区域渲染 | 近似峰值物理内存 |
|---|---:|---:|---:|
| 1 | 651 ms | 67 ms | 150 MB |
| 4 | 925 ms | 73 ms | 168 MB |
| 16 | 1170 ms | 103 ms | 239 MB |

相同配置的候选构图分别约 .24 / 1.03 / 2.71 ms；逐蒙版分析为 141 / 2138 / 4791 ms。当前测量不支持为节省几毫秒加入候选缓存，本轮未改该路径。参数各异的 16 蒙版对照未执行，不能由此推断所有配置的性能。

基准程序自身用 `-O` 编译，链接现有 Debug 对象以使用 `@testable`；Core Image 像素渲染实际完成。峰值内存为 10 ms 间隔的 `phys_footprint` 采样。首次仅读取 CGImage 尺寸的测量未触发像素 provider，读数无效，未纳入上表。

## 实际验证记录

工作目录为项目根，独立应用命令另标 `/tmp`。原片索引、照片、日志和临时程序仅保留于忽略的 `artifacts/acceptance-native-inspection-20261103/`，未提交。

### 项目检查与实拍脚本

| 完整命令 | 退出码 | 关键结果 |
|---|---:|---|
| `make check > artifacts/acceptance-native-inspection-20261103/baseline-check.log 2>&1` | 0 | 基线 191 tests / 0 failures，67.013 秒。 |
| `swift build -j 2 > artifacts/acceptance-native-inspection-20261103/build-first.log 2>&1` | 0 | 初次产品编译 25.79 秒，早于最终修正。 |
| `swift test -j 2 --filter NativeInspectionTests > artifacts/acceptance-native-inspection-20261103/native-tests-first.log 2>&1` | 1 | 新测试夹具 `.nan` 歧义及非 optional CIImage 强制解包错误。 |
| `swift test -j 2 --filter NativeInspectionTests > artifacts/acceptance-native-inspection-20261103/native-tests-corrected.log 2>&1` | 1 | `.infinity` 类型仍歧义，随后修正为 CGFloat。 |
| `swift test -j 2 --filter NativeInspectionTests > artifacts/acceptance-native-inspection-20261103/native-tests-verified.log 2>&1` | 1 | 7 tests / 1 failure：规则格纹残差为零，修正夹具并加严原图/缩图对照。 |
| `swift test -j 2 --filter NativeInspectionTests > artifacts/acceptance-native-inspection-20261103/native-tests-random-texture.log 2>&1` | 0 | 7 tests / 0 failures，7.862 秒。 |
| `make check > artifacts/acceptance-native-inspection-20261103/check-final.log 2>&1` | 0 | 198 tests / 0 failures，66.696 秒；早于串行资源修正。 |
| `make check > artifacts/acceptance-native-inspection-20261103/check-serialized.log 2>&1` | 0 | 共享队列后 198 tests / 0 failures，66.071 秒。 |
| `make check > artifacts/acceptance-native-inspection-20261103/check-delivery.log 2>&1` | 0 | RAW 周边读取修正后 198 tests / 0 failures，66.490 秒。 |
| `make check > artifacts/acceptance-native-inspection-20261103/check-snapshot.log 2>&1` | 0 | **最终源码 198 tests / 0 failures，66.574 秒**；build 4.87 秒，test build .97 秒。 |
| `swiftc -I .build/x86_64-apple-macosx/debug -I .build/x86_64-apple-macosx/debug/CLensfunBridge.build Scripts/evaluate_native_inspection.swift .build/x86_64-apple-macosx/debug/PhotoCore.build/*.o .build/x86_64-apple-macosx/debug/CLensfunBridge.build/CLensfunBridge.c.o -o artifacts/acceptance-native-inspection-20261103/evaluate-native-final > artifacts/acceptance-native-inspection-20261103/evaluator-build-final.log 2>&1` | 0 | 链接冻结核心的最终实拍验证程序。 |
| `/usr/bin/time -l artifacts/acceptance-native-inspection-20261103/evaluate-native-final '/Users/mimi/Desktop/图片' artifacts/acceptance-native-inspection-20261103/evaluation-desktop-final > artifacts/acceptance-native-inspection-20261103/evaluation-desktop-final.log 2>&1` | 0 | 13 张原片、13 个 sRGB / P3 样本，0 failures；基础和完整效果最大 RGBA 字节差均 0，57.06 秒。原片哈希不变。 |
| `/usr/bin/time -l artifacts/acceptance-native-inspection-20261103/evaluate-native-final artifacts/acceptance-20261101/input artifacts/acceptance-native-inspection-20261103/evaluation-raw-final --raw-only > artifacts/acceptance-native-inspection-20261103/evaluation-raw-final.log 2>&1` | 0 | 真实 4272×2848 CR2，sRGB / Display P3 的基础及完整效果均最大 1/255，2/2 通过，14.19 秒。原片哈希不变。 |

最终实拍程序完整渲染 RGBA8 并实际读取、复制全图 provider，随后裁取参考；比较区域的每个 RGBA 字节，门槛为 2/255。小图允许区域小于 512。桌面样本含 12 JPG、1 PNG，包含人像、风景、夜景及图形素材，不能全称相机实拍。RAW 单独明确筛选，未把坏文件跳过后冒充全目录通过。

性能探针的有效命令：

| 完整命令 | 退出码 | 结果 |
|---|---:|---|
| `swiftc -O -I .build/x86_64-apple-macosx/debug artifacts/acceptance-native-inspection-20261103/performance/runner.swift .build/x86_64-apple-macosx/debug/PhotoCore.build/*.o .build/x86_64-apple-macosx/debug/CLensfunBridge.build/*.o -o artifacts/acceptance-native-inspection-20261103/performance/detail-benchmark` | 0 | 链接已有 Debug 对象，runner 自身优化。 |
| `artifacts/acceptance-native-inspection-20261103/performance/detail-benchmark` | 0 | 56 条 JSONL，实际读取像素，数值和边界见上文。 |
| `swiftc -O -I .build/x86_64-apple-macosx/debug -I .build/x86_64-apple-macosx/debug/CLensfunBridge.build artifacts/acceptance-native-inspection-20261103/probe_raw_roi.swift .build/x86_64-apple-macosx/debug/PhotoCore.build/*.o .build/x86_64-apple-macosx/debug/CLensfunBridge.build/CLensfunBridge.c.o -o artifacts/acceptance-native-inspection-20261103/probe-raw-roi > artifacts/acceptance-native-inspection-20261103/probe-raw-roi-build.log 2>&1` | 0 | 编译 RAW 边界定位程序。 |
| `artifacts/acceptance-native-inspection-20261103/probe-raw-roi artifacts/acceptance-20261101/input > artifacts/acceptance-native-inspection-20261103/probe-raw-roi.log 2>&1` | 0 | 0px 周边：max 8，165 个通道差 >2；2/4/8/16/32/64/128/256/512px 周边均 max 1，0 个通道差 >2。 |

### 最终包与应用命令

独立应用从 `/tmp` 执行，移除 `PROJECT_ROOT`；没有借用源树中的动态库或数据库。自己的 NSHostingView/NSWindow 快照只验证视图渲染，不代表真实鼠标验收。

| 完整命令 | 退出码 | 关键结果 |
|---|---:|---|
| `bash Scripts/build_app.sh > artifacts/acceptance-native-inspection-20261103/release-final.log 2>&1` | 0 | Release build 54.62 秒，资源核验、签名通过；原应用另名保留。 |
| `codesign --verify --deep --strict build/PhotoAtelier.app > artifacts/acceptance-native-inspection-20261103/codesign-final.log 2>&1` | 0 | 无错误输出。 |
| `PYTHONOPTIMIZE=1 python3 Scripts/verify_app.py build/PhotoAtelier.app > artifacts/acceptance-native-inspection-20261103/bundle-verify-final.log 2>&1` | 0 | 4 signed x86_64 dylibs、55 XML profiles、exact licenses、portable paths 全部通过。 |
| `env -u PROJECT_ROOT '/Users/mimi/project/ai调色/build/PhotoAtelier.app/Contents/MacOS/PhotoAtelier' --native-inspection-self-test '/Users/mimi/project/ai调色/artifacts/acceptance-portrait-20261102/portrait-input' '/Users/mimi/project/ai调色/artifacts/acceptance-native-inspection-20261103/output-native-final' '/Users/mimi/project/ai调色/artifacts/acceptance-native-inspection-20261103/evidence-native-final' > '/Users/mimi/project/ai调色/artifacts/acceptance-native-inspection-20261103/native-self-test-final.log' 2>&1` | 0 | **NATIVE_INSPECTION_APP PASS · 23 checks**，18.636 秒；三张真实人物 TIFF，基础参数/逐图细节与批处理相同。 |
| `env -u PROJECT_ROOT '/Users/mimi/project/ai调色/build/PhotoAtelier.app/Contents/MacOS/PhotoAtelier' --portrait-self-test '/Users/mimi/project/ai调色/artifacts/acceptance-portrait-20261102/portrait-input' '/Users/mimi/project/ai调色/artifacts/acceptance-native-inspection-20261103/output-portraits-final' '/Users/mimi/project/ai调色/artifacts/acceptance-native-inspection-20261103/evidence-portraits-final' > '/Users/mimi/project/ai调色/artifacts/acceptance-native-inspection-20261103/portrait-self-test-final.log' 2>&1` | 0 | **PORTRAIT_APP_SMOKE PASS · 21 checks**，48.747 秒；三张真实人物、逐图计划及既有手动参数流程。 |
| `env -u PROJECT_ROOT '/Users/mimi/project/ai调色/build/PhotoAtelier.app/Contents/MacOS/PhotoAtelier' --self-test '/Users/mimi/project/ai调色/artifacts/acceptance-20261101/input' '/Users/mimi/project/ai调色/artifacts/acceptance-native-inspection-20261103/output-regression-final' '/Users/mimi/project/ai调色/artifacts/acceptance-native-inspection-20261103/evidence-regression-final' > '/Users/mimi/project/ai调色/artifacts/acceptance-native-inspection-20261103/regression-self-test-final.log' 2>&1` | 0 | **APP_SMOKE PASS · 37 checks · 3 exported · 1 isolated**，47.697 秒；含真实 CR2、三方案、LUT/色域、Lensfun、蒙版与坏文件隔离。 |
| `swiftc artifacts/acceptance-native-inspection-20261103/verify_exports.swift -o artifacts/acceptance-native-inspection-20261103/verify-exports > artifacts/acceptance-native-inspection-20261103/verify-exports-build.log 2>&1` | 0 | 编译 TIFF 复读程序；有一项多余 try 警告，不影响运行。 |
| `artifacts/acceptance-native-inspection-20261103/verify-exports artifacts/acceptance-native-inspection-20261103 > artifacts/acceptance-native-inspection-20261103/export-verify-final.log 2>&1` | 0 | **EXPORT PASS: 9 TIFF files fully decoded**；读取完整 provider，全部 16-bit Display P3、orientation 1、采样有限；CR2 衍生图 4272×2848。 |

最终三份原尺寸面板快照已查看，文字、导航框、1:1 区域和强度显示可读。上一阶段已验收应用仍保留在 `build/PhotoAtelier.previous-20261103-134258.app`；其可执行文件 SHA-256 与上一阶段验收摘要一致。

CUA 实际调用 `await cua.rewriteDocumentation();` 恢复说明后，`await cua.getApp('/Users/mimi/project/ai调色/build/PhotoAtelier.app');` 再次返回 `Sky Computer Use service startup request failed`（工具错误，无 shell 退出码）。真实鼠标、系统文件选择器和退出确认**未执行**，不把自己的视图快照计为交互验收；沿用用户的保留分支决定，不请求重复豁免。

| 项目既有检查入口 | 执行 / 跳过及理由 |
|---|---|
| `make build` / `swift build -j 2` | 已由最终 `make check` 执行，退出 0，包含类型检查。 |
| `make test` / `swift test -j 2` | 已由最终 `make check` 无过滤执行，198 项全部通过。 |
| `make app` | 未单独调用该别名；其唯一脚本 `bash Scripts/build_app.sh` 已直接运行，退出 0。 |
| `make run` | 未调用别名；最终应用已从 `/tmp` 通过绝对路径运行三种独立命令。真实 GUI 受 CUA 启动失败阻断，未验收。 |
| 独立 Lint / 类型检查 | 项目没有独立入口；未新增依赖，Swift 编译已覆盖类型检查。 |
| main 合并后回归 | 未执行；用户要求人工验收后再合并，main 未变，不删除功能分支。 |

### 未通过的实拍与应用诊断命令

以下失败保留日志，均由后续最终命令覆盖验证，不属于基线失败。

| 完整命令 | 退出码 | 原因与后续处理 |
|---|---:|---|
| `/usr/bin/time -l artifacts/acceptance-native-inspection-20261103/evaluate-native-verified '/Users/mimi/Desktop/图片' artifacts/acceptance-native-inspection-20261103/evaluation-desktop > artifacts/acceptance-native-inspection-20261103/evaluation-desktop.log 2>&1` | 1 | 13 项在 provider 行尾填充检查失败；修正读取范围后最终 13 项通过。 |
| `/usr/bin/time -l artifacts/acceptance-native-inspection-20261103/evaluate-native-corrected artifacts/acceptance-20261101/input artifacts/acceptance-native-inspection-20261103/evaluation-raw --raw-only > artifacts/acceptance-native-inspection-20261103/evaluation-raw.log 2>&1` | 1 | before sRGB/P3 max 8/6，未通过 2；修周边读取后最终两空间 max 1。 |
| `env -u PROJECT_ROOT '/Users/mimi/project/ai调色/build/PhotoAtelier.app/Contents/MacOS/PhotoAtelier' --native-inspection-self-test '/Users/mimi/project/ai调色/artifacts/acceptance-portrait-20261102/portrait-input' '/Users/mimi/project/ai调色/artifacts/acceptance-native-inspection-20261103/output-native' '/Users/mimi/project/ai调色/artifacts/acceptance-native-inspection-20261103/evidence-native' > '/Users/mimi/project/ai调色/artifacts/acceptance-native-inspection-20261103/native-self-test.log' 2>&1` | 1 | 19 checks 后报告严格比较失败，三个 TIFF 已导出；见 JSON 舍入定位。 |
| `swift build -j 2 > artifacts/acceptance-native-inspection-20261103/debug-report-build.log 2>&1` | 0 | 为报告定位增加匿名报告导出，Debug build 4 秒，不作为最终包验收。 |
| `env -u PROJECT_ROOT .build/x86_64-apple-macosx/debug/PhotoAtelier --native-inspection-self-test artifacts/acceptance-portrait-20261102/portrait-input artifacts/acceptance-native-inspection-20261103/output-native-diagnostic artifacts/acceptance-native-inspection-20261103/evidence-native-diagnostic > artifacts/acceptance-native-inspection-20261103/native-self-test-diagnostic.log 2>&1` | 130 | 主代理 SIGINT 中止慢速 Debug 诊断；未作为通过证据。 |
| `env -u PROJECT_ROOT '/Users/mimi/project/ai调色/build/PhotoAtelier.app/Contents/MacOS/PhotoAtelier' --native-inspection-self-test '/Users/mimi/project/ai调色/artifacts/acceptance-portrait-20261102/portrait-input' '/Users/mimi/project/ai调色/artifacts/acceptance-native-inspection-20261103/output-native-diagnostic-release' '/Users/mimi/project/ai调色/artifacts/acceptance-native-inspection-20261103/evidence-native-diagnostic-release' > '/Users/mimi/project/ai调色/artifacts/acceptance-native-inspection-20261103/native-self-test-diagnostic-release.log' 2>&1` | 1 | 19 checks；匿名报告确认原始 JSON 参数完全相同，只有 decoder 舍入。后续严格比较经过同一序列化边界，最终 23 项通过。 |

基线 `make check` 全绿，没有确认的基线检查失败。独立 Luna 审查已复核共享队列、延迟 provider、RAW 支持区、裁剪坐标及 JSON 舍入证据；主代理按最终命令重验。没有跳过/注释测试，也未使用 `--no-verify`。

### 交付核验

`python3 artifacts/acceptance-native-inspection-20261103/verify_delivery.py > artifacts/acceptance-native-inspection-20261103/delivery-audit-prestage.log 2>&1`，退出 **0**：79 个源码/构建输入哈希与验证快照一致，12 个交付文件通过凭据、私有原片名和大文件检查；13 张桌面原片及 RAW 索引中的原片哈希未变；15 个颜色空间样本、23/21/37 项应用检查、九张 TIFF、文档链接及 main 哈希均已交叉核对。源码和证据摘要保留于忽略目录，未纳入提交。

本轮本地提交信息为 `feat(preview): inspect native photo regions`，提交哈希见最终交付回复。按用户既定出口**不合并、不删除分支、不推送**。下一步在本机打开 `build/PhotoAtelier.app`，选择照片，复核面部、衣料、发丝和暗部颗粒，实际操作强度、重选、关闭、取消和系统文件对话框，再由用户决定合并。

### 迭代发现

1. 新测试首次两轮编译失败（退出 1）：此 SDK 的 `CGFloat.nan/infinity` 需要显式类型，`CIImage(bitmapData:)` 不可强制解包。修正夹具后重跑。
2. 第三轮七项测试有一项失败：规则格纹与 2×2 采样相位对齐，残差可能恰好为零。改为固定 avalanche hash 细纹理，保留噪点可测断言，新增与完整源图测量完全相同、与 1500 像素预览测量不同的断言。随后七项通过。
3. 独立审查指出取消不等于同步工作退出，旧检查与批量解码可能重叠；改为共享串行处理队列，补活动中关闭/重开与开始导出的应用自检。显式自检的原片哈希也改为后台分块读取。
4. 首次实拍脚本 13 项均在 provider 读取检查失败：CGImage 裁剪可沿用父图行跨度，但最后一行不必保留完整填充。改为验证到最后一个实际 RGBA 像素，仍逐字节比较全部区域；随后 13/13，最大字节差为 0。
5. 独立应用前两次 Release 验收在 19 项后失败于报告的严格相等。原始 manifest 内的计划与原尺寸报告 JSON 相同；manifest 经 JSONDecoder 后五个 Double 最多变化 `1.3878e-17`。改为让预期报告通过同一次 JSON encode/decode 后再严格比较，没有放宽产品参数容差。中间 Debug 诊断因未优化的逐像素分析耗时过长而由主代理 SIGINT 停止（退出 130），不计作通过。
6. 首次真实 CR2 的完整效果误差为 1/255，但基础比较侧在 sRGB / P3 分别达到 8 / 6 字节，未通过 2 字节门槛。探针多读取 2–512 像素周边后均降到 1 字节；本轮采用 8 像素支持范围后裁回。没有降低像素一致性断言，也没有改批处理或 RAW 解码配方。

## 变更文件

新增：

- `Sources/PhotoCore/NativeInspection.swift`：完整源图的有界区域渲染、坐标与栅格所有权。
- `Sources/PhotoAtelier/NativeInspectionController.swift`：后台请求、自动配方求值、取消与文件版本检查。
- `Sources/PhotoAtelier/NativeInspectionView.swift`：原像素比较、导航、实际参数和强度调整。
- `Sources/PhotoAtelier/NativeInspectionSmokeHarness.swift`：显式应用命令验收。
- `Tests/PhotoCoreTests/NativeInspectionTests.swift`：七项边界、取消、像素一致性和原像素测量测试。
- `Scripts/evaluate_native_inspection.swift`：只读实拍 / RAW 区域与完整输出比较。
- `docs/native-inspection.md`：本记录。

修改：

- `Sources/PhotoAtelier/AppModel.swift`：检查生命周期与共享串行资源队列。
- `Sources/PhotoAtelier/ContentView.swift`：工具栏入口和 sheet 清理。
- `Sources/PhotoAtelier/SmokeHarness.swift`：自检参数分发。
- `README.md`：使用入口与显示范围。
- `docs/adaptive-detail.md`：链接本轮原尺寸复核，保留历史验证记录。

无删除文件。

## 已知限制与人工复核

- 每次改变区域都会重做完整原图流程，不保留原图缓存；旧 frame 和导航图清除后，需等待新结果才能再次定位。复杂 RAW / 多蒙版可能较慢，取消也需等待同步阶段结束。
- 缩略图沿用基线的 `scanQueue`；ImageIO 缩图失败后仍可能回退 CI 解码，低概率与处理队列产生额外资源占用。本轮共享的是检查、预览与导出路径，不能声称全应用严格只有一个解码任务或固定内存上限。
- 普通预览仍按缩图处理；原尺寸检查与完整原图导出采用相同配方和测量，不意味着所有缩图参数都会与原图相同。
- 少量实拍和单个 CR2 不能覆盖所有相机、大图或场景。当前只验证此台 x86_64 Mac；Apple Silicon、其他显示器与所有 RAW 型号未验收。
- 既有 Core Image Kernel Language 仍有弃用警告，未屏蔽。应用命令流程会出现 SwiftUI AttributeGraph cycle 诊断；快照和流程成功不证明真实交互无问题，仍需下述人工验收。自检的活动任务阶段用 200 ms 轮询，适用于本轮较慢的人像输入，极快的小图可能错过活动状态并超时。
- 自动细节仍不能可靠区分毛孔、胶片颗粒、压缩和织物，也不含生成式细节恢复、自动祛痘或美型。无法恢复源文件已丢失的信息，不能声称与像素蛋糕完整功能等同。
- own-view 快照与应用命令不替代真实鼠标、系统文件选择器、退出确认和人工审美验收。保留本地分支，人工验收后再合并；本轮不执行 main 合并后回归。

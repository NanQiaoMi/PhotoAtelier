# 胶片风格与逐图 LUT 适配

## 本轮目标与使用

在「基础 → 风格库」搜索“富士风格”，可比较 Classic Chrome、ASTIA、Classic Neg、ETERNA、ACROS 五个第三方手调近似。它们不是富士官方 LUT 或机内色彩复刻，基础表不包含颗粒、磨皮、相机 RAW 渲染或镜头处理。新目录在后台生成 33³ 表，不增加依赖或联网运行要求。原 13 个风格的 ID、表格与旧处理路径保留。

选择这些新风格首次启用「按每张照片适配 LUT」。强度是上限，可调局部颜色、面部颜色、局部影调约束，以及是否保留原片黑白。适配依据展开后可查看各候选、实测变化、采用参数和回退原因。换风格保留用户强度；推荐强度仍是单独按钮。旧配方和普通风格不会因新增字段自行改变旧像素。

「风格库 → 理光风格与网络 LUT 来源」提供 ColorReps 的 Positive Film / Negative Film / Standard 页面。下载后可通过原有多文件入口导入。本轮只下载到隔离的本机研究目录，未随应用内置或再分发。作者没有明确原色、输入/输出传递函数及再分发/修改许可，不能仅凭标题推断可直接用于 sRGB 照片。自定义表先选择并确认其输入/输出空间，才能渲染、导出或保存配方；已有明确空间的配方载入视为采用该配方解释。确认是用户的解释，不是对上游契约的验证。

## 来源与采用边界

| 来源 | 实际核验 | 本轮使用 |
| --- | --- | --- |
| [sadziu/Fuji-Recipe-Converter](https://github.com/sadziu/Fuji-Recipe-Converter/tree/a6691ea0e880ddd5fd19d7ca2d48a502fb0e7e07) | 固定 commit；MIT 原文；`js/data.js` 明确手调近似，`engine.js` 在 gamma 编码 RGB 处理 | Swift 移植五组参数、单调曲线、HSL 与分离色调；输入/输出明确采用 gamma sRGB，不执行下载的代码 |
| [ColorReps Positive](https://colorreps.com/lut/ricoh-gr-positive-film)、[Negative](https://colorreps.com/lut/ricoh-gr-negative-film)、[Standard](https://colorreps.com/lut/ricoh-gr-standard) | 三个真实 33³ `.cube`；作者称 Positive/Standard 参考 RAW↔JPEG，Negative 是风格创作；未找到明确 RGB 契约或再分发许可 | 原始页面链接、用户导入；本机诊断不能证明原厂等价或空间正确 |
| [abpy/FujifilmCameraProfiles](https://github.com/abpy/FujifilmCameraProfiles) | Adobe camera matching 派生，CC BY-NC-SA/不得售卖限制 | 不复制进本应用 |
| [Fujifilm 官方 LUT](https://fujifilm-x.com/global/support/download/lut/) | 面向 F-Log / F-Log2 等视频输入，不是普通 sRGB 照片创意表 | 不把 Log 变换直接套到 JPEG 或已解码 RAW |

MIT 原文、固定源码 SHA-256、修改与色彩契约在 [第三方署名](../ThirdParty/FilmLUTs/ATTRIBUTION.md) 和 [许可](../ThirdParty/FilmLUTs/LICENSE-MIT.txt)。应用包带同一份文档和许可，打包检查固定许可 hash。表格在内存中生成，不提交大 `.cube`、照片、下载缓存或衍生图。

## 每张图实际执行的流程

1. 使用基础曝光、白平衡、几何和 LUT 前局部调整后的实际像素作为 LUT 参考。不会再次调用自动曝光或自动白平衡，也不把候选结果作为下一候选输入。
2. 本机 Vision 产生题材候选；面部地标与本图颜色样本产生皮肤软选区，排除眼、眉、嘴等。预览在全局参考不变时缓存语义信息；批处理每张重新检测。识别失败、没有足够脸部样本时明确标为未评估，仍做像素检查。题材标签不是审美结论。
3. 实测全图暗部、亮部、饱和覆盖、色相多样性，以及选区内颜色。暗/亮覆盖改变亮度保持候选；高彩度分布改变颜色保护候选；可靠面部样本影响面部保护。只有夜景标签与暗部测量相符时才额外保留夜色影调。暖光、夜景颜色不被当作白平衡错误，不从 RGB 猜相机 Kelvin。
4. 一次 LUT 编码/查表/反编码，共享结果，分别试强度上限的 100/75/50/25% × 两个保护等级，再加零强度参考，共 9 组。各组实际渲染与测量，不假设任意 LUT 的风险随强度单调变化。候选不修改用户配方。
5. 局部 kernel 根据新增 OKLab 色相、色度、近中性色染色、面部软蒙版与亮度跨度连续降低危险区域的权重。黑白 LUT 的降彩不会被当成需要恢复的颜色；严格接近中性黑白的原图可保留无彩关系。不会从模糊或已经剪切的文件凭空恢复细节。
6. 在小样测量色相/色度覆盖、皮肤色相与色度 P90，以及可测边缘的相对层次损失。没有中性/皮肤/边缘依据时指标为 `nil`，不伪造零风险。小样新增剪切比例仅作诊断：先缩图再判断阈值，可能产生原尺寸并不存在的压黑，不能据此把风格错误减弱或归零。
7. 连续的逐像素线段限制按目标 sRGB/P3 原色检查新越界，保留已有 HDR/负值。通过小样光色约束的候选按强度优先、同强度较少额外保护的顺序，在当前输入分辨率先计算阈值，再做面积、有效性和极值归约。首个原尺寸通过者入选；失败就继续下一候选，必要时选择零强度。孤立高光不能因缩图或低面积比例漏过。报告 policy 2 分开记录小样质量、原尺寸未检查/通过/拒绝状态和实际检查的候选 ID；旧报告缺少这些字段仍可读取。P3 的通道边界使用 P3 原色，亮度仍在原线性 sRGB 测量。
8. 之后仍执行 LUT 后蒙版、质感滤镜、整体颜色协调和输出映射。LUT 适配报告**只覆盖 LUT 阶段**，不能视为后续所有编辑均已通过同一检查；最终色彩变化另见 `colorQuality`，原尺寸窗口复核最终画面。

小样用最长边 192 像素，主预览最长边 1500，风格卡片 240，原尺寸和导出使用完整图。它们共用同一适配流程，各自从当前输入分辨率测量；主预览不是原尺寸的像素级保证。风格卡片省略局部蒙版，语义检测在一次比较内复用。主预览和原尺寸/导出共用串行资源队列，避免大图并发解码。

## 数值约束的含义

这些约束是可解释、可调的保守规则，没有经过覆盖所有摄影题材的训练或专业审美标注。高彩度、染色或柔和反差可以是意图；降低保护可保留更多风格。它不会自动判定某个品牌或某种 LUT 就适合某张照片。所有空间选项均要求输入/输出为同一 RGB 原色和曲线；F-Log、ACES、HDR、1D shaper 或跨空间变换仍需正确的前后变换，不能靠适配修好错误的色彩契约。

配方版本 9，读取 1–9。启用适配要求 v9，门禁覆盖当前设置、自动方案 baseline 和 referenceSettings。字段缺失或 disabled 不进入新渲染路径。批处理冻结统一设置，逐张结果及全部候选存入现有原子 manifest，不保存人脸位置或蒙版像素。

TIFF/PNG 使用 16 位输出，编码前完成整个像素渲染，避免 ImageIO 对延迟 RAW/滤镜图选择不同分块求值。实际 CR2 诊断中，原延迟 TIFF 路径相对所检查的画面在 sRGB/P3 最大差为 9/255、8/255；相同 ICC 的完整渲染后直接写 TIFF，两者复读差均为 0。该诊断定位的是编码前渲染方式，不把所有差异归因于 RAW 解码器，也不放宽 2/255 的实拍复读验收阈值。

## 验收与 Git 记录

大型变更：新增功能、渲染流程与配方字段，适用 AGENTS.md 3.1。分支 `codex/adaptive-film-luts`，建分支 HEAD / 已验证基线 `e467bdb5ff19d17503bbdf003659890deb6d5826`；稳定分支 `main` 保持 `837ec592c5428e4e4cd360e91f2592d69321f92d`。现场只读核实存在 origin（`https://github.com/NanQiaoMi/PhotoAtelier.git`）；本轮只做本地提交，不 fetch/pull/push。使用用户指定 GPT-6 Luna / max 子代理，按来源、目录、测试与只读审查划分写范围；主代理完成集成与验证。

- [x] 基线 `make check`：219 tests、0 failures。
- [x] 许可与空间、旧像素、v9/降级和原尺寸极值回归。
- [x] 桌面实拍/人像/RAW 的实际试渲染、原尺寸与 TIFF 对照、原片 hash。
- [x] 最终 `make check`、Release/许可/签名检查与独立启动。
- [ ] 鼠标/系统对话框、流畅性与人工审美验收。

按用户既定出口保留功能分支与本地提交，人工验收后再合并，不推送。可用本轮提交的 `git revert` 撤销功能；构建脚本另名保留旧应用，原片只读。

### 已执行命令

证据目录 `artifacts/acceptance-film-luts-20261103/` 被 Git 忽略；下表只记实际结果，最终验证后补齐。

| 完整命令（项目目录下，另注 cwd 的除外） | 退出码 | 关键输出 |
| --- | --- | --- |
| `make check > artifacts/acceptance-film-luts-20261103/baseline-check.log 2>&1` | 0 | 219 tests，0 failures，88.116 秒。 |
| `swift build -j 2 > artifacts/acceptance-film-luts-20261103/implementation-build.log 2>&1` | 1 | 风格库 VStack 超过 SwiftUI 单层 ViewBuilder 容量，类型检查超时；同时 harness 在编译期间被改动。已把提示分组，后续验证采用冻结源码。 |
| `swift test -j 2 --filter 'FilmLUTCatalogTests\|LUTAdaptationTests' > artifacts/acceptance-film-luts-20261103/targeted-tests.log 2>&1` | 0 | 当时新增适配测试尚未完成，因此实际仅执行目录 4 tests，0 failures。不能视为适配已验证。 |
| `swift test -j 2 --filter 'FilmLUTCatalogTests\|LUTAdaptationTests' > artifacts/acceptance-film-luts-20261103/adaptation-tests.log 2>&1` | 1 | 14 tests 中有 5 个断言失败，均为一个 alpha/HDR 夹具从错误的上下行读取；直接对照原图证实坐标错误，修正顶部原点辅助函数。 |
| `swift test -j 2 --filter 'FilmLUTCatalogTests\|LUTAdaptationTests' > artifacts/acceptance-film-luts-20261103/adaptation-tests-retry.log 2>&1` | 1 | 新增像素候选测试的 escaping closure 缺少显式 `self`，编译拒绝；已修正。 |
| `swift test -j 2 --filter 'FilmLUTCatalogTests\|LUTAdaptationTests' > artifacts/acceptance-film-luts-20261103/adaptation-tests-complete.log 2>&1` | 0 | 15 tests，0 failures，9.224 秒；包括真实 LUT 减弱、旧像素、版本槽位、暖灰、alpha/HDR、单像素高光、P3 与取消。 |
| `make check > artifacts/acceptance-film-luts-20261103/full-check.log 2>&1` | 2 | 234 tests 中 1 个版本夹具断言失败：已接受 v9，却把未来版本拒绝目录仍设为已存在的 `output-9`；改为 `output-10`。不是产品版本门禁放行。 |
| `make check > artifacts/acceptance-film-luts-20261103/full-check-retry.log 2>&1` | 0 | 234 tests，0 failures，85.300 秒；完整构建/类型检查和全部回归，没有过滤或跳过失败。 |
| `git diff --check && python3 -m py_compile Scripts/verify_app.py && bash -n Scripts/build_app.sh` | 0 | diff 空白、Python verifier 语法、打包脚本语法均通过。项目没有独立配置的 lint 入口。 |
| `bash Scripts/build_app.sh > artifacts/acceptance-film-luts-20261103/release-build.log 2>&1` | 0 | Release 编译 75.67 秒；四份签名 dylib、55 XML、胶片 MIT notice 固定 hash、签名和便携路径验证成功。旧应用另名保留为 `build/PhotoAtelier.previous-20261103-180618.app`。 |
| `env -u PROJECT_ROOT '/Users/mimi/project/ai调色/build/PhotoAtelier.app/Contents/MacOS/PhotoAtelier' --style-self-test '/Users/mimi/project/ai调色/artifacts/acceptance-portrait-20261102/portrait-input' '/Users/mimi/project/ai调色/artifacts/acceptance-film-luts-20261103/output-app' '/Users/mimi/project/ai调色/artifacts/acceptance-film-luts-20261103/evidence-app' > '/Users/mimi/project/ai调色/artifacts/acceptance-film-luts-20261103/app-self-test.log' 2>&1`（cwd `/tmp`） | 0 | `STYLE_WORKFLOW_APP PASS · 27 checks`，18.719 秒；包含未确认空间的渲染/导出门禁、导入隔离/取消、缓存与快切、五款适配比较、完整原尺寸路径、两次三图 P3 TIFF 批次、v9 manifest 与原片 hash。 |
| `swiftc -I .build/x86_64-apple-macosx/debug -I .build/x86_64-apple-macosx/debug/CLensfunBridge.build Scripts/evaluate_film_luts.swift .build/x86_64-apple-macosx/debug/PhotoCore.build/*.o .build/x86_64-apple-macosx/debug/CLensfunBridge.build/CLensfunBridge.c.o -o artifacts/acceptance-film-luts-20261103/evaluate-film-luts > artifacts/acceptance-film-luts-20261103/evaluator-build.log 2>&1` | 0 | 实拍评估器编译成功。 |
| `artifacts/acceptance-film-luts-20261103/evaluate-film-luts '/Users/mimi/Desktop/图片' artifacts/acceptance-portrait-20261102/portrait-input artifacts/acceptance-20261101/input artifacts/acceptance-film-luts-20261103/evaluation artifacts/acceptance-film-luts-20261103/ricoh-research > artifacts/acceptance-film-luts-20261103/evaluation.log 2>&1` | 130 | 前 5 张通过并保留对照图；Debug 对象的逐像素统计较慢，用 `kill -INT 43782` 停止此自有评估进程，转用与应用相同的 Release 核心完整重跑。这次不计完整验收。 |
| `swiftc -O -I .build/x86_64-apple-macosx/release -I .build/x86_64-apple-macosx/release/CLensfunBridge.build Scripts/evaluate_film_luts.swift .build/x86_64-apple-macosx/release/PhotoCore.build/*.o .build/x86_64-apple-macosx/release/CLensfunBridge.build/CLensfunBridge.c.o -o artifacts/acceptance-film-luts-20261103/evaluate-film-luts-release > artifacts/acceptance-film-luts-20261103/evaluator-release-build.log 2>&1` | 0 | 同一源码的 Release 评估器编译成功。 |
| `artifacts/acceptance-film-luts-20261103/evaluate-film-luts-release '/Users/mimi/Desktop/图片' artifacts/acceptance-portrait-20261102/portrait-input artifacts/acceptance-20261101/input artifacts/acceptance-film-luts-20261103/evaluation-release artifacts/acceptance-film-luts-20261103/ricoh-research > artifacts/acceptance-film-luts-20261103/evaluation-release.log 2>&1` | 1 | 17 个输入的 85 组预览与前两张人像原尺寸完成；CR2 的 TIFF 复读超过 2/255，停止，未执行其后的理光诊断。不计完整通过。 |
| `swiftc -O -I .build/x86_64-apple-macosx/release -I .build/x86_64-apple-macosx/release/CLensfunBridge.build artifacts/acceptance-film-luts-20261103/raw-diagnostic.swift .build/x86_64-apple-macosx/release/PhotoCore.build/*.o .build/x86_64-apple-macosx/release/CLensfunBridge.build/CLensfunBridge.c.o -o artifacts/acceptance-film-luts-20261103/raw-diagnostic > artifacts/acceptance-film-luts-20261103/raw-diagnostic-build.log 2>&1` | 1 | 诊断脚本调用了 Swift 已移除的 `CGColorSpaceCopyICCData`；改为 `copyICCData()`。 |
| `swiftc -O -I .build/x86_64-apple-macosx/release -I .build/x86_64-apple-macosx/release/CLensfunBridge.build artifacts/acceptance-film-luts-20261103/raw-diagnostic.swift .build/x86_64-apple-macosx/release/PhotoCore.build/*.o .build/x86_64-apple-macosx/release/CLensfunBridge.build/CLensfunBridge.c.o -o artifacts/acceptance-film-luts-20261103/raw-diagnostic > artifacts/acceptance-film-luts-20261103/raw-diagnostic-build-retry.log 2>&1` | 0 | 独立诊断脚本编译成功。 |
| `artifacts/acceptance-film-luts-20261103/raw-diagnostic > artifacts/acceptance-film-luts-20261103/raw-diagnostic.log 2>&1` | 0 | 两种色域、四种 RGBA16/CI/TIFF 路径完成；原导出最大差 9/8，完整渲染后写 TIFF 最大差 0/0，ICC 指纹相同、原片 hash 不变。数据在 `raw-diagnostic-run-960dbf03-db34-422c-a5c4-cbed3e8d8e75/`。随后修复产品导出路径。 |
| `swift test -j 2 --filter 'FilmLUTCatalogTests\|LUTAdaptationTests\|IOTests\|ColorPipelineTests' > artifacts/acceptance-film-luts-20261103/native-safety-export-tests.log 2>&1` | 1 | 编译成功，测试进程 signal 11，栈在首个旧测试释放 `ProcessingReport`；未到达新导出代码。 |
| `swift test -j 2 --filter 'FilmLUTCatalogTests\|LUTAdaptationTests\|IOTests\|ColorPipelineTests' > artifacts/acceptance-film-luts-20261103/native-safety-export-tests-retry.log 2>&1` | 1 | 同一增量缓存重复 signal 11，未宣称通过。 |
| `swift test -j 2 --scratch-path .build/film-luts-verification --filter 'FilmLUTCatalogTests\|LUTAdaptationTests\|IOTests\|ColorPipelineTests' > artifacts/acceptance-film-luts-20261103/native-safety-export-fresh-tests.log 2>&1` | 1 | 全新构建没有进程崩溃，29 项通过；新增高频夹具 1 项断言失败：Core Image 融合缩放和保护后小样 crossing 为 0。改成先完整物化再缩图，直接验证真实测量与光色规则，避免假设优化器顺序。 |
| `swift test -j 2 --scratch-path .build/film-luts-verification --filter LUTAdaptationTests.testDownsampleOnlyShadowCrossingDoesNotRejectNativeSafeCandidate > artifacts/acceptance-film-luts-20261103/threshold-regression/sample-threshold-regression.log 2>&1` | 0 | 1 test，0 failures，5.079 秒；物化原尺寸后再缩图确实产生伪 crossing，光色规则不据此拒绝，原尺寸检查通过且选择非零。 |
| `make check > artifacts/acceptance-film-luts-20261103/final-check.log 2>&1` | 0 | 从保留旧缓存后重新构建，236 tests，0 failures，80.108 秒。随后核对发现两个旧应用自测入口仍写死配方版本 8，已同步版本 9；最终包另以新记录验证。 |
| `make check > artifacts/acceptance-film-luts-20261103/final-check-current.log 2>&1` | 0 | 最终冻结源码：236 tests，0 failures，79.443 秒，构建/类型检查和全部测试完成，没有跳过。 |
| `bash Scripts/build_app.sh > artifacts/acceptance-film-luts-20261103/release-build-final.log 2>&1` | 0 | 最终 Release 编译 76.11 秒；离线镜头库、4 份 dylib、55 XML、原始许可 hash、签名及便携路径验证全部成功。旧包另名保留 `build/PhotoAtelier.previous-20261103-183651.app`。 |
| `swiftc -O -I .build/x86_64-apple-macosx/release -I .build/x86_64-apple-macosx/release/CLensfunBridge.build Scripts/evaluate_film_luts.swift .build/x86_64-apple-macosx/release/PhotoCore.build/*.o .build/x86_64-apple-macosx/release/CLensfunBridge.build/CLensfunBridge.c.o -o artifacts/acceptance-film-luts-20261103/evaluate-film-luts-final > artifacts/acceptance-film-luts-20261103/evaluator-final-build.log 2>&1` | 0 | 最终 Release 评估器编译成功。 |
| `artifacts/acceptance-film-luts-20261103/evaluate-film-luts-final '/Users/mimi/Desktop/图片' artifacts/acceptance-portrait-20261102/portrait-input artifacts/acceptance-20261101/input artifacts/acceptance-film-luts-20261103/evaluation-final artifacts/acceptance-film-luts-20261103/ricoh-research > artifacts/acceptance-film-luts-20261103/evaluation-final.log 2>&1` | 0 | 35.305 秒，17 个输入（14 个唯一原片 hash）、5 风格、103 份适配报告全有 9 候选且 LUT 阶段无新增原尺寸剪切；6 组原尺寸对照、3 理光表×4 小样数值诊断完成，原片 hash 全不变。 |
| `env -u PROJECT_ROOT '/Users/mimi/project/ai调色/build/PhotoAtelier.app/Contents/MacOS/PhotoAtelier' --style-self-test '/Users/mimi/project/ai调色/artifacts/acceptance-portrait-20261102/portrait-input' '/Users/mimi/project/ai调色/artifacts/acceptance-film-luts-20261103/output-app-final' '/Users/mimi/project/ai调色/artifacts/acceptance-film-luts-20261103/evidence-app-final' > '/Users/mimi/project/ai调色/artifacts/acceptance-film-luts-20261103/app-self-test-final.log' 2>&1`（cwd `/tmp`） | 0 | 最终应用 `STYLE_WORKFLOW_APP PASS · 27 checks`，14.186 秒；同等入口覆盖自定义空间门禁、比较、取消/缓存、原尺寸与两次人像 P3 TIFF 批次。仍有两条 AttributeGraph cycle 警告。 |
| `env -u PROJECT_ROOT '/Users/mimi/project/ai调色/build/PhotoAtelier.app/Contents/MacOS/PhotoAtelier' --portrait-self-test '/Users/mimi/project/ai调色/artifacts/acceptance-portrait-20261102/portrait-input' '/Users/mimi/project/ai调色/artifacts/acceptance-film-luts-20261103/output-portrait-final' '/Users/mimi/project/ai调色/artifacts/acceptance-film-luts-20261103/evidence-portrait-final' > '/Users/mimi/project/ai调色/artifacts/acceptance-film-luts-20261103/portrait-self-test-final.log' 2>&1`（cwd `/tmp`） | 0 | `PORTRAIT_APP_SMOKE PASS · 21 checks`，31.972 秒；真实人像分区、皮肤纹理、配方 v9 与批次工作流完成。 |
| `env -u PROJECT_ROOT '/Users/mimi/project/ai调色/build/PhotoAtelier.app/Contents/MacOS/PhotoAtelier' --self-test '/Users/mimi/project/ai调色/artifacts/acceptance-20261101/input' '/Users/mimi/project/ai调色/artifacts/acceptance-film-luts-20261103/output-general-final' '/Users/mimi/project/ai调色/artifacts/acceptance-film-luts-20261103/evidence-general-final' > '/Users/mimi/project/ai调色/artifacts/acceptance-film-luts-20261103/general-self-test-final.log' 2>&1`（cwd `/tmp`） | 0 | `APP_SMOKE PASS · 37 checks · 3 exported · 1 isolated`，26.999 秒；含真实 CR2、三方案、场景/亮度分区、局部调整、v9 manifest 与坏图隔离。坏图是预期测试输入，不是新增正常照片失败。 |

为避免包含旧报告布局的增量对象污染最终验证，将旧 Debug/Release 缓存原样改名保留，未删除缓存或源码，之后用项目原入口重建。命令退出码 0：

```python
# python3 - <<'PY'
import pathlib
base = pathlib.Path('artifacts/acceptance-film-luts-20261103')
for mode in ('debug', 'release'):
    src = pathlib.Path('.build/x86_64-apple-macosx') / mode
    dst = base / ('build-cache-before-policy2-' + mode)
    if dst.exists(): raise RuntimeError('backup already exists')
    if not src.is_dir(): raise RuntimeError('missing source build cache')
    src.rename(dst)
    print('preserved', mode, 'cache')
# PY
```

### 已测交互耗时与限制

最终 Release 应用的单次命令级观察：首次胶片主预览 0.899 秒、五款胶片适配缩图 1.000 秒、快速切回最后选择 0.150 秒；64³ 表后台导入与预览恢复共 3.701 秒，主循环最大采样间隔 0.052 秒。上一个策略的同等记录为 1.749 / 2.199 / 0.100 / 3.849 秒；单次观察不能当作普遍 p95 或稳定性能提升，也不能外推到所有硬件和 RAW。

最终实拍 85 组预览的选中强度均保留用户上限 65%、局部保护等级均为 25%；未为了显示“逐图不同”而人为改变强度。按照片实测生成的亮度保持范围为 65.575–69.135%，中性保护最高 51.989%，有可靠面部样本时肤色保护为 69%；黑白表不强制恢复肤色或中性色彩。局部 kernel 仍按各像素变化连续控制。原策略的 8 个减弱/归零记录在修复缩图误判后均恢复上限，其中两组从零恢复，且原尺寸检查仍通过。候选约束未放宽光色/皮肤/层次条件，也未移除原尺寸极值检查。

两张近景人像（1440×960）及 CR2（4272×2848），每张均在 sRGB/P3 比较全图与原尺寸窗口：六份报告字段完全一致；人像窗口最大字节差 0，RAW 窗口最大差 1/255；六次 16 位 TIFF 复读最大差均为 0。主代理实际查看了花丛、人像、雾景 RAW 的固定/适配对照，未看到新增明显异常染色；小图目视检查不能代替用户原尺寸审美验收。

理光三表×四小样的 12 份记录无数值失败，但全部使用“未经作者确认的 sRGB 假设”。这些结果不构成色彩契约正确、适合该照片或原厂等价的结论，也没有把原表加入应用或提交。

CUA `getState()` 实际返回 `Native apps: Error: Sky Computer Use service startup request failed`。仅获得浏览器 surface，不能用它替代原生应用鼠标/文件对话框验收。应用 own-view snapshots 的日志仍有两条 AttributeGraph cycle 警告，尚未定位其交互影响；不声明已修复。

导出前完整物化可能增加峰值内存：120 MP 的 RGBA16 单栅格约 0.96 GB，尚未计入处理图和编码暂存。已测样本不能代表上限长时批处理的内存表现。

### 检查入口与尚待验收

| 入口或范围 | 本轮最终状态 |
| --- | --- |
| `make build` / `make test` | 已由 `make check` 执行，退出码 0；236 tests，0 failures。 |
| Release / app verifier | 已执行 `bash Scripts/build_app.sh`，退出码 0；依赖、许可、签名、资源和加载路径通过。 |
| 原生应用命令级综合 / 人像 / 风格入口 | 均已独立运行，退出码 0；37 / 21 / 27 checks。 |
| 静态与脚本检查 | 已执行 `git diff --check && python3 -m py_compile Scripts/verify_app.py && bash -n Scripts/build_app.sh`，退出码 0；没有单独配置的 lint 入口。 |
| 其他历史实拍评估脚本 | 未重复运行；本轮使用提交的新胶片评估器覆盖改动涉及的逐图候选、RAW、色域和全图/窗口/导出一致性。 |
| 系统文件对话框、鼠标键盘、关闭确认、长时批次与最终审美 | 未执行；CUA 原生服务启动失败。按用户此前明确选择保留功能分支，等待人工验收后合并，不请求重复豁免。 |

基线失败：没有观察到失败项，开工前基线 `make check` 219 tests 通过。本轮新增测试夹具、版本测试路径、编译错误、RAW 延迟导出与小样误判均已修复并以最终记录复验。旧报告布局对应的增量缓存曾两次导致测试进程崩溃；缓存已原样保留，独立和最终重新构建后均未复现。不能据此声称所有开发环境缓存都不会发生问题。

人工验收时打开 `build/PhotoAtelier.app`，在风格库搜索“富士风格”，分别查看人像/浓色/暗调照片，比较五种风格并展开适配依据；用原尺寸检查查看脸部与高光，调整保护/强度并导出一小批。系统对话框、关闭流程和个人审美确认后再决定合并。回滚使用本轮功能提交的 `git revert`，不改写分支历史；构建前旧应用已另名保留。

### 变更文件

新增 9 个文件，修改 24 个文件，无删除。原片、下载的理光 `.cube`、生成表、图片对照、日志、二进制与私有索引均不入库。

新增：

- `Sources/PhotoCore/FilmLUTCatalog.swift`
- `Sources/PhotoCore/LUTAdaptation.swift`
- `Sources/PhotoAtelier/AdaptiveLUTPanel.swift`
- `Tests/PhotoCoreTests/FilmLUTCatalogTests.swift`
- `Tests/PhotoCoreTests/LUTAdaptationTests.swift`
- `Scripts/evaluate_film_luts.swift`
- `ThirdParty/FilmLUTs/ATTRIBUTION.md`
- `ThirdParty/FilmLUTs/LICENSE-MIT.txt`
- `docs/adaptive-film-luts.md`

修改：

- `Sources/PhotoCore/Models.swift`
- `Sources/PhotoCore/PhotoEngine.swift`
- `Sources/PhotoCore/PhotoIO.swift`
- `Sources/PhotoCore/AutomaticSafety.swift`
- `Sources/PhotoCore/NativeInspection.swift`
- `Sources/PhotoCore/BatchProcessor.swift`
- `Sources/PhotoCore/LUTCube.swift`
- `Sources/PhotoAtelier/AppModel.swift`
- `Sources/PhotoAtelier/ContentView.swift`
- `Sources/PhotoAtelier/StyleBrowserView.swift`
- `Sources/PhotoAtelier/StylePreviewController.swift`
- `Sources/PhotoAtelier/StyleWorkflowSmokeHarness.swift`
- `Sources/PhotoAtelier/SmokeHarness.swift`
- `Sources/PhotoAtelier/PortraitSmokeHarness.swift`
- `Tests/PhotoCoreTests/AdaptiveDetailTests.swift`
- `Tests/PhotoCoreTests/ColorCompatibilityTests.swift`
- `Tests/PhotoCoreTests/LocalMaskTests.swift`
- `Tests/PhotoCoreTests/SceneAdaptiveTests.swift`
- `Tests/PhotoCoreTests/StyleWorkflowTests.swift`
- `Tests/PhotoCoreTests/TonalCurveTests.swift`
- `Scripts/build_app.sh`
- `Scripts/verify_app.py`
- `README.md`
- `THIRD_PARTY_NOTICES.md`

上述六个既有测试文件的改动只更新当前/未来配方版本及对应拒绝目录，原断言覆盖保留。

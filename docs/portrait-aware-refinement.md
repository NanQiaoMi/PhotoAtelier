# 人像局部采样与精修入口

日期：2026-11-03。功能分支 `codex/portrait-aware-refinement`，建分支 HEAD 与基线均为 `1bd8636bfb76c2ea6949ac28b3438c736c2deeca`。稳定分支 `main` 保持在 `837ec592c5428e4e4cd360e91f2592d69321f92d`。本轮按新增功能、跨模块渲染行为变更归为大型变更；遵循用户“保留已提交功能分支，人工验收后再合并”的决定，仅本地提交。

## 目标与验收

本轮聚焦人像局部纹理、平整与操作入口。商业产品公开说明用于功能对照，不代表取得其算法或达到同等能力。

- [x] 既有构建与全部测试通过，旧手动细节、配方与颜色保护回归通过。
- [x] 相同选区像素在不同背景下，新候选保持一致；测试同时证明旧路径存在污染、新路径实际执行了处理。
- [x] 选区面积决定平整尺度，opacity 不改变尺度；alpha、平移、缩放图像图、HDR/负值和选区外像素得到检查。
- [x] 一键新建/复用面部候选，重复不增层，不丢弃用户局部光色和手动细节；满层与零 opacity 边界有检查。
- [x] 本机实拍逐图检测、原尺寸候选与实际导出复读完成，原片校验和保持不变；无人物照片/RAW 安全跳过面部精修。
- [x] 最终 Release 包及从 `/tmp` 启动的应用命令验证通过。
- [ ] 人工验收：鼠标画笔/修边、滑杆、文件对话框、退出确认，以及代表性人像的审美复核。此项保留至用户验收，不作为已完成合并门禁。

回滚方式为撤销本轮功能提交；不改写历史、不覆盖原片，也不合并或推送。研究、实拍、失败日志均位于忽略目录 `artifacts/acceptance-portrait-aware-20261103/`。

## 从公开源码学到了什么

本轮读取了固定提交的实际源码、许可证和已知问题，没有安装新依赖、执行下载代码或分发模型权重。

| 来源 | 核验内容 | 本轮采用/排除 |
|---|---|---|
| [EvoLocal](https://github.com/jackchiang93-crypto/EvoLocal/tree/619f358a732c9ab1782d97f12357cb92f332525f) | [频率分离与面部候选](https://github.com/jackchiang93-crypto/EvoLocal/blob/619f358a732c9ab1782d97f12357cb92f332525f/Sources/EvoLocal/Portrait.swift#L94)，源码 MIT；[README](https://github.com/jackchiang93-crypto/EvoLocal/blob/619f358a732c9ab1782d97f12357cb92f332525f/README.md#L59) 明列高强度平滑、边界块状和染色问题。SegFormer 权重按其说明限非商业研究。 | 学习纹理与低频分离、五官避让；全图 blur 后最后乘 mask 的方法仍会跨界取样，不照搬。未加入权重。 |
| [OpenCV Contrib](https://github.com/opencv/opencv_contrib/blob/1e9f79b60141c896b0863182786984f18d0974c0/modules/ximgproc/src/guided_filter.cpp#L696) | guided filter 用局部均值/协方差求导引模型；该源文件头为 3-Clause BSD。 | 学习导引场与被处理信号分开、低频和细节分开。**本轮没有实现 guided filter**，也没有引入 OpenCV；采用现有 Core Image 的选区加权高斯与边缘保护。 |
| [ComfyUI Image Filters](https://github.com/spacepxl/ComfyUI-Image-Filters/blob/bbb3fb0045461adf3602faeedaf40af57090d4e2/nodes.py#L37) | MIT；节点将 tensor 转 CPU NumPy 后调用 guided filter，通用细节节点不保证皮肤语义。 | 学习独立导引场/细节层的实验构造；不把 ComfyUI/PyTorch 运行时搬入桌面应用。 |
| [portrait-engine](https://github.com/chacalra/portrait-engine/tree/c4be1ed53afda315ca4fb5221b415c5f2f439ee7) | 可公开阅读，但 [pyproject.toml](https://github.com/chacalra/portrait-engine/blob/c4be1ed53afda315ca4fb5221b415c5f2f439ee7/pyproject.toml#L12) 与 [README](https://github.com/chacalra/portrait-engine/blob/c4be1ed53afda315ca4fb5221b415c5f2f439ee7/README.md#L250) 明示 Proprietary。 | 不能称为开放许可依赖；只作设计观察，没有复制、链接其代码或采纳其自报质量指标。 |
| [MediaPipe Face Landmarker](https://github.com/google-ai-edge/mediapipe/blob/14d5d49a32758c784f156cee552570c617ac5373/mediapipe/tasks/python/vision/face_landmarker.py#L3111) | 源码 Apache-2.0，模型资产仍须单独核版本和许可；地标不是皮肤像素分类。 | 已有原生 Vision 地标，本轮不增加第二套运行时或把地标改称皮肤解析。 |

[像素蛋糕公开皮肤说明](https://www.pixcakeai.com/guide/125945) 展示光影平整、高低频分开控制和纹理调节。本轮向这一可解释的处理方向推进；不包含自动祛痘/去痣、美型、身体皮肤分割、发丝解析、骨相塑造、生成纹理，也不声称完整复刻。

## 算法与兼容

### 1. 选区约束采样，而非仅约束最后写出

原路径从全图导引图生成小/大尺度 Gaussian，最后用 coverage 混合候选。选区外写出可以被阻止，但边界另一侧仍会参与选区内低频估计。

新自适应路径以当前最终 coverage 和源 alpha 为采样权重：

```text
low = Gaussian(guide × coverage) / Gaussian(sourceAlpha × coverage)
```

guide 本身已包含 source alpha。亮度使用 signed-log 域，色度使用零亮度的对手色分量。小/大尺度分别归一化；分母过小、无覆盖或无有效 alpha 时保留源像素。

强边缘保护同样受 coverage 约束：先将有效样本转为不透明的归一化标量，蒙版外分别填不会主导 max/min 的哨兵，再做 morphology。这样不会通过“是否跳过处理”的保护条件重新引入背景差异。选区内的真实强边缘仍抑制调整。

1/2 像素噪点邻域也按 coverage × alpha 加权并归一化；邻居的图像和蒙版分别转换坐标。选区内仍可能存在两个不同内容区域，软蒙版非零处仍参与采样，所以这不是语义识别模型。最终 coverage 混合、高光/色彩保护、重叠候选从同一 reference 独立生成及防重复累计逻辑继续保留。

### 2. 随有效面积调整平整尺度

面积 overview 为最长边 192 像素，只测空间尺度，不用它估计噪点。coverage 除以其峰值后积分并考虑源 alpha，避免只改变蒙版 opacity 就改变半径。面积为近似值，极小/窄碎选区有下采样误差。

```text
等效直径 = 2 × sqrt(有效面积 / π)
细半径 = clamp(等效直径 × 0.006, 0.5, 3) 像素
粗半径 = clamp(等效直径 × 0.035, 2, 18) 像素
```

这是有上限的选区尺度规则，不是从商业算法推得的最佳半径。多个脸共用一个 coverage 时采用合并选区面积，尚未逐脸单独求尺度。普通缩图与原尺寸的噪点频段仍不同；原尺寸检查与导出重新测量，不能承诺二者像素完全一致。

报告新增 optional `LocalDetailPlan.sampling`（面积/两级半径），新测量为 policy 2。旧报告缺字段仍可解码；旧手动细节的 nil mask 路径不变。配方仍保存 v9；已启用自动细节的旧配方重算时使用当前算法，报告不是冻结像素结果。没有新增配方参数、模型、依赖或 LUT 契约。

### 3. 智能人像精修入口

在「局部」点“智能人像精修”。优先复用当前的安全面部候选，其次复用已有候选，否则在容量允许时新建。安全条件为 `.faceSkin`、非反选、无加选组件、opacity 大于零。减选/相交修边保留。零 opacity 蒙版保留原样，不自动恢复用户强度；满 16 层且无可复用项时禁用。

新建默认 `.portrait` / 0.6；复用时保留用户适配强度、手动细节、曝光/光色、修边和其他蒙版，只启用并选择该面部候选。重复点击不增层。默认关闭粉色覆盖以查看处理结果，仍可手动打开覆盖修边；无可靠面部或样本不足时报告跳过，不声称处理成功。

面部候选继续依据 Vision 地标、脸颊样本和五官排除区；混合光、妆面、胡须、遮挡、深色皮肤与拼接/多人覆盖仍有局限。不会按预设肤色、美白目标自动修改人物。

## 变更文件

- `Sources/PhotoCore/LocalDetailSampling.swift`：新增面积计划、权重导引与选区极值采样。
- `Sources/PhotoCore/LocalDetailProcessing.swift`：隔离平整/噪点邻域、选区内边缘保护、坐标处理。
- `Sources/PhotoCore/AdaptiveLocalDetail.swift`：逐图采样计划与 policy 2 证据。
- `Sources/PhotoCore/AdaptiveDetailRendering.swift`：将最终 coverage 和计划送入候选渲染。
- `Sources/PhotoAtelier/AppModel.swift`、`MaskInspector.swift`：精修创建/复用命令与入口。
- `Sources/PhotoAtelier/AdaptiveDetailControls.swift`：说明隔离采样、尺度与原尺寸差异。
- `Sources/PhotoAtelier/PortraitSmokeHarness.swift`：扩展真实人像应用命令断言。
- `Tests/PhotoCoreTests/RegionDetailSamplingTests.swift`：新增区域采样回归。
- `Scripts/evaluate_portrait_sampling.swift`：本机原尺寸对照、实际 TIFF 复读和原片 hash 检查；输出包含私有源索引，应只放忽略目录。
- `README.md`、本页：用法、来源、边界与验证记录。

## 验证记录

以下记录只对应实际执行；未运行的人工验收和合并回归在末节单列。

| 完整命令（项目根目录） | 退出码 | 结果 |
|---|---:|---|
| `make check > artifacts/acceptance-portrait-aware-20261103/baseline-check.log 2>&1` | 0 | 基线 236 tests / 0 failures，85.102 秒。 |
| `swift build -j 2 > artifacts/acceptance-portrait-aware-20261103/build-first.log 2>&1` | 0 | 第一版 build 44.31 秒；后续扩展 harness/测试，非最终快照。 |
| `swift test -j 2 --filter 'RegionDetailSamplingTests\|AdaptiveDetailTests\|PortraitDetailTests' > artifacts/acceptance-portrait-aware-20261103/focused-first.log 2>&1` | 0 | 46 tests / 0 failures，11.790 秒。 |
| `swift test -j 2 --filter RegionDetailSamplingTests > artifacts/acceptance-portrait-aware-20261103/region-complete.log 2>&1` | 0 | 10 tests / 0 failures，0.905 秒；补充噪点邻域与等亮度色度均匀化。 |
| `make check > artifacts/acceptance-portrait-aware-20261103/check-final.log 2>&1` | 0 | 最终 246 tests / 0 failures，106.707 秒，无跳过。 |

合成对照：选区内不同外部背景的最大 RGB 差 **0**，旧路径边界平均亮度差 **0.029371**；新路径最大实际亮度变化 **0.002076**。噪点对照的隔离差 **0**、旧路径差 **0.045102**、实际亮度变化 **0.018**。独立采样半径测试中，中频变化比 **0.6792**、高频差分能量比 **0.9708**；该频率测试隔离了“半径”这个变量，使用同半径旧平整路径，不将它称为新隔离保护路径的实拍磨皮指标。

### 原尺寸实拍

本地桌面输入 13 张，13/13 完成：3 张人像产生不同参数，10 张没有可靠面部的照片为 `noDetection` / `insufficientSamples` 并保持中性。输出只写忽略目录；逐像素原尺寸测量使用 256px 分块，避免缩图平均掉稀疏异常。15 张实际 TIFF 复读为 16-bit Display P3 / orientation 1。

| 匿名样本 | 尺寸 | 约有效面积 | 细/粗半径 px | 新候选选区最大绝对 EV | 实际导出选区最大绝对 EV |
|---|---|---:|---|---:|---:|
| 10 | 1440×960 | 8000 | .606 / 3.532 | .00577 | .00619 |
| 11 | 1440×960 | 7192 | .574 / 3.349 | .00471 | .00556 |
| 12 | 1024×1152 | 2417 | .500 / 2.000 | .00858 | .00855 |

三组原尺寸候选的选区外 RGB 差为 0，均无非有限像素、新增越界，alpha 不变；与旧支持域的最大 RGB 差约 .00095 / .00180 / .00110，证明实拍实际走了不同渲染。**本组调整很轻**，不将它解释为显著修复了瑕疵或恢复毛孔。

完整管线后实际 TIFF 复读在选区外最大线性 RGB 差为 .001019（包含后续保护、浮点与编码差异），所以不承诺最终文件的选区外逐字节恒等。三组实际导出同样没有新增越界、非有限或 alpha 变化。本机评估总耗时 209.92 秒 / RSS 209,117,184 bytes，包含大量逐像素测量与多份 TIFF 写出，**不是预览交互性能指标**。

评估器编译命令退出 0：

```bash
swiftc -I .build/x86_64-apple-macosx/debug -I .build/x86_64-apple-macosx/debug/CLensfunBridge.build Scripts/evaluate_portrait_sampling.swift .build/x86_64-apple-macosx/debug/PhotoCore.build/*.o .build/x86_64-apple-macosx/debug/CLensfunBridge.build/CLensfunBridge.c.o -o artifacts/acceptance-portrait-aware-20261103/evaluate-portrait-sampling > artifacts/acceptance-portrait-aware-20261103/evaluator-build.log 2>&1
```

桌面实拍命令，退出 0：

```bash
/usr/bin/time -l artifacts/acceptance-portrait-aware-20261103/evaluate-portrait-sampling '/Users/mimi/Desktop/图片' artifacts/acceptance-portrait-aware-20261103/native-desktop > artifacts/acceptance-portrait-aware-20261103/native-desktop.log 2>&1
/usr/bin/time -l artifacts/acceptance-portrait-aware-20261103/evaluate-portrait-sampling artifacts/acceptance-portrait-aware-20261103/raw-only artifacts/acceptance-portrait-aware-20261103/native-raw > artifacts/acceptance-portrait-aware-20261103/native-raw.log 2>&1
```

第二条使用已有 CR2 的匿名本地副本（复制前后原片 hash 检查不变），退出 0，3.33 秒；4272×2848、`noDetection` / `insufficientSamples` / 面部参数中性。一般应用流程另实际完成 RAW 三方案及全尺寸导出。

元数据检查最初以 `swift -` 执行，随后保存同一 ImageIO 断言并运行 `swift artifacts/acceptance-portrait-aware-20261103/verify_exports.swift > artifacts/acceptance-portrait-aware-20261103/native-export-metadata-verified.log 2>&1`，两次退出 0，关键输出 `15 native TIFF exports: 16-bit, Display P3, orientation 1`；检查每份文件的位深、ICC profile name 和 orientation，未解码 HDR RAW 感光单元。

主代理查看 `portrait-comparison.png` 的三组原图/旧支持域/新支持域/完整精修局部对照，未见明显新增肤色污染、五官/发丝模糊或边缘块状；变化很轻，照片本身低分辨率、压缩和逆光的局限仍在。拼接图的背面人物仍不在面部候选里，不能据此声称多人完整覆盖。该私有图片与界面快照只留本机忽略目录。

### 最终应用

以下三条在项目根目录执行，退出码均 0：

```bash
bash Scripts/build_app.sh > artifacts/acceptance-portrait-aware-20261103/release-final.log 2>&1
codesign --verify --deep --strict build/PhotoAtelier.app > artifacts/acceptance-portrait-aware-20261103/signature-final.log 2>&1
PYTHONOPTIMIZE=1 python3 Scripts/verify_app.py build/PhotoAtelier.app > artifacts/acceptance-portrait-aware-20261103/bundle-final.log 2>&1
```

Release build 88.59 秒；4 个签名 x86_64 dylib、55 XML、准确许可证和 portable load paths 通过。旧应用保留为 `build/PhotoAtelier.previous-20261103-215803.app`。这是本机 Intel 构建，不声称 Universal/Apple Silicon 已验收。

以下两条从 `/tmp` 执行，移除 `PROJECT_ROOT`，退出码均 0：

```bash
env -u PROJECT_ROOT /usr/bin/time -l '/Users/mimi/project/ai调色/build/PhotoAtelier.app/Contents/MacOS/PhotoAtelier' --portrait-self-test '/Users/mimi/project/ai调色/artifacts/acceptance-portrait-20261102/portrait-input' '/Users/mimi/project/ai调色/artifacts/acceptance-portrait-aware-20261103/output-portraits' '/Users/mimi/project/ai调色/artifacts/acceptance-portrait-aware-20261103/evidence-portraits' > '/Users/mimi/project/ai调色/artifacts/acceptance-portrait-aware-20261103/portrait-app.log' 2>&1
env -u PROJECT_ROOT /usr/bin/time -l '/Users/mimi/project/ai调色/build/PhotoAtelier.app/Contents/MacOS/PhotoAtelier' --self-test '/Users/mimi/project/ai调色/artifacts/acceptance-20261101/input' '/Users/mimi/project/ai调色/artifacts/acceptance-portrait-aware-20261103/output-regression' '/Users/mimi/project/ai调色/artifacts/acceptance-portrait-aware-20261103/evidence-regression' > '/Users/mimi/project/ai调色/artifacts/acceptance-portrait-aware-20261103/regression-app.log' 2>&1
```

| 应用命令 | 结果 |
|---|---|
| 人像 | **34 checks**；实际创建候选并测量、16 层/零 opacity 边界、复用/重复不增层、保留曝光/颜色/手动细节/强度、切图失效、重置、3 TIFF 和逐图 policy 2 / 不同采样面积。应用 60.476 秒，进程 63.06 秒 / RSS 1,019,670,528 bytes。 |
| 原有流程 | **37 checks · 3 exported · 1 isolated**；Lensfun、RAW 解码/分析/三方案/原尺寸导出、LUT/色彩、蒙版修边/配方/定位建议均通过。应用 38.835 秒，进程 39.24 秒 / RSS 1,124,352,000 bytes。 |

未再次运行不涉及此次修改的风格库专用 app 命令；风格/LUT 的既有数值测试和通用应用 LUT 流程已经执行。`make build` / `make test` 由 `make check` 覆盖；`make app` 的命令体由最终 `bash Scripts/build_app.sh` 覆盖；`make run` 人工交互未执行。没有关闭测试、跳过失败用例或使用 `--no-verify`。

## 提交前核对与审查

99 项实现文件的 SHA-256 在最终全量检查前冻结。后续只补文档/忽略目录证据；最终交付 audit 重新检查实现 hash、20 份输入文件 hash（含重复本地副本/预置坏图，不当作20个独立真实场景）、13 实拍+1 RAW 结果、34/37 应用断言、3 个不同面积的 policy 2 导出报告及 main 未变。

独立 GPT-6 Luna/max 静态审查发现零 opacity 复用的 P2，已修复并由真实应用命令验证。其余采样路径未发现确认性 P1/P2；静态审查不代替 GPU 与审美验收。另一 GPT-6 Luna/max 子代理提供独立区域回归，主代理扩展并实际运行全部测试。本轮没有已知基线失败或未修复的构建/测试失败。

`git diff --check`、`git diff --cached --check` 均退出 0。`python3 artifacts/acceptance-portrait-aware-20261103/audit_delivery.py > artifacts/acceptance-portrait-aware-20261103/audit-staged.log 2>&1` 退出 0，关键输出 `DELIVERY AUDIT PASS: 99 source hashes, 20 input hashes, 13 photos + 1 RAW, native metrics, 34/37 app checks, 3 policy-2 batch reports, 12 staged text files; main unchanged; no credential pattern or large file.`。暂存区仅含上方列出的 12 个文本文件，不包含照片、日志、构建产物、下载缓存或本机配置；每份暂存文件小于 1 MB，并扫描私钥与常见凭据赋值模式。文档补记后重新显式暂存并复跑同一核对。

## 已知限制与未执行

现有 Core Image Kernel Language deprecated 警告仍存在；本轮没有迁移 Metal kernel。没有新的模型与权重许可包，也没有扩大到商业产品完整功能。基线检查没有失败。

最终包再次调用 `cua.getApp('/Users/mimi/project/ai调色/build/PhotoAtelier.app')`，工具返回 `Sky Computer Use service startup request failed`，记录于 `cua-status.txt`。真实鼠标画笔/修边、参数拖动、文件对话框与退出确认 **未执行**。依用户既定决定保留本地功能分支，人工验收后再合并；合并、main 回归、推送和发布均未执行。

下一步先在最终应用「局部 → 智能人像精修」测试覆盖/修边、关闭覆盖看效果、重复点击与 100% 原尺寸检查，再验收对话框与批处理。此后若扩大质量目标，应加入不同肤色、光照、遮挡、多人和近景高分辨率样本；身体/皮肤语义分割、祛瑕疵或骨相重塑需要另设模型许可、基线和可测目标。

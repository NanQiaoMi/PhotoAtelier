# 风格库、质感滤镜与交互增量

## 范围与使用

本轮在已有逐图分析、人物/背景/皮肤候选、局部蒙版和原尺寸检查之上，增加照片风格浏览、独立空间效果和后台 LUT 导入。目标是让同一张照片可以比较不同方向，再微调局部；本版不包含商业人像模型的自动祛痘、五官美型、换背景或生成式细节重建，不能称为完整复刻像素蛋糕。

1. 打开照片，在「风格库」按自然、人像、电影、风光、黑白或自定义分类，也可搜索名称、说明和标签。
2. 原有五个 LUT 的 ID、顺序、名称和每一个 Float 表格值保留；追加清新人像、奶油柔光、青橙电影、复古褪色、静谧森林、海岸微光、银盐黑白、柔和黑白，共 13 个 LUT，另有「原色」。这些是原创 sRGB 创意风格，没有复制商业品牌 LUT。
3. 缩图基于当前基础光色与几何结果，使用当前 LUT 强度、颜色保护、滤镜和导出空间。为了比较流畅，缩图最长边 240 像素，省略局部蒙版；选择后主预览使用完整当前配方，细节仍以原尺寸检查为准。不能把缩图当成导出画质验收。
4. 切换风格保留用户强度，只有点击「采用推荐强度」才改变它。内置推荐强度为 30–38%，仍需按照片比较。黑白 LUT 提供灰阶基底，与原色按强度及保护混合；需要纯黑白时可将基础饱和度设为零。
5. 在「基础 → 质感滤镜」独立调节高光辉光、柔和暗角和胶片颗粒，默认全部关闭，可以一键归零。这些效果可以与任意 LUT 叠加；「原色」也可单独使用滤镜。
6. 「导入 LUT」支持多选 `.cube`，在后台读取、解析并写入本机资料库，展示进度、停止和单文件错误。每个导入文件使用新 UUID 路径，不覆盖已有文件；停止保留已成功写入的风格，当前同步解析阶段返回后才响应取消。单文件上限 48 MB。
7. 自定义 LUT 必须按作者说明选择同一输入/输出 RGB 空间与曲线，所选契约逐 LUT 记住。保持原有 sRGB、Linear sRGB、P3、Rec.709 Gamma 2.4 和 Rec.709 OETF 语义；不会从标题猜 Log、HDR 或 ACES。

## 渲染与保护

顺序为：解码 / 镜头 → 基础光色与几何 → 固定测量参考 → 细节适配与 LUT 前蒙版 → LUT / 防染色 → LUT 后蒙版 → **质感滤镜** → 最终颜色协调 / 目标色域映射 → 编码。

- 辉光只从高光提取光能，半径随完整图像尺寸变化，最大添加系数 0.12，并按 SDR 白位余量共同缩小 RGB 贡献。它不抬起整幅中灰，不能恢复已经剪切的通道；HDR 原值不会为了效果被硬裁到 1。
- 暗角按完整 extent 的椭圆距离平滑衰减，各通道乘同一增益，最强角落约降低 34%，不直接更改色相或 alpha。
- 颗粒使用固定图像坐标的确定性中性增益，最大相对幅度约 ±3%，深黑与极亮区域减弱。相同尺寸的完整渲染与 ROI 可逐像素比较；小预览与原图的采样网格不同，不能声称颗粒逐点一致。
- 有限、非零原点、透明、负值和 HDR 浮点路径有回归检查。新效果参与最终颜色检查和目标色域处理，仍无法证明所有照片都符合用户审美。
- 蒙版范围、内容选区、区域建议与自动基础安全评估都排除滤镜，避免滤镜反过来改变测量依据；原尺寸比较的基础侧同样排除局部、LUT 和滤镜。

配方升级到 **v8**，读取 v1–v8；旧文件缺字段或三强度全零时保持原像素路径。current、automatic.baseline、automatic.referenceSettings 任一包含非零效果，都拒绝伪装为 v1–v7。自动基础参数复制保留用户滤镜，不把它当曝光或白平衡增量重复叠加。

## 调度与故障边界

启动时自定义库读取与导入解析使用后台串行队列。导入和批处理互斥，避免库完成事件干扰冻结配方及导出状态。

风格缩图使用与预览/原尺寸/导出相同的图像工作队列，每个卡片一个任务，卡片间允许新照片工作排入；参数更新合并 150 ms。输入键包含有界参考图身份、实际风格参数、LUT ID 列表、颜色契约和输出空间。只选中另一张风格卡片不重绘整个缩图库。最多同时比较 48 项，更多自定义 LUT 可搜索缩小范围。

取消和 generation 同时检查，旧任务不能发布到新列表；单卡失败显示错误并继续后续卡片，可重试。同步 RAW 解码、LUT 解析和一次 GPU 渲染不能立即中断，不把取消按钮描述为实时终止 GPU。

全局测量参考按真正影响它的参数缓存，单纯切换 LUT/滤镜复用区域建议与内容候选。没有新增全尺寸 RAW 缓存。普通预览和方案缩图在后台用 `deferred: false` 渲染，并读取、复制 provider 像素，避免 AppKit 首次显示时再执行图像图。

## 验收目标与 Git

- [x] 13 个 LUT、旧五表兼容、独立可调滤镜及配方版本门禁。
- [x] 核心新增顺序、alpha / HDR、ROI、目标色域、旧像素路径回归。
- [x] 最终快照 `make check`、Release / 签名和应用流程自检。
- [x] 桌面照片与真实 CR2 多风格渲染、原尺寸对照、16-bit TIFF 复读、原片 hash。
- [ ] 真实鼠标、系统文件对话框、滚动/键盘体验与人工审美验收。

按 AGENTS.md 3.1 的新增功能、数据格式、渲染基础设施及多源文件条件判定为大型变更。分支 `codex/style-effects-workflow`；建分支 HEAD 与已验证基线均为 `d31a937cc0ab11a0603546c69a4550300c31c544`。稳定分支 `main` 为 `837ec592c5428e4e4cd360e91f2592d69321f92d`。无 remote，仅本地；开工现场干净，无用户 WIP 或 stash。

按用户既定决定保留功能分支与本地提交，人工验收后再合并；不合并 main、不推送、不删除分支。回滚使用本轮提交的 `git revert`；构建脚本另名保留旧 `.app`，照片原件只读。使用用户指定的 GPT‑6 Luna / max 子代理分别负责 LUT 目录、滤镜内核和只读性能/交互审查，主代理完成集成和实际验证。没有安装依赖、下载模型或上传照片。

## 验证记录

证据位于忽略目录 `artifacts/acceptance-style-effects-20261103/`。实际结果在完成后补齐；下列基线已实际执行。

| 命令 | 退出码 | 结果 |
|---|---:|---|
| `make check > artifacts/acceptance-style-effects-20261103/baseline-check.log 2>&1` | 0 | 基线 198 tests，0 failures，82.972 秒。 |
| `swift test -j 2 --filter 'LUTCatalogTests\|CreativeEffectsTests\|StyleWorkflowTests' > artifacts/acceptance-style-effects-20261103/targeted-tests.log 2>&1` | 1 | 新面板使旧 SwiftUI ViewBuilder 超过 10 个直接子项；整理成 Group 后重验。 |
| `swift test -j 2 --filter 'LUTCatalogTests\|CreativeEffectsTests\|StyleWorkflowTests' > artifacts/acceptance-style-effects-20261103/targeted-tests-retry.log 2>&1` | 0 | 20 tests，0 failures；旧五表 hash 与 Swift 运行结果完全匹配。 |
| `swift test -j 2 --filter 'CreativeEffectsTests\|StyleWorkflowTests' > artifacts/acceptance-style-effects-20261103/integration-tests.log 2>&1` | 0 | 辉光修正后的 15 tests，0 failures。 |
| `make check > artifacts/acceptance-style-effects-20261103/final-check.log 2>&1` | 0 | 首轮集成 218 tests，0 failures，74.537 秒；审查后应用调度补丁仍需最终快照重验。 |
| `swiftc -I .build/x86_64-apple-macosx/debug -I .build/x86_64-apple-macosx/debug/CLensfunBridge.build Scripts/evaluate_style_effects.swift .build/x86_64-apple-macosx/debug/PhotoCore.build/*.o .build/x86_64-apple-macosx/debug/CLensfunBridge.build/CLensfunBridge.c.o -o artifacts/acceptance-style-effects-20261103/evaluate-styles > artifacts/acceptance-style-effects-20261103/evaluator-build.log 2>&1` | 0 | 实拍核验脚本编译成功。 |
| `artifacts/acceptance-style-effects-20261103/evaluate-styles '/Users/mimi/Desktop/图片' artifacts/acceptance-20261101/input artifacts/acceptance-style-effects-20261103/evaluation > artifacts/acceptance-style-effects-20261103/evaluation.log 2>&1` | 0 | 13 张桌面 JPEG/PNG 与一张真实 CR2，共 182 次 LUT 渲染；四张代表图在 sRGB/P3 共八次原尺寸/整图比较，最大差 **1/255**；四张完整 P3 TIFF 编码复读，最大差 **2/255**；14 张原片 SHA-256 全部未变，合计 125.518 秒（Debug 对象）。 |
| `make check > artifacts/acceptance-style-effects-20261103/final-check-verified.log 2>&1` | 2 | 新应用错误隔离夹具试图构造私有 LUT initializer，构建拒绝；改用公开控制器 API 的非法参数来测试逐卡失败，不放宽产品 LUT 构造边界。 |
| `make check > artifacts/acceptance-style-effects-20261103/final-check-complete.log 2>&1` | 0 | 交互审查修正后的 **218 tests，0 failures，83.420 秒**；包含 Swift 编译/类型检查、全部既有和新增回归，未过滤或跳过用例。 |
| `bash Scripts/build_app.sh > artifacts/acceptance-style-effects-20261103/release-build.log 2>&1` | 0 | 首个 Release 包、离线 Lensfun、四份 dylib 和应用签名/便携路径验证成功；随后补齐旧配方加新滤镜时的输出保护，最终包另行重建。 |
| `make check > artifacts/acceptance-style-effects-20261103/final-check-color-guard.log 2>&1` | 0 | 最终颜色边界补丁后 **219 tests，0 failures，80.654 秒**；覆盖 `colorHarmony=nil + 新滤镜 + sRGB/P3` 及无滤镜的旧像素路径。 |
| `bash Scripts/build_app.sh > artifacts/acceptance-style-effects-20261103/release-build-final.log 2>&1` | 0 | 最终 Release 完整构建（48.79 秒）、四个签名 x86_64 dylib、55 XML、许可、签名与便携路径验证全部完成；旧包另名保留于 `build/PhotoAtelier.previous-20261103-171523.app`，更早的包仍保留。 |
| `env -u PROJECT_ROOT '/Users/mimi/project/ai调色/build/PhotoAtelier.app/Contents/MacOS/PhotoAtelier' --style-self-test '/Users/mimi/project/ai调色/artifacts/acceptance-portrait-20261102/portrait-input' '/Users/mimi/project/ai调色/artifacts/acceptance-style-effects-20261103/output-style-final' '/Users/mimi/project/ai调色/artifacts/acceptance-style-effects-20261103/evidence-style-final' > '/Users/mimi/project/ai调色/artifacts/acceptance-style-effects-20261103/style-self-test-final.log' 2>&1`（cwd `/tmp`） | 0 | **STYLE_WORKFLOW_APP PASS · 18 checks**，15.088 秒；后台多文件导入/隔离/取消、导入与批处理互斥、记住自定义 P3 契约、参考缓存、缩图复用/取消/逐卡失败、快速选择、原尺寸滤镜、v8 与三图 P3 TIFF 导出及原片保护。 |
| `env -u PROJECT_ROOT '/Users/mimi/project/ai调色/build/PhotoAtelier.app/Contents/MacOS/PhotoAtelier' --native-inspection-self-test '/Users/mimi/project/ai调色/artifacts/acceptance-portrait-20261102/portrait-input' '/Users/mimi/project/ai调色/artifacts/acceptance-style-effects-20261103/output-native-final' '/Users/mimi/project/ai调色/artifacts/acceptance-style-effects-20261103/evidence-native-final' > '/Users/mimi/project/ai调色/artifacts/acceptance-style-effects-20261103/native-self-test-final.log' 2>&1`（cwd `/tmp`） | 0 | **NATIVE_INSPECTION_APP PASS · 22 checks**，21.609 秒；完整原图、逐图自动计划、快速改参数/位置、取消/重开/换图/开始导出和清单一致性。 |
| `env -u PROJECT_ROOT '/Users/mimi/project/ai调色/build/PhotoAtelier.app/Contents/MacOS/PhotoAtelier' --portrait-self-test '/Users/mimi/project/ai调色/artifacts/acceptance-portrait-20261102/portrait-input' '/Users/mimi/project/ai调色/artifacts/acceptance-style-effects-20261103/output-portraits-final' '/Users/mimi/project/ai调色/artifacts/acceptance-style-effects-20261103/evidence-portraits-final' > '/Users/mimi/project/ai调色/artifacts/acceptance-style-effects-20261103/portrait-self-test-final.log' 2>&1`（cwd `/tmp`） | 0 | **PORTRAIT_APP_SMOKE PASS · 21 checks**，36.518 秒；既有人物/背景、皮肤、逐图计划及手动参数/导出流程。 |
| `env -u PROJECT_ROOT '/Users/mimi/project/ai调色/build/PhotoAtelier.app/Contents/MacOS/PhotoAtelier' --self-test '/Users/mimi/project/ai调色/artifacts/acceptance-20261101/input' '/Users/mimi/project/ai调色/artifacts/acceptance-style-effects-20261103/output-regression-final' '/Users/mimi/project/ai调色/artifacts/acceptance-style-effects-20261103/evidence-regression-final' > '/Users/mimi/project/ai调色/artifacts/acceptance-style-effects-20261103/regression-self-test-final.log' 2>&1`（cwd `/tmp`） | 0 | **APP_SMOKE PASS · 37 checks · 3 exported · 1 isolated**，35.113 秒；真实 CR2、三方案、Lensfun、蒙版、LUT/色域及坏文件隔离。 |
| `swiftc artifacts/acceptance-style-effects-20261103/verify_exports.swift -o artifacts/acceptance-style-effects-20261103/verify-exports > artifacts/acceptance-style-effects-20261103/export-verifier-build.log 2>&1` | 0 | 独立 ImageIO TIFF 复读程序编译。 |
| `artifacts/acceptance-style-effects-20261103/verify-exports artifacts/acceptance-style-effects-20261103 > artifacts/acceptance-style-effects-20261103/export-verify-final.log 2>&1` | 0 | **EXPORT PASS: 16 TIFF files fully decoded**；全部为 16-bit Display P3、orientation 1、有限采样；包含完整 4272×2848 CR2 衍生图，读取了完整 provider。 |

性能基线是链接既有 Release 对象的一次 public-API 微基准：可见热态样本主预览约 159–304 ms，首次 Core Image/GPU 编译明显更慢；原始输出被截断，没有完整分布，不能推导 median/p95。完整命令和可核实读数保留在忽略目录 `performance/baseline-notes.md`；它不代表新增风格库的响应数据。

最终 Release 应用自检的一次观测：14 张当前照片风格缩图 **2.750 秒**；快速连续选择后最新主预览 **99.2 ms**；64 阶 `.cube` 与一个坏文件的后台导入总计 **4.249 秒**，50 ms 定时主循环最大实际间隔 **120.1 ms**（门槛 500 ms）。选择另一 LUT 后，已生成缩图对象直接复用，没有整组重新绘制。该测试使用三张匿名 JPEG，包含当前机器负载与轮询误差；不是跨照片 p95、60 fps 或相对于旧微基准的严格速度提升比例。首次编译、RAW 解码和完整分析可能更慢。

第二次独立复核发现：从旧配方迁移而来的 `colorHarmony=nil` 设置加上新滤镜后，先前会生成颜色报告，但没有执行目标色域映射。已将“有非零新滤镜”纳入目标映射条件，增加 sRGB/P3 的直接像素回归；无滤镜的旧配方仍保持原路径。14 图实测使用默认保护，未触发该条件缺口；最终源码与应用仍整体重验，不把首个 Release 包作为最终交付。自动增量报告也明确排除质感滤镜，避免误以为其安全范围覆盖后续风格叠加。

### 未执行范围与检查入口

CUA 实际调用 `await cua.rewriteDocumentation();` 恢复说明，随后 `let atelierApp = await cua.getApp('/Users/mimi/project/ai调色/build/PhotoAtelier.app');` 返回 **`Sky Computer Use service startup request failed`**（工具错误，无 shell 退出码）。鼠标、键盘、实际滚动、系统文件对话框及人工审美验收**未执行**；自己的 SwiftUI 视图快照不代替这些验收。沿用用户先前“人工验收后再合并”的决定，未申请新的风险豁免。

`style-browser.png` 与 `effects-workbench.png` 已由主代理实际查看，风格照片、选择框、中文说明、搜索/分类与主工作台正常显示；截图在忽略证据目录中。既有 SwiftUI **AttributeGraph cycle** 日志仍在部分 own-view 快照检查中出现，未将其视作已解决；最终应用命令检查均退出 0，但它是后续真实交互需要复核的已知问题。Core Image Kernel Language 的弃用警告仍存在。没有确认的基线构建/测试失败；本轮两次编译失败已修复并由最终全量检查覆盖，未跳过/注释测试，未使用 `--no-verify`。

| 项目入口 | 执行 / 跳过及原因 |
|---|---|
| `make build` / `swift build -j 2` | 最终 `make check` 已执行，退出 0，包含 Swift 类型检查。 |
| `make test` / `swift test -j 2` | 最终 `make check` 无过滤执行，219 tests，0 failures。 |
| `make app` | 未单独执行别名；其唯一入口 `bash Scripts/build_app.sh` 已执行并通过。 |
| `make run` | 未调用别名；同一最终包已从 `/tmp` 经绝对路径独立执行四组自检。真实 UI 受上述工具故障阻断。 |
| 独立 Lint / 类型检查 | 无独立项目入口，Swift 编译覆盖类型检查；没有引入新依赖。 |
| main 合并与合并后回归 | 未执行，用户要求先人工验收；main 未变，保留功能分支。 |

下一步在本机打开 `build/PhotoAtelier.app`，用自己的照片操作风格库分类、搜索、强度、三种滤镜、原尺寸检查及多文件导入/停止，再确认最终画质。完整商业人像功能、生成式恢复、通用 Log/ACES/HDR LUT、跨机器/相机覆盖和持续高帧率没有验收，不包含在本轮功能完成声明里。

### 交付审计

`python3 artifacts/acceptance-style-effects-20261103/audit_delivery.py > artifacts/acceptance-style-effects-20261103/delivery-audit.log 2>&1`，退出 **0**：29 个变更路径与预期一致，88 个源码/构建/测试输入哈希与最终验证快照一致，14 个源文件 hash 未变；新增内容未检出原片私有文件名、疑似凭据或大文件；文档链接有效；219 项测试、18/22/21/37 项应用检查与 16 张 TIFF 已交叉核对，main 哈希未变。源码、照片、可执行文件、日志和索引的审计数据均在忽略目录，不进入提交。

仅显式暂存本文列出的 29 个路径，提交信息 `feat(styles): add guarded LUT and effects workflow`；提交哈希见最终交付回复。按既定出口不合并、不删除分支、不推送。

## 变更文件

新增：

- `Sources/PhotoCore/CreativeEffects.swift`
- `Sources/PhotoAtelier/CreativeEffectsPanel.swift`
- `Sources/PhotoAtelier/PreviewRaster.swift`
- `Sources/PhotoAtelier/StyleBrowserView.swift`
- `Sources/PhotoAtelier/StylePreviewController.swift`
- `Sources/PhotoAtelier/StyleWorkflowSmokeHarness.swift`
- `Tests/PhotoCoreTests/CreativeEffectsTests.swift`
- `Tests/PhotoCoreTests/LUTCatalogTests.swift`
- `Tests/PhotoCoreTests/StyleWorkflowTests.swift`
- `Scripts/evaluate_style_effects.swift`
- `docs/style-effects.md`

修改：

- `Sources/PhotoCore/LUTCube.swift`
- `Sources/PhotoCore/Models.swift`
- `Sources/PhotoCore/PhotoEngine.swift`
- `Sources/PhotoCore/AutomaticSafety.swift`
- `Sources/PhotoCore/NativeInspection.swift`
- `Sources/PhotoAtelier/AppModel.swift`
- `Sources/PhotoAtelier/ContentView.swift`
- `Sources/PhotoAtelier/PhotoAtelierApp.swift`
- `Sources/PhotoAtelier/NativeInspectionView.swift`
- `Sources/PhotoAtelier/PortraitSmokeHarness.swift`
- `Sources/PhotoAtelier/SmokeHarness.swift`
- `Tests/PhotoCoreTests/AdaptiveDetailTests.swift`
- `Tests/PhotoCoreTests/ColorCompatibilityTests.swift`
- `Tests/PhotoCoreTests/LocalMaskTests.swift`
- `Tests/PhotoCoreTests/SceneAdaptiveTests.swift`
- `Tests/PhotoCoreTests/TonalCurveTests.swift`
- `README.md`
- `docs/native-inspection.md`

无删除文件。既有测试中的默认版本断言与未知未来版本改为 v8/v9，显式 v6/v7 向后兼容覆盖保留。

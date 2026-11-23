# PhotoAtelier 关键架构与工程决策记录（DECISIONS.md）

> 按 ADR（Architecture Decision Record）精简记录重要技术取舍与踩坑结论，防止后续迭代重复踩坑或推翻既有合理约束。

---

## ADR-001：GitHub Actions CI 采用 `macos-15`（Apple Silicon）+ Rosetta `arch -x86_64`

- **背景**：`Scripts/prepare_lensfun.py` 锁定提取 `x86_64` 架构的 Lensfun wheel，并在运行时校验 `platform.machine() == "x86_64"`。同时，GitHub Actions 提供的 `macos-15-intel` 无头虚拟机缺少完整 Metal GPU 支持，创建非软件渲染 `CIContext` 会触发 `IOAccelerator` 的 `IOAccelLogContextLeak` 崩溃及 NaN 区域检测异常；而 `macos-14` runner 配置在当前账号下已停用。
- **决策**：在 `.github/workflows/ci.yml` 中采用 `runs-on: macos-15`（Apple Silicon 具备完整 Paravirtualized Metal GPU），并通过 Rosetta `arch -x86_64` 显式调用系统自带的通用二进制 `/usr/bin/python3` 与 `/usr/bin/swift` 执行依赖准备、编译和全量测试；同时将 7 个测试类中非惰性的 `CIContext` / `PhotoEngine` 实例属性改为 `private static let` 惰性共享。
- **影响**：无需改动产品渲染代码或放宽测试条件，PR #6 实测稳定跑通 814/814 全量测试；需注意必须写全路径 `/usr/bin/python3`，避免命中仅含 `arm64` 切片的 Homebrew `python3`。

---

## ADR-002：人像精修全链路采用「照片自身相对判据」与「皮肤权重归一化模糊」

- **背景**：P3-E4 与 R1–R6 实拍人像评审发现，牙齿、眼白、虹膜清晰度、去油光与去头发等模块在欠曝或逆光真实照片上静默失效或反向破坏，原因均是用绝对亮度阈值（如 `L* > 60`、`lum > 0.70`）硬编码了单一影棚布光；同时普通盒式模糊会在脸缘把背景平均进来，形成亮/暗边缘光晕。
- **决策**：
  1. 肤色/毛孔/油光/牙齿/眼白/虹膜/头发分离全部改用相对于当前照片或当前人脸自身的统计量（分位点、中位亮度、实测纹理幅度中位数）作为门限与对比支点；
  2. 皮肤低频参考统一采用归一化卷积形式 `boxBlur(L · w) / boxBlur(w)`（`w` 为皮肤有效覆盖权重乘以非保护区权重），背景、发丝与五官不参与皮肤参考均值计算。
- **影响**：使人像模块行为随照片曝光、肤色与传感器噪点自适应迁移，且皮肤边界与保护区外保持零光晕、逐位不变。

---

## ADR-003：R7 祛瑕采用「双尺度 + 残差符号分离连通域 + 旋转不变二阶矩门控」

- **背景**：R6 实测表明原单尺度 `BlemishRemovalEngine`（低通半径 `~5 px`，面积上限 `pixelCount / 500`）对半径 `≥ 5 px` 的真实痘印与色斑消除率仅 0–9%；但简单放大半径与面积又会出现三个问题：暗斑与外围相反符号的低通正残差光晕环在 4-邻域下粘连导致整体超限、大斑点修补目标被自身拉暗残留灰坑、水平与斜向泪沟/法令纹/皱纹被误删。
- **决策**（PR #7，`Sources/PhotoCore/BlemishRemoval.swift`）：
  1. 保持精细尺度（`0.4%` 长边，最小 4 px）并新增中等尺度（`1.8%` 长边，最小 14 px），均采用皮肤权重归一化模糊；
  2. 按残差正负号（`-1` 暗斑 / `+1` 亮斑）分别做 4-邻域连通，杜绝与相反符号光晕环粘连；
  3. 中等尺度检测出斑点后，将其掩码从皮肤权重中剔除再重算干净低频基线，修补目标取干净基线并做 2 px 软边羽化；
  4. 对中等尺度以及精细尺度面积 `≥ 12 px` 的连通域计算二阶中心矩等效椭圆长短轴比 `sqrt(λ1 / λ2) <= 2.3`，在水平、垂直与任意斜角下统一拦截细长折痕，同时保持 `keepSpots` 跨尺度护痣。
- **影响**：零配方字段与版本号改动（保持 v33），旧配方行为兼容；CI 实测 817/817 全绿，半径 6–11 px 大痘印显著消除且水平/45° 斜向折痕与大号暗痣完整保留。

---

## ADR-004：`TonalCurve` 延伸高光段以精确乘法 `* 0.0625` 替代除法 `/ x7`

- **背景**：`TonalCurveEngine` 内核其他除法均已使用 `refinedReciprocal` 规避 Core Image 软件 JIT 近似倒数指令（约 12–13 bit 精度、`~1.22e-4` 误差），但高光延伸段 `x >= x7`（`x7 = 16.0`）遗留了裸除法 `output4567.w / x7`，在 macOS 15 软件渲染器上触发了 `TonalCurveTests.testSoftwareAndMetalContextsRenderCurveWithinFloatTolerance`（`1e-5` 容差）失败。
- **决策**（PR #6，`Sources/PhotoCore/TonalCurve.swift`）：改为 `x * (output4567.w * 0.0625)`，`1 / 16.0` 在 IEEE 754 中精确表示，零近似误差。
- **影响**：不放宽任何精度断言即可实现 CPU 软件渲染与 Metal 渲染跨后端严格一致。

---

## ADR-005：RAW 解码采用 `CIRAWFilter` 主路径 + `LibRaw 0.21.5` 动态链接回退

- **背景**：`CIRAWFilter` 拥有 Apple 官方 demosaic 与相机色彩标定，但旧 macOS 上缺失新型号相机支持；macOS 13 deployment target 亦无法使用仅 macOS 27 才提供的系统 CoreML 降噪（`decoderVersion = .version9`）。
- **决策**（`docs/raw-engine-evaluation.md`）：保持 `CIRAWFilter` 为主解码器，仅在失败时回退到随包动态链接的 `LibRaw 0.21.5`（LGPL-2.1，跟随 Lensfun 分发合规模式），并在 `analysis.decoder` 中如实标注 `"LibRaw"`；CoreML 降噪本期不做。
- **阻塞**：待获取 1–3 张真机 RAW 样片或确认目标相机型号后解锁实施。

# P3-E: 真实照片处理质量优化计划（基于 13 张真实样片的全链路诊断）

**日期**：2026-11-11
**目标**：让桌面真实图片（`/Users/mimi/Desktop/图片`，13 张：暗调×4、风光×4、人像半身×3、夜景×1、逆光×1）在当前引擎下处理到最好状态。
**方法**：不是凭想象排计划，而是先用诊断探针（`Scripts/probe_p2_applied.swift`）逐张实测每个模块的 `applied` 状态与 report note，从真实数据中找缺口。

---

## 0. 诊断结论总览（实测数据）

| 维度 | 实测结果 | 状态 |
|---|---|---|
| 场景模块（sky/bokeh/创意效果） | 13/13 张全部 `applied=true`，天空/景深/红晕/薄雾正常生效 | ✅ 健康 |
| 美肤模块（zonal/bodySkin/clothing/hair） | 3 张人像样片全部生效 | ✅ 健康 |
| **人像微雕 + 发色/胡青模块（P2 共 9 个）** | **3 张有人脸的样片上全部 `applied=false`**（探针 `bone-only` 单独跑也复现；修复后实测已生效） | ❌ **P0 缺陷（P3-E1 已修）** |
| 场景 sky 掩码 | 13 张都「成功」，但风光/夜景/逆光与暗调图全走 `return 0.40` 默认地平线 + `hasSky=true` 硬编码 | ⚠️ P1 疑似假阳性 |
| bokeh 散焦半径 | 13 张全部「最大散焦半径 16.8」一字不差——0.35×48px 是常数，与图像内容无关 | ⚠️ P1 疑似假阳性 |

---

## 1. P0 缺陷：人脸微雕模块在真实人像上全部静默跳过

### 1.1 现象

样片 10/11/12（人像·环境半身，Vision 检测 conf=1.00、17 点轮廓/6 点双眼/14 点唇全部可用）跑 `08_p2_reshape_suite` 管线：

- `liquify`：applied=true（正常）
- `facialZonal/bodySkin/clothing/portrait`：applied=true（正常）
- **`facialBoneContour/eyeShape/noseReshape/jawChinReshape/eyebrowReshape/facialContour/expression`：全部 applied=false**，note=「未检测到可用人脸」

### 1.2 根因（源码级确认）

[PhotoEngine.swift:487-489](Sources/PhotoCore/PhotoEngine.swift)：

```swift
let needsFaceMasks = needsPortraitMasks || makeupActive || facialZonalActive
    || multiPersonActive || eyeTeethActive || eyelidAegyoSalActive
```

`needsFaceMasks` 的触发列表**漏掉了 9 个模块**：P2 微雕 7 个（facialBoneContour/eyeShape/noseReshape/jawChinReshape/eyebrowReshape/facialContour/expression）+ P2-R 发色（hairColor）+ P2-S 唇毛胡青（facialHair）。这些模块在管线后段（~812-1010 行）读取 `detectedFaces`——但当只有其中之一启用时，`needsFaceMasks == false` → `detectedFaces = []` → 模块读到空列表 → 全部以「未检测到人脸」跳过。

**为什么 791 项测试没抓到**：单元测试直接调用引擎（`FacialBoneContourEngine.apply(to:faces:settings:)`，手工构造 landmarks），绕过了 `PhotoEngine.process` 的检测分发层；而 P3-D 回归管线把微雕与 `facialZonal` 组合使用，后者在触发列表内，恰好掩盖了缺口——只有微雕模块单独启用时才触发。

**为什么自动方案/分析页没暴露**：用户 UI 上勾选微雕时通常也会开着磨皮或妆容。

### 1.3 修复方案（P3-E1，约 0.5 天）

1. **修 `needsFaceMasks`**：把触发列表提取为静态谓词 `PhotoEngine.requiresFaceDetection(_:)`（单一事实来源，可独立测试），补入 9 个模块的 active 判断；
2. **补测试**：`Tests/PhotoCoreTests/FaceDetectionGatingTests.swift`——(a) 谓词触发矩阵（9 个修复模块 + 既有 7 个触发模块 + 4 个不应触发的中性/关闭用例）；(b) `PhotoEngine.process` 管线级测试（`preparedMakeupFaces` 注入 landmarks，断言 9 个模块逐一 `applied=true` 且无「未检测到人脸」告警；无人脸时显式降级）；
3. **真机回归**：探针确认 sample-10 上 bone-only 管线 `applied=true`（实测：智能全脸骨相光影修容处理完成，1 人）；
4. **配方兼容**：纯管线分发修复，不改配方字段/顺序/版本，无兼容性影响。

**验证方法论备注**：`preparedMakeupFaces` 注入会绕过 `needsFaceMasks` 门禁本身（496 行先于门禁取值），所以管线级测试不能证明门禁修复——门禁由谓词单测覆盖，注入测试覆盖「阶段确实消费 landmarks」；两者缺一不可。端到端真机验证由探针承担。

---

## 2. P1 疑点：场景模块假阳性（看起来在工作，实际可能是常数替换）

### 2.1 天空掩码疑似假阳性

`SkyEnhancement.detectHorizonHeight` 的 Vision 检测失败时**静默回退 `0.40`**（[SkyEnhancement.swift:127](Sources/PhotoCore/SkyEnhancement.swift)），且 `makeSkyMask` **永远返回 `hasSky=true`**（几何矩形上 60% 直接当日空）。后果：13 张样片（包括暗调室内、夜景、逆光）全部「成功应用天空增强」——暗调图的上 60% 也被当天空调了蓝色。

**修复（P3-E2，已实施）**：
- `makeSkyMask` 增加天空像素统计门禁（`measureSkyFraction`）：地平线以上区域降采样（64px 长边）渲染后统计天空候选像素（线性亮度 > 0.85 过曝白，或亮度 > 0.45 且蓝-红通道差 > 0.02 的蓝青色）占比，< 15%（`minimumSkyFraction`）时 `hasSky=false`，走显式「未检测到天空」跳过；只加在引擎自生成掩码路径，`precomputedSkyMask` 注入路径不受影响；
- **实施中修正过一个关键 bug**：`CIContext.render` 位图第 0 行是图像**顶部**（top-down），不是 bottom-left——初版方向写反导致量的是地平线以下，13 张样片全量重标定后才定稿阈值；
- **阈值 15% 用引擎实际测量路径（含 Vision 地平线检测）在 13 张真实样片上标定**：花田特写 01 = 0.04、大桥夜景 06 = 0.00、水彩合成图 09 = 0.00、树林逆光人像 11 = 0.14 → 全部正确拒绝；校园蓝天 02 = 0.54、海岸 03 = 0.42、仰拍天空 04 = 0.75、山坡带天空 05 = 0.21、楼顶过曝天空 07 = 0.30、花田蓝天 08 = 0.85、双联湖景人像 12 = 0.38 → 正确接受；湖面人像 10 = 0.55（湖面高亮偏蓝被计入，启发式固有边界）、白底图标 13 = 0.69（合成图）→ 假阳性但无害。**判定准确率 10/13，相比修复前 13/13 无条件增强（准确率 6/13），错误方向从「不该增强时增强」转为「有亮蓝区域才增强」**；
- 既有 SkyEnhancementTests 全部通过（14/14），新增 3 项门禁测试（分类正确性/室内拒绝/真天空接受）。

### 2.2 景深虚化半径是常数

`16.8px` = `0.35 × 48`（`apertureFocalSize 0...1 → 0~48px` 线性映射），与图像内容、人物深度完全无关。深度重构（`groundPerspectiveGradient`）可能没有真正参与半径调制，或调制了但 report 没反映。

**修复（P3-E3，已实施）**：
- **根因（探针实测确认）**：`depthGradientKernel` 内用 `samplerCoord` 计算 `ny`，但该内核在真实渲染路径下产出的深度图**空间上处处均匀（≈0.75）**——地面透视调制从未到达输出。此前所有「虚化」都是 `CIBlendWithMask` 对一个常数深度图的常数混合，`depthFalloffRate` 0.2 与 1.0 输出完全相同；
- **修复**：删除内核实现，改为**光栅化线性梯度**（`makeGroundGradient`，RGBAf extended linear sRGB，4px 宽列满足 64 字节行对齐，行 0 = 图像顶部远景 1.0 → 末行 = 底部近景 0.35），经 `CIColorMatrix`（falloff 缩放 − focalOffset 偏置）+ `CIColorClamp` 得到深度场；主体区域用 `CIBlendWithMask`（mask 取自掩码 alpha）压为 0。实施中踩过的坑：`CIImage(bitmapData:)` 行 0 渲染在图像**顶部**；行宽不足 64B 会错位读成乱码；掩码色值可能预乘导致 `mask.r` 失真，须用 **alpha** 作主体权重；
- **report 诚实化**：`BokehBlurReport` 新增 `nearRadius`/`farRadius`（自深度场底部/顶部实测采样的真实散焦半径），note 由常数「最大散焦半径 16.8px」改为「近景半径 X px，远景半径 Y px」；
- **验证**：合成条纹图全管线（透明掩码）底部保留度 0.78 → 顶部 0.14；真实样片 08 边缘能量比底部 0.63 / 中部 0.38 / 顶部 0.11；report 近景 16.8px（0.35×48）vs 远景 48px（1.0×48）；`depthFalloffRate` 现在真实改变深度梯度；新增回归测试 `testDepthGradientModulatesBlurTopToBottom`（锁定底部 > 中部 > 顶部的清晰度次序）与 `testSubjectRegionStaysSharpInsideDepthGradient`（不透明主体全域零虚化），BokehBlurTests 10/10 通过。

---

## 3. P2 增强：让人像样片处理到「最好状态」

修复 P0 后，3 张人像样片的微雕链路才第一次真正在真实照片上跑通。届时：

1. **重跑 10 管线审美回归**（P3-D 引擎已就绪），重点人工评审 sample-10/11/12 的「P2 微雕」「P2 大师」页签；
2. **保守量调优**：若发现微雕在 1440×960 半身人像上效果过弱/过强，调整回归管线参数并记录到 P1-H 样片矩阵；
3. **风景样片调优**：sample-02/04/08（风光）重点检查天空增强修复后的效果差异、创意效果组合的胶片感是否自然。

---

## 4. 执行排期

| 批次 | 内容 | 工作量 | 交付判据 |
|---|---|---|---|
| **P3-E1（本计划第一批，立即可做）** | 修 `needsFaceMasks` 漏列表 + 集成测试 + 13 张探针回归 | 0.5 天 | sample-10/11/12 微雕模块 applied=true；全量测试绿 |
| P3-E2 | 天空掩码真实性验证（统计检查 + 显式降级） | 1 天 | 暗调/夜景样片显式「未检测到天空」；风光样片正常 |
| P3-E3 | 景深场真实性审查与 report 增强 | 1 天 | 人像样片 report 显示近/远半径差异 |
| P3-E4 | 修完后的 10 管线全量回归 + 人工评审 + 参数调优 | 0.5 天 | 审美画廊人工评分，样片达到可交付状态 |

**总计约 3 个工作日**。P3-E1 是纯缺陷修复（无新功能），P3-E2/E3 是诚实性修复（让 report 不说假话），P3-E4 是验收。

---

## 5. 诊断工具沉淀

本次新增的 [Scripts/probe_p2_applied.swift](../Scripts/probe_p2_applied.swift)（编译产物在 /tmp，源码保留）可随时重跑：

```bash
BIN="$(swift build --show-bin-path)"
swiftc -I "$BIN" Scripts/probe_p2_applied.swift \
  "$BIN"/PhotoCore.build/*.o "$BIN"/CLensfunBridge.build/CLensfunBridge.c.o \
  -o /tmp/probe_p2_applied
/tmp/probe_p2_applied "/Users/mimi/Desktop/图片" 13
```

它打印每张样片在微雕/美肤组合下每个模块的 `applied` 与 note，是「真实照片 × 模块」覆盖矩阵的直接证据源，建议随 P3-E1 一起提交并纳入回归流程。

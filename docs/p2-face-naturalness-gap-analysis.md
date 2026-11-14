# P2 人像微雕自然度差距分析与重做方案

**日期**：2026-11-12
**触发**：P3-E4 画廊人工评审——"太假太过了，特别是人脸，一点都不自然"、"现在的简直就是乱搞"。
**结论先行**：假脸的根源不是参数档位，而是**架构性缺陷**——6 个"涂色"模块是盲模板（贴纸式），1 个引擎是盲形变（不看照片内容）。参数降到 0 之外，必须重构。

---

## 一、专业修图工艺基准（研究结论）

专业商业人像修图的公认流程（来源：Pratik Naik/Sef McCullough 等商业修图教学、知乎/站酷中文商业修图流程、Fstoppers/PetaPixel 分析文章）：

1. **去瑕**（heal/clone，单独图层）→ 2. **频率分离磨皮**（低频管颜色明暗、高频保毛孔纹理）→ 3. **双曲线/中性灰 D&B**（提亮压暗重塑光影，画笔流量极低）→ 4. **统一肤色** → 5. **整体调色** → 6. **锐化输出**。

核心纪律（我们逐条对照）：

| 专业纪律 | 违反它的后果 |
|---|---|
| **先看照片再动手**——每一步都响应照片内容（瑕疵在哪、光从哪来、是否已在笑） | 盲模板套照片 = 贴纸感 |
| **质感保留是商业与业余的分水岭**——毛孔、绒毛、局部色变必须保留；按 ISO 补回噪点 | 均匀涂抹 = 塑料皮 |
| **液化 5–15% 微调**，大半径低密度画笔，保护皱纹发丝，保留不对称 | 0.55 档形变 = 假脸 |
| **修容靠 D&B 塑光影，不涂颜色**——用照片自己的明暗塑形 | 加白色高光条 = 妆画在照片上 |
| **过度修不如少修**——欠修读作自然，过修读作假 | 全模块叠加 = 假上加假 |
| **眼神光只能增强已有的**，不能无中生有 | 合成 catchlight = 双重高光 |

---

## 二、12 模块审计：谁能救、谁必须重做

实现架构：人脸检测统一走 `FaceSemanticAnalyzer.detect`（Vision landmarks，1024 边 raster）；几何模块共享 `WarpField`（128×128 网格 + 高斯控制点 + pull-remap CIKernel，全局 3% 位移硬顶）。

### ✅ 架构正确、可以救（响应照片内容）

| 模块 | 现状 | 问题 | 救法 |
|---|---|---|---|
| **PortraitRefinement**（皮肤） | 真三频段分离（box blur 1.5%/0.8%/0.18%），D&B 目标是从照片实测的皮肤均值，delta 限幅 ±0.16、只动亮度不动色度，纹理有专门回注控制 | `dodgeBurn` 把低频拉向**全脸均值** = 均匀化涂平，抹掉光影立体感 | D&B 目标从"全脸均值"改为"保留低频空间结构"（只压瑕疵频段，不压光影频段） |
| **FacialZonalRefinement** | 泪沟/法令纹的提亮量取自照片本身的褶皱暗度（`max(0, drape − mid)`）；anti-shine 按像素自身亮度/色度门控；暗圈混合目标是采样皮肤色 | 区域位置是硬编码 bbox 比例（非 landmark） | 区域锚到 landmark；其余保留 |
| **BlemishRemoval** | 紧凑暗缺陷愈合（高频缺陷→局部低频基线） | — | 保留 |

### ⚠️ 架构可用、纪律要改（几何液化类）

Liquify / EyeShape / NoseReshape / JawChin / FacialContour / EyebrowReshape / Expression——审计结论：**结构上低强度能自然**（真 landmarks、平滑限幅位移），风险在：
- `ExpressionEngine` 的 `smileDegree` **无条件**上推嘴角（`mouthHeight × 0.52 × strength`），不看照片是否已在笑 → sample-10 的咧嘴假笑实锤（ExpressionEngine.swift:170-214）
- 左右判断只看 extreme X，歪头/侧脸向量镜像
- Expression 的 warp 无背景保护、无场平滑（其他模块有）
- 颅顶/发际线锚点是"眉顶 + 固定比例"的推导值，不是检测值

**救法**：参数档位锁进 5–15% 专业纪律 + smileDegree 加"已有笑容检测"（Vision 的 smileLikelihood 或嘴角-唇弓几何关系）+ 补齐 Expression 的背景保护。

### ❌ 架构性错误、必须重做（涂色盲模板）

审计定性：**"任何参数值都不可能自然"**——

1. **FacialBoneContourEngine**：CGContext 画死 T 区/C 区/人中/下颌线高光阴影引导图，高光是**加色白**（`col += vec3(1.0) * weight`），阴影是固定乘法压暗。不估计照片光向、不读肤色。光线从左来的照片，鼻梁上的白条依然画在正中 → 妆感/贴纸感
2. **NoseReshape 3D**、**JawChin contour**、**FacialContour 3D**、**Eyebrow 3D**、**Expression lip 3D**：同一模式的固定白高光 + 固定暗阴影
3. **EyeTeeth catchlight**：6 种硬编码白色形状加色叠在瞳孔上——**不检测已有眼神光**，原图有高光的照片直接出双高光（最极端的"无中生有"）
4. **Makeup 高光/腮红/修容**：位置是 bbox 模板，色度是固定值（高光 1.0/0.98/0.94、修容 0.42/0.34/0.28）——亮度保留机制是对的，但摆放和颜色是贴纸

另有一个 P3-E 顺手修掉的 bug：**单脸分支 `EyeTeethRefinementEngine.apply` 漏传 maskSet**（PhotoEngine.swift:823-825），一直走粗糙的多边形 fallback 而不是语义掩膜。

---

## 三、重做方案（分两阶段）

### 阶段 R1：止血（先让回归管线不再造假，改动小）

1. **回归管线模板大瘦身**——"宁可无感，不可假脸"：
   - 08/10 号管线：**关闭全部涂色模板模块**（bone/contour3D/lip3D/catchlight/makeup 高光修容）
   - 只保留：BlemishRemoval + PortraitRefinement（texture 回注调高）+ Zonal（泪沟法令纹，照片自适应的那部分）+ 眼牙的**测量型**子项（去红血丝/去黄，不动 catchlight）
   - 几何液化：仅保留 jawlineTighten / eyeSymmetry ≤ 0.10，其余归零
2. **catchlight 默认关闭**：`catchlightStrength` 默认 0，仅用户显式开启且检测确认瞳孔无高光时才可画
3. **修单脸分支 maskSet 漏传**（PhotoEngine.swift:823）

### 阶段 R2：重构涂色模块为"光响应 D&B"（架构修正）

按专业 D&B 逻辑重写 6 个涂色模块的公共底座：

1. **光向估计**：从面部区域亮度梯度估计主光方向（左/右/顶/正面的粗分类即可）
2. **从照片导出涂抹色**：高光色 = 采样该面部实际高光区色温；阴影色 = 采样实际阴影区色（带肤色，非纯黑/纯白）
3. **D&B 代替加色**：高光 = 局部提亮（screen/soft-light 语义、低流量），阴影 = 局部压暗，全部以照片自身明暗为基准做**增量**，模板只提供**位置先验**
4. **已有特征检测**：catchlight 先检测瞳孔内已有高光（阈值+连通域），有→增强，无→按光向决定画不画
5. **一致性验收标准**：同一张脸换光照方向，输出必须跟着光向变——这是"响应照片"的定义，写进单元测试

### 验收

- 13 样片 × 10 管线重跑画廊，人脸页签人工评审通过为唯一标准
- 新增"光向翻转一致性"单测 + "已有 catchlight 不叠加"单测

### 阶段 R3：第二轮实拍复盘的架构修复（2026-11-14）

R1/R2 之后，第二轮实拍评审的结论是「针对人的处理和优化特别差」——不是某一档参数过强，而是**人像管线作用在了错误的位置上**。逐项定位后修了 10 处（下表 6 条 + 下面 4 条），随后二次复盘又发现 2 处与参数无关的整图缺陷（见本节末尾的 R3 补丁）：

| 问题 | 根因 | 修复 |
|---|---|---|
| 人像管线几乎等于没做（样片 03 前后差 0.022） | Vision 的 `faceContour` 是**开口弧**（太阳穴→下巴→太阳穴），`boundingBox` 只到眉毛；皮肤蒙版因此只覆盖下颌一条，全脸各阶段都作用在一个小补丁上 | `FaceLandmarkSet.skinOvalPolygon` / `skinOvalBox`：用额顶帽闭合开口弧，皮肤蒙版覆盖整张脸的椭圆；已闭合轮廓（间隙 ≤ 0.35×对角线）不再二次加帽 |
| 全图 30% 柔化，皮肤蜡感 | `FacialZonalRefinement` 内核以 `mid` 模糊图为基底重建整幅照片，只回注 `texturePreservation` 的高频 | 内核改为**以原始像素为基底**，所有修正都乘区域蒙版；区域外逐位不变 |
| 灰脸 / 光比被抹平 | 所有区域共用 `drape − mid`（超宽模糊与中宽模糊之差）检测，它测的是**大尺度亮度**，在有明暗面的脸上到处触发 | 双检测器：`mid − fine` 只对细窄暗线（皱纹、法令纹、泪沟折痕）为正；`drape − mid` 只用于眼袋/黑眼圈这两个**宽阴影池**蒙版 |
| 区域位置是 bbox 硬编码比例 | 比例是按只到眉毛的框量的 | 蒙版锚到 landmark：法令纹沿鼻翼→嘴角、额头走眉上走廊 + 眉间、下颌走廊下移到下巴以下（覆盖颏下折痕）、T 区按闭合脸框重新布局 |
| D&B 把光影拉平 | `FrequencySeparation` 的 dodge 目标含全脸均值项，亮面被系统性压低、暗面被抬亮 | 目标改为**皮肤加权的脸级超宽趋势**（仅皮肤像素参与，头发/背景不拉低参考）；趋势本身就是光向，因此保留 100%，只削去相对趋势的斑驳偏差（实测低频谱标准差 0.0976 → 0.0928，均值不漂移） |
| 去油光 / 光泽控制在真实照片上完全不生效 | 门限用**绝对**线性亮度 `lum > 0.70`；引擎在 extended-linear-sRGB 工作，真实皮肤只有 0.05–0.30，实测最大改动 0.0028 | 两个判据都改为**相对**量：`lum / drape` 峰值比（油光是相对周围漫反射皮肤的局部尖峰）+ `chroma / lum` 白度（高光冲淡饱和度，皮肤提亮不冲淡）；`FrequencySeparation` 的 `gloss` 高光门限同样从绝对值 0.55–0.85 改为相对该脸平均皮肤亮度；全部与工作色彩空间无关 |

同批还补了三个「无中生有 / 贴纸感」的架构问题：

- **合成眼神光**（`EyeTeethRefinement`）：新增 `analyzeCatchlight`，从虹膜像素检测**已有高光**（有→原地增强，绝不叠第二颗）与**光向**（颊/额/颏三点亮度比较）；两者都无证据时不画。
- **微笑嘴角上推**（`ExpressionEngine`）：`ExpressionGeometry.existingSmileArc` 从照片自身的唇轮廓量出「已经在笑多少」，`smileHeadroom` 据此衰减 `smileDegree`——中性嘴吃满，咧嘴几乎不吃。
- **骨相光影的加色白**（`FacialBoneContourEngine`，R2 §3 第一条的落地）：高光不再 `col += vec3(1.0) * w`，而是向**照片自身的受光肤色**提亮、并按像素余量衰减（额头亮部不会被推到过曝）；阴影不再乘固定暗色，而是乘**阴影肤色 / 受光肤色**的逐通道比值（无偏色的脸得到精确中性压暗，冷阴影保留冷调）；C 区高光与颧下阴影按**实测光向**在背光侧衰减到 25%（衰减烤进引导蒙版，因为 CI kernel 语言不能把 `samplerCoord` 读进局部变量）。光向与两种肤色由 `lightResponse` 从五个面部位置实测。

最后补一个**单脸无效**的控件：**肤色统一**（`PortraitRefinement.unifySkinTone`）。它原本只在「多张脸之间」互相拉平——参考脸就是自己，增益恒为 1，单脸照片上强度拉满也是 0 改动。现在在跨脸增益之外，还把**每张脸自身的低频 a\*/b\*** 拉向该脸自己的平均色度（半径约 5.5% 脸宽，±4 Lab 单位限幅，只重分配不改变脸的均值），这才是修图里「统一肤色」的实际含义：压掉两颊泛红、单侧发黄这类斑驳色块，同时保留整体肤色与暖调。实测单脸低频谱色度标准差 a\* 2.56 → 2.30、b\* 1.62 → 1.53（强度 1.0），脸均值亮度/暖度漂移 < 0.05。

### R3 补丁：全图高光被静默削顶（2026-11-14 二次复盘）

对三张实拍人像逐像素比对时发现两个**与参数无关、开了就生效**的缺陷：

| 问题 | 根因 | 修复 |
|---|---|---|
| 只要开了任一「涂色/五区」模块，**整张照片的高光就被压到 1.0**——背景、头发、衣服全中招 | 十一个 CI 内核（分布在 9 个文件）都以 `return vec4(clamp(col, 0.0, 1.0), c.a)` 收尾，**对每个像素无条件 clamp**。引擎工作在 extended-linear-sRGB，真实高光合法超过 1.0（实测逆光轮廓光 1.22、高光斑 1.40），于是整幅图被削顶 | `FacialZonalRefinement` / `EyeTeethRefinement`（眼、牙、眼神光三个核）/ `FacialBoneContourEngine` / `EyelidAegyoSalRefinement` / `EyebrowReshapeEngine` / `ExpressionEngine` / `FacialContourEngine` / `NoseReshapeEngine` / `JawChinReshapeEngine` 全部改为：**区域权重为 0 时直接 `return c`**，clamp 只作用于真正被蒙版驱动的像素。新增单测 `testHighlightsOutsideZoneMasksAreNeverClipped`（去掉修复即失败：1.40 被削到 1.0） |
| 去反光在实拍上几乎不动 | 判据是**绝对** `luma > 0.65`（同上，实拍皮肤只有 0.05–0.30）；改成相对局部模糊后又被眼白污染——眼睛周围那块模糊本身就是白眼球和反光，比值恒接近 1 | 参照改为**该脸皮肤的中位亮度**（`faceSkinLuminance`：颊骨与额头三点，在 extended-linear 下实测），判据 `luma / skinLuma`；反光按定义是远亮于肤色的反射。实拍实测最大改动 0.0054 → **0.0701** |

另外修了两处「报告说谎」：牙齿/眼白蒙版在闭嘴、眼部过暗时**覆盖率恰好为 0**，但引擎仍把 `teeth`/`eye` 记进 `appliedSteps`（`EyeTeethRefinementReport` 的 `teethStainApplied` / `scleraBloodshotApplied` 也是直接抄滑杆值）。现在两个引擎都用 `hasCoverage`（`CIAreaMaximum` 实测蒙版覆盖率）判断，覆盖为零时不再声称执行，并把原因如实写进 note（"可能闭嘴、未露齿或眼部过暗"）。

### R4 补丁：牙齿/眼白蒙版恒为空、虹膜清晰度反向（2026-11-14 三次复盘）

R3 把「报告说谎」修好之后，note 里那句「缺少牙齿蒙版（可能闭嘴、未露齿或牙齿偏暗）」在三张实拍上**每次都出现**——一查不是闭嘴，是判据本身错了，而且错法和前面几处一模一样：**用绝对阈值编码了影棚布光**。

| 问题 | 根因 | 修复 |
|---|---|---|
| 牙齿美白、眼白提亮在真实人像上**永远不会触发** | `FaceSemanticAnalyzer.colorWeights` 的牙齿判据是绝对 `L* > 60..76`、眼白是绝对 `L* > 64..80`。实测三张实拍：张口那张的最亮牙釉质只有 **L\* 58–60**（判据下沿 60），最亮眼白只有 **L\* 38–45**（判据下沿 64）。两者都判空，覆盖率恒为 0 | 判据改为**相对于这张脸自己的像素**：牙齿看「比嘴唇明显不红」（唇环中位 a\* 18–23，牙釉质低 5–8 个单位）且不比唇暗；眼白看「在该眼自身亮度分布的**上段**」（P10–P90 之间取上 40%）且相对该眼自身色度足够白 |
| 小特征蒙版被羽化抹掉 | 蒙版统一用 `featherRadius` 高斯羽化，它是按**皮肤椭圆**这种大面积区域定尺寸的；真实人像上一张嘴在 1024 栅格上只有约 30×20 px，牙缝更窄，3–4 px 半径的高斯把核心直接摊平（实测峰值只剩 0.29 覆盖） | 牙齿/眼白/虹膜改用 `smallFeatureFeatherScale = 0.25`（同一羽化半径的四分之一），核心得以保持实心（峰值 0.88–0.91）；唇和眉是较宽的区域，保持原羽化 |
| 虹膜清晰度把眼睛**压暗** | 内核以绝对 `vec3(0.35)` 为对比支点；extended-linear 下真实虹膜只有 0.017–0.028，全部低于支点，于是"清晰度"拉满时整颗虹膜被压暗（96/96 像素变暗，0.0275 → 0.0085） | 支点改为**该照片虹膜蒙版的加权平均亮度**（`irisMeanLuminance`，CPU 侧实测后作为第 6 个内核参数传入）。对比度标准差 0.0047 → 0.0056，均值 +0.0002 |

眼白判据一开始写成「比该眼中位亮」，结果被合成人脸单测抓住：一张布光正常的眼睛里**眼白本身就是中位**，于是眼白被自己排除了。改成 P10–P90 分位后，欠曝和正常布光都落在同一个相对高度上。两个方向各有一条单测：`testTeethAndScleraMattesSurviveUnderexposure`（同一张合成脸在 1.0 / 0.35 / 0.15 三档曝光下，牙齿和眼白蒙版都必须覆盖同样的解剖位置——**去掉修复即失败**：0.35 档牙齿 0.013、眼白 0.0；0.15 档两者皆 0.0）与 `testClosedMouthWithLipstickProducesNoTeethMatte`（张嘴能认出来之后，闭嘴不能误认：亮红唇膏是最容易被放松后的判据放进来的情形，实测蒙版峰值为 0）。

实测效果（三张实拍，`PortraitRefinement` 全开）：张口那张现在会执行 `teeth`，三张都会执行 `eye`；闭嘴的两张牙齿仍正确保持为空并如实报 note。

虹膜那条是同一类错误的第三例，值得单独点出：控件叫「清晰度」，实际却在**压暗**眼睛——因为支点 0.35 是影棚级亮度，而实拍虹膜只有 0.017–0.028，全部落在支点之下。修好后同一张图对比度标准差 0.0047 → 0.0056、均值几乎不动（+0.0002），这才是"清晰度"该做的事。新增单测 `testIrisClarityExpandsContrastAroundTheIrisOwnLevel`（去掉修复即失败：对比度归零、亮部纤维被压暗）。

验收：`swift test` 全量 **810/810**；13 样片 × 10 管线重跑画廊（`artifacts/p3f-verify/full-review/index.html`）。新增单测：`testSmileDegreeRespectsExistingSmile`、`testCatchlightIsNeverInventedWithoutLightEvidence`、`testCatchlightEnhancesExistingHighlightInPlace`、`testCatchlightAnalysisDetectsExistingHighlightAndLightSide`、`testSkinToneUnificationEvensSingleFaceChromaWithoutShiftingItsMean`、`testHighlightsOutsideZoneMasksAreNeverClipped`、`testTeethAndScleraMattesSurviveUnderexposure`、`testClosedMouthWithLipstickProducesNoTeethMatte`、`testIrisClarityExpandsContrastAroundTheIrisOwnLevel`。

---

## 四、本报告的证据索引

- 画廊假脸实锤：sample-10 08 管线（自然微笑→咧嘴假笑）、sample-11（塑料皮+浓妆）、sample-12（远脸过度修饰）
- `ExpressionEngine.swift:170-214` smileDegree 盲推嘴角
- `FacialBoneContourEngine.swift:21-78` 固定白加色高光核
- `FrequencySeparation.swift:59-77` D&B 拉向全脸均值
- `PhotoEngine.swift:823-825` 单脸分支漏传 maskSet
- `EyeTeethRefinement.swift:389-435` 合成 catchlight 无检测
- 审计代理完整报告（12 模块逐一 file:line）在会话记录

# P2-J 智能天空识别、氛围增强与置换架构设计与实施规范

## 1. 业务价值与目标 (Objectives)

在商业摄影（外景婚纱、旅拍写真、户外肖像、文旅摄影）中，天空是构图与画面意境的决定性元素。然而实际拍摄中，受天气与动态范围限制，天空往往面临以下痛点：
1. **高光过曝/死白**：由于相机宽容度限制，对准人像曝光时天空常白茫茫一片；
2. **灰蒙沉闷/阴天漫射**：缺少云层层次与色彩反差，画面平淡无奇；
3. **光照断层/贴纸感**：传统粗暴的抠图换天空会导致人物与天空光色割裂（“假贴纸感”），头发丝与树枝边缘产生刺眼白边光晕。

**P2-J 核心目标**：
1. **纯原生、离线、零外部模型**：基于 Apple Vision `VNDetectHorizonRequest` 地平线分析、人物/主体分割隔离蒙版 (`PersonMatte`)、色彩拓扑梯度与 GPU `CIColorKernel` 着色器，100% 离线、低内存、毫秒级渲染；
2. **五大天空精修与氛围置换维度**：
   - `skyVibrance` (湛蓝天色还原)：针对泛白或灰暗天空自适应恢复纯净湛蓝与青金梯度；
   - `cloudContrast` (云层戏剧反差)：增强积云与卷云明暗立体反差，呈现云卷云舒的层次质感；
   - `sunsetWarmth` (日落晚霞氛围)：自适应地平线注入暮色金红或暖橙光晕，营造黄昏氛围感；
   - `skyPreset` (内置程序化天空预设)：提供 5 款经典影楼外景天空风格（湛蓝晴空、日落晚霞、暮光紫霞、戏剧阴云、柔光晨曦）；
   - `foregroundRelight` (前景人物环境光漫射匹配)：根据天空光温自动向人物发丝与前景渗透环境漫射光，彻底消除边缘抠图贴纸感；
   - `edgeFeather` (边缘羽化与防光晕过渡)：智能处理树木剪影、发丝微观边缘与地平线过渡。
3. **工程与质量规范**：
   - 严格遵循中性无损直通（Neutral No-Op，参数为 0 或未启用时像素 100% 字节不变）；
   - 升级 Recipe Version 19，完全向下兼容 v1~v18 配方；
   - 遵循用户全局规则 3.3（先建分支、小步提交、全量测试验证、--no-ff 合并、回归验证）。

---

## 2. 详细解剖与着色器设计 (Anatomy & CIColorKernel Math)

### 2.1 智能天空识别蒙版 (`makeSkyMask`)

- **地平线检测**：调用 Vision `VNDetectHorizonRequest`，获取地平线倾角 $\theta$ 与垂直截距 $y_{\text{horizon}}$；若无显著地平线，默认采用画面上 $60\%$ 为天空潜在区；
- **人物主体防误伤**：利用已有的 `PersonMatte` 或 `VNGeneratePersonSegmentationRequest` 将人物身躯、头部、发丝区域反向剔除；
- **亮度与色度拓扑筛选**：
  天空像素特征：上边界连通度高、明度高（$L > 0.45$）或呈现蓝青色相（$B > R$）；地表深色植被、泥土、暗色建筑（$L < 0.35$ 且高频纹理丰富）被自适应排除；
- **引导羽化 (Guided Feathering)**：
  对粗蒙版应用边缘自适应高斯模糊，生成平滑自然的过渡蒙版 $m_{\text{sky}}(x, y) \in [0, 1]$。

### 2.2 GPU 加速核心着色器 (`CIColorKernel`)

```c
kernel vec4 skyEnhance(
    sampler orig,
    sampler skyMask,
    sampler groundMask,
    float skyVibrance,
    float cloudContrast,
    float sunsetWarmth,
    int skyPreset,
    float foregroundRelight,
    float edgeFeather
)
```

1. **湛蓝天空还原 (Sky Vibrance)**：
   在 $m_{\text{sky}}$ 内，对于偏白过曝区域（$L > 0.65$），自适应补充天青与宝蓝色调：
   $$\text{blueBoost} = (1.0 - \text{saturation}) \times L \times \text{skyVibrance} \times 0.60 \times m_{\text{sky}}$$
   $$C_{\text{azure}} = C + \text{vec3}(-0.15 \times \text{blueBoost}, 0.05 \times \text{blueBoost}, 0.35 \times \text{blueBoost})$$

2. **云层立体反差 (Cloud Contrast)**：
   提取天空区域中高频明暗对比，对暗云区轻微下压、亮云区增强高光，塑造积云厚重感。

3. **暮色晚霞渐变 (Sunset Warmth)**：
   沿地平线到画面顶部的垂直归一化距离 $v = (y - y_{\text{horizon}}) / (1.0 - y_{\text{horizon}})$：
   地平线附近注入金色暖光（$\text{Amber}: (1.0, 0.60, 0.20)$），顶部渐变为深蓝/紫罗兰（$\text{Indigo}: (0.30, 0.25, 0.60)$）。

4. **内置程序化天空 (Procedural Sky Presets)**：
   根据 `skyPreset` 枚举生成平滑天穹渐变：
   - 1 (`azureClear`): 深湛蓝天穹渐变；
   - 2 (`sunsetGlow`): 浓烈火烧云晚霞；
   - 3 (`twilightLilac`): 唯美梦幻紫霞；
   - 4 (`dramaticClouds`): 银灰戏剧云层；
   - 5 (`morningDawn`): 晨曦温润桃粉。

5. **前景环境光漫射匹配 (Foreground Relight)**：
   提取天空在近地平线区域的平均环境光照色相与明度；在前景人物及地表区域（$1 - m_{\text{sky}}$），按 `foregroundRelight` 比例将此漫射光柔和叠加至发丝与边缘高光处，达成光影融合。

---

## 3. 实现计划与步骤

1. **数据模型 (`Sources/PhotoCore/Models.swift`)**：
   - 新增 `SkyPreset` 枚举（`none`, `azureClear`, `sunsetGlow`, `twilightLilac`, `dramaticClouds`, `morningDawn`）；
   - 新增 `SkyEnhancementSettings` 与 `SkyEnhancementReport`；
   - 在 `AdjustmentSettings` 中增加 `sky: SkyEnhancementSettings?`；
   - 在 `ProcessingReport` 中增加 `sky: SkyEnhancementReport?`；
   - 升级 `Recipe.validateVersion()` 范围至 1...19，并在 `sky` 非中性时要求 19。
2. **核心处理引擎 (`Sources/PhotoCore/SkyEnhancement.swift`)**：
   - 实现 `SkyEnhancementEngine`，集成 Vision `VNDetectHorizonRequest`、`PersonMatte` 人物剔除与 GPU `CIColorKernel`。
3. **主管线挂载 (`Sources/PhotoCore/PhotoEngine.swift`)**：
   - 在 `process` 管线挂载 `SkyEnhancementEngine.apply`（位于局部蒙版之前、人像/衣物之后）；
   - 更新 `requiredRecipeVersion`。
4. **UI 与应用状态 (`Sources/PhotoAtelier/AppModel.swift` & `PortraitRetouchPanel.swift`)**：
   - 在 `AppModel` 中提供响应式状态与重置方法；
   - 在精修面板中增加【智能天空氛围与置换】分组（`cloud.sun.fill`）。
5. **单元与兼容性测试 (`Tests/PhotoCoreTests/SkyEnhancementTests.swift`)**：
   - 编写针对默认值、校验、Recipe 19 门禁、中性直通、无天空跳过、湛蓝还原、云层反差、日落晚霞、程序化预设与前景光色匹配的测试。
6. **全量回归与打包验证**：
   - 跑全量测试，Universal App 打包与 `verify_app.py` 验证。

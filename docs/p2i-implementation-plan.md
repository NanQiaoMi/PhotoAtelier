# P2-I 智能宠物精修与写真美化架构设计与实施规范

## 1. 业务价值与目标 (Objectives)

在影楼与摄影工作室日常业务中，宠物写真（猫咪、狗狗肖像）以及人宠同框（婚纱人宠照、家庭合影、宠物生日派对）占比日益攀升。商业修图软件（如像素蛋糕「宠物美化」）将宠物专属美化列为核心卖点。

现有通用人脸与人像精修模块仅识别人类五官与皮肤，遇到宠物时无法定位五官，传统的磨皮与调色常导致宠物毛发糊成一片或眼睛无神。

**P2-I 核心目标**：
1. **纯原生与零外部模型**：基于 Apple Vision 框架内建的 `VNRecognizeAnimalsRequest`（macOS 10.15+ 支持，支持 Cat / Dog 目标识别与边界定位），配合 Core Image GPU 着色器，100% 离线、私密且超高速；
2. **五大专项写真精修维度**：
   - `furFluffiness` (毛发蓬松与根根分明)：微观毛流频段对比度提升，使被闪光灯压扁或镜头柔化的毛发呈现蓬松丰盈质感；
   - `eyeBrightening` (明眸提亮与眼神光聚焦)：精准提取宠物眼眶区域，提亮晶状体暗部并凸显眼神光高光，令双眸灵动清澈；
   - `muzzleMoisture` (鼻吻润泽与立体反差)：加深猫狗鼻头及吻部暗部层次，凸显湿润水光质感；
   - `coatDehaze` (毛发去灰与纯正色泽提升)：消除环境光散射及逆光产生的灰蒙蒙雾感，还原毛发深黑、金黄、银灰的原生纯度；
   - `coatWhiten` (浅色/白毛去黄去污)：针对白猫、白狗（萨摩耶、比熊等）嘴边及四肢微黄氧化暗沉进行色调中和；
   - `texturePreservation` (微观毛流细节保真)：默认 0.70，确保处理后绝无塑料橡皮擦糊感。
3. **架构与工程规范**：
   - 严格遵循中性无损直通（Neutral No-Op，参数为 0 或未启用时像素 100% 字节不变）；
   - 升级 Recipe Version 18，兼容 v1~v17 配方；
   - 遵循用户全局规则 3.3（先分支、小步提交、全量测试验证、--no-ff 合并、回归验证）。

---

## 2. 详细解剖与着色器设计 (Anatomy & CIColorKernel Math)

### 2.1 动物识别与几何定位 (`VNRecognizeAnimalsRequest`)

- **识别目标**：调用系统级 `VNRecognizeAnimalsRequest`，获取 `[VNRecognizedObjectObservation]`。
- **空间归一化**：
  - 提取猫/狗边界框 `boundingBox: CGRect`（Bottom-Left 原点，0...1 归一化坐标）；
  - **头部区域 (Head & Ears)**：位于边界框上方约 $35\%$ 区域，中心约在 $(\text{midX}, y_0 + h \times 0.75)$；
  - **眼眶区域 (Eyes Corridor)**：位于头部中心两侧，左右对称区域 $(\text{midX} \pm w \times 0.15, y_0 + h \times 0.78)$；
  - **鼻吻区域 (Muzzle & Nose Corridor)**：位于头部下中区 $(\text{midX}, y_0 + h \times 0.65)$；
  - **毛发主体 (Coat & Torso)**：边界框中下区及全躯干羽化覆盖。

### 2.2 GPU 着色器数学公式 (`CIColorKernel`)

1. **毛发高频提取 (Fur High-Frequency Band)**：
   $$\text{high} = C_{\text{orig}} - C_{\text{blur}}$$
   $$\text{fluffyColor} = C_{\text{orig}} + \text{high} \times \text{furFluffiness} \times 0.80 \times m_{\text{coat}}$$

2. **眼眶暗部提亮与高光聚集 (Eye Brightening)**：
   在 $m_{\text{eyes}}$ 蒙版内：
   $$L_{\text{lift}} = L + L \times (1.0 - L) \times \text{eyeBrightening} \times 0.65 \times m_{\text{eyes}}$$
   高光区域（$L > 0.75$ 眼神光点）保持锐度并微增对比。

3. **鼻吻湿润感强化 (Muzzle Moisture)**：
   在 $m_{\text{muzzle}}$ 蒙版内：
   对暗部轻微压暗形成黑亮底色，对高反光点做局部对比增强以呈现水光湿润。

4. **去灰与色泽纯化 (Coat Dehaze & Vibrance)**：
   非线性拉伸毛发动态范围并根据毛发色相提升色彩饱和度：
   $$C' = \text{clamp}\left(\frac{C - 0.04 \times \text{coatDehaze} \times m_{\text{coat}}}{1.0 - 0.04 \times \text{coatDehaze} \times m_{\text{coat}}}, 0.0, 1.0\right)$$

5. **白毛去黄提纯 (Coat Whiten)**：
   检测高明度低饱和偏黄区域（$R > B, G > B$），适度提升蓝通道补偿：
   $$B'' = B + (R - B) \times \text{coatWhiten} \times 0.50 \times m_{\text{coat}}$$

---

## 3. 实现计划步骤

1. **数据模型 (`Sources/PhotoCore/Models.swift`)**：
   - 增加 `PetEnhancementSettings` 与 `PetEnhancementReport`；
   - 在 `AdjustmentSettings` 中增加 `petEnhancement: PetEnhancementSettings?`；
   - 在 `ProcessingReport` 中增加 `petEnhancement: PetEnhancementReport?`；
   - 升级 `Recipe.validateVersion()` 支持 1...18，并在 `petEnhancement` 非中性时要求 18。
2. **核心处理引擎 (`Sources/PhotoCore/PetEnhancement.swift`)**：
   - 实现 `PetEnhancementEngine`，集成 Vision `VNRecognizeAnimalsRequest` 与 GPU `CIColorKernel`。
3. **主处理管线串联 (`Sources/PhotoCore/PhotoEngine.swift`)**：
   - 在 `processPipeline` 中挂载 `PetEnhancementEngine.apply`（位于人像精修之后、风格滤镜之前）；
   - 更新 `requiredRecipeVersion`。
4. **UI 与应用状态 (`Sources/PhotoAtelier/AppModel.swift` & `PortraitRetouchPanel.swift`)**：
   - 在 `AppModel` 中提供响应式状态与重置方法；
   - 在人像精修面板中增加【智能宠物写真美化】可折叠分组（`pawprint.fill`）。
5. **单元与兼容性测试 (`Tests/PhotoCoreTests/PetEnhancementTests.swift`)**：
   - 编写针对默认值、校验、Recipe 18 门禁、中性直通、无宠物跳过、毛发蓬松、明眸提亮、鼻吻润泽、毛发去灰、白毛去黄的测试。
6. **全量回归与打包验证**：
   - 跑全量测试，Universal App 打包与 `verify_app.py` 验证。

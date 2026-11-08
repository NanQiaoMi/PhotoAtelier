# P2-P 实施计划：智能双眼皮雕刻、双眼皮贴修饰与卧蚕立体塑形

## 1. 目标与背景

在商业人像精修（婚纱摄影、肖像写真、日韩系/新中式写真）中，眼周微表情与眼裂结构是决定被摄者神采与眼眸灵动感的关键（对齐 PixelCake 官方能力矩阵 §4.3/§4.4 眼睛美化与硬核 AI 功能）。在实际拍摄中，常见痛点包括：
1. **单眼皮/内双/不对称眼皮**：许多被摄者存在一单一双、大小眼或眼皮折痕不明显的问题，需要自然定制双眼皮形态；
2. **人工双眼皮贴穿帮**：拍摄时佩戴的双眼皮贴极易在闪光灯或侧光下产生白色高反光反差、生硬阶梯边缘或胶水反光，传统修图需逐张手动仿制图章涂抹，耗时且易留痕；
3. **下眼睑眼周扁平或凹陷**：缺乏自然的卧蚕（下睑轮匝肌前环），显得眼神冷淡或显老；而人工重塑卧蚕易与眼袋混淆，需要精准的阴影与高光微雕。

本里程碑交付 **P2-P 智能双眼皮雕刻、双眼皮贴修饰与卧蚕立体塑形系统 (Smart Double Eyelid Sculpting, Eyelid Tape Concealing & Aegyo Sal Sculpting)**：
1. **4 款经典双眼皮形态**：开扇型 (Fan-shaped)、平行型 (Parallel)、新月型 (Crescent)、欧美型 (Wide Parallel)，支持折痕高度与宽度的毫米级微调；
2. **双眼皮贴智能隐形 (Eyelid Tape Concealing)**：在上眼睑折痕走廊内智能识别胶贴高反光斑与阶梯边缘，利用双边导向平滑与肤色过渡无缝抹平反光与硬边；
3. **微笑卧蚕立体微雕 (Aegyo Sal Sculpting)**：在下眼睑睫毛线下精准定位眼轮匝肌走形，程序化分离雕刻卧蚕珠光饱满高光区与下缘柔和阴影线，塑造甜美灵动的「桃花微笑眼」；
4. **多人独立分配与预设**：无缝对接 P2-M 多人画像体系（`PersonPortraitProfile.eyelidAegyoSalOverride`），支持新娘/新郎/模特独立眼部微调；
5. **配方版本控制**：升级配方版本门禁至 23（`Recipe.validateVersion()` 升级至 v23）。

---

## 2. 交付物与功能清单

### 2.1 数据模型扩展 (`Sources/PhotoCore/Models.swift`)
- 新增 `EyelidStyle` 枚举：
  - `.off`
  - `.fan`（开扇型）
  - `.parallel`（平行型）
  - `.crescent`（新月型）
  - `.wide`（欧美宽双）
- 新增 `EyelidAegyoSalSettings` 结构体：
  - `enabled: Bool`
  - 双眼皮形态调节：
    - `eyelidStyle: EyelidStyle`
    - `eyelidStrength: Double` (0...1)
    - `eyelidHeight: Double` (0.5...2.0，默认 1.0)
    - `eyelidWidth: Double` (0...1，默认 0.5)
  - 祛双眼皮贴：
    - `tapeConceal: Double` (0...1)
  - 卧蚕立体微雕：
    - `aegyoSalLuminance: Double` (0...1)
    - `aegyoSalShadow: Double` (0...1)
    - `aegyoSalWidth: Double` (0.5...1.5，默认 1.0)
- 新增 `EyelidAegyoSalReport`。
- `AdjustmentSettings` 增加 `eyelidAegyoSal: EyelidAegyoSalSettings?`。
- `PersonPortraitProfile` 增加 `eyelidAegyoSalOverride: EyelidAegyoSalSettings?`。
- `ProcessingReport` 增加 `eyelidAegyoSal: EyelidAegyoSalReport?`。
- `Recipe.validateVersion()` 门禁上限升至 23，非中性 `eyelidAegyoSal` 要求版本 23。

### 2.2 核心算法引擎 (`Sources/PhotoCore/EyelidAegyoSalRefinement.swift`)
- **眼周解剖几何定位**：
  - 基于 `FaceLandmarkSet` 的 `leftEye`、`rightEye`、`leftEyebrow`、`rightEyebrow` 以及瞳孔中心；
  - 上眼睑走廊：从内眦（内眼角）经上眼睑边缘到外眦（外眼角），沿法线方向向上计算双眼皮折痕轨迹；
  - 下眼睑卧蚕走廊：从下睫毛边缘向下延伸 2-4mm 范围，构建卧蚕高光脊线与阴影谷线。
- **Core Image GPU 着色器加速**：
  - `eyelidSculptKernel`：在上眼睑折痕曲线处注入柔和的微暗折痕阴影与上方微高光反射，根据形态函数（开扇渐宽、平行均等、新月中凸、欧美高挑）生成自然皮褶；
  - `tapeConcealKernel`：在上眼睑区域检测异常高光白条与边缘梯度差，保边模糊中和高频反光，重构平滑眼皮质感；
  - `aegyoSalKernel`：沿下眼睑曲率精确映射卧蚕立体光影，叠加柔和明度增益与底线深色晕染，避免与眼袋结构冲突。

### 2.3 渲染管线集成 (`Sources/PhotoCore/PhotoEngine.swift`)
- 在人像细节精修阶段（与眼齿精修协同）执行双眼皮与卧蚕微调；
- 完整支持单人全局配置及多人 `multiPerson` 分人独立重载；
- 记录 `EyelidAegyoSalReport` 与调试说明。

### 2.4 参数同步与批量设置 (`AdjustmentSync.swift` & `SelectiveSyncSheet.swift`)
- `AdjustmentSyncOptions` 增加 `eyelidAegyoSal: Bool = true`；
- 选择性同步浮层增加「双眼皮与卧蚕精雕」勾选项。

### 2.5 UI 面板集成 (`PortraitRetouchPanel.swift` & `AppModel.swift`)
- `PortraitRetouchPanel.swift` 新增「双眼皮与卧蚕精雕」模块；
- 包含形态选择器、各项微调滑杆与重置；
- 支持多人画像切换联动。

### 2.6 测试与质量保证
- 新增 `Tests/PhotoCoreTests/EyelidAegyoSalTests.swift`；
- 升级历史测试中的未来版本检测断言（由 23 升至 24）；
- 全量单元测试回归与 Universal 架构编译验证。

---

## 3. 验收标准（可勾选）

- [ ] `EyelidAegyoSalSettings` 正确编解码，中性设置不改变任何图像像素；
- [ ] 4 款双眼皮形态（开扇/平行/新月/欧美）在眼周坐标系下正确光栅化且折痕平滑连续；
- [ ] 双眼皮贴反光与生硬阶梯边缘能被有效平抚抑制且保留正常眼皮色彩；
- [ ] 卧蚕高光与下缘阴影线立体微雕效果显著且不产生眼袋下垂感；
- [ ] 非中性 `eyelidAegyoSal` 配方受到 Recipe Version 23 门禁保护；
- [ ] `AdjustmentSync` 与选择性同步面板支持双眼皮与卧蚕参数同步与合并；
- [ ] 多人场景下支持按人物或角色独立配置双眼皮与卧蚕参数；
- [ ] `swift test -j 2` 全量测试通过且 0 失败；
- [ ] Universal macOS 应用构建通过并通过 `verify_app.py` 完整性校验；
- [ ] Git 流程严格遵循 Rule 3（基线 `b9f3ddb`、分支 `feat/p2p-eyelid-aegyosal-refinement`、`--no-ff` 合并、分支删除）。

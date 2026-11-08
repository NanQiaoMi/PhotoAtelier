# P2-P 发布说明：智能双眼皮雕刻、双眼皮贴修饰与卧蚕立体塑形 (Smart Double Eyelid Sculpting, Eyelid Tape Concealing & Aegyo Sal Sculpting)

## 概述

在商业人像精修、新娘妆容、证件照与写真后期中，眼部精细微雕是决定眼神灵动感与面部精致度的关键一环（对齐 PixelCake 官方能力矩阵 §3.3/§4.3/§4.4）。针对单眼皮/内双/肿泡眼、贴双眼皮贴产生的强反光与阶梯硬边、以及下眼睑扁平缺乏亲和力的问题，行业修图师通常需要手动绘制折痕阴影并逐像素柔化反光，效率低且极难保证双眼对称自然。

本次更新交付 **P2-P 智能双眼皮雕刻、双眼皮贴修饰与卧蚕立体塑形系统 (Smart Double Eyelid Sculpting, Eyelid Tape Concealing & Aegyo Sal Sculpting)**：
1. **4 大经典双眼皮形态模板**：开扇型（Fan/In-fold，内窄外宽经典东方眼型）、平行型（Parallel，欧亚典雅端庄）、新月型（Crescent，瞳孔上方最高圆润幼态）、欧美型（Wide Parallel，高挑深邃混血感），支持折痕深邃度、高度比率与横向宽度调节；
2. **智能去双眼皮贴反光与阶梯纹 (Eyelid Tape Concealing)**：自动感知上眼睑双眼皮贴反光高光带，抑制镜面强反光并平抚胶贴断层阶梯边缘，取样周边眼部原生肤色进行微米级漫反射融合；
3. **卧蚕立体微雕与高光修容 (Aegyo Sal Sculpting)**：精准定位下睑缘轮匝肌解剖学凸起区（眼裂下 36% 处）注入柔和珠光高光，并在下缘（眼裂下 90% 处）微刻立体阴影凹槽，清晰界定卧蚕边界并彻底避免下垂眼袋形态；
4. **100% 离线与 Metal/Core Image GPU 着色器加速**：基于原生 `FaceLandmarkSet` 解剖眼周拓扑，通过单 Pass 专用 `CIColorKernel` 并发执行眼周微调，零外部模型权重，端到端毫秒级吞吐；
5. **多人多脸独立覆盖与角色适配**：深度接入 P2-M 多人分人框架（`PersonPortraitProfile.eyelidAegyoSalOverride`），男女老少可分别配置不同眼型与卧蚕；
6. **配方升级至 Version 23**：非中性 `eyelidAegyoSal` 受 Recipe Version 23 门禁保护；历史配方无损兼容向下。

---

## 核心技术与数据结构变更

### 1. 数据模型 (`Sources/PhotoCore/Models.swift`)
- **`EyelidStyle` 枚举**：`.off` (关闭)、`.fan` (开扇型)、`.parallel` (平行型)、`.crescent` (新月型)、`.wide` (欧美型)。
- **`EyelidAegyoSalSettings` 结构体**：
  - `enabled: Bool`：主开关；
  - `eyelidStyle: EyelidStyle`：双眼皮折痕形态；
  - `eyelidStrength: Double` (0...1)：双眼皮折痕深邃度与对比度；
  - `eyelidHeight: Double` (0.5...2.0，默认 1.0)：双眼皮折痕相对睑缘垂直高度比例；
  - `eyelidWidth: Double` (0...1，默认 0.5)：双眼皮外侧向眼尾延伸宽度；
  - `tapeConceal: Double` (0...1)：去双眼皮贴反光、抚平边缘硬阶梯强度；
  - `aegyoSalLuminance: Double` (0...1)：卧蚕隆起饱满珠光高光强度；
  - `aegyoSalShadow: Double` (0...1)：卧蚕下缘立体微雕阴影线深度；
  - `aegyoSalWidth: Double` (0.5...1.5，默认 1.0)：卧蚕隆起垂直宽度缩放比例。
- **`EyelidAegyoSalReport`**：记录执行状态、人脸数量、双眼皮/双眼皮贴/卧蚕分别应用情况及提示信息。
- **`AdjustmentSettings` 扩充**：`public var eyelidAegyoSal: EyelidAegyoSalSettings? = nil`。
- **`PersonPortraitProfile` 扩充**：`public var eyelidAegyoSalOverride: EyelidAegyoSalSettings? = nil`。
- **`ProcessingReport` 扩充**：`public var eyelidAegyoSal: EyelidAegyoSalReport? = nil`。
- **`Recipe.validateVersion()`**：支持范围升级为 `1...23`，非中性 `eyelidAegyoSal` 强制要求版本 23。

### 2. 核心算法引擎 (`Sources/PhotoCore/EyelidAegyoSalRefinement.swift`)
- **解剖眼部形态发生器**：计算左右眼内外眦、瞳孔中心、上睑缘弧线与下睑缘弧线，根据参数动态生成引导蒙版；
- **双眼皮导向图 (`eyelidGuideMask`)**：R 通道编码折痕深邃阴影，G 通道编码折痕上方微反光提亮，B 通道编码双眼皮贴检测修饰带；
- **卧蚕导向图 (`aegyoSalGuideMask`)**：R 通道编码轮匝肌高光珠光隆起，G 通道编码下缘立体微雕阴影；
- **`eyelidAegyoSalKernel` CIColorKernel 着色器**：单次采样同时融合原生像素、基准肤色、折痕阴影/高光、胶带漫反射混合以及卧蚕光影。

### 3. 主引擎管线集成 (`Sources/PhotoCore/PhotoEngine.swift`)
- 在多人分人循环中集成 `EyelidAegyoSalRefinementEngine.applyPerPerson`；
- 在单人/全局渲染管线中执行 `EyelidAegyoSalRefinementEngine.apply`；
- 配方版本计算器 `requiredRecipeVersion` 支持版本 23 检测。

### 4. 批量同步与 UI 交互 (`Sources/PhotoCore/AdjustmentSync.swift` & `Sources/PhotoAtelier/`)
- `AdjustmentSyncOptions` 增加 `eyelidAegyoSal: Bool = true`；
- `SelectiveSyncSheet.swift` 在「人像美颜与微整形」增加同步复选框；
- `AppModel.swift` 增加双眼皮与卧蚕的状态管理、修改与重置方法；
- `PortraitRetouchPanel.swift` 新增「双眼皮雕刻与卧蚕立体塑形」控制组，内含形态选择器与精调滑块。

---

## 验证与测试

1. **单元测试 (`Tests/PhotoCoreTests/EyelidAegyoSalTests.swift`)**：
   - 测试默认配置与中性判断无损跳过；
   - 测试 8 项参数越界防护与校验；
   - 测试开扇型/平行型/新月型/欧美型 4 款双眼皮形态生成与报告；
   - 测试去双眼皮贴反光与阶梯纹；
   - 测试卧蚕高光与下缘修容微雕；
   - 测试配方版本 23 门禁控制与未来版本拦截；
   - 测试选择性同步合并与剔除；
   - 测试多人人脸独立配置覆盖与蒙版融合。
2. **回归测试**：全量执行 670 项单元测试，全部 0 failure 通过。
3. **应用构建验证**：成功构建 Universal (x86_64 + arm64) macOS 二进制应用包，通过 `verify_app.py` 完整性校验。

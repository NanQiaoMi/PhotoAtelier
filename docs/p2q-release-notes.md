# P2-Q 发布说明：智能全景背景光斑虚化与景深重构 (Smart Bokeh & Optical Depth-of-Field Synthesis)

## 概述

在商业人像写真、婚纱摄影、外景旅拍与证件照后期中，大光圈镜头（如 85mm f/1.2、50mm f/1.2）带来的焦外弥散光斑（Bokeh）与自然虚化是营造画面空间感、电影感与主体视觉聚焦的核心手段（对齐 PixelCake 官方能力矩阵 §3.3/§4.9）。摄影师往往为了保证人物焦点清晰与边缘锐利而收缩光圈（如 f/2.8 或 f/4.0），但后期需要将背景进行光学级景深虚化与点光源光斑雕刻。

传统的全图高斯模糊或简单蒙版模糊存在三大致命缺陷：
1. **边缘光晕泛白与溢色 (Edge Halos & Bleed)**：前景人物轮廓被背景模糊像素侵蚀或泛白，产生粗糙抠图感；
2. **缺乏物理景深梯度 (No Physical Depth Field)**：背景平铺式单一模糊度，违背光学物理上「离焦平面越远虚化越深」的规律；
3. **高光发闷缺乏晶莹光斑 (Dull Highlights)**：点光源高光被平均模糊成雾状，无法形成光学光圈叶片衍射成型的晶莹弥散光斑。

本次更新交付 **P2-Q 智能全景背景光斑虚化与景深重构系统 (Smart Bokeh & Optical Depth-of-Field Synthesis)**：
1. **连续物理景深场重构 (`makeContinuousDepthMap`)**：基于 Apple Vision 人物语义分割蒙版，融合地面透视衰减梯度与离焦距离场，构建连续平滑的物理景深分布；
2. **4 大经典光学光圈光斑模拟 (`BokehShape`)**：
   - **圆形光斑 (`.circular`)**：现代 85mm f/1.2 顶级定焦圆润饱满光斑；
   - **多边形光斑 (`.polygonal`)**：9 叶片机械光圈衍射多边形微硬质光斑；
   - **旋转光斑 (`.swirly`)**：经典 Petzval 匹兹伐复古旋焦漩涡弥散环；
   - **柔焦奶油光斑 (`.creamy`)**：STF 变迹滤镜 (Smooth Trans Focus) 极致柔滑奶油虚化；
3. **点光源高光光斑雕刻与增强 (`specularHighlightBoost`)**：自适应高光阈值提取与能量放大 GPU 着色器，将背景微弱点光源璀璨重构为高动态晶莹光斑；
4. **前景人物边缘溢色防护 (`edgeBleedProtection`)**：物理锁定主体轮廓处于清晰焦平面，前景边缘无侵蚀、无重影、无雾化光晕；
5. **100% 离线与 Metal/Core Image GPU 着色器加速**：基于原生 `CIBokehBlur` 与自研 `CIColorKernel` 并发执行，零外部模型权重，端到端毫秒级实时渲染；
6. **配方升级至 Version 24**：非中性 `bokehBlur` 受 Recipe Version 24 门禁保护；历史配方无损兼容向下。

---

## 核心技术与数据结构变更

### 1. 数据模型 (`Sources/PhotoCore/Models.swift`)
- **`BokehShape` 枚举**：`.circular` (现代圆形)、`.polygonal` (多边形机械光圈)、`.swirly` (复古旋焦)、`.creamy` (柔美奶油 STF)。
- **`BokehBlurSettings` 结构体**：
  - `enabled: Bool`：主开关；
  - `apertureFocalSize: Double` (0...100，默认 0.0)：等效光圈弥散圆尺寸 (CoC)；
  - `bokehShape: BokehShape`：光圈光斑形态；
  - `focalPlaneOffset: Double` (0...1，默认 0.0)：对焦平面位置偏移；
  - `depthFalloffRate: Double` (0.2...3.0，默认 1.0)：景深虚化随距离衰减速率；
  - `specularHighlightBoost: Double` (0...1，默认 0.35)：点光源光斑高光璀璨度增强；
  - `edgeBleedProtection: Double` (0...1，默认 0.85)：前景人物边缘防溢色与轮廓锁定强度。
- **`BokehBlurReport`**：记录执行状态、光圈尺寸、光斑形态、高光增强比率及提示信息。
- **`AdjustmentSettings` 扩充**：`public var bokehBlur: BokehBlurSettings? = nil`。
- **`ProcessingReport` 扩充**：`public var bokehBlur: BokehBlurReport? = nil`。
- **`Recipe.validateVersion()`**：支持范围升级为 `1...24`，非中性 `bokehBlur` 强制要求版本 24。

### 2. 核心算法引擎 (`Sources/PhotoCore/BokehDepthEngine.swift`)
- **物理景深图生成 (`makeContinuousDepthMap`)**：结合前景人物 Alpha 蒙版与地面透视距离渐变，计算每个像素的标准化离焦距离；
- **点光源高光萃取着色器 (`specularBoostKernel`)**：针对暗部到高光的非线性阈值提取，在虚化前注入能量提升弥散圆亮度；
- **光学光斑生成与合成**：结合 `CIBokehBlur`、`CITwirlDistortion` 与自适应变迹参数，输出各形态的真实光学景深弥散图；
- **边缘锁定与合成**：通过保护蒙版将主体锐利像素与景深虚化背景精确层叠，杜绝光斑倒灌。

### 3. 主引擎管线集成 (`Sources/PhotoCore/PhotoEngine.swift`)
- 在主渲染管线中紧随背景增强/置换之后执行 `BokehDepthEngine.apply`；
- 配方版本计算器 `requiredRecipeVersion` 支持版本 24 检测。

### 4. 批量同步与 UI 交互 (`Sources/PhotoCore/AdjustmentSync.swift` & `Sources/PhotoAtelier/`)
- `AdjustmentSyncOptions` 增加 `bokehBlur: Bool = true`；
- `SelectiveSyncSheet.swift` 在「背景与画质调整」增加同步开关；
- `AppModel.swift` 增加景深光斑状态管理与重置方法；
- `PortraitRetouchPanel.swift` 新增「智能景深光斑虚化」独立控制组，提供形态选择器与 5 项精调滑块。

---

## 验证与测试

1. **单元测试 (`Tests/PhotoCoreTests/BokehBlurTests.swift`)**：
   - 默认配置中性检测与无损跳过；
   - 参数边界防护与范围自动收敛；
   - 4 种光学光斑形态渲染与报告记录；
   - 点光源高光萃取与增强验证；
   - 前景边缘锁定与防溢色保护验证；
   - 配方版本 24 门禁控制与未来版本拦截；
   - 选择性同步合并与重置行为验证；
   - 景深图生成一致性与单调性测试。
2. **回归测试**：全量执行 678 项单元测试，全部 0 failure 通过。
3. **应用构建验证**：成功构建 Universal (x86_64 + arm64) macOS 二进制应用包，通过 `verify_app.py` 完整性校验。

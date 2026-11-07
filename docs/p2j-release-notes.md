# PhotoAtelier P2-J 发布说明 (Release Notes)

## 智能天空识别、氛围增强与置换 (Smart Sky Detection, Atmospheric Relighting & Sky Replacement)

**版本**: v1.19.0 (Recipe Version 19)  
**基线分支**: `feat/p1c-culling-makeup-perf` (`9d2b528`)  
**特性分支**: `feat/p2j-sky-enhancement-relighting`  
**核心定位**: 对齐商业软件（PixelCake）商业外景与婚纱人像天空增强与置换能力，提供 100% 离线、零外部大模型依赖、Core Image GPU 极速渲染的智能天空识别、氛围渲染与环境光照匹配。

---

### 一、核心功能特性

1. **智能天空区域识别与多级羽化 (`detectHorizonHeight` & `makeSkyMask`)**:
   - 基于系统级 `VNDetectHorizonRequest` 地平线检测结合人物遮罩反转（`PersonMatte.mask`），精确切分天际线与前景。
   - 连续自适应边缘羽化（`edgeFeather: 0.0...1.0`），消除地平线山峦、树梢及人物发丝边界的生硬边缘与边缘光晕（Halo）。
   - 空天空区域优雅跳过：检测到全黑或无天空遮罩时自动 0 耗时跳过，不篡改原图。

2. **湛蓝天色还原 (`skyVibrance`)**:
   - 针对高光过曝、泛白（$L > 0.40$）的死白天空区域，基于天顶物理渐变模型，注入自然的天空青/蓝色阶，找回通透碧蓝质感。
   - 中性控制：为 0 时不改变色阶。

3. **积云立体反差 (`cloudContrast`)**:
   - 采用带通高/中频对比度提取算法，强化云层受光面与阴影面的立体明暗差，唤醒云朵层次与体积感，避免全帧对比度拉伸破坏整图通透感。

4. **晚霞地平线氛围 (`sunsetWarmth`)**:
   - 沿地平线高度向天顶衰减注入落日金橙与暮色微紫渐变色，模拟黄金时段（Golden Hour）日落暖阳氛围。

5. **5 种程序化天空置换预设 (`skyPreset` & `replacementOpacity`)**:
   - **湛蓝晴空 (`azureClear`)**: 晴空万里，自下而上青蓝渐变。
   - **晚霞流金 (`sunsetGlow`)**: 暮色金橙与落日紫霞交织。
   - **暮光紫丁香 (`twilightLilac`)**: 唯美淡紫与冷青暮光。
   - **戏剧性云层 (`dramaticClouds`)**: 厚重积雨云层次与层次感光影。
   - **晨曦破晓 (`morningDawn`)**: 柔和朝霞暖杏色与晨曦微蓝。
   - 支持 `replacementOpacity`（0.0 ~ 1.0）连续混合，保留真实云彩细节。

6. **前景环境光照匹配 (`foregroundRelight`)**:
   - 解决商业天空置换中最严重的“贴纸感”痛点：智能提取当前天空/预设的环境主光色相（Ambient Light Tint），自适应温和映射到地面、前景植被与主体人像，使天地色调完美融为一体。

---

### 二、配方版本与架构兼容性

- **Recipe Version 19**:
  - `Recipe.validateVersion()` 支持范围扩充至 `1...19`。
  - 当且仅当 `sky` 处于非中性状态（开启且任意天空增强/置换参数非零）时，配方版本自动升级至 19。
  - 完全向后兼容：v1 ~ v18 的旧配方均可无缝加载与渲染，中性参数保持旧版配方版本不变。
  - 拒绝未来未支持的版本（20 及以上）。

---

### 三、UI 交互设计

- **右侧修图面板 (`PortraitRetouchPanel.swift`)**:
  - 新增「天空氛围与置换」模块（`cloud.sun.fill` 图标），支持一键总开关、预设选择器 Picker、6 组微调滑块与恢复默认按钮。
  - 结构化分组：
    - **预设与混合**: 预设方案、置换不透明度；
    - **色阶与云彩**: 湛蓝天色、积云反差、晚霞暖调；
    - **边缘与光照**: 边缘羽化、前景环境光匹配。
- **撤销与重做**:
  - 接入 `AppModel`，支持快捷键撤销/重做与中性无损重置。

---

### 四、验证结果

- **单元测试**: `SkyEnhancementTests` 11 项用例 100% 通过（涵盖默认值与参数校验、v19 配方门禁、旧版本往返、中性无损 no-op、无天空跳过、湛蓝天色、积云反差、晚霞氛围、程序化置换、前景光照匹配、PhotoEngine 管道集成）。
- **兼容性测试**: `ColorCompatibilityTests`, `LocalMaskTests`, `SceneAdaptiveTests` 73 项用例 100% 通过。
- **全量测试套件**: 613 项测试用例全部通过（0 失败）。

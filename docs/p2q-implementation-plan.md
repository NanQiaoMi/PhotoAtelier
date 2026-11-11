# P2-Q 实施计划：智能全景背景光斑虚化与景深重构 (Smart Bokeh & Depth-of-Field Synthesis)

## 1. 目标与范围

在人像摄影与婚纱写真中，大光圈虚化（Shallow Depth of Field）与散焦光斑（Optical Bokeh）是凸显主体、净化杂乱背景的核心武器。然而，拍摄现场受限于镜头最大光圈、焦距、安全快门或多人合影对焦景深需求，往往拍摄出深景深、全图清晰的照片。商业修图工具（如 PixelCake 镜头与背景虚化、Lightroom 镜头模糊 Lens Blur）均提供了高品质的景深合成能力。

本里程碑交付 **P2-Q 智能全景背景光斑虚化与景深重构系统 (Smart Bokeh & Depth-of-Field Synthesis)**：
1. **连续景深图估算 (Continuous Depth Map Synthesis)**：
   - 基于原生 Vision 人像高精度分割蒙版（`VNGeneratePersonSegmentationRequest`）；
   - 结合垂直透视地面投影梯度与主体空间距离变换，自适应生成平滑物理景深场（包含近景前景、焦平面主体、中景过渡、远景极限散焦层）；
2. **4 大经典光学光圈散焦光斑模拟 (Optical Diaphragm Bokeh Shapes)**：
   - `.circular`：圆形现代大光圈镜头（如 85mm f/1.2 / 50mm f/1.2，柔润饱满）；
   - `.polygonal`：9 叶片多边形机械光圈（经典德味镜头，立体棱角光斑）；
   - `.swirly`：旋焦光斑（Petzval / 俄罗斯八羽怪 Helios 经典螺旋漩涡焦外）；
   - `.creamy`：柔焦奶化散焦（STF 变迹滤镜，超平滑极润边缘）；
3. **背景点光源高光爆发 (Specular Highlight Bokeh Boost)**：
   - 检测背景高亮小光源、树隙逆光、夜景霓虹与影棚小灯；
   - 在 GPU 着色器中将其扩展为具有球差边缘环提亮（Spherical Aberration Edge Ring）的光学光斑盘；
4. **前景主体边缘精准锁定与防溢色保护 (Edge Bleed & Fringe Protection)**：
   - 彻底解决传统高斯模糊导致的「人物边缘泛白、主体向背景溢色、背景虚化渗入人物发丝」的硬伤；
   - 采用双边保边滤波与引导羽化蒙版，将主体发丝与衣物轮廓牢牢锁定在焦平面；
5. **参数模型与配方升级至 Version 24**：
   - 接入 Recipe Version 24 严格门禁；
   - 全量支持选择性参数复制与批量同步（`AdjustmentSyncEngine`）；
   - 100% 离线，零外部模型权重，GPU Core Image 着色器加速。

---

## 2. 验收标准

- [ ] **中性保护**：`enabled = false` 或 `apertureFocalSize == 0` 时，100% 保持原图无损，不消耗 GPU 处理，报告 `applied: false`；
- [ ] **参数边界校验**：
  - `apertureFocalSize`: 0...1（对应 0~50px 散焦半径）；
  - `focalPlaneOffset`: -0.5...0.5（默认 0.0 锁定主体）；
  - `depthFalloffRate`: 0.2...2.0（默认 1.0）；
  - `specularHighlightBoost`: 0...1（默认 0.5）；
  - `edgeBleedProtection`: 0...1（默认 0.85）；
- [ ] **4 款光斑形状测试**：`.circular`、`.polygonal`、`.swirly`、`.creamy` 均能正确渲染且生成有效输出；
- [ ] **高光光斑爆发**：开启 `specularHighlightBoost > 0` 时背景点光源形成透亮光斑；
- [ ] **配方版本 24 门禁**：非中性 `bokehBlur` 要求 Recipe Version 24，低版本报错拦截，未来版本 25 拦截；
- [ ] **选择性参数复制**：`AdjustmentSyncOptions.bokehBlur` 支持按需勾选或排除；
- [ ] **测试全覆盖**：新增专项测试全部通过，全量 670+ 测试 0 failure 回归；
- [ ] **全双架构应用包**：Universal 二进制成功构建并通过签名和依赖检查。

---

## 3. 实现步骤与执行清单

1. **`Sources/PhotoCore/Models.swift`**：
   - 定义 `BokehShape` 枚举（`.circular`, `.polygonal`, `.swirly`, `.creamy`）；
   - 定义 `BokehBlurSettings` 结构体及验证方法；
   - 定义 `BokehBlurReport` 结构体；
   - `AdjustmentSettings` 增加 `bokehBlur: BokehBlurSettings? = nil`；
   - `ProcessingReport` 增加 `bokehBlur: BokehBlurReport? = nil`；
   - `Recipe.validateVersion()` 升级至支持 `1...24` 并加入 `bokehBlur` 门禁。
2. **`Sources/PhotoCore/BokehDepthEngine.swift`**：
   - 实现物理景深图生成算法（基于人物分割、地面渐变与距离场）；
   - 编写 Core Image Metal / GLSL GPU 散焦与光斑着色器；
   - 实现高光点光源提取与多孔径光斑形态卷积；
   - 实现保边融合与防溢色抑制。
3. **`Sources/PhotoCore/PhotoEngine.swift`**：
   - 在主管线背景处理阶段挂载 `BokehDepthEngine.apply`；
   - 更新 `requiredRecipeVersion` 支持版本 24 检测。
4. **`Sources/PhotoCore/AdjustmentSync.swift` & `SelectiveSyncSheet.swift`**：
   - 添加 `bokehBlur: Bool = true` 及对应预设与合并逻辑；
   - 在选择性同步窗口「镜头效果与风格质感」中增加景深光斑虚化复选框。
5. **`Sources/PhotoAtelier/AppModel.swift` & `PortraitRetouchPanel.swift`**：
   - 增加 `bokehBlurSettings`、`updateBokehBlur`、`setBokehBlurEnabled`、`resetBokehBlur`；
   - 在面板中提供大光圈景深虚化与光斑雕刻控制组。
6. **测试与验证**：
   - 顺延既有测试的未来版本测试由 24 至 25；
   - 编写 `Tests/PhotoCoreTests/BokehBlurTests.swift`；
   - 运行并全绿通过，执行 Universal 构建。

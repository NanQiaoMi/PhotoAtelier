# P2-Y: 智能眉形微雕、根根分明野生眉毛流感与双眉对称性矫正实现计划

## 1. 目标与商业级功能范围

在商业人像摄影、婚纱写真与大片精修中，眉毛被称为“五官之首”，直接决定了面部的精气神、情绪表达与骨相深邃度。客户常见的眉形痛点包括：
- 眉毛稀疏变浅、断眉缺角、缺乏质感；
- 眉尾下垂（八字眉/苦相眉/缺乏活力）；
- 眉形过粗生硬或过细寡淡；
- 眉毛过短局促或过长下耷；
- 双侧眉毛高低不一（高低眉、大小眉不对称）；
- 眉骨扁平、缺乏欧式/立体骨相的纵深高光与深邃微阴影。

**P2-Y** 引入业界顶尖的**智能眉形微雕、根根分明野生眉毛流感与双眉对称性矫正系统**：

1. **眉尾高度与走势提拉 (`browTailLift: Double`, -0.5...0.5)**：
   - 负值舒缓过于上挑的凌厉眉形，正值提拉下垂眉尾，改善八字眉与疲惫感，提振整个人物的眼神与气场。
2. **眉毛粗细饱满度微调 (`browThickness: Double`, -0.5...0.5)**：
   - 负值横向微收过粗生硬浓眉，正值上下饱满扩增细弱稀疏眉毛，打造柔和饱满的骨相眉形。
3. **眉身长度与眉梢延展 (`browLength: Double`, -0.5...0.5)**：
   - 负值微收过长发散的眉梢，正值沿眉峰弧度向外延伸短眉，协调三庭五眼外侧横向比例。
4. **双眉对称性智能校准 (`browSymmetry: Double`, 0...1.0)**：
   - 自动检测左右眉毛的高度差（高低眉）、倾斜角度差与曲率差异，智能将双眉向平衡中轴对称态平滑插值微调。
5. **根根分明野生眉毛流感与密度充盈 (`wildBrowTexture: Double`, 0...1.0)**：
   - 基于 GPU 高频微观纹理着色器与形态学各向异性滤波，智能填补断眉与稀疏斑驳缺口，强化根根分明的自然野生眉毛流感与毛发立体质感。
6. **眉骨 3D 立体高光与眉下阴影 (`brow3DContour: Double`, 0...1.0)**：
   - 眉弓骨（Brow Ridge / Superciliary Arch）外侧迎光面渲染珍珠柔光立体高光（Red通道 +15%），并在眉骨下方眼窝凹陷处渲染极其细腻的微修容阴影（Green通道 -12%），增强眉眼深邃混血立体骨相。
7. **100% 离线与硬件加速**：
   - 基于 Apple Vision 原生关键点与 Core Image GPU `WarpField` 及 `CIColorKernel`，零外部模型权重依赖。
8. **多人肖像分人独立覆盖**：
   - 支持 `PersonPortraitProfile.eyebrowReshapeOverride` 与 `EyebrowReshapeEngine.applyPerPerson`。
9. **配方版本门禁升级**：
   - 配方版本升级至 32（Recipe v32），旧版本严格守卫。
10. **选择性参数同步**：
    - `AdjustmentSyncOptions.eyebrowReshape: Bool = true` 及 `SelectiveSyncSheet.swift`。
11. **UI 面板集成**：
    - `AppModel.swift` 状态流与 `PortraitRetouchPanel.swift` 智能眉形微雕面板。

---

## 2. 架构设计与模块组织

```
PhotoCore/
├── EyebrowReshapeEngine.swift     # 核心计算：双眉几何提取、连续形变场、野生眉毛流Shader与眉骨3D光影Kernel
├── Models.swift                  # EyebrowReshapeSettings、EyebrowReshapeReport、Recipe v32
├── PhotoEngine.swift             # 管线步骤 3j 串接、版本需求推导
├── AdjustmentSync.swift          # 选择性同步合并与预设更新
PhotoAtelier/
├── SelectiveSyncSheet.swift      # 同步弹窗勾选项
├── AppModel.swift                # 状态绑定、撤销重做支持
└── PortraitRetouchPanel.swift    # 智能眉形微雕 UI 滑杆面板
Tests/PhotoCoreTests/
└── EyebrowReshapeTests.swift     # 13+ 单元与集成测试
```

---

## 3. 验收标准与测试矩阵

- [ ] `EyebrowReshapeSettings` 包含全部 6 项参数，默认中性且范围校验严格；
- [ ] 中性设置或无人脸时完全零开销跳过；
- [ ] 眉尾提拉、粗细、长度、双眉对称性、野生眉毛流感与 3D 眉骨光影协同运作无撕裂与伪影；
- [ ] 多人肖像支持单人独立参数覆盖与单人分人处理；
- [ ] 配方版本 32 门禁守卫完备，低版本遇到非中性设置报错；
- [ ] 选择性同步勾选时正确同步，未勾选时保留目标；
- [ ] 所有单元测试与全量回归 100% 通过（776+ 测试）；
- [ ] 生产 App 构建与代码签名完整性校验通过。

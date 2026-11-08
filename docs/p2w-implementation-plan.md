# P2-W: 智能下颌角/下巴微雕与面部下庭轮廓重塑实现计划

## 1. 目标与商业级功能范围

在商业人像与婚纱客照精修中，下庭轮廓（下颌角宽度、下颌线清晰度、下巴长短翘度与形态）是塑造脸型（小V脸、鹅蛋脸、幼态圆脸）、提升精修质感的核心关键。客户常见痛点包括：下颌角宽大骨实质感厚重（方脸/国字脸）、短下巴下巴后缩显钝、长下巴显老显凶、下巴平钝缺乏灵动形态、下颌缘松弛与双下巴模糊等。

**P2-W** 引入业界顶尖的**智能下颌角/下巴微雕与面部下庭轮廓重塑系统**：

1. **下颌角收窄与折角微雕 (`jawWidth: Double`, -0.5...0.5)**：
   - 负值横向向内收拢双侧下颌角（Gonial angle），柔化方脸与国字脸骨感折角，打造流畅鹅蛋脸；正值微拓宽下颌角增加骨相力量感。
2. **下巴长度调节与下庭平衡 (`chinLength: Double`, -0.5...0.5)**：
   - 纵向微调颏下点（Mentum/Gnathion）位置；负值向上收短过长下巴优化成熟脸下庭比例，正值向下延伸拉长短下巴。
3. **下巴翘度微调（解决下巴后缩） (`chinProjection: Double`, -0.5...0.5)**：
   - 正值向前上方微提拉颏唇沟下方凸起，模拟骨相微翘立体感，有效改善侧颜下巴后缩；负值柔化过于前突的下巴。
4. **下巴形态微雕（圆幼下巴 vs 精致V脸） (`chinShape: Double`, -0.5...0.5)**：
   - 负值收紧下巴两侧弧度雕琢精致V脸与瓜子下巴；正值圆润饱满化下巴边缘打造减龄幼态圆下巴。
5. **下颌缘紧致与线条清晰度 (`jawlineTighten: Double`, 0...1.0)**：
   - 沿双侧下颌缘布置向心紧致形变点，模拟吸脂紧肤提拉，收敛双下巴虚影与松弛组织，凸显清晰紧致的下颌骨边缘轮廓。
6. **下巴立体高光与微修容 (`chinContour: Double`, 0...1.0)**：
   - 智能生成颏部中心珍珠质感高光（Red通道 +15%）与颏下缘/颌下三角柔和阴影（Green通道 -12%），增强下庭立体纵深。
7. **100% 离线与硬件加速**：
   - 基于 Apple Vision `FaceLandmarkSet.faceContour` 原生关键点与 Core Image GPU `WarpField` 及 `CIColorKernel`，零外部模型权重依赖。
8. **多人肖像分人独立覆盖**：
   - 支持 `PersonPortraitProfile.jawChinReshapeOverride` 与 `JawChinReshapeEngine.applyPerPerson`。
9. **配方版本门禁升级**：
   - 配方版本升级至 30（Recipe v30），旧版本严格守卫。
10. **选择性参数同步**：
    - `AdjustmentSyncOptions.jawChinReshape: Bool = true` 及 `SelectiveSyncSheet.swift`。
11. **UI 面板集成**：
    - `AppModel.swift` 状态流与 `PortraitRetouchPanel.swift` 下颌下巴微雕面板。

---

## 2. 架构设计与模块组织

```
PhotoCore/
├── JawChinReshapeEngine.swift     # 核心计算：下庭几何提取、WarpField连续位移场、3D光影Kernel
├── Models.swift                  # JawChinReshapeSettings、JawChinReshapeReport、Recipe v30
├── PhotoEngine.swift             # 管线步骤 3h 串接、版本要求计算
├── AdjustmentSync.swift          # 选择性同步合并与预设更新
PhotoAtelier/
├── SelectiveSyncSheet.swift      # 同步弹窗勾选项
├── AppModel.swift                # 状态绑定、撤销重做支持
└── PortraitRetouchPanel.swift    # 下庭微雕 UI 滑杆面板
Tests/PhotoCoreTests/
└── JawChinReshapeTests.swift     # 14+ 单元与集成测试
```

---

## 3. 验收标准与测试矩阵

- [ ] `JawChinReshapeSettings` 包含全部 6 项参数，默认中性且范围校验严格；
- [ ] 中性设置或无人脸时完全零开销跳过；
- [ ] 鼻嘴三角与面部上半部分受到平滑保护衰减，无撕裂与形变伪影；
- [ ] 3D 颏部高光与颌下微阴影 Shader 准确叠加；
- [ ] 多人肖像支持单人独立参数覆盖与单人分人处理；
- [ ] 配方版本 30 门禁守卫完备，低版本遇到非中性设置报错；
- [ ] 选择性同步勾选时正确同步，未勾选时保留目标；
- [ ] 所有单元测试与全量回归 100% 通过（751+ 测试）；
- [ ] 生产 App 构建与代码签名完整性校验通过。

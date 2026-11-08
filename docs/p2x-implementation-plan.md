# P2-X: 智能太阳穴/颧骨与面部外轮廓流畅度微雕实现计划

## 1. 目标与商业级功能范围

在高端商业人像摄影、婚纱写真与大片精修中，面部外轮廓的流畅度（Facial Contour Smoothness）直接决定了面部的视觉年龄、骨相立体度与脸型高级感。客户常见的骨相痛点包括：
- 太阳穴凹陷（菱形脸/凸显颧骨宽大、面部呈波浪状）；
- 颧骨突出与弓部外扩（线条生硬、缺乏柔和感）；
- 面颊凹陷干瘪（吸腮感、显疲态与衰老骷髅感）；
- 整体面部外轮廓凹凸波折（折角突兀、缺乏平滑鹅蛋脸流畅度）；
- 苹果肌下垂或扁平缺乏幼态饱满感。

**P2-X** 引入业界顶尖的**智能太阳穴/颧骨与面部外轮廓流畅度微雕系统**：

1. **太阳穴凹陷饱满化充盈 (`templePlump: Double`, 0...1.0)**：
   - 横向向外微推双侧颞部（Temporal Fossa）凹陷处，平整发际线与颧弓之间的衔接，打造充盈饱满的上庭外轮廓。
2. **颧骨突出与外扩内推平滑 (`cheekboneNarrow: Double`, 0...1.0)**：
   - 横向向内微收双侧颧骨与颧弓最宽处，柔化生硬棱角，弱化菱形脸特征，不失骨相天然立体结构。
3. **面颊凹陷丰盈与胶原蛋白感 (`cheekPlump: Double`, 0...1.0)**：
   - 向外丰盈颧下与下颌角之间的面颊凹陷软组织，消除干瘪吸腮感，恢复面颊胶原蛋白充盈的年轻态。
4. **面部外轮廓波折平滑度调和 (`contourSmoothness: Double`, 0...1.0)**：
   - 沿太阳穴-颧弓-面颊-下颌角完整外轮廓进行曲率平滑调和，智能消除凹凸阶梯波折，一键重塑流畅鹅蛋脸轮廓。
5. **苹果肌立体微雕与提拉 (`appleCheekLift: Double`, -0.5...0.5)**：
   - 正值向内上方提拉饱满双侧苹果肌（Malar fat pad），展现减龄幼态笑肌高光点；负值舒缓过于隆起的苹果肌。
6. **面部外轮廓柔光立体光影 (`contour3DShading: Double`, 0...1.0)**：
   - 智能生成双侧苹果肌柔光高光（Red通道 +14%）与颧弓外侧/颞部边缘柔和修容阴影（Green通道 -12%），增强面部中段骨相立体纵深。
7. **100% 离线与硬件加速**：
   - 基于 Apple Vision 原生关键点与 Core Image GPU `WarpField` 及 `CIColorKernel`，零外部模型权重依赖。
8. **多人肖像分人独立覆盖**：
   - 支持 `PersonPortraitProfile.facialContourOverride` 与 `FacialContourEngine.applyPerPerson`。
9. **配方版本门禁升级**：
   - 配方版本升级至 31（Recipe v31），旧版本严格守卫。
10. **选择性参数同步**：
    - `AdjustmentSyncOptions.facialContour: Bool = true` 及 `SelectiveSyncSheet.swift`。
11. **UI 面板集成**：
    - `AppModel.swift` 状态流与 `PortraitRetouchPanel.swift` 面部外轮廓微雕面板。

---

## 2. 架构设计与模块组织

```
PhotoCore/
├── FacialContourEngine.swift      # 核心计算：外轮廓几何提取、WarpField连续位移场、3D光影Kernel
├── Models.swift                  # FacialContourSettings、FacialContourReport、Recipe v31
├── PhotoEngine.swift             # 管线步骤 3i 串接、版本要求计算
├── AdjustmentSync.swift          # 选择性同步合并与预设更新
PhotoAtelier/
├── SelectiveSyncSheet.swift      # 同步弹窗勾选项
├── AppModel.swift                # 状态绑定、撤销重做支持
└── PortraitRetouchPanel.swift    # 外轮廓微雕 UI 滑杆面板
Tests/PhotoCoreTests/
└── FacialContourTests.swift      # 13+ 单元与集成测试
```

---

## 3. 验收标准与测试矩阵

- [ ] `FacialContourSettings` 包含全部 6 项参数，默认中性且范围校验严格；
- [ ] 中性设置或无人脸时完全零开销跳过；
- [ ] 太阳穴丰盈、颧骨内推、面颊饱满、外轮廓平滑、苹果肌提拉与 3D 光影协同运作无撕裂与伪影；
- [ ] 多人肖像支持单人独立参数覆盖与单人分人处理；
- [ ] 配方版本 31 门禁守卫完备，低版本遇到非中性设置报错；
- [ ] 选择性同步勾选时正确同步，未勾选时保留目标；
- [ ] 所有单元测试与全量回归 100% 通过（763+ 测试）；
- [ ] 生产 App 构建与代码签名完整性校验通过。

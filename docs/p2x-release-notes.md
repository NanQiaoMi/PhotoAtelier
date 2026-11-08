# P2-X: 智能太阳穴/颧骨与面部外轮廓流畅度微雕 (Release Notes)

## 1. 概述与交付物

在高端商业人像摄影、婚纱写真与大片精修中，面部外轮廓的流畅度（Facial Contour Smoothness）直接决定了面部的视觉年龄、骨相立体度与脸型高级感。客户常见的骨相痛点包括：
- 太阳穴凹陷（菱形脸/凸显颧骨宽大、面部呈波浪状）；
- 颧骨突出与弓部外扩（线条生硬、缺乏柔和感）；
- 面颊凹陷干瘪（吸腮感、显疲态与衰老骷髅感）；
- 整体面部外轮廓凹凸波折（折角突兀、缺乏平滑鹅蛋脸流畅度）；
- 苹果肌下垂或扁平缺乏幼态饱满感。

**P2-X** 里程碑正式落地了媲美像素蛋糕（PixelCake）、醒图与美图云修的**智能太阳穴/颧骨与面部外轮廓流畅度微雕系统**：

- **太阳穴凹陷饱满化充盈 (`templePlump`, 0...1.0)**：横向向外充盈双侧颞部（Temporal Fossa）凹陷处，平整发际线与颧弓之间的衔接，打造充盈饱满的上庭外轮廓；
- **颧骨突出与外扩内推平滑 (`cheekboneNarrow`, 0...1.0)**：横向向内微收双侧颧骨与颧弓最宽处，柔化生硬棱角，弱化菱形脸特征，不失骨相天然立体结构；
- **面颊凹陷丰盈与胶原蛋白感 (`cheekPlump`, 0...1.0)**：向外丰盈颧下与下颌角之间的面颊凹陷软组织，消除干瘪吸腮感，恢复面颊胶原蛋白充盈的年轻态；
- **面部外轮廓波折平滑度调和 (`contourSmoothness`, 0...1.0)**：沿太阳穴-颧弓-面颊-下颌角完整外轮廓进行曲率平滑调和，智能消除凹凸阶梯波折，一键重塑流畅鹅蛋脸轮廓；
- **苹果肌立体微雕与提拉 (`appleCheekLift`, -0.5...0.5)**：正值向内上方提拉饱满双侧苹果肌（Malar fat pad），展现减龄幼态笑肌高光点；负值舒缓过于隆起的苹果肌；
- **面部外轮廓柔光立体光影 (`contour3DShading`, 0...1.0)**：智能生成双侧苹果肌柔光高光（Red通道 +14%）与颧弓外侧/颞部边缘柔和修容阴影（Green通道 -12%），增强面部中段骨相立体纵深；
- **100% 离线与硬件加速**：完全基于 Apple Vision 原生关键点与 Core Image GPU `WarpField` 变形场及 `CIColorKernel`，零外部模型权重依赖；
- **多人肖像分人独立覆盖**：支持 `PersonPortraitProfile.facialContourOverride` 与 `FacialContourEngine.applyPerPerson`；
- **配方版本门禁升级**：升级至配方版本 31（Recipe v31），旧版本严格守卫。

---

## 2. 变更文件清单

1. `Sources/PhotoCore/FacialContourEngine.swift` (新增) - 外轮廓几何特征提取（temple, zygoma, cheek fossa, apple cheek）、连续形变场计算与 3D 高光阴影 Shader；
2. `Sources/PhotoCore/Models.swift` (修改) - 新增 `FacialContourSettings`、`FacialContourReport`、配方版本 31 守卫与分人覆盖；
3. `Sources/PhotoCore/PhotoEngine.swift` (修改) - 单人/多人管线串接（步骤 3i）、设置校验与版本需求推导（版本 31）；
4. `Sources/PhotoCore/AdjustmentSync.swift` (修改) - 批处理选择性同步支持与预设整合；
5. `Sources/PhotoAtelier/SelectiveSyncSheet.swift` (修改) - 同步面板 UI 勾选项；
6. `Sources/PhotoAtelier/AppModel.swift` (修改) - 状态管理、撤销重做绑定与面部外轮廓面板交互；
7. `Sources/PhotoAtelier/PortraitRetouchPanel.swift` (修改) - 太阳穴/颧骨与外轮廓微雕面板 UI 滑杆组件；
8. `Tests/PhotoCoreTests/FacialContourTests.swift` (新增) - 13 项单元测试与边界用例；
9. 16 处现有测试文件 - 未来配方版本断言从 31 升级至 32；
10. `docs/p2x-implementation-plan.md` (新增) - 方案设计说明文档。

---

## 3. 验证结果

- `swift test --filter FacialContourTests`: **13/13 passed in 2.773s (0 failures)**
- `swift test --filter JawChinReshapeTests`: **13/13 passed in 3.899s (0 failures)**
- 全量测试 `swift test -j 2`: **763/763 passed in 226.915s (0 failures)**
- 生产打包 `bash Scripts/build_app.sh`: **Exit code 0 (533.51s)**
- 静态与签名验证 `python3 Scripts/verify_app.py build/PhotoAtelier.app && codesign --verify --deep --strict build/PhotoAtelier.app`: **4 signed dylibs, exact licenses, zero warnings (Exit code 0)**

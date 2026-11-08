# P2-W: 智能下颌角/下巴微雕与面部下庭轮廓重塑 (Release Notes)

## 1. 概述与交付物

在商业人像摄影、高端写真与客照精修中，下庭轮廓与下巴骨相美学直接决定整张面庞的脸型（小V脸、鹅蛋脸、幼态圆脸）、立体感与精致度。客户常见痛点包括：下颌角宽大骨感沉重（方脸/国字脸）、短下巴下巴后缩显钝不协调、长下巴显成熟显老、下巴形态平钝不灵动、双下巴与下颌缘边缘模糊松弛等。

**P2-W** 里程碑正式落地了媲美像素蛋糕（PixelCake）、醒图与美图云修的**智能下颌角/下巴微雕与面部下庭轮廓重塑系统**：

- **下颌角收窄与折角微雕 (`jawWidth`, -0.5...0.5)**：负值横向向内收拢双侧下颌角（Gonial angle），柔化方脸与国字脸骨感折角，打造流畅鹅蛋脸；正值微拓宽下颌角增加骨相力量感；
- **下巴长度调节与下庭平衡 (`chinLength`, -0.5...0.5)**：纵向微调颏下点（Mentum/Gnathion）位置；负值向上收短过长下巴优化成熟脸下庭比例，正值向下延伸拉长短下巴；
- **下巴翘度微调（解决下巴后缩） (`chinProjection`, -0.5...0.5)**：正值向前上方微提拉颏唇沟下方凸起，模拟骨相微翘立体感，有效改善侧颜下巴后缩；负值柔化过于前突的下巴；
- **下巴形态微雕（圆幼下巴 vs 精致V脸） (`chinShape`, -0.5...0.5)**：负值收紧下巴两侧弧度雕琢精致V脸与瓜子下巴；正值圆润饱满化下巴边缘打造减龄幼态圆下巴；
- **下颌缘紧致与线条清晰度 (`jawlineTighten`, 0...1.0)**：沿双侧下颌缘布置向心紧致形变点，模拟吸脂紧肤提拉，收敛双下巴虚影与松弛组织，凸显清晰紧致的下颌骨边缘轮廓；
- **下巴微光立体修容 (`chinContour`, 0...1.0)**：智能生成颏部中心珍珠质感高光（Red通道 +15%）与颏下缘/颌下三角柔和阴影（Green通道 -12%），增强下庭立体纵深；
- **100% 离线与硬件加速**：完全基于 Apple Vision 原生关键点与 Core Image GPU `WarpField` 变形场及 `CIColorKernel`，零外部模型权重依赖；
- **多人肖像分人独立覆盖**：支持 `PersonPortraitProfile.jawChinReshapeOverride` 与 `JawChinReshapeEngine.applyPerPerson`。

---

## 2. 变更文件清单

1. `Sources/PhotoCore/JawChinReshapeEngine.swift` (新增) - 下庭几何特征提取（chinTip, leftJawAngle, rightJawAngle, mandibleMid, submental）、多维度连续变形场计算与 3D 高光阴影 Shader；
2. `Sources/PhotoCore/Models.swift` (修改) - 新增 `JawChinReshapeSettings`、`JawChinReshapeReport`、配方版本 30 守卫与分人覆盖；
3. `Sources/PhotoCore/PhotoEngine.swift` (修改) - 单人/多人管线串接、设置校验与版本需求推导（版本 30）；
4. `Sources/PhotoCore/AdjustmentSync.swift` (修改) - 批处理选择性同步支持与预设整合；
5. `Sources/PhotoAtelier/SelectiveSyncSheet.swift` (修改) - 同步面板 UI 勾选项；
6. `Sources/PhotoAtelier/AppModel.swift` (修改) - 状态管理、撤销重做绑定与下颌下巴面板交互；
7. `Sources/PhotoAtelier/PortraitRetouchPanel.swift` (修改) - 下颌角与下巴微雕面板 UI 滑杆组件；
8. `Tests/PhotoCoreTests/JawChinReshapeTests.swift` (新增) - 13 项单元测试与边界用例；
9. 15 处现有测试文件 - 未来配方版本断言从 30 升级至 31；
10. `docs/p2w-implementation-plan.md` (新增) - 方案设计说明文档。

---

## 3. 验证结果

- `swift test --filter JawChinReshapeTests`: **13/13 passed in 6.164s (0 failures)**
- `swift test --filter NoseReshapeTests`: **14/14 passed in 6.083s (0 failures)**
- 全量测试 `swift test -j 2`: **750/750 passed in 216.881s (0 failures)**
- 生产打包 `bash Scripts/build_app.sh`: **Exit code 0**
- 静态与签名验证 `python3 Scripts/verify_app.py && codesign --verify --deep --strict`: **4 signed dylibs, exact licenses, zero warnings (Exit code 0)**

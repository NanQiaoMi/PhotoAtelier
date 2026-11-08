# P2-Y: 智能眉形微雕、根根分明野生眉毛流感与双眉对称性矫正 (Release Notes)

## 1. 概述与交付物

在高端商业人像摄影、婚纱写真与大片精修中，眉毛（Eyebrows）被称为“面部五官之骨架与情绪之窗”。眉形的高度、走势、粗细、毛流感与左右对称性直接决定了面部的神采、气质与视觉年龄。客户常见的眉形痛点包括：
- 眉尾下垂（八字眉、显愁苦、丧气与衰老疲惫感）；
- 眉毛稀疏变淡或局部断眉（缺乏毛流感与原生蓬松度）；
- 眉形过于粗笨或过于纤细（与脸型比例失调）；
- 眉身过短或过长（导致五官比例分散或拥挤）；
- 高低眉、挑眉或左右眉弓走势不对称（拍照时神态不协调）；
- 眉骨扁平缺乏立体感（眼眶与眼窝缺乏深邃纵深）。

**P2-Y** 里程碑正式落地了媲美像素蛋糕（PixelCake）、醒图与美图云修的**智能眉形微雕、根根分明野生眉毛流感与双眉对称性矫正系统**：

- **眉尾高度与走势提拉 (`browTailLift`, -0.5...0.5)**：正值垂直提拉双侧外眉尾（Lateral Brow Tails），快速消除下垂八字眉与眼部下垂丧气感，展现干练神采；负值平缓下压过挑眉峰；
- **眉毛粗细与饱满度微调 (`browThickness`, -0.5...0.5)**：垂直向外扩展增加眉毛宽度与饱满度，或向内收细打造纤细精致柳叶眉，自适应不同妆容与脸型需求；
- **眉身长度与眉梢延展 (`browLength`, -0.5...0.5)**：沿眉弓走势横向延展或收缩眉身与眉梢长度，协调太阳穴与眼裂比例；
- **双眉对称性智能校准 (`browSymmetry`, 0...1.0)**：自动检测左右眉毛在眉峰高度、眉尾高低与整体倾角的差异，自适应平衡并对齐双眉走势，消除拍照时的挑眉或高低眉瑕疵；
- **根根分明野生眉毛流感与密度充盈 (`wildBrowTexture`, 0...1.0)**：基于 GPU 微对比度高频毛流提取 Shader（`wildBrowTextureKernel`），定向增强眉部细微毛流纤维结构，并自然充盈稀疏间隙，重塑自然立体的呼吸感羽毛野生眉；
- **眉骨 3D 立体高光与眉下阴影 (`brow3DContour`, 0...1.0)**：智能在眉弓骨峰生成柔光高光（Red通道 +15%）并在眉下眼窝微陷处生成柔和修容阴影（Green通道 -12%），打造深邃混血眼窝与高挺立体眉骨；
- **100% 离线与硬件加速**：完全基于 Apple Vision 原生关键点（`FaceLandmarkSet.leftEyebrow`, `rightEyebrow`, `leftEye`, `rightEye`）与 Core Image GPU `WarpField` 变形场及 `CIColorKernel`，零外部模型权重依赖；
- **多人肖像分人独立覆盖**：支持 `PersonPortraitProfile.eyebrowReshapeOverride` 与 `EyebrowReshapeEngine.applyPerPerson`；
- **配方版本门禁升级**：升级至配方版本 32（Recipe v32），旧版本严格守卫。

---

## 2. 变更文件清单

1. `Sources/PhotoCore/EyebrowReshapeEngine.swift` (新增) - 眉部几何特征提取（眉头、眉峰、眉尾、高低差）、连续形变场计算、野生眉毛流 Shader 与 3D 眉骨修容 Shader；
2. `Sources/PhotoCore/Models.swift` (修改) - 新增 `EyebrowReshapeSettings`、`EyebrowReshapeReport`、配方版本 32 守卫与分人覆盖；
3. `Sources/PhotoCore/PhotoEngine.swift` (修改) - 单人/多人管线串接（步骤 3j）、设置校验与版本需求推导（版本 32）；
4. `Sources/PhotoCore/AdjustmentSync.swift` (修改) - 批处理选择性同步支持与预设整合；
5. `Sources/PhotoAtelier/SelectiveSyncSheet.swift` (修改) - 同步面板 UI 勾选项；
6. `Sources/PhotoAtelier/AppModel.swift` (修改) - 状态管理、撤销重做绑定与眉形微雕面板交互；
7. `Sources/PhotoAtelier/PortraitRetouchPanel.swift` (修改) - 眉形微雕面板 UI 滑杆组件；
8. `Tests/PhotoCoreTests/EyebrowReshapeTests.swift` (新增) - 13 项单元测试与边界用例；
9. 17 处现有测试文件 - 未来配方版本断言从 32 升级至 33；
10. `docs/p2y-implementation-plan.md` (新增) - 方案设计说明文档。

---

## 3. 验证结果

- `swift test --filter EyebrowReshapeTests`: **13/13 passed**
- `swift test --filter FacialContourTests`: **13/13 passed**
- 全量测试 `swift test -j 2`: **776/776 passed (0 failures)**
- 生产打包 `bash Scripts/build_app.sh`: **Exit code 0**
- 静态与签名验证 `python3 Scripts/verify_app.py build/PhotoAtelier.app && codesign --verify --deep --strict build/PhotoAtelier.app`: **Exit code 0**

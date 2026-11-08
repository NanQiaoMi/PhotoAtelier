# P2-T: 智能面部微表情、微笑嘴角与唇形立体微雕 (Release Notes)

## 1. 概述与交付物

商业肖像修图与影楼人像后期中，客户常因表情紧绷呈现苦相、嘴角下垂、人中过长显得老气或唇形扁平不对称。
**P2-T** 里程碑正式落地了媲美像素蛋糕（PixelCake）、醒图与美图云修的**智能面部微表情、微笑嘴角与唇形立体微雕系统**：

- **微笑嘴角与嘴角上扬 (`smileDegree`, 0...1)**：模拟解剖学笑肌（Zygomaticus major）牵引动力学，将口角自然向上、向外抬升，改善紧绷苦相，弧度圆润顺滑；
- **微笑宽度与张弛度 (`smileWidth`, -0.5...0.5)**：横向微调嘴角舒展弧度，正值开朗舒展，负值适度收敛；
- **唇角对称性校准 (`lipSymmetry`, 0...1)**：自动检测并抚平左右口角高低倾斜差，校正歪嘴笑与不对称表情；
- **幼态人中缩短 (`philtrumShortening`, 0...1)**：向上适度提拉丘比特弓，缩短视觉人中距离，塑造减龄幼态面容比例；
- **丰唇立体微雕 (`upperLipPlump`, `lowerLipPlump`, -0.5...0.5)**：独立精雕上唇厚度与下唇嘟嘟饱满度；
- **唇峰珠光高光与下唇窝立体微阴影 (`lip3DHighlight`, 0...1)**：在唇珠与下唇饱满突起处叠加微米级柔光珠光高光，并增强下唇窝环境光微阴影，呈现水润立体嘟嘟唇质感；
- **100% 离线与硬件加速**：完全基于 Apple Vision 原生关键点与 Core Image GPU `WarpField` 变形场，零外部模型权重依赖。

---

## 2. 变更文件清单

1. `Sources/PhotoCore/ExpressionEngine.swift` (新增) - 核心微表情变形场生成、几何提取与 3D 光影着色渲染；
2. `Sources/PhotoCore/Models.swift` (修改) - 新增 `ExpressionSettings`、`ExpressionReport`、配方版本 27 守卫与分人覆盖；
3. `Sources/PhotoCore/PhotoEngine.swift` (修改) - 单人/多人管线串接、设置校验与版本需求推导；
4. `Sources/PhotoCore/AdjustmentSync.swift` (修改) - 批处理选择性同步支持与预设整合；
5. `Sources/PhotoAtelier/SelectiveSyncSheet.swift` (修改) - 同步面板 UI 勾选项；
6. `Sources/PhotoAtelier/AppModel.swift` (修改) - 状态管理、撤销重做绑定与微表情面板交互；
7. `Sources/PhotoAtelier/PortraitRetouchPanel.swift` (修改) - 微表情与微笑唇形微雕面板 UI 滑杆组件；
8. `Tests/PhotoCoreTests/ExpressionTests.swift` (新增) - 13 项单元测试与边界用例；
9. 14 处现有测试文件 - 未来配方版本断言从 27 升级至 28；
10. `docs/p2t-implementation-plan.md` (新增) - 方案设计说明文档。

---

## 3. 验证结果

- `swift test --filter ExpressionTests`: **13/13 passed in 0.522s (0 failures)**
- 全量测试 `swift test -j 2`: **710/710 passed in 173.386s (0 failures)**
- 生产打包 `bash Scripts/build_app.sh`: **Exit code 0**
- 静态与签名验证 `python3 Scripts/verify_app.py && codesign --verify --deep --strict`: **4 signed dylibs, exact licenses, zero warnings (Exit code 0)**

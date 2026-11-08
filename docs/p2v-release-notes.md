# P2-V: 智能鼻部精致微雕、立体鼻梁高光与驼峰鼻/朝天鼻矫正 (Release Notes)

## 1. 概述与交付物

鼻部作为面部中庭的视觉核心（面中之王），其挺拔度、鼻翼宽度、鼻头形态与鼻唇角角度决定了肖像的立体感、精致度与中庭长短比例。商业婚纱、写真摄影与客照精修中，常见的痛点包括：鼻翼肉感偏宽、鼻头圆钝肥大、鼻梁低平缺乏骨相立体感、中庭偏长显成熟、轻微朝天漏鼻孔、驼峰鼻背起节或鹰钩鼻下垂等。

**P2-V** 里程碑正式落地了媲美像素蛋糕（PixelCake）、醒图与美图云修的**智能鼻部精致微雕、立体鼻梁高光与驼峰鼻/朝天鼻矫正系统**：

- **鼻翼收窄与精雕 (`narrowNoseWing`, -0.5...0.5)**：正值横向向内收拢两侧鼻翼基底与鼻翼沟，告别肉感鼻翼，收缩鼻翼宽度；负值向外微扩协调过窄鼻翼；
- **鼻头立体微缩与塑形 (`noseTipSize`, -0.5...0.5)**：负值径向向心微缩鼻尖软骨圆润区域，收小圆钝蒜头鼻，雕琢水滴形精致鼻尖；正值微增饱满度；
- **鼻梁挺拔度与骨骼收窄 (`noseBridgeWidth`, -0.5...0.5)**：负值向中轴向内收紧鼻根（Radix）至鼻背骨性结构宽度，增强鼻梁挺拔修长感；正值微拓宽鼻梁；
- **鼻唇角/鼻尖仰俯角调节（朝天鼻/鹰钩鼻矫正） (`nosePitchAngle`, -0.5...0.5)**：负值轻微上旋鼻小柱与鼻尖矫正下垂鹰钩鼻；正值纵向延展下压鼻尖改善短鼻漏鼻孔（朝天鼻纠正）；
- **驼峰鼻背平缓抚平 (`humpSmoothing`, 0...1.0)**：准确定位鼻背中上 1/3 骨软骨交界隆起区域，横向微压缩抚平骨性凸起，呈现平整流畅的天然直鼻侧颜；
- **鼻长调节与中庭平衡 (`noseLength`, -0.5...0.5)**：纵向调节鼻下点与鼻尖纵向跨度，负值缩短鼻长优化幼态短中庭比例，正值拉长调节短脸比例；
- **鼻梁立体高光与双侧修容阴影 (`nose3DContour`, 0...1.0)**：智能渲染鼻梁中轴与鼻尖珍珠质感立体高光（Red通道 +18% 亮度），结合鼻侧壁与鼻小柱下三角柔和修容阴影（Green通道 -15% 影调），实现天然骨相光影修容；
- **100% 离线与硬件加速**：完全基于 Apple Vision 原生关键点与 Core Image GPU `WarpField` 变形场及 `CIColorKernel`，零外部模型权重依赖；
- **多人肖像分人独立覆盖**：支持 `PersonPortraitProfile.noseReshapeOverride` 与 `NoseReshapeEngine.applyPerPerson`。

---

## 2. 变更文件清单

1. `Sources/PhotoCore/NoseReshapeEngine.swift` (新增) - 核心鼻部几何特征提取（radix, subnasale, alarBases, tip, midBridge）、多维度连续变形场计算与 3D 高光阴影 Shader；
2. `Sources/PhotoCore/Models.swift` (修改) - 新增 `NoseReshapeSettings`、`NoseReshapeReport`、配方版本 29 守卫与分人覆盖；
3. `Sources/PhotoCore/PhotoEngine.swift` (修改) - 单人/多人管线串接、设置校验与版本需求推导（版本 29）；
4. `Sources/PhotoCore/AdjustmentSync.swift` (修改) - 批处理选择性同步支持与预设整合；
5. `Sources/PhotoAtelier/SelectiveSyncSheet.swift` (修改) - 同步面板 UI 勾选项；
6. `Sources/PhotoAtelier/AppModel.swift` (修改) - 状态管理、撤销重做绑定与鼻部面板交互；
7. `Sources/PhotoAtelier/PortraitRetouchPanel.swift` (修改) - 鼻部精致微雕与立体塑形面板 UI 滑杆组件；
8. `Tests/PhotoCoreTests/NoseReshapeTests.swift` (新增) - 14 项单元测试与边界用例；
9. 14 处现有测试文件 - 未来配方版本断言从 29 升级至 30；
10. `docs/p2v-implementation-plan.md` (新增) - 方案设计说明文档。

---

## 3. 验证结果

- `swift test --filter NoseReshapeTests`: **14/14 passed in 6.473s (0 failures)**
- `swift test --filter EyeShapeTests`: **13/13 passed in 4.878s (0 failures)**
- `swift test --filter ColorCompatibilityTests`: **39/39 passed in 15.564s (0 failures)**
- 全量测试 `swift test -j 2`: **737/737 passed in 208.570s (0 failures)**
- 生产打包 `bash Scripts/build_app.sh`: **Exit code 0**
- 静态与签名验证 `python3 Scripts/verify_app.py && codesign --verify --deep --strict`: **4 signed dylibs, exact licenses, zero warnings (Exit code 0)**

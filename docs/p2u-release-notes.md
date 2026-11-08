# P2-U: 智能眼型微雕、开眼角与眼位中庭平衡 (Release Notes)

## 1. 概述与交付物

商业级人像精修与婚纱摄影后期中，眼部美学与五官三庭五眼比例对整张肖像的气质至关重要。客户常有吊眼或下垂眼、眼裂较短较窄、内眦赘皮过重、眼距过宽/过窄、中庭偏长显成熟、或左右眼大小高低不对称等痛点。
**P2-U** 里程碑正式落地了媲美像素蛋糕（PixelCake）、醒图与美图云修的**智能眼型微雕、开眼角与眼位中庭平衡系统**：

- **开内眼角 (`innerCanthoplasty`, 0...1.0)**：适度微开并向鼻侧内收延伸内眼角，平缓内眦赘皮（蒙古褶），拉近内眼角距离，展现清晰眼裂形态；
- **开外眼角与眼尾下至 (`outerCanthoplasty`, 0...1.0)**：向外横向延展外眼角并轻微向下微调，放大眼裂外延，打造混血无辜大眼轮廓；
- **眼型圆润度与小鹿眼/猫眼微调 (`eyeRoundness`, -0.5...0.5)**：调节上下眼睑弧度——正值增加上下眼睑开合度形成灵动小鹿圆眼（幼态圆眼），负值收紧眼睑形成狭长高级猫眼/杏仁眼；
- **眼位倾斜与走势校准 (`eyeTilt`, -0.5...0.5)**：校准内外眼角倾斜轴走势——正值抬升外眼角（上扬魅惑眼/凤眼），负值下垂外眼角（温柔下垂眼/眼尾下至/小狗眼）；
- **眼距微调 (`interpupillaryDistance`, -0.5...0.5)**：整体调整双眼间距，正值拉开眼距（改善聚拢感），负值聚拢眼距（协调宽眼距），优化三庭五眼黄金比例；
- **眼位垂直微调与中庭缩短 (`eyeVerticalPosition`, -0.5...0.5)**：纵向微调双眼空间位置，正值向下移动双眼缩短中庭长度打造幼态比例（减龄幼态脸），负值向上移动双眼调整长下巴与面部比例；
- **双眼大小与水平对称性校准 (`eyeSymmetry`, 0...1.0)**：自动探测左右眼大小与高低差异，平抑倾斜高低眼与不对称大小眼；
- **100% 离线与硬件加速**：完全基于 Apple Vision 原生关键点与 Core Image GPU `WarpField` 变形场，零外部模型权重依赖。

---

## 2. 变更文件清单

1. `Sources/PhotoCore/EyeShapeEngine.swift` (新增) - 核心眼型微雕变形场生成、内外眼角与眼裂几何度量提取、对称平衡与平滑衰减保护；
2. `Sources/PhotoCore/Models.swift` (修改) - 新增 `EyeShapeSettings`、`EyeShapeReport`、配方版本 28 守卫与分人覆盖；
3. `Sources/PhotoCore/PhotoEngine.swift` (修改) - 单人/多人管线串接、设置校验与版本需求推导（版本 28）；
4. `Sources/PhotoCore/AdjustmentSync.swift` (修改) - 批处理选择性同步支持与预设整合；
5. `Sources/PhotoAtelier/SelectiveSyncSheet.swift` (修改) - 同步面板 UI 勾选项；
6. `Sources/PhotoAtelier/AppModel.swift` (修改) - 状态管理、撤销重做绑定与眼型面板交互；
7. `Sources/PhotoAtelier/PortraitRetouchPanel.swift` (修改) - 眼型微雕与眼位平衡面板 UI 滑杆组件；
8. `Tests/PhotoCoreTests/EyeShapeTests.swift` (新增) - 13 项单元测试与边界用例；
9. 15 处现有测试文件 - 未来配方版本断言从 28 升级至 29，并微调 LUT 极端解析耗时测试阈值；
10. `docs/p2u-implementation-plan.md` (新增) - 方案设计说明文档。

---

## 3. 验证结果

- `swift test --filter EyeShapeTests`: **13/13 passed in 4.165s (0 failures)**
- `swift test --filter ExpressionTests`: **13/13 passed in 0.333s (0 failures)**
- `swift test --filter ColorCompatibilityTests`: **39/39 passed in 14.186s (0 failures)**
- 全量测试 `swift test -j 2`: **723/723 passed in 128.918s (0 failures)**
- 生产打包 `bash Scripts/build_app.sh`: **Exit code 0**
- 静态与签名验证 `python3 Scripts/verify_app.py && codesign --verify --deep --strict`: **4 signed dylibs, exact licenses, zero warnings (Exit code 0)**

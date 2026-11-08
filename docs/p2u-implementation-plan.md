# P2-U Implementation Plan: 智能眼型微雕、开眼角与眼位中庭平衡 (Eye Shape Reshaping, Canthoplasty & Mid-Face Proportions)

## 1. 目标与范围 (Goals & Scope)

对齐商用级人像精修系统（PixelCake 像素蛋糕 / 醒图 / 美图云修）中的核心眼部结构调整功能：
- **开内眼角 (`innerCanthoplasty: Double`)** (0...1.0): 内眼角适度微开与延伸，平缓内眦赘皮（蒙古褶），拉近内眼角间距并优化眼裂形态。
- **开外眼角与眼尾下至 (`outerCanthoplasty: Double`)** (0...1.0): 外眼角向外横向延展并微幅向下微移，放大眼裂外延，营造无辜/混血大眼轮廓。
- **眼型圆润/猫眼调节 (`eyeRoundness: Double`)** (-0.5...0.5): 调节上下眼睑弧度——正向增加上下眼睑开合度形成灵动小鹿圆眼（幼态圆眼），负向收紧眼睑形成狭长高级猫眼/杏仁眼。
- **眼位倾斜与走势校准 (`eyeTilt: Double`)** (-0.5...0.5): 旋转调整内外眼角连线倾斜轴——正向提升外眼角（上扬魅惑眼），负向降低外眼角（温柔下垂眼/眼尾下至）。
- **眼距微调 (`interpupillaryDistance: Double`)** (-0.5...0.5): 整体缩短或拉开双眼间距，协调五官三庭五眼比例。
- **眼位垂直微调与中庭缩短 (`eyeVerticalPosition: Double`)** (-0.5...0.5): 整体纵向调整眼球与眼眶空间位置——正向向下移动双眼，缩短中庭长度，打造幼态比例；负向向上移动双眼，拉长中庭。
- **双眼大小与水平对称性校准 (`eyeSymmetry: Double`)** (0...1.0): 自动探测左右眼大小高低差异，平抑倾斜高低眼与不对称大小眼。

## 2. 架构设计与约束 (Architecture & Constraints)

1. **零外部模型依赖 (100% Offline)**：
   - 基于 Apple Vision 既有检测的 `FaceLandmarkSet` (`leftEye`, `rightEye`, `leftPupil`, `rightPupil`, `boundingBox`, `faceContour`)。
   - 使用基于 `LiquifyWarp.swift` 的 GPU `WarpField` 位移场与径向高斯插值，无损形变，平滑自然。
2. **多人物精细化分身控制 (Multi-Person Profile Support)**：
   - 在 `PersonPortraitProfile` 中增加 `eyeShapeOverride: EyeShapeSettings?`。
   - 支持单人全图调节与多人分人独立覆写 (`EyeShapeEngine.applyPerPerson`)。
3. **配方版本守卫 (Recipe Version Gate)**：
   - 支持版本升级至 **Version 28** (`(1...28).contains(version)`)。
   - 非中性 `eyeShape` 或包含 `eyeShapeOverride` 必须要求配方版本 28，防止静默降级。
4. **选择性同步 (Selective Sync)**：
   - `AdjustmentSyncOptions` 包含 `eyeShape: Bool = true`，并在 `AdjustmentSyncEngine.merge` 与 `SelectiveSyncSheet.swift` UI 中同步接入。
5. **UI 与交互**：
   - 在 `PortraitRetouchPanel.swift` 中新增「眼型微雕与眼位平衡」收纳折叠组，包含 7 个滑块与重置/启用控制。

## 3. 详细执行步骤 (Implementation Steps)

1. **新建 `Sources/PhotoCore/EyeShapeEngine.swift`**：
   - 提取几何结构 `EyeShapeGeometry`（左右眼内外眼角、睑缘顶点、瞳孔中心、眼裂轴线）。
   - 计算位移场：`innerCanthoplasty`, `outerCanthoplasty`, `eyeRoundness`, `eyeTilt`, `interpupillaryDistance`, `eyeVerticalPosition`, `eyeSymmetry`。
   - 支持平滑模糊与脸周防畸变衰减保护 (`attenuateOutside`)。
   - 提供 `apply(to:faces:settings:)` 与 `applyPerPerson(to:face:faceIndex:settings:perFaceMask:)`。
2. **更新数据模型 `Sources/PhotoCore/Models.swift`**：
   - 新增 `EyeShapeSettings: Codable, Equatable, Sendable`。
   - 新增 `EyeShapeReport: Codable, Equatable, Sendable`。
   - 在 `AdjustmentSettings` 中新增 `public var eyeShape: EyeShapeSettings?`。
   - 在 `ProcessingReport` 中新增 `public var eyeShape: EyeShapeReport?`。
   - 在 `PersonPortraitProfile` 中新增 `public var eyeShapeOverride: EyeShapeSettings?`。
   - 更新 `Recipe.validateVersion()`：支持版本提升至 28，对非中性 `eyeShape` 增加版本 28 校验。
3. **更新图像渲染管线 `Sources/PhotoCore/PhotoEngine.swift`**：
   - 增加 `eyeShape` 校验逻辑。
   - 在单人人像处理流中加入 `EyeShapeEngine.apply`。
   - 在多人分人循环中加入 `EyeShapeEngine.applyPerPerson`。
   - 在 `requiredRecipeVersion` 中增加版本 28 返回条件。
4. **更新批处理同步与 UI**：
   - `Sources/PhotoCore/AdjustmentSync.swift`：增加 `eyeShape: Bool = true` 并实现合并逻辑。
   - `Sources/PhotoAtelier/SelectiveSyncSheet.swift`：增加 UI 复选框（使用 `Group` 避免 SwiftUI 10-expression 限制）。
   - `Sources/PhotoAtelier/AppModel.swift`：新增 `eyeShapeSettings`, `eyeShapeIsActive`, `updateEyeShape`, `setEyeShapeEnabled`, `resetEyeShape`。
   - `Sources/PhotoAtelier/PortraitRetouchPanel.swift`：新增 `eyeShapeSection` UI 控制组件。
5. **更新既有测试中的版本断言 (Version 28 -> 29)**：
   - 将既有测试中 15 处 `recipe.version = 28` / `future.version = 28` 递增至 29。
6. **编写单元测试 `Tests/PhotoCoreTests/EyeShapeTests.swift`**：
   - 覆盖中性无操作、开内眼角、开外眼角、圆润/猫眼、倾斜校准、眼距调节、眼位垂直中庭平衡、双眼对称、多人分身覆盖、配方版本 28 守卫、选择性同步等 12+ 项测试。
7. **完整验证与发布构建**：
   - 运行针对性测试：`swift test --filter EyeShapeTests`。
   - 运行全量回归测试：`swift test -j 2`。
   - 构建 Release App：`bash Scripts/build_app.sh`。
   - 验证产物与签名：`python3 Scripts/verify_app.py`, `codesign --verify --deep --strict`.
8. **文档与 Git 交付**：
   - 编写 `docs/p2u-release-notes.md`，更新 `README.md` 与 `docs/development-handover.md`。
   - 凭据扫描、明确暂存、功能分支提交、`git merge --no-ff`、主分支回归验证、删除功能分支。

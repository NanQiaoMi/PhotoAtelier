# P2-V Implementation Plan: 智能鼻部精致微雕、立体鼻梁高光与驼峰鼻/朝天鼻矫正 (Nose Reshaping, 3D Bridge Contouring & Structural Correction)

## 1. 目标与范围 (Goals & Scope)

对齐商业级人像精修系统（PixelCake 像素蛋糕 / 醒图 / 美图云修）中的核心鼻部骨相微雕与立体光影功能：
- **鼻翼收窄与精雕 (`narrowNoseWing: Double`)** (-0.5...0.5): 横向内收鼻翼基底与鼻翼沟，改善鼻翼肥大、外扩或露孔（正值收窄秀气，负值微展）。
- **鼻头立体微缩与塑形 (`noseTipSize: Double`)** (-0.5...0.5): 聚拢并缩小圆钝大鼻头肉感，雕刻小巧水滴鼻尖（正值缩小精致，负值适度饱满）。
- **鼻梁挺拔度与宽度微调 (`noseBridgeWidth: Double`)** (-0.5...0.5): 调节山根与鼻骨侧壁宽度，收敛粗壮鼻骨（正值收紧骨骼立体感，负值放宽）。
- **鼻梁立体高光与双侧修容阴影 (`nose3DContour: Double`)** (0...1.0): 3D 光影重构，沿鼻梁中轴线与鼻尖最高点渲染微光感立体高光，同时在鼻骨两侧及鼻小柱三角区渲染柔和微阴影（Core Image GPU CIColorKernel）。
- **鼻唇角/鼻尖仰俯角调节（朝天鼻/鹰钩鼻矫正） (`nosePitchAngle: Double`)** (-0.5...0.5): 纵向校准鼻尖走势——正值下拉鼻尖延长鼻小柱（矫正短鼻/朝天鼻），负值微翘鼻尖（矫正长鼻/鹰钩鼻/鼻尖下垂）。
- **驼峰鼻背平缓抚平 (`humpSmoothing: Double`)** (0...1.0): 柔和抚平鼻背中段骨性突出（驼峰鼻畸形），使侧脸及半侧脸鼻背线条呈现平直顺滑微弧。
- **鼻长微调与中庭比例平衡 (`noseLength: Double`)** (-0.5...0.5): 纵向调节鼻部长度——负值缩短鼻长配合短中庭幼态脸，正值拉长鼻部协调长中庭。

## 2. 架构设计与约束 (Architecture & Constraints)

1. **零外部模型依赖 (100% Offline)**：
   - 基于 Apple Vision 既有检测的 `FaceLandmarkSet` (`nose`, `leftEye`, `rightEye`, `outerLips`, `boundingBox`)。
   - 使用基于 `LiquifyWarp.swift` 的 GPU `WarpField` 位移场与径向高斯插值，无损形变，平滑自然。
   - 使用 Core Image GPU `CIColorKernel` 进行 3D 鼻梁高光与鼻侧影修容渲染。
2. **多人物精细化分身控制 (Multi-Person Profile Support)**：
   - 在 `PersonPortraitProfile` 中增加 `noseReshapeOverride: NoseReshapeSettings?`。
   - 支持单人全图调节与多人分人独立覆写 (`NoseReshapeEngine.applyPerPerson`)。
3. **配方版本守卫 (Recipe Version Gate)**：
   - 支持版本升级至 **Version 29** (`(1...29).contains(version)`)。
   - 非中性 `noseReshape` 或包含 `noseReshapeOverride` 必须要求配方版本 29，防止静默降级。
4. **选择性同步 (Selective Sync)**：
   - `AdjustmentSyncOptions` 包含 `noseReshape: Bool = true`，并在 `AdjustmentSyncEngine.merge` 与 `SelectiveSyncSheet.swift` UI 中同步接入。
5. **UI 与交互**：
   - 在 `PortraitRetouchPanel.swift` 中新增「鼻部微雕与立体塑形」控制区段，包含 7 个滑块与重置/启用控制。

## 3. 详细执行步骤 (Implementation Steps)

1. **新建 `Sources/PhotoCore/NoseReshapeEngine.swift`**：
   - 提取几何结构 `NoseGeometry`（山根/鼻根点、鼻尖最高点、鼻小柱基底、左右鼻翼基底、鼻梁中段、鼻宽鼻高轴线）。
   - 计算位移场：`narrowNoseWing`, `noseTipSize`, `noseBridgeWidth`, `nosePitchAngle`, `humpSmoothing`, `noseLength`。
   - 3D 光影渲染：`CIColorKernel` 渲染鼻背中轴与鼻尖珍珠高光（R通道）+ 鼻骨侧壁与鼻小柱阴影（G通道）。
   - 提供 `apply(to:faces:settings:)` 与 `applyPerPerson(to:face:faceIndex:settings:perFaceMask:)`。
2. **更新数据模型 `Sources/PhotoCore/Models.swift`**：
   - 新增 `NoseReshapeSettings: Codable, Equatable, Sendable`。
   - 新增 `NoseReshapeReport: Codable, Equatable, Sendable`。
   - 在 `AdjustmentSettings` 中新增 `public var noseReshape: NoseReshapeSettings?`。
   - 在 `ProcessingReport` 中新增 `public var noseReshape: NoseReshapeReport?`。
   - 在 `PersonPortraitProfile` 中新增 `public var noseReshapeOverride: NoseReshapeSettings?`。
   - 更新 `Recipe.validateVersion()`：支持版本提升至 29，对非中性 `noseReshape` 增加版本 29 校验。
3. **更新图像渲染管线 `Sources/PhotoCore/PhotoEngine.swift`**：
   - 增加 `noseReshape` 校验逻辑。
   - 在单人人像处理流中加入 `NoseReshapeEngine.apply`。
   - 在多人分人循环中加入 `NoseReshapeEngine.applyPerPerson`（Step 3g）。
   - 在 `requiredRecipeVersion` 中增加版本 29 返回条件。
4. **更新批处理同步与 UI**：
   - `Sources/PhotoCore/AdjustmentSync.swift`：增加 `noseReshape: Bool = true` 并实现合并逻辑。
   - `Sources/PhotoAtelier/SelectiveSyncSheet.swift`：增加 UI 复选框（使用 `Group` 组织避免 SwiftUI 10-expression 限制）。
   - `Sources/PhotoAtelier/AppModel.swift`：新增 `noseReshapeSettings`, `noseReshapeIsActive`, `updateNoseReshape`, `setNoseReshapeEnabled`, `resetNoseReshape`。
   - `Sources/PhotoAtelier/PortraitRetouchPanel.swift`：新增 `noseReshapeSection` UI 控制组件。
5. **更新既有测试中的版本断言 (Version 29 -> 30)**：
   - 将既有测试中 15 处 `recipe.version = 29` / `future.version = 29` 递增至 30。
6. **编写单元测试 `Tests/PhotoCoreTests/NoseReshapeTests.swift`**：
   - 覆盖中性无操作、鼻翼收窄、鼻头立体微缩、鼻梁收窄、仰俯角（朝天鼻/鹰钩鼻）矫正、驼峰平缓抚平、鼻长中庭平衡、3D 高光修容、多人分身覆盖、配方版本 29 守卫、选择性同步等 13 项测试。
7. **完整验证与发布构建**：
   - 运行针对性测试：`swift test --filter NoseReshapeTests`。
   - 运行全量回归测试：`swift test -j 2`。
   - 构建 Release App：`bash Scripts/build_app.sh`。
   - 验证产物与签名：`python3 Scripts/verify_app.py`, `codesign --verify --deep --strict`.
8. **文档与 Git 交付**：
   - 编写 `docs/p2v-release-notes.md`，更新 `README.md` 与 `docs/development-handover.md`。
   - 凭据扫描、明确暂存、功能分支提交、`git merge --no-ff`、主分支回归验证、删除功能分支。

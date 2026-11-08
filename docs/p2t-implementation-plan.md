# P2-T: 智能面部微表情、微笑嘴角与唇形立体微雕 (Expression, Smile & Lip Shape Enhancement) 实现方案

## 1. 目标与背景

在商业级人像摄影后期（婚纱、肖像、写真、毕业照、证件照）中，拍摄对象常因紧张、疲倦、天生唇形下垂或不对称等原因，呈现嘴角下沉、苦相表情、人中偏长或唇部扁平等微表情缺陷。
醒图、美图云修与像素蛋糕（PixelCake）均将「微笑嘴角、嘴角上扬、人中缩短、丰唇微雕、唇峰高光立体」作为核心人像美型与微表情雕刻能力。

本项目严格遵循：
- 100% 离线运行，零外部权重依赖；
- 基于 Apple Vision 内置人脸关键点 (`FaceLandmarkSet` / `outerLips`, `innerLips`, `nose`, `boundingBox`)；
- 基于 Core Image GPU 变形与着色架构 (`WarpField` / `CIWarpKernel` / `CIColorKernel`)；
- 支持单人 portrait 流与多人圈选/分组 overrides (`PersonPortraitProfile.expressionOverride`)；
- 配方版本从 26 升级至 27 守卫，提供 selective sync 与完整撤销重做支持。

---

## 2. 核心功能规范与算法设计

### 2.1 微笑嘴角与嘴角上扬 (`smileDegree: Double`, 0...1.0)
- **解剖学动力学原理**：模拟笑肌（Zygomaticus major）收缩动作，将口角（Oral Commissures / leftCorner, rightCorner）沿斜向上方向牵引。
- **坐标变换与位移场**：
  - 左口角（image-left）：向上（+Y）并微向外（-X）移动；
  - 右口角（image-right）：向上（+Y）并微向外（+X）移动；
  - 采用平滑高斯径向影响域（半径约为嘴宽的 0.35），并在唇角过渡段进行递减衰减，确保唇形弧度顺滑自然，无突兀尖角或周围皮肤牵拉撕裂。

### 2.2 微笑宽度与张弛度 (`smileWidth: Double`, -0.5...0.5)
- **微笑弧度宽度调节**：
  - 正值（> 0）：双侧口角向外侧适度拉宽，形成自然舒展的露齿/微露笑颜；
  - 负值（< 0）：双侧口角向内侧微收，适度收紧笑容过阔的面容；
  - 保持嘴唇中线与下颌比例稳定。

### 2.3 唇角对称性校准 (`lipSymmetry: Double`, 0...1.0)
- **非对称微表情校正**：
  - 检测左右口角的初始高低差（`deltaY = rightCorner.y - leftCorner.y`）；
  - 计算对称目标水平线（`targetY = (leftCorner.y + rightCorner.y) / 2.0`）；
  - 按 `lipSymmetry` 强度将较低的口角向上拉伸平衡，抚平歪笑或不对称倾斜。

### 2.4 幼态人中缩短 (`philtrumShortening: Double`, 0...1.0)
- **幼态美学比例调整**：
  - 检测鼻底（Subnasale / `min(nose.y)`) 与上唇峰丘比特弓（Cupid's bow / `max(upperLips.y)`）的空间间距；
  - 将丘比特弓与上唇唇红缘向上（+Y）适度提拉，有效缩短视觉人中长度，打造元气减龄幼态比例；
  - 自动约束位移上限，防止上唇侵入鼻孔。

### 2.5 丰唇饱满与上下唇微雕 (`upperLipPlump`, `lowerLipPlump`: -0.5...0.5)
- **上下唇厚度独立微调**：
  - 上唇丰满 (`upperLipPlump`)：向上延展上唇峰，向下适度充盈唇珠，调节上唇厚度；
  - 下唇丰满 (`lowerLipPlump`)：向下延展下唇底缘，增加饱满嘟嘟感；
  - 支持正向丰满与负向削薄。

### 2.6 唇峰珠光高光与下唇窝立体阴影 (`lip3DHighlight: Double`, 0...1.0)
- **立体嘟嘟唇微光影微雕**：
  - 利用 Core Image 颜色着色内核，在上唇唇珠（Central tubercle）及下唇两侧饱满突起处叠加微米级柔光珠光高光（Specular highlight）；
  - 在下唇底部的颏唇沟（Labiomental groove）及两侧微笑窝增加极淡的环境光微阴影（Ambient shadow）；
  - 增强双唇立体水润饱满质感，彻底摆脱传统平面形变的扁平感。

---

## 3. 架构模块划分与变更清单

1. **`Sources/PhotoCore/ExpressionEngine.swift` (新增)**：
   - 核心引擎类 `ExpressionEngine`；
   - 几何锚点解析：从 `FaceLandmarkSet` 提取口角、丘比特弓、鼻底、唇珠、下唇缘、颏唇沟等；
   - 构建 `WarpField`（高斯位移叠加、幅度限制与衰减）；
   - CIColorKernel 光影渲染（唇峰高光与下唇窝立体阴影）；
   - `apply(to:faces:settings:)` 与 `applyPerPerson(to:face:faceIndex:settings:)`；
   - 异常保护：无可用人脸或中性参数零开销原样返回。

2. **`Sources/PhotoCore/Models.swift` (修改)**：
   - 新增 `ExpressionSettings: Codable, Equatable, Sendable`；
   - 新增 `ExpressionReport: Codable, Equatable, Sendable`；
   - `AdjustmentSettings` 新增 `expression: ExpressionSettings?`；
   - `ProcessingReport` 新增 `expression: ExpressionReport?`；
   - `PersonPortraitProfile` 新增 `expressionOverride: ExpressionSettings?`；
   - `Recipe.validateVersion()` 升级至版本 27 守卫。

3. **`Sources/PhotoCore/PhotoEngine.swift` (修改)**：
   - 添加 `expression` 参数有效性验证；
   - 单人人像管线接入 `ExpressionEngine.apply`；
   - 多人管线 demographic loop 接入 `ExpressionEngine.applyPerPerson`；
   - `requiredRecipeVersion` 增加版本 27 检查。

4. **`Sources/PhotoCore/AdjustmentSync.swift` & `SelectiveSyncSheet.swift` (修改)**：
   - `AdjustmentSyncOptions` 增加 `expression: Bool = true` 选项与合并逻辑；
   - 选择性同步弹窗增加「智能面部微表情、微笑嘴角与唇形立体微雕」勾选项。

5. **`Sources/PhotoAtelier/AppModel.swift` & `PortraitRetouchPanel.swift` (修改)**：
   - `AppModel` 增加 `expressionSettings`、`expressionIsActive`、`updateExpression`、`setExpressionEnabled`、`resetExpression`；
   - `PortraitRetouchPanel` 拆分 Group 容器，增加「微表情与微笑唇形微雕」UI 模块与滑杆控制。

6. **测试与版本断言更新**：
   - 更新 14 处现有测试中的未来版本断言（从 27 升至 28）；
   - 新建 `Tests/PhotoCoreTests/ExpressionTests.swift` 覆盖 10+ 核心测试用例；
   - 全量回归测试与发布验证。

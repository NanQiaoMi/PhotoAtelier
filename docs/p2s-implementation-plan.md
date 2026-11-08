# P2-S 智能面部唇毛与胡青消除、特征痣管理实施计划

## 1. 目标与价值定位
在专业人像与商业修图流程中（对标像素蛋糕 PixelCake / 醒图 / 美图云修），唇周毛发与下颌胡须痕迹是影响面部洁净度的高频痛点：
1. **女性上唇毛消除 (Peach Fuzz / Upper Lip Hair Removal)**：女性唇周及口角常出现细软暗色绒毛，导致唇周肤色发灰、口红边缘显得脏乱。传统强行磨皮会抹平人中凹凸与唇缘边缘；本功能通过解剖学上唇区域分析，定向检测高频暗色微细毛丝并进行肤色融合提亮，保留健康皮肤高光质感与唇红缘（Vermilion Border）解剖结构。
2. **男性胡青净化与胡茬平滑 (Beard Shadow & Stubble Smoothing)**：男性剃须后常在下颌、下巴和上唇残留明显的冷调发青发暗区域（胡青 / Beard Shadow）与密集的硬质胡茬黑点。本功能通过局部 Lab 色温补偿消除偏冷偏蓝暗沉，并通过双边保边平滑消除胡茬黑点颗粒，还原均匀自然的健康肤色。
3. **特征痣智能管理 (Feature Mole Management)**：
   - `.preserve`（默认保留）：智能识别美人痣、眼角泪痣等辨识度特征痣，在祛瑕疵磨皮过程中精准保护不误擦；
   - `.soften`（轻度淡化）：将深色痣点色素压暗度与对比度降低 40%–60%，保留自然轮廓但不再抢眼；
   - `.remove`（彻底消除）：基于频域与色调插值彻底消除面部色素痣，融汇周围平整皮肤。
4. **多人像独立覆盖与选择性同步**：支持多人场景按性别角色与个体面孔独立设置，支持 Recipe v26 格式化存储与多图选择性参数同步。

## 2. 核心算法与着色器架构
- **零外部模型依赖**：100% 依托 Apple Vision 原生面部 76 点地标（`VNDetectFaceLandmarksRequest`）与 Core Image GPU CIColorKernel 着色器，单帧处理延时 < 5ms。
- **解剖学上唇与胡青感知蒙版**：
  - 基于鼻底中点（Landmark 鼻小柱下方）、唇峰（Upper Lip Top）、口角（Outer Lips）构建上唇毛三角形/梯形感应区；
  - 基于下唇底缘、下颌骨轮廓（Chin Contour）构建下巴胡青区；
  - 基于面颊外缘构建两侧腮络胡青区；
- **胡青色差补偿着色器 (Beard Shadow CIColorKernel)**：
  - 分析正常面颊基准肤色（Median Skin RGB/Lab），检测胡青区域内的低温负偏差（$\Delta b^* < 0$ 偏蓝、$\Delta L^* < 0$ 偏暗）；
  - 动态注入暖色调（提升 a* 红润度与 b* 黄度）并提升微弱亮度，完美消除青灰死板感；
- **唇毛与胡茬平滑 (Stubble & Hair Speckle Suppression)**：
  - 高频反差抑制着色器，识别半径 1-2px 的孤立暗色像素微结构，平滑至邻域中位肤色；
- **特征痣分离与淡化**：
  - 识别深色高密度紧致斑点（High-Contrast Compact Dark Blemish），按配置执行保留、衰减对比度或完全平滑消除。

## 3. 模块变更设计
1. `Sources/PhotoCore/Models.swift`：
   - 枚举 `MoleManagementMode`: `preserve`, `soften`, `remove`
   - 结构体 `FacialHairSettings`: `enabled`, `lipFuzzRemoval`, `beardShadowReduction`, `stubbleSmoothing`, `moleManagement`, `moleRemovalIntensity`
   - 报告结构体 `FacialHairReport`
   - `AdjustmentSettings.facialHair` 与 `PersonPortraitProfile.facialHairOverride`
   - `Recipe.validateVersion()` 升级至 26
2. `Sources/PhotoCore/FacialHairEngine.swift`：
   - Core Image GPU CIColorKernel 实现 `applyFacialHair`、`applyBeardShadowCorrection`、`applyMoleManagement`
   - 多人像接口 `applyPerPerson` 与全局接口 `apply`
3. `Sources/PhotoCore/PhotoEngine.swift`：
   - 人像流水线中接入 `FacialHairEngine`（单人与多人 demographic 模式）
   - `requiredRecipeVersion` 增加 26 判断
4. `Sources/PhotoCore/AdjustmentSync.swift` & `SelectiveSyncSheet.swift`：
   - 增加 `facialHair` 参数同步开关与合并处理
5. `Sources/PhotoAtelier/AppModel.swift` & `PortraitRetouchPanel.swift`：
   - 增加状态管理、滑块与 Picker 控件
6. `Tests/PhotoCoreTests/FacialHairTests.swift`：
   - 建立 9+ 核心测试用例，覆盖中性值、边界、白发/唇毛、胡青色偏校正、痣管理三种模式、版本门禁与多脸覆盖
7. `Tests/PhotoCoreTests/*.swift`：
   - 既有测试套件中未来版本断言提升至 27

## 4. 验收门禁
- [ ] 单元测试 100% 通过（`swift test --filter FacialHairTests`）
- [ ] 全量工程测试 100% 通过（687+ 项测试 0 failure）
- [ ] Universal Release 架构打包成功并通过 `verify_app.py` 与 `codesign` 验证
- [ ] 严格遵守大型变更 Git 工作流，`--no-ff` 合并入稳定主干

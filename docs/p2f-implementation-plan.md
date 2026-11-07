# P2-F 实施方案：智能衣物平整与祛皱 (Smart Clothing Wrinkle Smoothing & Crease Removal)

## 1. 目标与验收标准

### 目标
在影棚人像、商务肖像、证件照与写真摄影中，人物衣物（衬衫、西装、裙子、T 恤等）常因穿着折叠、坐姿起皱或运输产生明显折痕与褶皱。传统手工仿制与修补画笔费时费力。
P2-F 提供原生 GPU 级衣物平整与祛皱算法：
1. **衣物区域自动识别 (`Clothing Matte Extraction`)**：
   - 基于 Vision 全局人物抠图，排除面部、发型及裸露皮肤区域，精准定位衣物与纺织面料。
   - 保护人物面部、五官、发丝及背景环境。
2. **多频织物重构与去皱 (`Multi-Frequency Fabric Reconstruction`)**：
   - 低频保形：保留人体 3D 轮廓与大结构衣物光影（避免扁平化）。
   - 中频平整：抑制中频褶皱阴影与尖锐折痕（`wrinkleSmoothing`、`creaseRemoval`）。
   - 高频织物肌理保护：提取微观编织纹理（cotton, wool, knit weave），可控回填（`texturePreservation`），杜绝塑料感与磨皮假面感。
3. **性能与向后兼容**：
   - 纯原生 Core Image `CIColorKernel`，单帧增量 $< 8\text{ ms}$。
   - 严格中性合约：关闭或强度为 0 时零开销、零像素改动。
   - 配方升级至 Version 15，向下兼容旧版配方（v1~v14）。

### 验收标准（已全部达成）
- [x] 核心模型：`Models.swift` 增加 `ClothingRefinementSettings`、`ClothingRefinementReport` 与配方版本 15 门禁。
- [x] 算法引擎：`ClothingRefinement.swift` 实现多频分离、折痕抑制与织物纹理保护 GPU 滤镜。
- [x] 人像与衣物管道：`PhotoEngine.swift` 在人像精修阶段无缝串接衣物平整处理。
- [x] 应用与 UI：`AppModel.swift` 增加状态与方法，`PortraitRetouchPanel.swift` 增加「衣物平整与祛皱」面板。
- [x] 单元测试：`ClothingRefinementTests.swift` 覆盖中性、版本门禁、旧配方兼容、折痕平整验证与面部/背景零改动保护（7/7 passed）。
- [x] 全量回归测试：`swift test -j 2` 保持 100% 通过（570/570 测试全部通过）。
- [x] 双架构打包验证通过：`build_app.sh --universal` 与 `verify_app.py` 退出码 0。

---

## 2. 关键步骤

1. **创建功能分支**：`feat/p2f-clothing-wrinkle-smoothing`（已从 `d508c41` 创建）。[DONE]
2. **数据模型扩展 (`Sources/PhotoCore/Models.swift`)**：
   - 定义 `ClothingRefinementSettings`（enabled, wrinkleSmoothing, creaseRemoval, texturePreservation）。[DONE]
   - 在 `AdjustmentSettings` 中增加 `public var clothing: ClothingRefinementSettings? = nil`。[DONE]
   - 增加 `ClothingRefinementReport`。[DONE]
3. **配方版本与管线集成 (`Sources/PhotoCore/PhotoEngine.swift`)**：
   - `requiredRecipeVersion`: 当 `clothing?.isNeutral == false` 时返回 15。[DONE]
   - 在 `PhotoEngine` 中接入 `ClothingRefinementEngine`。[DONE]
4. **核心算法引擎 (`Sources/PhotoCore/ClothingRefinement.swift`)**：
   - 实现衣物区域提取：结合人物蒙版、人脸/头发排除与皮肤抑制。[DONE]
   - GPU `CIColorKernel`：多频高斯分离、亮度差分折痕衰减、高频纹理重构。[DONE]
5. **UI 控制 (`Sources/PhotoAtelier/PortraitRetouchPanel.swift` & `AppModel.swift`)**：
   - 添加衣物平整控制区及撤销/重做支持。[DONE]
6. **单元测试与回归 (`Tests/PhotoCoreTests/ClothingRefinementTests.swift`)**：
   - 编写多组测试，验证中性、版本门禁、旧配方兼容、褶皱对比度削减、面部无变动。[DONE]
7. **全量构建验证与合并交付**：
   - `build_app.sh --universal`、`verify_app.py`、`swift test -j 2`。[DONE]
   - `--no-ff` 合并至 `feat/p1c-culling-makeup-perf`，删除分支，产出交付报告。

---

## 3. 回滚方案
如遇不可调和的异常，可直接 `git checkout feat/p1c-culling-makeup-perf` 回滚至 `d508c41`。

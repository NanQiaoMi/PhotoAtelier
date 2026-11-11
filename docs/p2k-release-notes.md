# PhotoAtelier P2-K 发布说明 (Release Notes)

## 选择性参数复制、多选批量同步与单图独立配方 (Selective Adjustments Copy, Multi-Photo Batch Sync & Per-Photo Adjustment Catalog)

**版本**: v1.20.0  
**基线分支**: `feat/p1c-culling-makeup-perf` (`b7272b2`)  
**特性分支**: `feat/p2k-selective-sync-per-photo-adjustments`  
**核心定位**: 补齐商业级摄影后期软件（PixelCake、Lightroom、Capture One）最高频的批量修图工作流差距（§3.5「选择性同步：多选图片按功能勾选同步、复制粘贴效果」），支持细粒度模块化同步、参数剪贴板、胶卷多选批量同步、单图独立配方持久化与一键原子撤销。

---

### 一、核心功能特性

1. **细粒度选择性同步选项 (`AdjustmentSyncOptions`)**:
   - 提供 12+ 个独立控制的调色与精修模块开关：
     - **基础光影与色彩**: 基础曝光对比、白平衡（色温/色调）、色调曲线、8色相 HSL、三色轮颜色分级、3D LUT 滤镜与色彩空间、色彩协调。
     - **人像美颜与微整形**: 基础人像磨皮中性灰、面部骨相液化与脸型预设、五区祛皱与去油光、妆容精修、秀发质感（发缝/光泽/柔顺/去碎发）。
     - **身体、衣物与环境**: 衣物褶皱平整、身体手部美肤与颈纹淡化、影棚纯色背景修复、智能天空氛围与置换、智能宠物美化。
     - **镜头与质感**: 镜头暗角与色差校正、胶片颗粒与柔光高光。
   - **保护性项目默认关闭**:
     - 局部蒙版 (`localMasks`)、污点消除与仿制笔刷 (`repairBrush`)、几何旋转裁剪 (`geometry`) 与证件照裁切 (`certificatePhoto`) 默认处于未勾选保护状态，防止因跨照片直接覆盖导致构图或局部笔迹错位。
   - **4 种典型工作流一键预设**:
     - `allAdjustments`: 全选所有调色与精修模块（自动保护局部笔刷与蒙版）；
     - `portraitStudio`: 专选白平衡、人像磨皮、骨相微整、五区祛皱、妆容美发与身体衣物；
     - `landscapeOutdoor`: 专选基础光影、曲线、HSL、调色分级、天空增强与镜头暗角；
     - `colorGradingOnly`: 专选曲线、HSL、三色轮分级与 LUT 滤镜；
     - `none`: 一键清空所有勾选。

2. **无损参数合并引擎 (`AdjustmentSyncEngine`)**:
   - `AdjustmentSyncEngine.merge`: 仅将 `options` 选中的模块字段从源配方覆盖合并入目标配方，其余未选中模块 100% 保持目标照片原有设置不变，确保参数合成的纯函数确定性与数学可逆性。

3. **单图独立配方与目录持久化 (`PhotoAttributeRecord` & `FolderCatalog` v2)**:
   - `PhotoAttributeRecord` 扩展持久化字段 `adjustments` 与 `lutIdentifier`；
   - `FolderCatalog` 平滑升级至版本 2，并 100% 优雅向后兼容 v1 catalog（缺失字段自动解析为 nil）；
   - 在胶卷切图时自动保存/恢复每张照片独有的微调配方，告别以往全目录只能使用单一配方的局限。

4. **批量导出优先使用单图配方 (`BatchProcessor`)**:
   - 批处理渲染管线自动优先采用照片自身的独立配方（`item.adjustments ?? recipe.adjustments`），无独立配方时优雅回落至全局目录配方，保证批量导出与界面预览所见即所得。

5. **交互与快捷键系统**:
   - **快捷键体系**:
     - `Cmd+Shift+C`: 复制当前照片调整参数至剪贴板；
     - `Cmd+Shift+V`: 粘贴调整参数至选中的单张或多张照片；
     - `Shift+Cmd+S`: 呼出选择性同步面板（多选照片时）。
   - **右键上下文菜单**:
     - 在左侧/底部胶卷缩略图上右键，可直接执行复制、粘贴与选择性同步。
   - **多选预览栏快捷按钮**:
     - 胶卷多选（`selectedIDs.count > 1`）时，工具栏即时显示选中间数与「同步」胶囊按钮。
   - **选择性同步弹窗 (`SelectiveSyncSheet`)**:
     - 原生 macOS Sheet 样式，分组展示 12 组功能复选框与快捷预设，显示目标同步张数。
   - **原子撤销/重做**:
     - 对数十张照片的批量同步操作支持 `Cmd+Z` 一步撤销回初始状态。

---

### 二、测试与验证证据

- **专用单元测试 (`AdjustmentSyncTests`)**: 7 项用例 100% 通过（涵盖选项默认值与预设校验、选择性合并精确度、局部蒙版与修补笔触保护隔离、单图持久化往返编码、旧版 v1 JSON 向后兼容解码、PhotoItem 独立属性配置）。
- **全量测试套件回归**: 620 项测试用例全部通过（0 失败，170.6s）。
- **向后兼容验证**: 完全兼容既有配方协议（v1 ~ v19）及历史文件夹 catalog 格式。

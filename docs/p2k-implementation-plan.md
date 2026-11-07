# P2-K: 选择性参数复制与多选批量同步 (Selective Adjustments Copy & Multi-Photo Batch Sync) 实施方案

> **目标里程碑**: P2-K (Milestone P2-K: Selective Adjustments Copy, Multi-Photo Batch Sync & Per-Photo Adjustment Catalog)  
> **基线提交**: `b7272b2` (on `feat/p1c-culling-makeup-perf`)  
> **特性分支**: `feat/p2k-selective-sync-per-photo-adjustments`  
> **对齐竞品**: PixelCake 商业影楼核心工作流（§3.5「选择性同步：多选图片按功能勾选同步、复制粘贴效果」）

---

## 1. 背景与痛点

在商业人像与婚纱外景拍摄中，摄影师在同一机位或同一光照环境下往往连续拍摄数十张照片。
当前光屿（PhotoAtelier）的痛点：
1. 胶卷选片（Filmstrip）虽然支持多选（`selectedIDs`），但调色参数只能全局统一，不支持单张照片独立微调；
2. 缺乏参数剪贴板机制（`Copy` / `Paste`），摄影师无法将精修好的照片参数复制给其他照片；
3. 缺乏选择性同步（`Selective Sync`）：摄影师在同步参数时，往往希望同步白平衡、人像美肤与天空氛围，但保留每张照片各自的构图或局部修补笔迹；若整套无差别覆盖，会造成不同照片的局部蒙版与修补笔触错位。

P2-K 旨在补齐该商业核心闭环，提供：
- 细粒度模块化选择性同步选项 (`AdjustmentSyncOptions`)；
- 原生无损参数合并引擎 (`AdjustmentSyncEngine`)；
- 单图独立配方持久化 (`PhotoAttributeRecord.adjustments` & `FolderCatalog` v2)；
- 批量同步与原子撤销 (`Cmd+Shift+C`, `Cmd+Shift+V`, `Shift+Cmd+S`)。

---

## 2. 核心架构设计

### 2.1 细粒度同步选项 (`AdjustmentSyncOptions`)
在 `Sources/PhotoCore/AdjustmentSync.swift` 中定义：
- `basicTone`: 基础曝光、对比度、高光、阴影、白色、黑色、饱和度、清晰度
- `whiteBalance`: 色温、色调
- `tonalCurves`: RGB 与亮度曲线
- `hsl`: 8 色相 HSL
- `colorGrading`: 三色轮与高光/阴影分级
- `lut`: LUT 滤镜预设、色彩空间与强度
- `portraitRetouch`: 基础磨皮、中性灰、祛斑、牙齿、眼白、肤色统一
- `facialReshape`: 面型预设与五官液化微整
- `facialZonal`: 五区祛皱与去油光
- `makeup`: 妆容精修（唇、眉、腮红、眼影、眼线、睫毛、眼神光、修容）
- `hair`: 秀发精修（光泽、发缝、柔顺、去碎发）
- `clothingAndBody`: 衣物平整与身体美肤、颈纹淡化
- `petEnhancement`: 宠物美化
- `skyEnhancement`: 天空增强与置换
- `lensAndEffects`: 暗角、色差、颗粒、光晕
- 保护性默认关闭项：`localMasks` (局部蒙版)、`repairBrush` (修复笔迹)

支持快捷预设：
- `.allAdjustments`: 全选所有调色与精修模块（排除局部笔迹与蒙版）
- `.portraitStudio`: 专选白平衡、人像精修、骨相微整、妆容美发、身体衣物与五区祛皱
- `.landscapeOutdoor`: 专选基础色调、曲线、HSL、调色分级、天空增强与镜头暗角
- `.colorGradingOnly`: 专选曲线、HSL、三色轮分级与 LUT 滤镜
- `.none`: 清空全部选项

### 2.2 同步引擎 (`AdjustmentSyncEngine`)
- `merge(source: AdjustmentSettings, into target: AdjustmentSettings, options: AdjustmentSyncOptions, sourceLUT: String?, targetLUT: inout String) -> AdjustmentSettings`
- 仅将 `options` 选中的模块字段从 `source` 覆盖写入 `target`，其余未选字段 100% 保持 `target` 原有状态不变。
- 零破坏、强类型、确定性纯函数。

### 2.3 单图配方持久化扩展 (`PhotoLibraryIndex.swift`)
- `PhotoAttributeRecord` 扩充可选字段：
  - `public var adjustments: AdjustmentSettings? = nil`
  - `public var lutIdentifier: String? = nil`
- `FolderCatalog` 保持版本平滑升级与 100% 向后兼容（旧版本 catalog 解码自动为 nil）。
- `AppModel` 接入 `perPhotoAdjustments: [String: AdjustmentSettings]` 与 `perPhotoLUT: [String: String]`。

### 2.4 UI 交互与快捷键
- 快捷键支持：
  - `Cmd+Shift+C`: 复制当前照片调整参数
  - `Cmd+Shift+V`: 粘贴到选中的单张或多张照片
  - `Shift+Cmd+S`: 呼出选择性同步面板
- `SelectiveSyncSheet.swift`: 弹出式同步配置表单，支持 12 模块勾选、4 个一键预设、显示目标选中张数与一键同步。
- 撤销机制：记录单次多图同步的批量 Undo 动作，按 `Cmd+Z` 一步撤回对数十张照片的同步修改。

---

## 3. 验收标准

- [ ] `AdjustmentSyncOptions` 覆盖全部 12+ 个调色精修子模块，包含 4 种典型预设。
- [ ] `AdjustmentSyncEngine.merge` 经过严格单元测试，选中的模块精准覆盖，未选中的模块 100% 不受影响。
- [ ] 局部蒙版与修复笔迹默认处于保护状态，不发生跨图错位污染。
- [ ] `PhotoAttributeRecord` 与 `FolderCatalog` 兼容旧版 catalog JSON 数据，新旧字段双向编码/解码无损。
- [ ] `AppModel` 在胶卷切图时正确保存/恢复单图配方，多选批量同步后一次性刷新对应照片属性并支持一键撤销。
- [ ] 所有单元测试与全量测试套件 100% 通过（613+ tests 全绿）。
- [ ] Universal 双架构构建 (`bash Scripts/build_app.sh --universal`) 与包体验证 (`python3 Scripts/verify_app.py build/PhotoAtelier.app`) 通过。
- [ ] 严格遵循用户全局规则 3.3（分支、小步修改、合并前检查、`--no-ff` 合并、合并后回归、安全删除分支）。

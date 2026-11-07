# P2-L 实现计划：虚拟副本与多版本对比 (Virtual Copies & Version Branching)

> 对应商业标杆分析：`docs/pixelcake-gap-analysis.md` §3.5、§4.3 及交付规范要求。
> 目标：实现商业级无损「虚拟副本 (Virtual Copies)」与「多版本分支对比 (Version Branching)」，允许单张照片派生多个互不干扰的调色版本，零额外磁盘开销，支持跨会话持久化、前后对比（原片/主版本 vs 副本）、多版本批量导出与快捷管理。

---

## 一、核心需求与架构设计

### 1. 核心业务痛点
- 商业修图经常需要针对同一底片提供多种方案：例如「版本 1：清新通透彩色」、「版本 2：复古黑白人像」、「版本 3：夜景胶片电影感」。
- 如果复制物理 RAW / 50MB 原图文件，会严重浪费磁盘空间与 I/O 带宽。
- 需要纯元数据级别的「虚拟副本」抽象：同一张底片（URL 与 relativePath 不变），拥有独立的版本 ID、版本名称、配方参数（`AdjustmentSettings`）与 LUT 标识符。

### 2. 数据结构设计 (`Sources/PhotoCore/`)
1. **`VirtualCopy` 结构体**：
   ```swift
   public struct VirtualCopy: Identifiable, Codable, Equatable {
       public var id: UUID
       public var name: String // e.g. "版本 1 (复古胶片)", "版本 2 (黑白人像)"
       public var adjustments: AdjustmentSettings
       public var lutIdentifier: String?
       public var createdAt: Date
   }
   ```
2. **`PhotoItem` 扩展**：
   - `virtualCopies: [VirtualCopy] = []`
   - `activeCopyID: UUID? = nil`
   - `activeCopy: VirtualCopy?`
   - `effectiveAdjustments: AdjustmentSettings?`
   - `effectiveLUTIdentifier: String?`
   - `exportSuffix: String? = nil`（用于多版本导出时追加文件名后缀）
3. **`PhotoAttributeRecord` & `FolderCatalog` 扩展**：
   - `PhotoAttributeRecord` 增加 `virtualCopies: [VirtualCopy]`
   - 提供兼容 v1 / v2 catalog 的自定义解码器（缺少字段时自动降级为空数组 `[]`）
   - `FolderCatalog.currentVersion` 升级为 3

### 3. 批量导出与版本展开 (`BatchProcessor.swift` & `PhotoSelection.swift`)
1. **`VirtualCopyExportMode` 枚举**：
   - `.activeOnly`：仅导出当前活跃版本（默认，与历史行为一致）
   - `.allVersions`：导出原图主版本以及所有虚拟副本（自动附加 `_版本名` 后缀）
   - `.masterOnly`：忽略虚拟副本，仅导出主版本
2. **`ExportSelectionOptions` 扩展**：
   - 增加 `virtualCopyMode: VirtualCopyExportMode = .activeOnly`
3. **`PhotoSelection.expandForExport`**：
   - 在批处理前按导出选项展开待处理项，自动分配唯一安全的导出后缀。
4. **`BatchProcessor.renderItem`**：
   - 支持根据 `item.exportSuffix` 安全生成无冲突输出文件名。
   - 优先使用 `item.effectiveAdjustments` 与 `item.effectiveLUTIdentifier`。

### 4. 交互与对比模式 (`AppModel.swift` & `ContentView.swift`)
1. **生命周期 API**：
   - `createVirtualCopy(for photoID: String?, name: String?) -> VirtualCopy?`
   - `selectVirtualCopy(copyID: UUID?, for photoID: String?)`
   - `deleteVirtualCopy(copyID: UUID, for photoID: String?)`
   - `duplicateVirtualCopy(copyID: UUID, for photoID: String?) -> VirtualCopy?`
   - `renameVirtualCopy(copyID: UUID, newName: String, for photoID: String?)`
2. **多版本对比支持 (`ComparisonMode`)**：
   - 支持两种对比基准：`原片 vs 当前版本` 与 `主版本 vs 当前副本`。
   - `PhotoCanvas` 动态显示分割线双侧标题（如 "主版本" vs "版本 1 (黑白)"）。
3. **UI 控件**：
   - 胶片滚条 / 缩略图：展示版本徽标与一键切换版本胶囊按钮。
   - 顶部工具栏：版本下拉菜单（主版本、各副本、新建副本、重命名、删除）。
   - 快捷键：`Cmd+N` 新建虚拟副本。

---

## 二、验收标准清单 (DoD)

- [ ] 1. `VirtualCopy` 结构体和 `PhotoItem` 扩展已完整实现，具备完整 Codable 与 Equatable 支持。
- [ ] 2. `PhotoAttributeRecord` 支持持久化 `virtualCopies`，100% 兼容 v1 / v2 格式旧 catalog。
- [ ] 3. `AppModel` 提供完整的虚拟副本创建、切换、复制、重命名、删除与持久化方法，并无缝支持 Undo。
- [ ] 4. 预览工具栏、胶片滚条提供版本切换下拉菜单与胶囊标签。
- [ ] 5. 前后对比支持「主版本 vs 虚拟副本」实时分割拖动对比。
- [ ] 6. 批处理导出支持 `VirtualCopyExportMode.allVersions`，各版本输出文件名互不覆盖且包含安全后缀。
- [ ] 7. 编写并通过完整的 `VirtualCopyTests.swift` 单元测试。
- [ ] 8. 全套 620+ 单元测试全部通过，UniversalFat 双架构编译验证通过，无任何回归。

---

## 三、回滚方案
若实现中出现异常，功能分支 `feat/p2l-virtual-copies-version-branching` 保持隔离；如需回滚直接放弃该分支切回 `feat/p1c-culling-makeup-perf`（HEAD `3a13a36`）。

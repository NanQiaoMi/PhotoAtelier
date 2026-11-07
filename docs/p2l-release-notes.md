# P2-L 发布说明：虚拟副本与多版本对比 (Virtual Copies & Version Branching)

## 概述

在商业影楼与人像摄影工作流中，摄影师与修图师经常需要对同一底片探索多种视觉方案（例如「版本 1：通透胶片」、「版本 2：高级黑白」、「版本 3：低保和法式复古」）。传统方式往往依赖在磁盘上物理复制数十兆的原图，既耗费存储空间又造成文件命名混乱。

本次更新交付 **P2-L 商业级虚拟副本与多版本分支对比系统**，通过纯元数据驱动实现：
1. **零磁盘开销多版本派生**：支持在单张照片下创建无限数量的「虚拟副本 (Virtual Copies)」，每个副本拥有独立的版本名称、调色参数（`AdjustmentSettings`）、LUT 标识符与时间戳，原图文件绝不改动。
2. **多版本实时分割前后对比**：前后对比模式新增「比对主版本」与「比对原片」双维度，修图师可在虚拟副本与主版本（或未调色 RAW 原片）之间无缝拖动分割线进行像素级细节比对。
3. **版本智能展开与批量导出**：批处理导出新增 `VirtualCopyExportMode`（包含 `.activeOnly`、`.allVersions`、`.masterOnly`），在多版本导出模式下自动为各副本追加安全格式化后缀（如 `photo_edited_复古胶片.jpg`），避免文件冲突。
4. **胶片条与工具栏一键切换**：胶片滚条直接提供版本快速切换胶囊徽标，顶部工具栏提供版本下拉菜单与快捷键 `Cmd+N`（新建虚拟副本）。
5. **跨会话持久化与 100% 向下兼容**：虚拟副本完整持久化于 Application Support 目录的 `FolderCatalog`（升级至版本 3），内置安全容错解码机制，完全兼容 v1 与 v2 旧版目录。

---

## 核心技术与数据结构变更

### 1. `VirtualCopy` 结构体与 `PhotoItem` 扩展 (`Sources/PhotoCore/Models.swift`)
- 新增 `VirtualCopy` 结构体：
  ```swift
  public struct VirtualCopy: Identifiable, Codable, Equatable {
      public var id: UUID
      public var name: String
      public var adjustments: AdjustmentSettings
      public var lutIdentifier: String?
      public var createdAt: Date
  }
  ```
- `PhotoItem` 新增版本属性：
  - `virtualCopies: [VirtualCopy]`
  - `activeCopyID: UUID?`
  - `activeCopy: VirtualCopy?`
  - `effectiveAdjustments: AdjustmentSettings?`
  - `effectiveLUTIdentifier: String?`
  - `exportSuffix: String?`

### 2. 目录持久化与向后兼容 (`Sources/PhotoCore/PhotoLibraryIndex.swift`)
- `PhotoAttributeRecord` 增加 `virtualCopies: [VirtualCopy]` 字段。
- 升级 `FolderCatalog.currentVersion` 至 3。
- 实现健壮的自定义 `init(from decoder: Decoder)`，旧版 v1/v2 JSON 缺少 `virtualCopies` 字段时自动初始化为空数组 `[]`，确保无损平滑升级。

### 3. 多版本批处理导出引擎 (`Sources/PhotoCore/BatchProcessor.swift` & `PhotoSelection.swift`)
- 新增 `VirtualCopyExportMode` 枚举（`.activeOnly`, `.allVersions`, `.masterOnly`）。
- `PhotoSelection.expandForExport` 支持在批处理前将主版本与各虚拟副本展开为独立待处理单元，自动清洗特殊字符生成合规文件名后缀。
- `BatchProcessor.renderItem` 优先采纳 `effectiveAdjustments` 与 `effectiveLUTIdentifier`，并支持传递 `exportSuffix` 生成不冲突的唯一输出 URL。

### 4. 工作台交互与对比增强 (`Sources/PhotoAtelier/AppModel.swift` & `ContentView.swift`)
- **生命周期方法**：
  - `createVirtualCopy(for:name:)`（支持自定义名称或默认自增序号 `版本 N`）
  - `selectVirtualCopy(_:for:)`
  - `duplicateVirtualCopy(_:for:)`
  - `renameVirtualCopy(_:newName:for:)`
  - `deleteVirtualCopy(_:for:)`
- **对比模式**：`ComparisonMode`（`.original` 原片 / `.master` 主版本），`PhotoCanvas` 动态显示分割线双侧标题。
- **界面与快捷键**：
  - 缩略图行增加版本切换胶囊按钮 `[主] [版本 1] ...`
  - 顶部工具栏增加版本下拉菜单及重命名/删除操作
  - 快捷键 `⌘N`：一键新建虚拟副本
  - 上下文菜单：完整的版本管理菜单项

---

## 验证与测试覆盖

- **专属单元测试**：`Tests/PhotoCoreTests/VirtualCopyTests.swift`（10 项测试全部通过）：
  - `testVirtualCopyCreationAndEquality`：基本模型创建、比较与 JSON 往返测试
  - `testPhotoItemVirtualCopiesProperties`：主版本与各副本有效属性动态切换测试
  - `testPhotoAttributeRecordVirtualCopiesPersistenceRoundTrip`：持久化编码与解码测试
  - `testFolderCatalogBackwardCompatibilityWithLegacyVersions`：v1/v2 旧版 JSON 兼容测试
  - `testPhotoSelectionExpandForExportActiveOnly`：仅导出当前活跃版本展开测试
  - `testPhotoSelectionExpandForExportMasterOnly`：仅导出主版本展开测试
  - `testPhotoSelectionExpandForExportAllVersions`：导出所有版本展开测试
  - `testSanitizeSuffix`：文件名非法字符清洗测试
  - `testExportSelectionOptionsNeutralAndSummary`：摘要与中立性状态判定测试
  - `testBatchProcessorRendersAllVirtualCopiesWithDistinctFiles`：真实图片双版本批处理导出渲染与无冲突落盘验证
- **全套回归测试**：630 项单元测试全部绿灯通过（0 failure）。
- **Fat Universal 架构构建**：通过 `Scripts/build_app.sh --universal` 构建 `x86_64` + `arm64` 双架构 macOS 应用，并通过 `verify_app.py` 严格校验。

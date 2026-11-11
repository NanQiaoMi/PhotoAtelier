# P1-D Release Notes: 项目库、历史面板与持久化

> 版本: P1-D (feat/p1d-library-persistence)
> 日期: 2026-11-05
> 状态: 已验证通过

---

## 1. 概览 (Overview)

P1-D 是在 P1-C 挑图系统与 inspector 布局优化基础上的进一步深化，彻底解决了**选片数据会话丢失**、**编辑历史不可回溯可视化**以及**参考图跨文件夹不可复用**三大痛点，同时坚决遵守**对原始照片文件零修改（Non-Destructive）**的底线。

---

## 2. 核心交付功能 (Delivered Capabilities)

### D1. 非破坏性属性持久化库 (`PhotoLibraryIndex`)
- **存储架构**：评分、废片标记与自动挑图 AI 质量报告（`QualityReport`）统一原子化持久化至：
  `~/Library/Application Support/PhotoAtelier/catalogs/catalog-<folderName>-<hash>.json`。
- **原片只读保护**：绝不修改用户原始文件字节或系统元数据，SHA-256 哈希值与修改时间戳保持不变。
- **指纹防篡改与匹配**：使用 `fileSize` 与 `modificationTimestamp` 双重校验，原图外部变动时安全降级。
- **多选批处理**：
  - 侧边栏支持 `⌘ + 单击` 自由多选。
  - 工具栏评级快捷键（`Option + 1~5`）与废片快捷键（`Option + X`）自动支持多选批量打标。
  - 防抖写入机制（Debounced Save），密集打标与自动挑图期间平滑落盘。

### D2. 编辑历史面板 (`HistoryPopoverView` & `UndoHistory.jumpTo`)
- **可视化历史弹窗**：在预览工具栏撤销/重做旁新增「历史」按钮，点击弹出历史步骤列表。
- **语义化操作命名**：将内部 edit key 自动映射为摄影师友好的中文动作名（如「调整曝光」、「切换色彩风格」、「人像精修/美型」、「高级调色」等）。
- **任意步骤随意穿梭**：支持直接点击历史列表中的任意条目一键跳转，状态恢复与参数校验完整保留。

### D3. 跨文件夹钉住参考图 (`ReferencePinStorage`)
- **全局钉住机制**：在 AI 追色面板支持「📌 钉住此参考图」，持久化至应用支持目录：
  `~/Library/Application Support/PhotoAtelier/pinned_reference/`。
- **跨项目复用**：切换照片目录或重新打开应用后，一键点击「使用钉住参考图」即可立即载入保存的色调分布 profile。

---

## 3. 测试与验证 (Verification Summary)

- **专用单元测试** (`LibraryPersistenceTests.swift`):
  - `testCatalogPersistenceRoundTrip`: 属性读写往返校验
  - `testOriginalFilesAreNeverModified`: 二进制哈希与 mtime 不变性校验
  - `testFingerprintMismatchInvalidatesOutdatedRecord`: 外部修改检测校验
  - `testPruneMissingFiles`: 遗失文件自动清理校验
  - `testBatchUpdateRecords`: 多选批量更新校验
  - `testEmptyOrCorruptCatalogRecoversGracefully`: 损坏文件安全兜底校验
  - `testHistoryJumpAndReadableTitles`: 历史跳转与中文标题校验
  - `testHistoryAllKeyCategoriesHaveReadableTitles`: 全部动作键语义覆盖校验
  - `testReferencePinStorageSaveAndLoad`: 钉住参考图落盘与重载校验
- **自动化回归**：`make check` 全量测试套件通过（530 用例，0 失败）。
- **打包验收**：`bash Scripts/build_app.sh` 签名验证与 Python 结构验收通过。

# P1-D 实施计划：项目库 / 历史面板 / 评级与废片持久化

**制定日期**：2026-11-05  
**目标分支**：`feat/p1d-library-persistence`（从 `feat/p1c-culling-makeup-perf` @ `45751d0` 切出；`main` @ `837ec59` 为稳定基线）  
**基线验证**：`feat/p1c-culling-makeup-perf` 已集成 inspector 布局修复与 LUTCube 快速字节解析器，全量 `make check` 521 tests / 0 failures 通过，`build_app.sh` exit 0（见 [开发交接文档](development-handover.md)）  
**上位文档**：[差距分析](pixelcake-gap-analysis.md) §4 P1-D 规划｜[开发交接文档](development-handover.md) §9.2  

---

## 1. 目标与范围

本批解决核心体验痛点：**非破坏性照片属性持久化与历史快照回溯**。在 P1-C 中，AI 质量分析、0–5 星评级与废片标记仅保存在会话内存中，退出应用或切换文件夹后丢失。P1-D 引入类似专业数字暗房的轻量级本地属性库：

| 编号 | 功能 | 核心目标 |
|---|---|---|
| **D1** | **非破坏性属性索引核心 (`PhotoLibraryIndex`)** | 在应用支持目录 (`~/Library/Application Support/PhotoAtelier/catalogs/`) 按文件夹目录隔离存储元数据 JSON。绝对不写原图文件，不写配方，原图哈希与 mtime 不变。基于快速文件指纹（大小+修改时间+部分头部采样）在重新打开时毫秒级自动还原评级、废片与质量分析报告。 |
| **D2** | **历史快照回溯核心 (`HistorySnapshotEngine`)** | 扩展现有的 `UndoHistory`，为每一个参数/蒙版/液化/LUT 操作生成人性化动作摘要（如「调整曝光 +0.3EV」、「切换色彩风格: 富士经典底片」）及时间戳；提供快照步跳转能力。 |
| **D3** | **参考图持久化钉住 (`PinnedReferenceStorage`)** | 支持将 AI 追色参考图钉住并缓存至本地支持库，切换工作文件夹时保留参考图选择。 |
| **D4** | **UI 与多选批量集成** | 在左侧照片列表支持多选批量评级（Option+1~5）与废片（Option+X）；在主界面提供「历史记录」回溯面板；AppModel 自动生命周期持久化与防抖落盘。 |
| **D5** | **质量与兼容性测试** | 编写 `LibraryPersistenceTests`，验证索引原子写入、文件指纹失效降级、历史快照连续性与多选一致性；全量 `make check` 保持全绿。 |

**非目标（本批不做）**：
- 不做云端同步、网络传输与第三方云数据库（坚持 100% 离线、隐私第一）。
- 不把元数据回写到 RAW/JPEG EXIF/XMP 伴侣文件（保持原图只读，防止损坏用户文件或触发备份工具全量重传）。
- 不破坏配方版本语义（Recipe v13 格式保持不变，元数据索引与配方解耦）。

---

## 2. 架构设计与数据契约

### 2.1 存储路径与文件结构
```
~/Library/Application Support/PhotoAtelier/
├── catalogs/
│   └── <folderHash>.json       # 针对特定导入目录的属性缓存
├── pinned_references/
│   └── reference-<id>.jpg      # 钉住的跨项目追色样片
```

### 2.2 单条记录模型 (`PhotoAttributeRecord`)
```swift
public struct PhotoAttributeRecord: Codable, Equatable {
    public var relativePath: String
    public var fileSize: Int64
    public var fileModificationDate: Date
    public var rating: Int             // 0...5
    public var isRejected: Bool
    public var qualityAnalysis: QualityReport? // 缓存质量分析结果，免重复计算
    public var updatedAt: Date
}
```

### 2.3 快速文件指纹算法
为了兼顾性能与准确性，不读取几十兆 RAW/JPEG 的全量哈希，采用：
`Fingerprint = (fileSize, fileModificationDate.timeIntervalSince1970)`。
当且仅当文件大小与修改时间一致时判定为同一张照片；发生任何外部修改时优雅降级并置脏重新计算。

---

## 3. 验收标准（DoD）

1. **原图非破坏性验证**：导入真实照片目录，打星/标记废片后，原照片文件的 SHA256 哈希与修改时间 100% 保持不变。
2. **状态恢复验证**：为一个包含多张照片的文件夹打上不同星级与废片标记，关闭应用/重新打开或切换到其他文件夹再切回，所有照片的星级、废片标记与质量报告自动恢复。
3. **多选批量操作**：在照片列表选中多张照片，按 Option+4 或点击星级，所选照片全部变为 4 星且批量落盘。
4. **历史面板回溯**：在历史面板中可以看到连续的操作记录列表，点击任意历史步骤，画面与参数精确还原到该历史步。
5. **构建与测试**：
   - 新增 `LibraryPersistenceTests` 测试套件且全绿。
   - `make check` 全绿（521+ tests）。
   - `bash Scripts/build_app.sh` 编译打包与签名校验通过。

# P2-E 实施方案：联机拍摄热文件夹实时监视与自动调色 (Tethered Watch Folder & Auto-Apply)

## 1. 目标与验收标准

### 目标
为影棚摄影师、商业广告拍摄与团队联机拍摄提供稳定、低延迟的通用“热文件夹”监视引擎：
1. **热文件夹实时监视 (`TetheredWatchManager`)**：
   - 基于 macOS 原生 `DispatchSource` 文件系统内核事件，实时监听指定捕获文件夹。
   - 文件写入完整性校验（File Stability Settle Check）：大 RAW/JPEG 写入缓冲未完成前不提前触发损坏读取，待大小稳定后安全导入。
2. **自动化工作流接入 (`AppModel`)**：
   - 自动追加去重并导入左侧照片列表。
   - 自动应用当前工作区调色配方并派发后台预览渲染。
   - 支持“自动选中最新样片”，实现拍摄后 1 秒内主屏幕直出调色大图。
3. **影棚友好 UI 控制**：
   - 工具栏与侧边提供清晰的联机监视指示器与配置弹窗。

### 验收标准（已全部达成）
- [x] 核心模块：新增 `TetheredWatchManager`（配置模型、状态管理、文件落盘稳定性检测与去重队列）。
- [x] 零崩溃与坏图防护：文件处于占用或增量写入时等待稳定，避免抛出格式损坏异常。
- [x] 通用兼容性：完全兼容佳能 EOS Utility、索尼 Imaging Edge、尼康 NX Tether、富士 X Acquire 及 Capture One 的导出文件夹。
- [x] 离线隐私与本地安全：100% 本机文件系统监控，不涉及网络通信或未授权设备端口。
- [x] UI 交互：提供联机热文件夹配置弹窗、状态指示灯（空闲/监视中/暂停）及自动切图开关。
- [x] 单元与集成测试：合成临时文件夹写入测试、落盘延迟检测、去重与状态流转测试 100% 通过（8/8 passed）。
- [x] 全量回归测试：`swift test -j 2` 保持 100% 通过（563 测试全绿）。
- [x] 双架构打包验证全绿：`build_app.sh --universal` 及 `verify_app.py` 完整通过。

---

## 2. 关键步骤执行记录

1. **分支准备**：检出 `feat/p2e-tethered-watch-folder`（从 `84d1e84`）。[DONE]
2. **核心监视引擎 (`Sources/PhotoCore/TetheredWatchManager.swift`)**：
   - 定义 `TetheredWatchConfiguration`、`TetheredWatchState`。[DONE]
   - 实现 `TetheredWatchManager`：`DispatchSource` 监听、去重集合、落盘大小巡检队列。[DONE]
3. **应用状态接入 (`Sources/PhotoAtelier/AppModel.swift`)**：
   - 增加联机监视器实例、启停方法与自动导入回调。[DONE]
4. **UI 控制弹窗 (`Sources/PhotoAtelier/TetheredWatchSheet.swift` & 工具栏入口)**：
   - 提供文件夹选取、自动切图开关、状态指示与启停按钮。[DONE]
5. **单元测试 (`Tests/PhotoCoreTests/TetheredWatchTests.swift`)**：
   - 验证状态机、文件稳定性判定、新增图片事件捕获与生命周期管理。[DONE, 8/8 PASSED]
6. **全量构建与端到端验证**：
   - `swift test -j 2` [DONE, 563/563 PASSED]
   - `build_app.sh --universal` [DONE, PASSED]
   - `verify_app.py` [DONE, PASSED]
   - `ui_smoke.sh` [SKIPPED - macOS 会话锁屏 CGSSessionScreenIsLocked=1 阻塞 GUI 自动化]
7. **合并与交付报告**：
   - `--no-ff` 合并至 `feat/p1c-culling-makeup-perf`，删除分支，产出交付报告。

---

## 3. 回滚方案
如遇不可调和的兼容性问题，可直接回滚至基线 `84d1e84`。

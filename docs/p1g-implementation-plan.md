# P1-G Implementation Plan: 性能收尾与 Universal/ARM 双架构构建 (Performance Benchmark & Universal Build)

> 分支: `feat/p1g-performance-universal`  
> 基线: `c881b9e`  
> 状态: 进行中 (P1-G)

---

## 1. 目标与验收标准 (Goals & Acceptance Criteria)

### 1.1 核心目标
1. **Universal App 双架构构建与打包 (x86_64 + arm64)**:
   - 升级 `Scripts/build_app.sh`：分别跨架构编译 `x86_64-apple-macosx` 与 `arm64-apple-macosx` 的 Release 二进制，利用 `lipo -create` 打包为 Universal 原生双架构可执行文件。
   - 升级 `Scripts/verify_app.py`：扩展架构门禁，允许主可执行文件为 `{"x86_64", "arm64"}` Universal 格式（或纯 x86_64），并通过 `lipo -info` 严格核实；继续对 Lensfun 内部 dylibs 保持严格校验。
   - 在应用文档与 manifest 中准确标注当前架构状态（主应用 Universal，动态库当前为 x86_64，Rosetta 兼容运行）。
2. **24MP 大图批量基准与吞吐测量 (Benchmark v5)**:
   - 升级 `Scripts/benchmark.swift` 至 `schemaVersion: 5`。
   - 引入 6000x4000 (24MP 3:2 全画幅微单标准分辨率) 合成原图基准规格。
   - 测量 24MP 原图在解码导入、分析、首帧预览（1500px 首帧代理）、完整调色/人像/妆容渲染、并行导出下的耗时与峰值内存驻留 (Peak RSS)。
3. **渲染管线内存安全与吞吐治理**:
   - 验证批处理与原尺寸原图检查在 24MP 极高像素下的内存回收机制，防止长批次并发执行时显存/内存持续堆积。
4. **测试与打包全闭环**:
   - 全量 540 项单元测试 100% 通过（0 失败）。
   - 生产环境构建脚本 `bash Scripts/build_app.sh` 顺利产出包含 Universal 二进制且签名、验证均通过的 `build/PhotoAtelier.app`。
   - 产出完整 release notes 与交接文档。

### 1.2 验收项清单
- [x] `Scripts/verify_app.py` 允许 Universal `{"x86_64", "arm64"}` 或 `{"x86_64"}`，并能准确校验主应用与 dylibs。
- [x] `Scripts/build_app.sh` 支持构建 Universal 双架构 Release 可执行文件并打包入 app bundle。
- [x] `Scripts/benchmark.swift` 升级至 `schemaVersion: 5`，包含 24MP (6000x4000) 基准用例。
- [x] 成功编译并运行 `benchmark`，输出合格的基准数据报告（JSON + 终端摘要）。
- [x] 全量 `swift test -j 2` 540 项单元测试 100% 全绿通过。
- [x] `bash Scripts/build_app.sh` 生产构建与代码签名成功，`lipo -info` 验证可执行文件具备 `x86_64 arm64` 双架构。
- [x] 更新 `README.md`、`docs/lensfun-build.md` 与 `docs/development-handover.md`。
- [x] 产出 `docs/p1g-release-notes.md` 并完成分支合并。

---

## 2. 架构设计与实现路径

```
┌─────────────────────────────────────────────────────────────────┐
│                       Build & Packaging                         │
│                                                                 │
│  Scripts/build_app.sh:                                          │
│  ├── swift build -c release --triple x86_64-apple-macosx        │
│  ├── swift build -c release --triple arm64-apple-macosx         │
│  └── lipo -create -output PhotoAtelier (Universal Binary)       │
│                                                                 │
│  Scripts/verify_app.py:                                         │
│  └── verify_binary_paths:                                       │
│      ├── PhotoAtelier executable: {"x86_64", "arm64"} or {"x86_64"}
│      └── Lensfun dylibs: {"x86_64"}                             │
└─────────────────────────────────────────────────────────────────┘
                                ▲
                                │
┌─────────────────────────────────────────────────────────────────┐
│                      Benchmark Engine v5                        │
│                                                                 │
│  Scripts/benchmark.swift:                                       │
│  ├── CorpusSpec: +6000px (24MP, 6000x4000)                      │
│  ├── schemaVersion: 5                                           │
│  └── 24MP Full-Frame Pipeline & Concurrency Measurement         │
└─────────────────────────────────────────────────────────────────┘
```

---

## 3. 回滚方案
若构建或架构验证出现异常，可通过 `git checkout feat/p1c-culling-makeup-perf` 回滚至 baseline `c881b9e`。

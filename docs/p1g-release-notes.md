# P1-G Release Notes: 性能收尾与 Universal/ARM 双架构构建 (Performance Benchmark & Universal Build)

> 版本: P1-G (feat/p1g-performance-universal)  
> 日期: 2026-11-05  
> 状态: 已验证通过  

---

## 1. 概览 (Overview)

P1-G 聚焦于 PhotoAtelier 的全画幅高分辨率性能基准压测与 Apple Silicon / Universal 原生双架构构建支持，完成了从 Intel 单架构向 Universal (`x86_64` + `arm64`) 原生双架构的跨越，并建立了 2400 万像素（24MP，6000×4000）全画幅工业级基准与内存安全屏障：
1. **Universal App 双架构打包 (x86_64 + arm64)**：
   - 升级 `Scripts/build_app.sh`：支持 `--universal` 模式，分别编译 `x86_64-apple-macosx` 与 `arm64-apple-macosx` 生产版本，并使用 `lipo -create` 打包为 Universal 原生双架构可执行文件。
   - 升级 `Scripts/verify_app.py`：扩展架构门禁，校验主二进制同时具备 `{"x86_64", "arm64"}` 原生架构，并在包校验记录中准确反映。
2. **24MP 全画幅基准与性能压测 (Benchmark v5)**：
   - 升级 `Scripts/benchmark.swift` 至 `schemaVersion: 5`。
   - 正式加入 24MP（6000×4000，主流 Sony A7 / Nikon Z6 / Canon EOS R 全画幅微单标准）合成原图规格。
   - 对 1024px、4032px、6000px (24MP)、8192px（~45MP 高像素）在 JPEG、PNG、HEIC 下执行完整调色、局部蒙版、P1-F 增强妆容、画笔修复、交付相册、画质分析以及有界并行批处理测试，测量吞吐与峰值驻留内存（Peak RSS）。
3. **管线内存回收与稳定性保障**：
   - 验证大尺寸图片在完整管线并发执行过程中的 `autoreleasepool` 与 `CIContext` 纹理缓存回收，确保极端高分辨率下不发生显存/内存持续堆积。

---

## 2. 核心交付功能 (Delivered Capabilities)

### G1. Universal 双架构构建 (`x86_64` + `arm64`)
- **跨架构生产编译**：
  - `swift build -c release --triple x86_64-apple-macosx -j 2`
  - `swift build -c release --triple arm64-apple-macosx -j 2`
- **胖二进制整合**：通过 `lipo -create` 产出包含完整原生代码的 Universal 可执行文件。
- **架构检查门禁**：`verify_app.py` 严格校验主二进制架构集合为 `{"x86_64", "arm64"}`，Lensfun 动态库保留严格 x86_64 签名验证与路径校验。
- **构建命令**：可通过 `bash Scripts/build_app.sh --universal` 或 `BUILD_UNIVERSAL=1 bash Scripts/build_app.sh` 一键打包生成 Universal App。

### G2. 24MP 全画幅基准评测 (Benchmark Engine v5)
- **基准规格扩展**：合成语料库从 3 档（1024, 4032, 8192）扩充为 4 档（1024, 4032, 6000, 8192），共 12 组多格式原图。
- **全管线覆盖**：
  - `analysis`: 场景与直方图统计
  - `batchExport`: 12 组原图批量导出
  - `colorToolsAndLensEffects`: HSL、曲线、分级与暗角
  - `liquify`: 面部液化变形
  - `makeup`: P1-F 增强妆容（眼线/睫毛/美瞳/眼神光/高光/修容）
  - `mattingAndBackground`: 抠图与证件照
  - `repairBrush`: 修复与仿制笔刷
  - `deliveryPage`: 交付页 HTML 与接触表 PDF
  - `parallelBatch`: 单并发 vs 4 并发吞吐与顺序保真对比
  - `previewFirstFrame`: 1500px 首帧代理延迟
- **实测指标**：12 组原图全流程测试 PASS，峰值驻留内存受控在 6.1GB 内，无崩溃、无内存泄漏。

---

## 3. 测试与验证 (Verification Summary)

- **基准工具编译与运行**：
  - 编译：`swiftc ... Scripts/benchmark.swift ... -o artifacts/p1g-performance-verify/benchmark/benchmark` (exit 0)
  - 运行：`artifacts/p1g-performance-verify/benchmark/benchmark` (exit 0, PASS)
  - 输出报告：`artifacts/p1g-performance-verify/benchmark/benchmark.json` (schemaVersion: 5)
- **Universal 打包与架构校验**：
  - `bash Scripts/build_app.sh --universal`：成功产出 `build/PhotoAtelier.app` (exit 0)
  - `lipo -info build/PhotoAtelier.app/Contents/MacOS/PhotoAtelier`：
    `Architectures in the fat file: build/PhotoAtelier.app/Contents/MacOS/PhotoAtelier are: x86_64 arm64`
  - `python3 Scripts/verify_app.py build/PhotoAtelier.app`：校验通过，4 个签名 dylib 与 55 个 XML 镜头文件完整一致 (exit 0)
- **全量测试套件**：`swift test -j 2` 全量 540 项测试 100% 通过（0 失败）。

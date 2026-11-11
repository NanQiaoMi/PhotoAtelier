# RAW 引擎评估：LibRaw 集成可行性（评估报告）

**日期**：2026-11-11
**性质**：评估批次（未改任何产品代码，`main` 无新增提交）
**结论先行**：**技术上完全可行，本机验证通过；策略上建议「降级回退」而非「替换主解码器」。真正卡进度的是真机 RAW 样本，不是技术。**

---

## 1. 背景

路线图待办（`docs/development-handover.md` §9.3）：评估 LibRaw（LGPL，动态链接）与 CoreML 降噪模型；RAW 专用高光重建。当前 RAW 路径完全依赖 `CIRAWFilter`（Apple 系统解码器），README 已声明「RAW 相机型号覆盖取决于 macOS 版本」。

**动机**：CIRAWFilter 不支持的相机/变体会直接报错隔离（[PhotoIO.swift:212](Sources/PhotoCore/PhotoIO.swift)），新相机在旧 macOS 上常出现解码空白。LibRaw 可作为受控的回退解码器扩大覆盖面。

---

## 2. 许可与分发合规（结论：可行，两个注意点）

### 2.1 许可结构

LibRaw 0.21.5 双许可：**LGPL-2.1 OR CDDL-1.0**，二选一（来源：[libraw.org/about](https://www.libraw.org/about)、[Homebrew formula](https://formulae.brew.sh/formula/libraw)）。其 dcraw 衍生代码已剥离 RESTRICTED/GPL2 部分，这正是双许可成立的前提。

### 2.2 与现有 Lensfun 的合规对比

| 维度 | Lensfun 0.3.4（现有） | LibRaw 0.21.5（若集成） |
|---|---|---|
| 许可 | LGPL-3.0+ | LGPL-2.1（更宽松）或 CDDL-1.0 |
| 集成方式 | 动态 dylib（`build/…/Frameworks/Lensfun/*.dylib`） | 同样可用动态 dylib 或静态链接进一个独立 dylib |
| 现有合规基建 | `THIRD_PARTY_NOTICES.md`、`verify_app.py` 包校验、许可目录 | 直接复用同一套机制 |
| Relink 义务 | 动态链接即满足 | 动态链接即满足；CDDL 路线连 relink 都不要求（文件级 copyleft，仅修改 LibRaw 源文件需开源） |

**注意点 1**：LGPL 要求最终用户可替换该库。现仓库 Lensfun 的做法（独立 dylib 放 `Frameworks/` + 随包许可文本 + `verify_app.py` 校验）已满足同等义务，LibRaw 照搬即可，**无新增合规负担**。

**注意点 2**：若选 CDDL-1.0 路线（更省事），修改 LibRaw 自身源码的部分必须开源；不改源码则无义务。集成时应避免 patch LibRaw 源码，把定制放在 Swift 侧。

---

## 3. 本机构建验证（全部通过）

在 `/tmp/libraw-eval`（临时目录，不入库）完成：

| 验证项 | 结果 |
|---|---|
| 源码获取 | LibRaw-0.21.5.tar.gz（1.5 MB），SHA-256 `a74a2e68…38305`，官网固定版本 |
| x86_64 构建 | `make -f Makefile.dist -j 12` **23.9s** 全量编译通过（12 核 32GB 本机） |
| **Universal 双架构** | 在 `Makefile.dist` 的 CFLAGS 加 `-arch x86_64 -arch arm64 -mmacosx-version-min=13.0` 后，`lib/libraw.a` 与 `libraw_r.a` 均为 **fat binary（x86_64 + arm64）** ✅ |
| 静态库体积 | 每个 2.8 MB（通用二进制）；链接后 app 增量约 1–2 MB |
| `raw-identify` 对非 RAW 输入 | 优雅报错 "Unsupported file format or not RAW file"，不崩溃 ✅ |
| **Swift 调用 C API 冒烟** | `swiftc` 链接 `libraw.a`，`@_silgen_name` 直调 `libraw_versionNumber/cameraCount/capabilities`：返回 0x1505（v0.21.5）、1181 相机型号、能力位正常 ✅ |
| 解码工作流 C API | `libraw_open_file/open_buffer/unpack/unpack_thumb/dcraw_process/mem_image` 全部导出，`libraw_c_api.cpp` 提供 Swift 可直接用的 C 接口层 ✅ |
| Xcode 14.3.1 / macOS 13.7 兼容 | 构建与运行均通过；`-mmacosx-version-min=13.0` 与项目 deployment target 一致 |

**与 Lensfun 分发模式的适配**：现仓库通过 `prepare_lensfun.py` 从固定 wheel 提取 dylib + 数据库。LibRaw 同样可以写一个 `prepare_libraw.py`：下载固定 SHA-256 的源码 → 本机编译（或直接预编译放 git LFS）→ 产出 `.dependencies/libraw/lib/libraw.dylib`。`build_app.sh` 的签名/校验流程已处理任意 dylib，无需改动。

---

## 4. 引擎能力对比与策略建议

### 4.1 能力对比（来源：[Apple CIRAWFilter 文档](https://developer.apple.com/documentation/coreimage/cirawfilter)、[SilicaRAW 解码器评估](https://github.com/raspverry/SilicaRAW/blob/main/docs/spikes/002-raw-decoder.md)、[LibRaw 相机支持页](https://www.libraw.org/supported-cameras)、[ApolloOne 实践](https://www.apollooneapp.com/_files/ugd/54d349_3c58d052d7404adca5acd948bf1874fc.pdf)）

| 维度 | CIRAWFilter（现有） | LibRaw 0.21.5 |
|---|---|---|
| 图像质量 | **更优**：Apple 官方 demosaic、相机厂商标定色彩、镜头校正、高光恢复 | dcraw 系算法，质量可用但无厂商标定 |
| 相机覆盖 | macOS 13 约 700+ 型号（不公开列表，随系统更新）；**新相机在旧 macOS 上缺失** | **1181 型号编译内建**（本机实测 `cameraCount=1181`），不依赖系统版本 |
| 高光恢复 | `highlightRecoveryEnabled`（API 级） | `params.highlight` 0–4 级（`blend_highlights`/`recover_highlights`） |
| 输出 | extended linear sRGB（项目已用 scene-linear） | 16bit linear/相机 RGB，需自行做色彩矩阵→工作空间转换 |
| RAW 9 CoreML 降噪 | **macOS 27 才有**（[WWDC26 Session 305](https://developer.apple.com/videos/play/wwdc2026/305/)），macOS 13 用户完全不可得 | 无 ML 降噪；有 FBDD 噪点参数（质量有限） |
| 威胁模型 | 闭源系统组件，行为随系统版本漂移 | 开源可审计、版本固定、SHA-256 锁定 |

### 4.2 策略：**CIRAWFilter 主解码 + LibRaw 回退**

不建议替换主解码器（会损失质量与色彩标定）。建议分层：

```
PhotoIO.load(RAW)
├─ 1. CIRAWFilter 解码成功 → 主路径（现有代码零改动）
├─ 2. CIRAWFilter 失败（rawReadError）→ LibRaw 回退：
│     open_file → unpack → dcraw_process(use_camera_wb=1, output_bps=16,
│     highlight=1, no_auto_bright=1) → 相机RGB 16bit
│     → CIImage + 色彩标签 → 既有 extended-linear sRGB 渲染路径
└─ 3. 两者都失败 → 现有的显式报错隔离（不变）
```

关键设计约束（沿用项目既有原则）：
- 回退解码在 `analysis.decoder = "LibRaw"` 中如实标注（与现有 `"decoderEstimated"` 白点标注同一诚实原则）；
- LibRaw 路径关闭其全部「自动美化」（`no_auto_bright=1`、`bright=1`、曝光不改），保持 scene-linear 语义与 CIRAWFilter 路径一致；
- 16bit 相机 RGB → 线性 sRGB 需要 LibRaw 的 `color.cam_xyz` 色彩矩阵自行构建 CIICCProfile 或手写 3×3 矩阵 kernel——这是集成中最有技术含量的部分，约 200–400 行 Swift + 一个 CIColorKernel。

### 4.3 工作量估算

| 工作项 | 规模 |
|---|---|
| `CLibRawBridge` target（modulemap + C 垫片） | ~100 行 C 头 + Package.swift 改动 |
| `prepare_libraw.py`（固定版本下载/编译/校验，对齐 `prepare_lensfun.py` 模式） | ~150 行 Python |
| Swift 回退解码器 + 色彩矩阵转换 | ~400 行 |
| Recipe 版本门禁（回退路径不进配方，仅导入层行为，**可能不需要新版本**——待实现时定） | 0 或小 |
| 测试（合成 DNG fixture 可自造；真机 RAW 样本另需） | ~200 行 |
| **合计** | **约 3–4 个工作日**（单人） |

### 4.4 CoreML 降噪结论（本期不做）

Apple 的 AI 降噪在 **RAW 9 / macOS 27** 才提供（[WWDC26](https://developer.apple.com/videos/play/wwdc2026/305/)），项目 target 是 macOS 13，不存在可用的系统级 ML 降噪 API；自训/引入第三方 CoreML 降噪模型涉及模型许可、体积（数百 MB）与「离线隐私」定位冲突，按 gap-analysis §6 边界**维持不做**，继续用现有启发式降噪（v7 门禁）。macOS 27 普及后可零成本吃到系统升级红利（opt-in `decoderVersion = .version9`）。

---

## 5. 阻塞项与决策点

**唯一硬阻塞：本机没有任何 RAW 样本**（桌面/下载/图片库全文索引均为 JPEG/PNG，`mdfind` 零命中）。没有真机 RAW 文件就无法：
- 验证 CIRAWFilter 对你相机的实际覆盖（也许根本不需要 LibRaw 回退）；
- 评估 LibRaw 输出与 Apple 输出的色彩一致性；
- 做质量验收（A/B 对比、高光恢复实测）。

**需要你提供**（任一即可解锁）：
1. 任意 1–3 张你自己相机拍的 RAW（CR3/NEF/ARW/RAF/DNG 均可），放到如 `~/Desktop/RAW-samples/`（只读使用，不入库）；
2. 或者直接告诉我相机型号，我先查 LibRaw/Apple 覆盖表判断是否真的需要回退。

**决策点**（拿到样本后需要确认）：
- [x] 采用「CIRAWFilter 主 + LibRaw 回退」分层（已确认，2026-11-11）；
- [x] 许可路线：**LGPL-2.1**，跟随 Lensfun 动态链接分发模式（已确认，2026-11-11）；
- [x] 回退路径在「分析」页如实标注解码器来源（`analysis.decoder = "LibRaw"`，已确认，2026-11-11）。

---

## 6. 本次评估的验证记录

| 项 | 命令/证据 | 结果 |
|---|---|---|
| 源码完整性 | `shasum -a 256 LibRaw-0.21.5.tar.gz` | `a74a2e68303d…c9038305` |
| x86_64 全量构建 | `make -f Makefile.dist -j 12` | 23.9s，exit 0 |
| Universal 构建 | CFLAGS 加 `-arch x86_64 -arch arm64` 后 rebuild | `lipo -info` 确认 fat binary |
| 非 RAW 优雅失败 | `raw-identify <jpg>` | 明确报错不崩溃 |
| Swift C API 冒烟 | `swiftc -I -L … -lraw` + `@_silgen_name` 直调 | 版本/相机数/能力位全部正确 |
| 本机 RAW 样本搜索 | `mdfind kMDItemContentTypeTree=="public.camera-raw-image"` | 零命中（阻塞项） |

*临时构建产物在 `/tmp/libraw-eval/`（不入库、可随时删除）；本批次未修改仓库任何文件。*

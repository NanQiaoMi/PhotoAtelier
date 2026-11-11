# P1-B 功能交付说明：证件照/换背景 / 修复画笔 / 本地客户交付页

**日期**：2026-11-04
**分支**：`feat/p1b-retouch-delivery`（基线 `2ea97cb`，计划提交 `06ff345`，实现提交见文末）
**上位计划**：[P1-B 实施计划](p1b-implementation-plan.md)｜**上一批**：[P1 交付说明](p1-release-notes.md)

本批继续补齐差距分析 P1 的剩余高价值能力：证件照/换背景、手动修复画笔/仿制图章、本地客户交付页。全部本地运行、不联网、不读取用户私人照片、不引入第三方运行时依赖；算法为启发式 v1，**不宣称与商业抠图/美型/选片系统等同**。

---

## 1. 功能清单

### 1.1 证件照 / 换背景（B1 / B4）

右栏新增「证件照」页签（页签顺序：分析 / 基础 / 局部 / 人像 / 追色 / 导出 / 调色 / **证件照**）：

| 能力 | 说明 | 边界 |
|---|---|---|
| 人物抠图 | Vision 人物分割 + 边缘细化/羽化/去色边，输出前景 alpha | 发丝/半透明/复杂背景仍可能不完美；无人物时显式跳过/报错，不静默改图 |
| 背景替换 | 纯色（红/蓝/白/灰/自定义 HEX）或本地图片背景；可选阴影合成 | 启发式 v1，非商业级抠图；背景图为本地文件，缺失显式报错 |
| 证件照尺寸 | 一寸 25×35mm / 二寸 35×49mm / 小一寸 22×32mm / 大一寸 33×48mm / 小二寸 35×45mm（300 DPI 像素） | 尺寸为常用预设，特殊规格需后续扩展 |
| 裁剪/构图 | 基于人脸框的头部比例、水平居中、留白/偏移/膨胀 | 人脸检测失败时显式跳过并说明 |
| 打印排版 | 5 寸/6 寸/A4 纸张、行列/间距/边距的排版几何预览 | 生成几何供后续打印/导出；真实打印色彩未验收 |
| 管线位置 | 追色之后、局部蒙版之前；裁剪改变 extent 时会提示复核蒙版 | 改背景后依赖背景颜色的局部调整需复核 |

### 1.2 修复画笔 / 仿制图章（B2 / B5）

「人像」页签新增「修复 / 仿制画笔 v1」区：

| 能力 | 说明 | 边界 |
|---|---|---|
| 修补 heal | 低频 + 邻近纹理的启发式填充；非生成式、不重建结构 | 大面积/结构性缺陷效果有限；可撤销 |
| 仿制 clone | 按来源偏移原样复制像素，可调半径/强度/羽化 | 来源偏移不自动跟踪；换图会清空来源 |
| 笔迹交互 | 画布拖拽/单击，整笔撤销；与液化/蒙版互斥 | 真实鼠标笔迹交互未自动化 |
| 管线位置 | 镜头效果之后、人像修复之前；无笔迹完全跳过 | 手动修补后的像素参与人像测量 |
| 配方 v12 | 笔迹列表存配方，非中性字段需 v12；旧配方保持原路径 | 笔迹数量/半径有上限 |

### 1.3 本地客户交付页（B3 / B6）

「导出」页新增「导出客户交付页（HTML + 接触表 PDF）」区：

| 能力 | 说明 |
|---|---|
| 静态 HTML 相册 | 内嵌 CSS、相对路径缩略图/预览图，无 JS、无外链、无网络请求（file:// 打开） |
| 接触表 PDF | CoreGraphics 网格排版，A4/Letter 纸张、标题/页码、缩略图 aspect-fit |
| 隐私剥离 | 不复制 GPS/相机序列号/EXIF/XMP/Artist，产物字节扫描无隐私标记、无绝对路径 |
| 批量集成 | 批量导出后生成到 `output/delivery[-N]`（唯一不覆盖），manifest **v4** 记录路径/设置/照片数 |
| 单张动作 | 导出当前照片的交付页（后台队列，不阻塞 UI） |
| 配方 v12 | 交付页设置存配方，非中性需 v12；旧配方缺字段保持原路径 |

- 边界：非云、非选片系统；交付预览来自「已导出文件」（可能已 resize/水印，语义为实际交付物）；真实打印/纸张与审美未验收；GUI 点选未自动化。

---

## 2. 管线顺序与配方 v12

**最终管线顺序（v12）**：

```
基础影调 → 全局几何 → 液化/美型 → 调色工具（曲线/HSL/分级）
→ 镜头效果（暗角/色差）→ 修复画笔/仿制图章 → 人像修复 v1
→ AI 追色 → 背景替换/证件照（裁剪）→ 局部蒙版/细节 → LUT
→ 输出色域映射 → 导出（水印/缩放/模板/交付页）
```

- 修复画笔在人像之前：手动修补后的像素参与人像测量。
- 背景替换在追色之后、局部之前：局部蒙版坐标不变，但背景颜色已替换；文档标注「改背景后需复核依赖背景颜色的局部调整」。
- 配方版本 **v12**：新增 `certificatePhoto`、`repairBrush`、`deliveryPage` 等字段要求 v12；旧 v1–v11 配方缺字段保持原像素路径；非中性新字段出现在旧版本配方中由 `validateVersion` 拒绝，不静默降级；保存含新字段的配方自动升级 v12。
- 批量清单 schema **v4**（新增交付页字段）；旧清单读取兼容。

---

## 3. 验证与证据

| 检查 | 结果 | 证据 |
|---|---|---|
| `make check` | 退出码 0，**458 tests / 0 failures**（146.2s） | `/tmp/p1b_final_check.log` |
| `bash Scripts/build_app.sh` | 退出码 0，4 签名 dylib / 55 XML / 许可 / portable paths 通过；`codesign --verify --deep --strict` 与 `python3 Scripts/verify_app.py` 均 exit 0 | 最终构建日志 |
| 重建包 `UI_SMOKE_FORCE_FAIL_ATTEMPTS=2 bash Scripts/ui_smoke.sh` | **exit 0：attempt 3/3、8 页签、14 截图**（人像:bottom/导出:delivery/调色:bottom/证件照:bottom）；app sha256=301080f0…、commit=a2361c7；重试策略实测生效 | `artifacts/p1b-b7-verify/ui-smoke/` |
| 最终树 benchmark | 编译/运行 exit 0，`benchmark: PASS`；schemaVersion 3；mattingAndBackground 2714.4ms/9、repairBrush 5130.2ms/9、deliveryPage 3426.2ms；peak RSS 5172.8MB | `artifacts/p1b-b7-verify/benchmark-final/benchmark.json` |
| 定向测试 | PersonMatting 8、IDPhotoLayout 8、RepairBrush 13、DeliveryGallery 13、ColorCompatibility 37、Batch 18、IO 19、Engine 21、PortraitRetouch 17、LocalMask 19、SceneAdaptive 15 等 | 各工作项报告 |
| 应用自检 | `APP_SMOKE PASS · 36 checks` + `PORTRAIT_CONTRACT_SELF_CHECK PASS`（certificateVersion=12） | `--self-test` 证据目录 |

**未验证项（不得当作已验收）**：
1. 真实照片的抠图/证件照/修复画笔/交付页审美与打印验收（需用户授权样片后单独执行）。
2. 真实鼠标笔迹/证件照面板/交付页 GUI 点选未自动化（ui_smoke 只覆盖主路径与面板渲染）。
3. 24MP 大图抠图/修复/交付页生成性能、批量吞吐未基准（benchmark 为 debug 对象 + 合成语料）。
4. Apple Silicon 原生构建与运行（本机 Intel；依赖仍 x86_64）。
5. 发丝/半透明/复杂背景抠图、大面积结构缺陷修补、特殊证件照规格、真实打印纸张色彩未验收。
6. 已知非阻塞 nit：证件照页签 onAppear 条件使用 `certificatePhoto != nil`（关闭开关后可能多一次无 Vision 的预览）；修复画笔半径滑杆与引擎范围已对齐；交付页 UI 滑杆范围窄于模型等记录为后续 UI 改进项。

---

## 4. 文件地图

- 证件照/换背景核心：`Sources/PhotoCore/{PersonMatting,BackgroundReplacement,IDPhotoLayout}.swift`；集成：`Models/PhotoEngine/AppModel/ContentView/IDPhotoPanel.swift`
- 修复画笔核心：`Sources/PhotoCore/RepairBrush.swift`；集成：`Models/PhotoEngine/AppModel/ContentView/PhotoCanvas/PortraitRetouchPanel.swift`
- 交付页核心：`Sources/PhotoCore/DeliveryGallery.swift`；集成：`Models/BatchProcessor/AppModel/ContentView.swift`
- 测试：`Tests/PhotoCoreTests/`（新增 4 个测试文件 + 既有文件扩展）
- 质量工具：`Scripts/benchmark.swift`、`Scripts/ui_smoke.sh`（B7 适配）

---

*本说明与代码同时提交；证据产物在 `artifacts/`（gitignored，不入库）。*

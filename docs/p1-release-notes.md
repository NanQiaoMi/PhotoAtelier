# P1 功能交付说明（第一批）：调色工具 / 面部液化美型 / 水印导出

**日期**：2026-11-04
**分支**：`feat/p1-color-beauty`（基线 `2af5ccd`，计划提交 `f1b3066`，实现提交见文末）
**上位计划**：[P1 实施计划](p1-implementation-plan.md)｜**上一批**：[P0 交付说明](p0-release-notes.md)

本批交付对应差距分析 P1 的第一批：调色工具扩展、面部液化/美型、水印导出。全部本地运行、不联网、不读取用户私人照片、不引入第三方运行时依赖；算法为启发式 v1，**不宣称与商业 AI 美型/专业调色软件等同**。

---

## 1. 功能清单

### 1.1 调色工具扩展（P1-1 / P1-5）

右栏新增「调色」页签（页签顺序：分析 / 基础 / 局部 / 人像 / 追色 / 导出 / **调色**）：

| 工具 | 说明 | 边界 |
|---|---|---|
| HSL 8 色相 | 红/橙/黄/绿/青/蓝/紫/洋红八带，每带色相偏移、饱和度、明度；平滑带间权重 | 低彩度中性色保护，避免染灰；不是任意色相拾取器 |
| RGB / 亮度曲线 | 三通道 + 亮度曲线，2–16 控制点，单调三次插值（无过冲），显示编码 sRGB 语义 | 不提供参数曲线/直方图拖拽；曲线以 LUT 实现 |
| 颜色分级 | 阴影/中间调/高光三色轮 + 全局偏色 + balance，按亮度平滑混合 | 中性保护与限幅；不是完整 3-way 校色台 |
| 镜头效果 | 暗角（强度/中点/羽化/圆度）+ 横向色差（红/蓝径向位移，小幅度） | 不替代 Lensfun 的镜头标定校正；暗角为创意效果 |
| 调色管线位置 | 基础影调与几何之后、镜头效果之前；先于 LUT/局部/人像蒙版测量 | 见 §2 |

- 全中性 = 像素不变；旧配方（v1–v10）缺字段走原路径。
- 已知限制：HSL 与分级为启发式保护，极端强度可能局部偏色；真实照片审美验收未执行。

### 1.2 面部液化 / 美型（P1-2 / P1-6）

「人像」页签新增液化区：

| 能力 | 说明 | 边界 |
|---|---|---|
| 7 种脸型预设 | 经典/幼态/英气/少年/圆脸/长脸/方脸，映射到轮廓/眼/鼻/嘴/下巴参数 | 预设是启发式参数组合，不是 AI 骨相重塑 |
| 6 个滑杆 | 瘦脸 / 小脸 / 大眼 / 鼻翼 / 嘴唇 / 下巴，−1…1，与预设叠加并夹取到合法范围 | 幅度有上限；极端组合可能不自然 |
| 手动液化画笔 | push / rebuild / smooth 三种模式，半径/强度可调，画布上直接拖拽；整笔可撤销 | 画笔覆盖为椭圆足迹（按宽/高比例），与作用区域一致 |
| 背景直线保护 | 位移幅度上限 + 场平滑 + 脸框外衰减 | 只限制明显弯曲，不保证所有直线完全不动 |
| 管线位置 | 基础影调 → 几何（旋转/透视/自动水平/Lensfun）→ 液化 → 调色/人像/局部/LUT | 液化改变几何，**修改液化后需复核既有蒙版**；配方中蒙版坐标按变形后图像归一化 |
| 无脸时 | 脸型/滑杆禁用并说明；手动笔迹仍可应用 | 人脸地标来自本机 Vision，侧脸/遮挡/小脸可能检测失败 |

- 位移有界、恒等零重采样；>4MP 图像用网格上采样以限制内存。
- 已知限制：真实鼠标笔迹交互未自动化（应用自检 + ui_smoke 覆盖面板渲染）；24MP 性能未基准；真实照片审美未验收。

### 1.3 水印导出（P1-3 / P1-7）

「导出」页新增水印区：

| 能力 | 说明 |
|---|---|
| 文字水印 | 文本、系统字体、颜色、透明度、缩放、旋转、可选阴影/描边 |
| 图片水印 | 本地 PNG/JPEG（保留 alpha）、缩放、透明度、旋转、位置 |
| 位置 | 9 宫格 + 自定义偏移，自动夹取在画布内；旋转/大字号自动缩小不裁切 |
| 双版本 | 主输出 = 带水印（沿用原名），副本 = `_nowatermark` 后缀；同属一份交付物，任一失败回滚 |
| 批量清单 | manifest schema **v3**，`exportSummary` 记录实际水印参数（kind/anchor/opacity/scale/rotation/text|imagePath/dual），逐张记录 applied 与两个输出路径 |
| 兼容 | 水印字段可选；非中性水印 + 旧版本配方 → v11 门禁拒绝；v1–v10 无水印路径像素/命名不变 |

- 水印在缩放（resize）之后、白底合成/编码/原子写入之前叠加；缺图/损坏图显式报错且不产生半成品。
- 已知限制：系统字体依赖（跨 macOS 版本字形度量可能不同）；单行文字、非排版工具；GUI 点选未自动化；真实照片审美未验收。

---

## 2. 管线顺序与配方 v11

**最终管线顺序（v11）**：

```
基础影调（曝光/WB/五区 EV/对比/饱和/高光/阴影）
→ 全局几何（旋转/透视/自动水平/Lensfun 畸变）
→ 液化/美型
→ 调色工具（曲线 → HSL → 颜色分级）
→ 镜头效果（暗角/横向色差）
→ 人像修复 v1
→ AI 追色
→ 局部蒙版/细节
→ LUT
→ 输出色域映射
```

- 保留 P0 的「基础影调 → 几何」旧顺序以维持 v1–v10 配方像素路径；液化放在几何之后、调色/人像/蒙版之前。
- 配方版本 **v11**：新增 `colorTools`（HSL/曲线/分级）、`lensEffects`、`liquify`、`watermark` 字段要求 v11；旧 v1–v10 配方缺字段保持原像素路径；非中性新字段出现在旧版本配方中由 `validateVersion` 拒绝，不静默降级；保存含新字段的配方自动升级 v11。
- 批量清单记录逐张调色/液化/水印状态；schema v3（新增水印字段）。

---

## 3. 验证与证据

| 检查 | 结果 | 证据 |
|---|---|---|
| `make check` | 退出码 0，**398 tests / 0 failures**（119.5s） | `/tmp/p1_final_check2.log` |
| `bash Scripts/build_app.sh` | 退出码 0，4 签名 dylib / 55 XML / 许可 / portable paths 通过；`codesign --verify --deep --strict` 与 `python3 Scripts/verify_app.py` 均 exit 0 | 最终构建日志 |
| 重建包 `bash Scripts/ui_smoke.sh` | 待最终验收填写（7 页签/水印区） | `artifacts/p0-20261103/ui-smoke/` 或 `artifacts/p1-4-verify/` |
| 最终树 benchmark | 编译/运行 exit 0，`benchmark: PASS`；schemaVersion 2，新增调色/镜头效果 4288ms/9 图、液化 6686ms/3 图、水印 3884ms/9 图，peak RSS 4066MB | `artifacts/p1-4-verify/benchmark/benchmark.json` |
| 定向测试 | ColorToolsTests 28、LiquifyWarpTests 9、WatermarkTests 16、ColorCompatibilityTests 34、IOTests 19、BatchTests 14、PortraitRetouchTests 12 等 | 各工作项报告 |
| 应用自检 | `APP_SMOKE PASS · 36 checks` + `PORTRAIT_CONTRACT_SELF_CHECK PASS`（liquifyVersion=11） | `--self-test` 证据目录 |

**未验证项（不得当作已验收）**：
1. 真实照片的调色/液化/水印审美与画质评审（需用户授权样片后单独执行）。
2. 真实鼠标笔迹/水印 GUI 点选/系统面板交互未自动化（ui_smoke 只覆盖主路径与面板渲染）。
3. 24MP 大图液化/调色性能、批量双版本吞吐未基准（benchmark 为 debug 对象 + 合成语料）。
4. Apple Silicon 原生构建与运行（本机 Intel；依赖仍 x86_64）。
5. P1-7 评审遗留非阻塞 nit：水印 UI 缩放滑杆 0.2–4、旋转 ±45° 窄于模型允许范围（0.02–20、±180°）；双版本开关在水印无效状态下仍可打开（批处理会忽略）；结构非法水印的批量 fail-fast 缺专门测试（代码已实现）。这些记录为后续 UI/测试改进项，不影响已批准行为。

---

## 4. 文件地图

- 调色核心：`Sources/PhotoCore/{ColorTools,ColorCurves,ColorGrading,LensEffects}.swift`；集成：`Models/PhotoEngine/AppModel/ContentView/ColorToolsPanel.swift`
- 液化核心：`Sources/PhotoCore/{LiquifyWarp,FaceReshape}.swift`；集成：`Models/PhotoEngine/AppModel/ContentView/PortraitRetouchPanel/PhotoCanvas.swift`
- 水印核心：`Sources/PhotoCore/WatermarkRenderer.swift`；集成：`Models/PhotoIO/BatchProcessor/ContentView/AppModel.swift`
- 测试：`Tests/PhotoCoreTests/`（新增 3 个测试文件 + 既有文件扩展）
- 质量工具：`Scripts/benchmark.swift`、`Scripts/ui_smoke.sh`（P1-4 适配）

---

*本说明与代码同时提交；证据产物在 `artifacts/`（gitignored，不入库）。*

# P2-A 功能交付说明：人像发型与高阶骨相美型（高颅顶、发际线微调、丰太阳穴）

> 分支: `feat/p2a-hair-cranial-reshaping`  
> 基线: `a638f8c`  
> 日期: 2026-11-06  
> 里程碑: P2 阶段首发里程碑 (Milestone P2-A: Hair & Cranial Reshaping)

---

## 1. 概述与背景

在专业人像摄影修图（对照 PixelCake / 像素蛋糕与商业影楼级标准）中，**“头包脸”** 的头面比例和流畅的骨相轮廓是决定人像年轻感与高级感的关键。

作为 P2 阶段（高阶人像发型美型与商业交付）的首发功能，**P2-A** 在现有的 `FaceReshape`（五官液化与面型轮廓）纯向量形变场引擎基础上，扩展实现了针对头部发型与高阶骨相的 3 个人气功能：
1. **高颅顶 / 颅顶增高 (`cranialTop`)**：
   - 向上（Core Image +y）柔和拉升头顶发量与颅顶区域，实现视觉“头包脸”，解决发型扁塌贴头皮的问题，显著优化头脸比；
2. **发际线微调 (`hairline`)**：
   - 向下（Core Image -y）自然调整发际线上缘，填补过宽额头与后移发际线，亦支持反向拉升过窄额头；
3. **丰太阳穴 (`temple`)**：
   - 向两侧水平外展（左侧 -x、右侧 +x）颞窝区域，平滑外眼角/眉尾到颧弓上方的凹陷过渡，重构饱满圆润的年轻态外轮廓。

---

## 2. 核心架构与技术实现

### 2.1 纯向量形变场与无感集成 (`WarpField`)
- 依托 PhotoAtelier 既有的 `WarpField`（`CIWarpKernel` / Metal 栅格插值）架构，完全在 Core Image / GPU 原生着色器上运行，零第三方模型依赖，单张处理延迟 < 8ms；
- 继承了 `backgroundProtection` 边缘渐变保护机制，并将保护区域自适应纵向上延至 `boundingBox.height * 1.55`，既给颅顶发型拉升提供充足形变空间，又彻底防止背景直线被牵连弯曲；
- 保持与手动修容液化笔刷（`strokes`）的完全正交叠加。

### 2.2 确定性几何地标推导 (`FaceReshapeGeometry`)
- 从 Vision 68 点人脸地标中提取眉毛上缘点集合与下巴最低点，推导垂直面高 `faceHeight`；
- **颅顶锚点 (`cranialCenter`)**：定位在 `(midX, min(0.98, eyebrowTopY + 0.50 * faceHeight))`，辅以宽半径（`boundingWidth * 0.75`）平滑高斯衰减，确保发丝整体蓬松不产生局部尖锐凸起；
- **发际线锚点 (`hairlineCenter`)**：三锚点协同（中央主锚点 + 左右副锚点），避免单点拖曳导致额头发际线呈三角突起，过渡自然；
- **太阳穴锚点 (`templeLeft` / `templeRight`)**：结合眉梢外侧端点与轮廓上端，向左/向右径向扩展，有效抚平太阳穴凹陷；
- 针对无眉毛或缺少部分地标的特殊/合成图像，提供基于 `boundingBox` 与轮廓的鲁棒兜底计算。

### 2.3 严格向后兼容与预设融合
- **Codable 向后兼容**：`cranialTop`、`hairline`、`temple` 默认均为 `0`，历史配方（v1~v14）反序列化时缺失字段自动解码为 `0`；
- **零漂移中性保障**：三个参数为 `0` 时完全中性（零位移向量），不改变任何原有像素；
- **面型预设（`FaceShapePreset`）美学调优**：
  - `youthful`（幼态）：+0.25 高颅顶，+0.10 发际线，+0.15 丰太阳穴；
  - `heroic`（英气）：+0.15 高颅顶，+0.10 丰太阳穴；
  - `boyish`（少年）：+0.20 高颅顶，+0.05 发际线，+0.10 丰太阳穴；
  - `round`（圆脸）：+0.30 高颅顶（纵向拉长比例），+0.05 丰太阳穴；
  - `long`（长脸）：+0.20 发际线（缩短额头中庭），+0.20 丰太阳穴；
  - `square`（方脸）：+0.20 高颅顶，+0.15 丰太阳穴。

### 2.4 原生 UI 面板响应式集成
- 在 `PortraitRetouchPanel.swift` 中为“面部轮廓与液化”新增 3 个滑块：`高颅顶`、`发际线`、`丰太阳穴`，支持 `-1...1` 双向微调，实时绑定 `liquify.parameters`；
- 采用 SwiftUI 多 `Group` 组合规避 Trailing Closure 10 视图上限，确保渲染性能与编译严谨。

---

## 3. 验收与验证证据

| 检查项 | 命令 | 退出码 | 关键结果 |
|---|---|---|---|
| 单元测试 (全包回归) | `swift test -j 2` | 0 | **541 tests passed, 0 failures (164.2s)** |
| 针对性液化测试 | `swift test -j 2 --filter LiquifyWarpTests` | 0 | 10 tests passed (含颅顶向上、发际线向下、太阳穴外展、向后兼容) |
| 通用架构应用构建 | `bash Scripts/build_app.sh --universal` | 0 | 生成 arm64 + x86_64 双架构应用及签名验证通过 |
| 独立应用包验证 | `python3 Scripts/verify_app.py build/PhotoAtelier.app` | 0 | 4 signed dylibs, 55 XML profiles, portable load paths |
| UI 自动化冒烟测试 | `UI_SMOKE_OPEN_METHOD=cli UI_SMOKE_FAST=1 bash Scripts/ui_smoke.sh artifacts/p2a-verify/ui-smoke` | 0 | **Attempt 1/3 PASS**: 8 检查器页签切换，18 张高分截图捕获无异常 |

---

## 4. 交付清单

- `Sources/PhotoCore/FaceReshape.swift`:
  - 扩展 `FaceReshapeParameters` 结构体：新增 `cranialTop`、`hairline`、`temple` 字段、Codable 解码与边界收敛；
  - 扩展 `FaceShapePreset`：为各风格面型预置骨相与发型美学参数；
  - 扩展 `FaceReshapeGeometry`：增设颅顶、发际线、左右太阳穴几何计算与容错兜底；
  - 扩展 `FaceReshapeEngine`：实现三项位移场向量叠加计算与保护区自适应扩展。
- `Sources/PhotoAtelier/PortraitRetouchPanel.swift`:
  - 新增 `高颅顶`、`发际线`、`丰太阳穴` 3 个交互滑块。
- `Tests/PhotoCoreTests/LiquifyWarpTests.swift`:
  - 增补方向性位移断言与历史 JSON 解码向后兼容测试。
- `docs/p2a-implementation-plan.md`:
  - 详细实施计划与验收检查清单。
- `docs/p2a-release-notes.md`:
  - 本交付文档。

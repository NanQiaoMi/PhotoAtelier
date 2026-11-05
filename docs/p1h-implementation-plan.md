# P1-H Implementation Plan: 真实照片审美验收体系 (Aesthetic Review System & Real Photo Corpus)

> 分支: `feat/p1h-aesthetic-acceptance`  
> 基线: `e3dd4b7`  
> 状态: 进行中 (P1-H)

---

## 1. 目标与验收标准 (Goals & Acceptance Criteria)

### 1.1 核心目标
1. **建立 6 大题材真实照片样片集规范 (Corpus Taxonomy & Specifications)**:
   - 覆盖 6 大主流拍摄场景：人像 (Portrait: 特写/户外/室内/多脸)、风光 (Landscape: 自然/城市/蓝天)、夜景 (Night: 城市夜景/高对比)、逆光 (Backlight: 强逆光/发丝光/面部提亮)、高调 (High-Key: 浅色背景/大面积留白)、暗调 (Low-Key: 黑色背景/深沉质感)。
   - 样片管理底线：样片必须严格只读、绝不入库 Git、处理前后通过 SHA-256 核验确保原图零篡改；输出使用匿名化 ID（如 `sample-portrait-01`），绝不泄露拍摄者或客户真实文件名/路径/元数据。
2. **审美评测自动化执行引擎 (`Scripts/evaluate_aesthetic.swift`)**:
   - 编译并运行基于 `PhotoCore` 的自动化审美评测脚本。
   - 针对每张真实照片执行 6 大核心管线方案：
     - `Baseline`: 原始样片
     - `Scene_Adaptive`: 场景识别与自适应三方案（自然平衡、清晰通透、柔和淡雅）
     - `Portrait_Enhance`: 智能人像修复（祛瑕疵、中性灰双频平整、牙齿美白、眼白提亮、肤色统一）
     - `Makeup_Retouch`: 完整妆容（唇色/眉色/腮红/眼影/眼线/睫毛/美瞳/高光/修容）
     - `Film_Style`: 经典胶片自适应（Classic Chrome / ASTIA / ETERNA 调色与保护）
     - `Full_Pipeline`: 商业成片组合管线（场景校正 + 人像增强 + 妆容塑颜 + 胶片影调）
   - 自动生成高保真前后对比图（Before / After JPEG），以及 512×512 关键微观区域 1:1 细节切片（眼周睫毛、发丝高光、面部毛孔皮肤、高光阴影边界）。
   - 自动生成离线交互式 HTML 评审相册（支持 Before/After 拖拽对比、1:1 切片放大、评分表录入）与 `aesthetic-manifest.json` 机器可读清单。
3. **固定评审模板与 5 维量化评分标准 (Scoring Rubric & Review Template)**:
   - 建立文档化的 5 维量化评审体系（1–5 分制）：
     1. **微观质感与毛孔保留度 (Skin Texture & Micro-details)**
     2. **色彩还原与色调协调度 (Color Fidelity & Harmony)**
     3. **高光与暗部过渡平滑度 (Dynamic Range & Tonal Gradation)**
     4. **几何形变与边缘自然度 (Geometry & Edge Integrity)**
     5. **商业成片交付度 (Commercial Delivery Readiness)**
   - 产出标准评审模板规范 `docs/aesthetic-review-system.md`。
4. **测试与回归全闭环**:
   - 全量 540 项测试全绿，确认真实照片评测与合成回归测试严格解耦。
   - 产出 `docs/p1h-release-notes.md`，更新交接文档与 README。

### 1.2 验收项清单
- [x] 编写并建立 `docs/aesthetic-review-system.md` 规范文档，明确 6 大场景样片分类、评分细则与评审模板。
- [x] 编写 `Scripts/evaluate_aesthetic.swift`，支持指定输入样片目录、输出目录，输出前后对比图、1:1 局部切片、HTML 评审看板与 manifest JSON。
- [x] 成功编译并在真实样片上运行 `evaluate_aesthetic.swift`，验证输出完整且原图 SHA-256 零变更。
- [x] 全量 `swift test -j 2` 单元测试通过（540 tests, 0 failures）。
- [x] 更新 `README.md` 与 `docs/development-handover.md`（标记 P1-H 完成）。
- [x] 产出 `docs/p1h-release-notes.md` 并完成 `--no-ff` 分支合并。

---

## 2. 架构设计与评测流水线

```
┌─────────────────────────────────────────────────────────────────┐
│               Real Photo Input Corpus (Read-Only)               │
│                                                                 │
│  /Users/mimi/Desktop/图片 (or user-provided folder)             │
│  ├── Portrait (特写 / 室内 / 户外 / 多人)                       │
│  ├── Landscape (自然 / 城市 / 天空)                             │
│  ├── Night / Backlight / High-Key / Low-Key                     │
│  └── SHA-256 Pre/Post Verification (Zero-Modification Guarantee)│
└─────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│             Scripts/evaluate_aesthetic.swift Engine             │
│                                                                 │
│  Pipelines executed per photo:                                  │
│  ├── 1. Baseline (Raw / Original)                               │
│  ├── 2. Scene Adaptive (Natural / Punchy / Soft)                │
│  ├── 3. Portrait Retouch (Blemish / Frequency Sep / Teeth / Eyes)│
│  ├── 4. Makeup & Sculpt (Lip / Brow / Cheek / Eyelash / Highlight)│
│  ├── 5. Film Adaptation (Classic Chrome / ASTIA / ETERNA)       │
│  └── 6. Commercial Master Pipeline (Combined full flow)         │
│                                                                 │
│  Generators:                                                    │
│  ├── Before / After Full-Res JPEG pairs                         │
│  ├── 512x512 1:1 Micro-Inspection Crops (Eyes, Hair, Skin)      │
│  ├── aesthetic-manifest.json                                    │
│  └── index.html Interactive Review Gallery                      │
└─────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│               Aesthetic Review System & Rubrics                 │
│                                                                 │
│  docs/aesthetic-review-system.md:                               │
│  ├── 5-Dimension Scoring Rubric (1-5 Scale)                     │
│  ├── Sample Metadata Registry (24 Canonical Samples)            │
│  └── Archival Review Scorecards & Guidelines                    │
└─────────────────────────────────────────────────────────────────┘
```

---

## 3. 回滚方案
若方案存在偏差，可切回分支基线 `e3dd4b7`。

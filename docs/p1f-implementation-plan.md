# P1-F Implementation Plan: 妆容与人像精修增强 (Makeup & Retouch Enhancement)

> 分支: `feat/p1f-makeup-retouch-enhancement`  
> 基线: `a4f4af3`  
> 状态: 进行中 (P1-F)

---

## 1. 目标与验收标准 (Goals & Acceptance Criteria)

### 1.1 核心目标
1. **眼部精修扩展 (Eye Makeup & Iris Refinement)**:
   - **眼线 (Eyeliner)**: 沿上眼睑边缘轮廓自适应羽化描绘与加深 (`eyelinerIntensity`, `eyelinerColor`)。
   - **睫毛加密 (Eyelash Density)**: 沿上眼睑外沿微扩展自然浓密暗化 (`eyelashIntensity`)。
   - **美瞳 / 虹膜润色 (Iris / Pupil Tinting)**: 基于瞳孔地标及眼球范围，构建柔和虹膜蒙版，支持美瞳色相、饱和度与微提亮 (`irisIntensity`, `irisColor`)。
   - **眼神光增强 (Catchlight)**: 增强瞳孔高光反射微光，提升肖像眼神神采 (`catchlightIntensity`)。
2. **立体高光与面部修容 (Highlight & Contour)**:
   - **面部高光 (Face Highlight)**: 基于鼻梁、额骨中段及苹果肌高点生成自然提亮柔光 (`highlightIntensity`)。
   - **暗部修容 (Face Contour)**: 基于下颌轮廓线与侧颊构建渐进阴影柔和加深 (`contourIntensity`)。
3. **严格非破坏与配方门禁 (Recipe v14 Gating)**:
   - 配方支持版本 14，`Recipe.validateVersion` 增加 v14 门禁。
   - 当使用眼线/睫毛/美瞳/眼神光/高光/修容任意增强参数时，自动提升为 v14 配方；仅使用基础妆容（唇/眉/腮红/眼影）时保持 v13 配方。
   - 全中性状态下不修改任何输出像素（100% byte & pixel transparent）。
   - 实现向前向后兼容的 JSON 解码机制。
4. **UI 精细化集成**:
   - 在「人像」检查器的妆容面板中新增眼部精修（眼线/睫毛/美瞳/眼神光）与立体塑颜（高光/修容）滑杆与取色器。
   - 无人脸或置信度不足时禁用并显式提示，绝不静默改图。

### 1.2 验收项清单
- [x] `MakeupSettings` 扩展字段定义完善，实现向后兼容解码与中性状态判定。
- [x] `MakeupEngine` 支持眼线、睫毛、美瞳、眼神光、高光、修容六大管线阶段。
- [x] 配方版本门禁升级至 v14，防静默降级逻辑正确生效。
- [x] 无脸或地标置信度不足时安全回退并抛出明确错误或安全跳过。
- [x] UI 面板交互正常，`Group` 视图数量合规，无编译或渲染警告。
- [x] `MakeupEngineTests` 新增全套覆盖测试，全绿通过。
- [x] 全量 `make check`（全项目测试套件）无回归，100% 通过。
- [x] `bash Scripts/build_app.sh` 生产构建签名与验证通过。

---

## 2. 架构设计与实现路径

```
┌─────────────────────────────────────────────────────────────────┐
│                          PhotoCore                              │
│                                                                 │
│  MakeupEngine.swift:                                            │
│  ├── MakeupSettings:                                            │
│  │   ├── +eyelinerColor / +eyelinerIntensity                    │
│  │   ├── +eyelashIntensity                                      │
│  │   ├── +irisColor / +irisIntensity                            │
│  │   ├── +catchlightIntensity                                   │
│  │   ├── +highlightIntensity / +contourIntensity                │
│  │   └── +requiresVersion14                                     │
│  │                                                              │
│  ├── MakeupEngine.apply:                                        │
│  │   ├── Eyeliner pass (upper eyelid path rasterization)        │
│  │   ├── Eyelash pass (dilated upper margin darkening)          │
│  │   ├── Iris pass (pupil centered radial color blend)          │
│  │   ├── Catchlight pass (specular highlight micro-brighten)    │
│  │   ├── Highlight pass (T-zone & cheek high point brighten)    │
│  │   └── Contour pass (jawline & cheek hollow shading)          │
│  │                                                              │
│  Models.swift:                                                  │
│  ├── Recipe version 1...14 validation                           │
│  └── PhotoEngine.requiredRecipeVersion update (v14 for enhanced)│
└─────────────────────────────────────────────────────────────────┘
                                ▲
                                │
┌─────────────────────────────────────────────────────────────────┐
│                        PhotoAtelier                             │
│                                                                 │
│  PortraitRetouchPanel.swift:                                    │
│  ├── 眼部精修区 (眼线 / 睫毛 / 美瞳 / 眼神光)                   │
│  └── 立体塑颜区 (面部高光 / 暗部修容)                           │
└─────────────────────────────────────────────────────────────────┘
```

---

## 3. 回滚方案
若出现阻塞性问题，可通过 `git checkout feat/p1c-culling-makeup-perf` 回滚至 baseline `a4f4af3`。

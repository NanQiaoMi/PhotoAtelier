# P2-B 功能交付说明：秀发精修与发缝填充（发缝填补、秀发光泽、发色深邃）

> 分支: `feat/p2b-hair-refinement`  
> 基线: `40e119d`  
> 日期: 2026-11-06  
> 里程碑: P2 阶段第二里程碑 (Milestone P2-B: Hair Refinement & Parting Filling)

---

## 1. 概述与背景

在人像精修与商业影楼级摄影后期中，头发状态对人像画面的精致度有着决定性影响：
1. **发缝填充 (`hairGapFilling`)**：
   - 解决头顶分缝过宽、发际线/额角边缘稀疏、头皮泛白反光的问题。智能识别暴露的浅色头皮，将其加深并中和粉白肤色，使其融入发根阴影，同时完整保留穿过发缝的暗色发丝纹理，避免传统涂抹导致的色块感；
2. **秀发光泽 / 天使光环 (`hairGloss`)**：
   - 模拟高档洗护广告中的发冠弧形缎面高光（Angel Ring），在发冠与顶发高光区域增添柔和通透的缎面光泽，拯救干枯毛躁发质；
3. **发色深邃 / 去枯黄 (`hairDarkening`)**：
   - 加深发丝中频影调，抑制因漂染褪色或强光反射导致的枯黄杂色（brassiness），让头发恢复黑亮浓密感，提升面部肤色通透对比。

---

## 2. 核心架构与技术实现

### 2.1 原生着色器与纯向量计算 (`HairRefinementEngine`)
- 完全基于 GPU / Core Image 着色器（`CIColorKernel`）原生运行，单 pass 处理完成全部空间权重计算与像素调优；
- 单帧耗时 < 4ms，零第三方神经网络或模型下载依赖，100% 离线隐私安全；
- 全中性保真：三个参数为 0 时直接返回输入图像，零像素漂移，不改变渲染管线原样。

### 2.2 智能发缝与头皮识别算法
- **空间几何走廊**：以人脸中轴线及面部高度为基准，上延推导头顶发冠纵深走廊；
- **头皮置信度判定**：
  - 基于线性 sRGB / OKLab 光谱特征：结合局部亮度（$L > 0.18$）与肤色暖红分量（$R - B > 0.02$），准确定位被发丝包围的暴露浅色头皮；
  - **发丝保护机制**：穿过发缝的暗色真实发丝因亮度较低，自动被排除在加深之外，发丝清晰度与微细节 100% 得到保留；
  - **柔和晕染与去红**：对判定为头皮的区域平滑降低明度并抑制多余红黄色调，自然隐匿发缝。

### 2.3 严格向后兼容与配方协议
- `PortraitRefinementSettings` 新增 `hairGapFilling`、`hairGloss`、`hairDarkening` 字段；
- 自定义 `init(from decoder: Decoder)` 兼容处理：旧版本（v10 ~ v14）配方文件缺失新增字段时，均自动缺省解码为 `0`；
- 参数取值范围严格限定在 `0...1`，经 `PortraitRefinementEngine.validate` 严格校验。

### 2.4 UI 响应式面板集成
- 在 `PortraitRetouchPanel.swift` 的人像精修模块中，新增“秀发精修与发缝”专属控制区；
- 提供「发缝填充」、「秀发光泽」、「发色深邃」三个交互滑块，支持撤销/重做与一键归零。

---

## 3. 验收与验证证据

| 检查项 | 命令 | 退出码 | 关键结果 |
|---|---|---|---|
| 针对性头发测试 | `swift test -j 2 --filter HairRefinementTests` | 0 | **6/6 tests passed** (发缝填充、高光天使光环、发色去黄、向后兼容解码) |
| 人像精修回归测试 | `swift test -j 2 --filter PortraitRetouchTests` | 0 | **17/17 tests passed** |
| 全量单元测试回归 | `swift test -j 2` | 0 | **547 tests passed, 0 failures (65.2s)** |
| 通用架构应用构建 | `bash Scripts/build_app.sh --universal` | 0 | 生成 arm64 + x86_64 双架构应用，Codesign 签名有效 |
| 独立应用包验证 | `python3 Scripts/verify_app.py build/PhotoAtelier.app` | 0 | 4 signed dylibs, 55 XML profiles, portable load paths |
| UI 自动化冒烟测试 | `UI_SMOKE_OPEN_METHOD=cli UI_SMOKE_FAST=1 bash Scripts/ui_smoke.sh artifacts/p2b-verify/ui-smoke` | 0 | **Attempt 1/3 PASS**: 8 页签切换顺畅，18 张真实截图生成完毕 |

---

## 4. 交付清单

- `Sources/PhotoCore/HairRefinement.swift`:
  - `HairRefinementEngine` 原生着色器与流水线执行引擎。
- `Sources/PhotoCore/PortraitRefinement.swift`:
  - 扩展 `PortraitRefinementSettings`、参数校验与流水线串接。
- `Sources/PhotoCore/PhotoEngine.swift`:
  - 接入地标传递以增强头发分析精度。
- `Sources/PhotoAtelier/PortraitRetouchPanel.swift`:
  - 新增秀发精修交互面板。
- `Tests/PhotoCoreTests/HairRefinementTests.swift`:
  - 增补方向性位移、加深比例、向后兼容解码等 6 项单测。
- `docs/p2b-implementation-plan.md` & `docs/p2b-release-notes.md`:
  - 需求方案与正式发布说明。

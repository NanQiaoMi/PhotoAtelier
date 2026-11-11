# P3-D: P2 全模块真实照片审美回归（实施计划）

**日期**：2026-11-11
**分支**：`feat/p3d-aesthetic-regression-p2`
**前置**：P1-H 审美验收体系（`Scripts/evaluate_aesthetic.swift`）+ P2-A…P2-Z 26 模块全部合入主干 `main`

---

## 1. 背景与目标

P2 批次（26 个新模块）合入主干后，尚未在真实照片上做过一轮全量审美回归。P1-H 建立的评测引擎仅覆盖 P0~P1 六条管线（基线/场景/人像/妆容/胶片/商业全流程），P2 模块不在矩阵内。

**目标**：把 P2 模块纳入审美验收矩阵，用授权样片（`/Users/mimi/Desktop/图片`，13 张，只读）跑全量评分，确认：

1. P2 模块在真实照片上无质量回退（糊脸、假色、几何畸变、边缘溢出）；
2. P2 组合管线商业交付度可评审、可量化；
3. 评测画廊支持 10 条管线逐张对比。

## 2. 改动内容

### 2.1 新增 4 条 P2 回归管线（`Scripts/evaluate_aesthetic.swift`）

| 管线 ID | 名称 | 覆盖 P2 模块 | 保守量设置 |
|---|---|---|---|
| `07_p2_skin_suite` | P2 美肤全家桶 | P2-H 五区祛皱去油光、P2-G 身体手部美肤、P2-F 衣物祛皱、P2-B/C 发质精修（发缝/光泽/柔顺/去碎发） | 全部 0.30–0.50 |
| `08_p2_reshape_suite` | P2 微雕全家桶 | 液化高颅顶（P2-A）、P2-Z 骨相光影折叠度、P2-U 眼型、P2-V 鼻部、P2-W 下颌、P2-Y 眉形、P2-X 太阳穴颧骨、P2-T 微笑唇形 | 强度 0.55，参数 0.25–0.40 |
| `09_p2_scene_suite` | P2 场景全家桶 | P2-J 天空氛围、P2-Q 景深虚化、P2-D 影棚背景修复、创意效果（halation/mist/grain） | 0.20–0.45 |
| `10_p2_master_suite` | P2 商业大师 | 美肤+微雕+P2-N 眼神光美牙+景深+经典胶片全链路组合 | 综合保守量 |

设计原则：**只用保守量（不超过 0.5）**。回归测试的目的是暴露质量缺陷而非展示最佳效果；保守参数下出现的糊脸/假色说明算法有缺陷，而激进参数下的瑕疵属于「使用超范围」。

### 2.2 HTML 画廊页签动态化

原画廊页签是写死的 6 按钮行，扩展后与渲染管线数脱节。改为从共享 `pipelines` 列表动态生成 10 个页签，`10_p2_master_suite` 作为默认展示页签。

## 3. 验证方式

```bash
# 编译（依赖 swift build 的 PhotoCore 对象文件）
BIN="$(swift build --show-bin-path)"
swiftc -I "$BIN" Scripts/evaluate_aesthetic.swift \
  "$BIN"/PhotoCore.build/*.o "$BIN"/CLensfunBridge.build/CLensfunBridge.c.o \
  -o artifacts/p3d-verify/evaluate_aesthetic

# 单张冒烟（~30s）
./artifacts/p3d-verify/evaluate_aesthetic "/Users/mimi/Desktop/图片" "artifacts/p3d-verify/smoke" --limit 1

# 全量 13 张（~5-6 分钟）
./artifacts/p3d-verify/evaluate_aesthetic "/Users/mimi/Desktop/图片" "artifacts/p3d-verify/full-review"
```

**通过标准**：

- [x] 编译零告警退出；
- [x] 单张冒烟 10 条管线全部渲染，SHA-256 零篡改审计通过；
- [x] HTML 页签含 4 个新 P2 页签且切换正常；
- [ ] 全量 13 张完成，manifest 记录全部 `unchanged: true`；
- [ ] 人工评审：检查 P2 微雕管线在人脸样片上无过度形变，美肤管线无塑料感，景深虚化边缘无溢色（需打开画廊人工打分）。

## 4. 边界与说明

- 评测脚本产物在 `artifacts/`（gitignored），不入库；真实照片只读、不复制、不提交；
- 部分样片可能不触发特定模块（如无人脸样片上五官微雕模块显式跳过），这是预期行为——引擎的「检测不足时显式跳过」原则会在 report 中留 note；
- 本批次**不改 PhotoCore 引擎代码**，纯评测体系扩展；若评审发现模块质量缺陷，缺陷修复另立批次；
- 宠物模块（P2-I）、分人精修（P2-M）、虚拟副本（P2-L）不在回归矩阵：前两者依赖样片里有宠物/多人（当前 13 张样片无法保证），后者是元数据功能无像素输出。

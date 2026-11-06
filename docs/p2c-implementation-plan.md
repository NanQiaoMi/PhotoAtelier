# P2-C 实施方案：秀发柔顺与边缘碎发消除 (Hair Anti-Frizz Smoothing & Flyaway Removal)

## 1. 目标与验收标准

### 目标
在 P2-A（高颅顶/发际线/太阳穴）与 P2-B（发缝填充/秀发光泽/发色深邃）的基础上，补齐像素蛋糕人像发型精修全家桶的最后两个关键能力：
1. **秀发柔顺 / 抚平毛躁 (`hairSmoothing`)**：在发型主体区域平滑微观毛躁与分叉干枯高频杂色，保留大走向发束与高光轮廓，令秀发呈现柔顺丝滑质感。
2. **边缘去碎发 (`flyawayRemoval`)**：在头部与发冠外轮廓的过渡光晕区（Halo Zone），自动识别翘起、散乱外溢的 1~3 像素细碎飞丝，并按邻域纯净背景定向抚平消除，告别头顶“炸毛”。

### 验收标准（可勾选）
- [x] `PortraitRefinementSettings` 新增 `hairSmoothing`（0...1，默认 0）与 `flyawayRemoval`（0...1，默认 0）。
- [x] 严格中性：当所有控制量为 0 时，管线完全不改图，`isNeutral == true`。
- [x] 向下兼容：旧版配方 JSON（v1~v14）反序列化时缺失新字段自动缺省为 0，不破坏既有配方。
- [x] 零外部大模型依赖：基于 GPU `CIColorKernel` 与 `CIGaussianBlur` 运行，4K 增量延迟 $< 5\text{ ms}$。
- [x] `PortraitRetouchPanel` 在「秀发精修与发缝」区新增「秀发柔顺」与「边缘去碎发」滑杆。
- [x] 单元测试全覆盖：新增针对柔顺与去碎发的测试用例。
- [x] 全量回归测试通过：`swift test -j 2` 保持 100% 通过（549 个测试）。
- [x] 双架构打包验证与 UI 冒烟测试全绿。

---

## 2. 关键步骤与分工

1. **分支准备**：
   - 从 `feat/p1c-culling-makeup-perf`（`a4969b3`）检出 `feat/p2c-hair-flyaway-smoothing`。
2. **数据模型扩展 (`PortraitRefinement.swift`)**：
   - 新增 `hairSmoothing: Double = 0` 与 `flyawayRemoval: Double = 0`。
   - 显式 `init(from decoder:)` 补充解码支持。
   - 更新 `isNeutral` 与 `validate`。
3. **着色器与处理引擎升级 (`HairRefinement.swift`)**：
   - 升级 `hairKernel` 支持 `__sample smoothed` 输入，接收 `smoothing` 与 `flyaway` 参数。
   - 几何光晕区分割：发冠顶部与两侧碎发过渡带计算。
   - 细线结构边缘高频差分与邻域背景抚平。
4. **UI 面板接入 (`PortraitRetouchPanel.swift`)**：
   - 在「秀发精修与发缝」区域追加 `portraitSlider("秀发柔顺", \.hairSmoothing)` 与 `portraitSlider("边缘去碎发", \.flyawayRemoval)`。
5. **单元与集成测试 (`HairRefinementTests.swift`)**：
   - 验证柔顺对毛躁高频方差的平滑效果。
   - 验证边缘去碎发对背景散乱细线的抑制效果。
   - 验证全中性与旧 JSON 序列化兼容。
6. **全量构建与端到端验证**：
   - `swift test -j 2`
   - `build_app.sh --universal`
   - `verify_app.py`
   - `ui_smoke.sh`
7. **合并与收尾**：
   - `--no-ff` 合并至 `feat/p1c-culling-makeup-perf`，删除功能分支，产出交付报告。

---

## 3. 回滚方案
如遇不可调和的兼容性或性能问题，可直接回滚至基线 `a4969b3`。

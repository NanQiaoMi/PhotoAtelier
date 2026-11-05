# 右侧检查器与 LUT 风格架布局优化设计

**日期**：2026-11-05
**分支**：`fix/inspector-layout`
**触发**：真实照片（`/Users/mimi/Desktop/图片/` 内 13 张，经符号链接只读导入，不复制、不入库）验证时发现两处布局缺陷。

---

## 1. 问题复现（基线，真实图片）

测试方式：`PhotoAtelier --open-folder /Users/mimi/Desktop/图片` 启动，窗口 1400×900，导入 13 张真实图片后切到「基础」页。

### P1：右侧检查器 8 个页签横向溢出、末尾被裁切

- 检查器固定宽度 312pt，内容区宽度 278pt（左右各 17pt 内边距）。
- 原实现用 `Picker(.segmented)` 放 8 个页签；实测 AX 几何：
  - 页签组 `pos=1136,306 size=336×22`；
  - 检查器左边界 = 窗口右边界 1460 − 312 = 1148；
  - 即页签组左侧越界 12pt、右侧到 1472，超出窗口右边界 1460 **12pt**；
  - 最后一个「证件照」`pos=1418,305 size=54×24`，右边缘 1472，被窗口裁切（截图可见「证件照」末字被切）。
- 根因：8 段 Segmented Picker 的最小固有宽度大于 278pt，SwiftUI 不换行、不滚动，直接溢出父容器。

### P2：LUT 风格架标题行溢出、右侧操作被裁切、无滚动提示

- 「色彩风格 / LUT COLLECTION / 比较全部 19 种风格」在同一行，使用 `Spacer()` 推开操作按钮。
- 实测截图：中心列右边界处「比较全部 19 种风格」被裁成「比较全部 19 种风…」，按钮与分隔线相切；`LUT COLLECTION` 副标题占用标题行宽度。
- 卡片行 `ScrollView(.horizontal, showsIndicators: false)`：无滚动条、无渐隐/半卡提示，用户不知道还有 11 种风格；卡片右侧直接顶到分隔线。
- 根因：标题行没有宽度分配/降级策略；横向滚动无可见 affordance；卡片行缺少与面板边距一致的尾部留白。

---

## 2. 设计目标

1. **零裁切**：在窗口默认 1400×900 与最小 1120×740 下，8 个页签、LUT 标题与操作按钮完整可见，不越过检查器/中心列边界。
2. **可发现性**：LUT 架明确表达「还有更多风格」——可见滚动条或右侧半张卡片/渐隐；操作入口「全部 N 种」完整可点。
3. **信息层级**：页签从「挤压的 8 段」改为「4×2 网格」，图标+文字，选中态清晰；LUT 标题行主标题优先，副标题降级。
4. **一致性**：新增控件沿用现有配色（`AtelierPalette`）、圆角（5–6pt）、字号（10–11pt）、间距（6–8pt）与暗色风格。
5. **可访问性**：每个页签有 `accessibilityLabel`、选中态；LUT 卡片有 `help` 与选中态；滚动区域支持键盘/触控板。
6. **不改业务行为**：仅布局与呈现层；`inspectorTab` 语义、LUT 选择、样式浏览器入口、撤销/预览 token 不变。

---

## 3. 详细设计

### 3.1 右侧检查器页签（`InspectorTabBar`）

**结构**：两行 × 四列网格（`LazyVGrid` 固定 4 列，间距 6pt），页签顺序不变：
分析 / 基础 / 局部 / 人像 / 追色 / 导出 / 调色 / 证件照。

**尺寸**：
- 内容宽 278pt（312 − 17×2）；每格宽 = (278 − 3×6) / 4 ≈ 65pt，高 28pt；
- 行间距 6pt；整体高度 28×2 + 6 = 62pt（原 Picker 高 22pt + 上下 18pt 内边距 = 58pt，基本持平）。

**视觉**：
- 默认：透明底、`muted` 文字、11pt 图标 + 10.5pt 标签；
- 选中：`accent.opacity(0.16)` 圆角 6pt 底、`accent` 文字与图标、1pt `accent.opacity(0.55)` 描边；
- 悬停（macOS）：`white.opacity(0.05)` 底；
- 图标映射：分析 `chart.bar.xaxis`、基础 `slider.horizontal.3`、局部 `circle.dashed`、人像 `person.crop.circle`、追色 `eyedropper.halffull`、导出 `square.and.arrow.up`、调色 `circle.lefthalf.filled`、证件照 `person.text.rectangle`。

**行为**：
- `Button` 绑定 `$inspectorTab`，点击即时切换；保留原有 `onChange(of: inspectorTab)` 的全部清理逻辑（取消蒙版/液化/修复笔迹、触发人像检测）。
- `accessibilityLabel(tab.title)`，选中态由系统 `isSelected` trait 表达。
- 不引入横向滚动，避免隐藏页签。

**响应式**：检查器宽度保持 312pt；若未来加宽到 ≥340pt，网格自动拉伸（`LazyVGrid` flexible 列）。

### 3.2 LUT 风格架（`presetShelf`）

**标题行**：
- 左侧：`色彩风格`（主标题，10pt semibold）+ 计数徽标 `19`（8pt，`muted`，圆角 3pt 底）；
- 右侧：紧凑按钮 `全部 19 种` + `chevron.right`（10pt，`accent`），`lineLimit(1)`、`fixedSize()`，点击打开 `StyleBrowser`；
- 副标题 `LUT COLLECTION` 从标题行移除，改为 `色彩风格` 的 `help` 提示与样式浏览器页内说明，避免挤占宽度；
- 使用 `ViewThatFits(in: .horizontal)`：宽屏显示「全部 19 种」；窄屏降级为图标按钮 `rectangle.grid.2x2` + `help("浏览全部 19 种风格")`，保证永不裁切；
- 标题行右内边距与卡片行一致（0，由外层 22pt padding 统一）。

**卡片行**：
- 卡片 96×60pt（原 94×58），圆角 6pt，间距 8pt；
- 保留图标 + 选中勾选/描边；标签 10pt `lineLimit(1)`、固定 96pt 宽、`truncationMode(.tail)`；
- 滚动容器：`ScrollView(.horizontal)` + `.scrollIndicators(.visible)`（macOS 13+），尾部追加 24pt 占位与右侧渐隐遮罩（`LinearGradient` 8pt 宽），表达「还有更多」；
- 卡片行上下 `padding(.vertical, 2)`，与标题行间距 10pt；
- 选中卡片滚动到可见区域（`ScrollViewReader.scrollTo`，切换 LUT 时）；
- 保留 `disabled(model.batchRunning)` 与 `help(option.detail)`。

**高度**：标题行 18pt + 间距 10 + 卡片 60 + 标签 14 + 上下 padding 18×2 ≈ 138pt（原约 140pt，基本不变），不挤压预览区。

### 3.3 右侧检查器顶部（顺带修正）

- 标题「调色面板 / 重置」保持；直方图 `frame(height: 57)` + `frame(maxWidth: .infinity)`，确保不因父容器拉伸而裁切；
- 直方图下方刻度行保持 8pt；
- 页签网格上下内边距 14pt（原 18pt），给内容区多留 8pt。

---

## 4. 验收标准（含 2026-11-05 实测结果）

| 检查 | 标准 | 实测结果（2026-11-05，真实图片 13 张） |
|---|---|---|
| 页签零裁切 | 1400×900 与 1120×740 下，8 个页签全部落在检查器内；截图目视无截断 | ✅ 1400×900 与 1120×740 截图均为 4×2 网格，8 个页签完整可见（「证件照」不再被裁切） |
| LUT 标题行 | 「全部 19 种」按钮完整可见，右边缘 ≤ 中心列右边界；无省略号 | ✅ 标题行显示「色彩风格 19 / 全部 19 种 ›」完整无截断 |
| LUT 滚动提示 | 滚动条可见或右侧半卡/渐隐可见；可横向滚动到第 19 种 | ✅ 右侧可见半张卡片（第 9 张）作为滚动提示；滚动条在滚动时显示 |
| 真实图片 | `/Users/mimi/Desktop/图片/` 内 13 张（只读导入，不入库）验证直方图、预览、LUT、页签切换 | ✅ footer「已载入 13 张照片 · 图片」，直方图/预览/风格架均用真实照片渲染 |
| 回归 | `swift build`、测试通过；撤销/预览/样式浏览器入口不变 | ✅ `swift build -j 2` exit 0；`swift test --skip` 既有慢测后 520/0（见交接文档 §7.3） |
| 最小窗口 | 1120×740 下中心列最窄，仍满足上述标准 | ✅ 1120×740 下「基础」「证件照」页均无裁切 |

**证据**（`artifacts/` gitignored，不提交；真实照片截图含用户内容，仅本机留存）：
- 修复前基线：`artifacts/layout-real/layout-1400x900.png`（旧布局：页签溢出/LUT 标题行裁切）
- 修复后：`artifacts/layout-real/tab1-1400x900.png`、`tab1-1120x740.png`、`tab7-1120x740.png`
- 采集脚本：临时 `/tmp/capture_tab.sh`（启动 `--open-folder` + `--initial-tab` → 设窗口尺寸 → `screencapture -R`），未提交。

---

## 5. 风险与边界

- 仅布局改动，不改变业务语义；页签网格高度略增（约 +4pt），内容区相应减少，可接受。
- 真实照片含私人内容：仅本机只读导入与本地截图证据（`artifacts/`，gitignored），不复制、不提交、不嵌入最终交付物。
- 未做真实用户可用性测试；截图与 AX 几何断言作为验收证据。

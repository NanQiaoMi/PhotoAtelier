# P3-A/B/C + 风格扩展批次: 人像 UX 重构、交互增强与创意效果/相机厂商风格 (Release Notes)

> **批次构成**：本文件合并记录 2026-11-10 至 2026-11-11 交付的 6 个功能批次。
> 全部为**纯 UI/交互与风格目录扩展**，**未改动** `PhotoEngine` 处理管线顺序、配方字段结构或版本门禁（配方仍为 v1–v33）。

| 批次 | 提交 | 内容 |
|---|---|---|
| P3-A 人像 UX 重构 | `e513887` (merge `17d6d0f`) | 修图面板六大场景分类页签、20 模块独立旁路/复位、按住瞬时对比、整体强度倍率、大师预设 |
| P3-B 风格架实时缩图 | `e4a0da9` (merge `6a011e7`) | 预设架逐风格实时渲染缩图、分类筛选胶囊、内联强度滑杆、可折叠胶片条 |
| P3-C 交互打磨 | `29129cb` (merge `56dcbb9`) | 长按看原图、自适应面部特写(1:1)、风格架分类与推荐强度徽标 |
| UX 对比增强 | `0762166` (merge `8eee207`) | 2-up 并排同步对比、分屏手柄边界钳制、五官定位 HUD、风格架滚动箭头 |
| 创意效果扩展 I | `3181358` (merge `3705ca5`) | 胶片红晕(halation)、黑柔薄雾(mist) 着色器 + 6 款新 LUT（日系通透/复古港风/柯达金/莫兰迪/暗调油画/高对比黑白） |
| 创意效果扩展 II | `2975052` (merge `0a668ec`) | 胶片褪色(fade)、银盐留银(bleachBypass) 着色器 + 13 款相机厂商风格 LUT |

---

## 1. P3-A: 人像修图面板 UX 重构

### 1.1 六大场景分类页签

`Sources/PhotoAtelier/PortraitModuleTypes.swift` (新增)、`PortraitRetouchPanel.swift`、`PortraitModuleComponents.swift` (新增)

- `PortraitCategory`：**智能速修 / 极润美肤 / 骨相光影 / 五官微雕 / 美妆秀发 / 身形服饰** 六大场景横向胶囊页签，图标 + 中文标签；
- 无脸或检测不足时除「智能速修」外全部禁用（保持 v1 的显式降级原则，不静默改图）。

### 1.2 20 个精修模块卡片化

`PortraitModuleType` 将既有 P0–P2 全部人像能力收敛为 **20 个独立模块**（质感磨皮、五区祛皱去油光、肤色统一、身体美肤、骨相光影、太阳穴颧骨、下颌下巴、鼻、眉、眼型、双眼皮卧蚕、眼神光牙齿、微笑唇形、彩妆、秀发、发色、唇毛胡青痣、身形、衣物、景深虚化），每张卡片提供：

- **🟡 活跃指示点**：模块参数非中性时点亮；
- **👁️ 单击旁路 / 按住瞬时对比**：单击临时停用该模块，按住不放瞬时关闭该模块效果对比前后差异，松开恢复（纯预览会话状态，不写配方）；
- **⟲ 单模块复位**：仅将该模块恢复中性默认值，不影响其他模块。

### 1.3 人像效果总控倍率

- 「智能速修」页新增 **整体强度滑杆 0%–150%**（`portraitMasterIntensity`，步进 0.05）：对所有 20 个模块的强度做全局缩放；
- 通过 `effectiveAdjustmentsForPreview` 仅作用于**预览路径**；缩放是预览会话状态，保存配方仍记录原始滑杆值（关掉应用重开即回 100%）。

### 1.4 大师级商业人像预设

`PortraitPreset.builtIns` 新增 5 个一键全脸预设（`applyPortraitPreset`）：

| 预设 | 效果要点 |
|---|---|
| 高级折叠骨相 | 面部折叠度 + T区/C区高光 + 收颧骨下颌角 |
| 清冷超模微雕 | 眼尾微提 + 根根野生眉 + 冷调修容 |
| 自然幼态少女 | 短中庭 + 饱满卧蚕苹果肌 + 微笑嘴角 |
| 商业影棚精修 | 中性灰磨皮 + 去油光泪沟 + 眼神光美牙 |
| 男士硬朗雕塑 | 硬朗下颌 + 去胡青 + 保留原生胡须与特征痣 |

预设写入真实配方参数（可撤销、可继续微调、随批量导出生效），与预览旁路/倍率机制互不影响。

### 1.5 活跃效果 HUD

`PortraitActiveHUD`：面板顶部横幅实时罗列当前已修改的模块胶囊，单击胶囊可跳转或快速旁路。

---

## 2. P3-B/C: 风格架与画布交互增强

### 2.1 风格架实时缩图 (`e4a0da9`)

`Sources/PhotoAtelier/PresetShelfView.swift` 重构：

- 每个风格卡片显示**当前照片的真实渲染缩图**（后台渲染队列，悬停浮起 + 选中徽标 + 渐变压字）；
- **分类筛选胶囊**：全部 / 相机 / 人像 / 电影 / 自然 / 风光 / 黑白 / 自定义（`LUTPresetGroup.camera` 新分类，见 §3.2）；
- 选中风格后**内联强度滑杆**（0–100%）直接出现在卡片下方，偏离推荐强度 >3% 时出现「推荐 N%」一键采用徽标。

### 2.2 长按看原图 (`29129cb`)

- 工具栏「按住看原图」（`holdOriginalActive`）：按住不放临时查看整张原片，松开立即还原；也可单击切换锁定。

### 2.3 自适应面部特写

- 工具栏「面部特写」按钮（`focusOnFaceEvent`）：智能缩放并平移居中至检测人脸，再次点击返回适合窗口；
- 修图面板内另有「面部特写 (1:1)」按钮（`triggerFocusOnFace`），便于微雕时精细对比。

### 2.4 双图并排对比 + 分屏手柄钳制 + 五官 HUD (`0762166`)

`Sources/PhotoAtelier/AppModel.swift` 新增 `ComparisonLayout`（**分屏** / **并排**）；`PhotoCanvas.swift`：

- **并排 2-up**：左右两个同步平移缩放的完整对比窗格（`sideBySideView`）；
- **分屏手柄边界钳制**：分割线手柄 Y 坐标钳制在画布范围内（24 至 height−38），不再越界；
- **五官定位 HUD**（`showFaceLandmarksHUD` + `faceLandmarksOverlay`）：画布上高亮 Vision 识别的五官关键点与轮廓路径。

### 2.5 风格架滚动箭头 (`0762166`)

风格架两端新增箭头按钮（`scrollRelative`），按页滚动并居中目标卡片。

---

## 3. 创意效果与风格目录扩展

### 3.1 四款新创意效果着色器 (`3181358`、`2975052`)

`Sources/PhotoCore/CreativeEffects.swift` 的 `CreativeEffectsSettings` 扩展为 7 个强度通道：

| 效果 | 字段 | 视觉语义 |
|---|---|---|
| 胶片红晕 | `halation` | 模拟胶片背层光渗：高光提取后按红色偏移模糊回叠 |
| 黑柔薄雾 | `mist` | 黑柔柔焦漫射（Pro-Mist 风格，亮部扩散轻抬黑位） |
| 胶片褪色 | `fade` | 微抬黑位哑光、收低饱和的复古褪色 |
| 银盐留银 | `bleachBypass` | 留银工艺：提升反差与金属质感 |

- 全部为 `CIColorKernel` GPU 着色器，与既有辉光/暗角/颗粒同一节点图，**在 LUT 之后**应用（`PhotoEngine.process` 顺序不变）；
- 既有约束全部延续：几何与 alpha 保持、SDR 高光不裁切、HDR/负值源不钳制、ROI 渲染与全图一致、颗粒确定性哈希；
- `isNeutral` 覆盖全部 7 通道，零值字段走旧像素路径；延续配方 **v8 门禁**（非中性创意效果整体要求 ≥v8，无需新版本号——字段落在同一 `creativeEffects` 组内，`validateVersion` 与 `requiredRecipeVersion` 均经既有 `isNeutral` 汇总守卫覆盖）；
- 「质感滤镜」面板新增快捷预设胶囊：经典胶片 / 黑柔电影 / 复古暗角 / 日系轻雾 / 理光街拍 / 银盐留银 / 日系哑光。

### 3.2 LUT 目录扩至 32 款原创 + 5 款署名富士近似

`Sources/PhotoCore/LUTCube.swift`（程序化 17³ 表，`LUTPresetGroup.camera` 新分类）：

- **第一批 6 款** (`3181358`)：日系通透、复古港风、柯达金胶片、莫兰迪灰调、暗调油画、高对比黑白；
- **第二批 13 款相机厂商风格** (`2975052`)：理光正片、理光高反差黑白（森山大道风）、徕卡鲜活/经典/M黑白、富士Velvia/PRO Neg、索尼S-Cinetone/FL、尼康鲜活/人像、佳能红润、哈苏HNCS；
- 17³ 表**程序化生成**（非外部 .cube 导入），风格近似为原创实现并明确署名致敬对象，不内置权源不明的表；
- 全部带推荐强度（0.30–0.38）与中文标签（如「佳能」「HNCS」「森山大道」），接入风格架搜索；
- **自检契约同步**：`StyleWorkflowSmokeHarness` 的风格数量断言 19→25→38（含原色与 5 款富士近似）；
- 既有 5 款 legacy LUT 全表哈希断言（`testLegacyPresetOrderAndFullTableHashesRemainUnchanged`）保持不变，旧像素路径零改动。

---

## 4. 变更文件清单（累计 6 批）

1. `Sources/PhotoAtelier/PortraitModuleTypes.swift` (新增) — 分类/模块/预设类型定义；
2. `Sources/PhotoAtelier/PortraitModuleComponents.swift` (新增) — 模块卡片/页签/HUD 组件；
3. `Sources/PhotoAtelier/PortraitRetouchPanel.swift` — 六类页签路由、总控倍率、大师预设；
4. `Sources/PhotoAtelier/PresetShelfView.swift` — 实时缩图、分类筛选、内联强度、滚动箭头；
5. `Sources/PhotoAtelier/PhotoCanvas.swift` — 2-up 并排、手柄钳制、五官 HUD overlay；
6. `Sources/PhotoAtelier/ContentView.swift` — 按住看原图、面部特写、五官定位、对比布局切换；
7. `Sources/PhotoAtelier/AppModel.swift` — 旁路/倍率/特写/HUD 状态与 effectiveAdjustmentsForPreview；
8. `Sources/PhotoAtelier/CreativeEffectsPanel.swift` — 7 滑杆 + 7 快捷胶囊；
9. `Sources/PhotoCore/CreativeEffects.swift` — 4 款新着色器与校验；
10. `Sources/PhotoCore/LUTCube.swift` — 19 款新 LUT 与 camera 分组；
11. `Sources/PhotoAtelier/StyleWorkflowSmokeHarness.swift` — 风格数量契约 19→25→38；
12. `Tests/PhotoCoreTests/CreativeEffectsTests.swift`、`LUTCatalogTests.swift` — 新效果/新目录测试。

---

## 5. 验证结果

- 全量测试 `swift test -j 2`：**791/791 passed，0 failures**（150.5s，2026-11-11 本机实测）；
- `swift build -j 2`：exit 0；
- 生产打包 `bash Scripts/build_app.sh`：**exit 0**，包校验通过（4 签名 dylib、55 XML profiles、便携路径，2026-11-11 本机实测）；
- `CreativeEffectsTests`（11 项，含 halation/mist/fade/bleachBypass 几何/alpha/ROI/HDR 断言）与 `LUTCatalogTests`（27 款目录元数据、中性守恒、单色去色度断言）全部通过；
- 风格数量自检契约 38（debug 启动自动断言）通过；
- UI 冒烟：**未完成**（前 4 页签截图正常后中止，避免打扰用户；补跑方式见 §5.1）。

### 5.1 UI 冒烟结果（2026-11-11，未完成）

- `bash Scripts/ui_smoke.sh artifacts/p3-verify/ui-smoke`：**中途终止，未通过判定**。前 4 个页签（分析/基础/局部/人像）截图已取得且渲染正常（`01-launch.png`、`02-folder-loaded.png`、`03-cull-controls.png`、`tab-01…04-*.png`），后 4 个页签与 `ui-smoke.json` 未生成；
- 终止原因：冒烟需要反复启动 GUI 应用并截图，与用户正在使用机器冲突，应用启动后即被停止（无失败证据，但也无通过证据）；
- **补跑方式**（机器空闲时执行，约 3–5 分钟）：
  ```bash
  bash Scripts/ui_smoke.sh artifacts/p3-verify/ui-smoke-final
  ```
  通过标准：`ui-smoke.json` 中 `status=pass`、`tabCount=8`，证据绑定 app SHA256 与 commit。
- 全部页签截图与滚动区段截图落在 `artifacts/p3-verify/ui-smoke/`（gitignored）。

---

## 6. 已知边界

- 人像旁路（👁️）与总控倍率均为**预览会话状态**，不写入配方、不随批量导出持久化；批量导出使用配方原始参数。需要把倍率效果固化时，直接把各模块滑杆调到目标值即可。
- 32 款原创 LUT 为程序化近似风格，不是对厂商官方色彩科学的一比一复刻；署名标签表示「灵感致敬」，详见风格详情文案。
- 2-up 并排对比的左右窗格同步平移缩放，但高光/阴影警告等叠加层仅在主窗格显示。

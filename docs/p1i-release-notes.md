# P1-I 功能交付说明：技术债整理、自检前向兼容与 UI 冒烟测试去 flakiness

> 分支: `feat/p1i-tech-debt-cleanup`  
> 基线: `026ac7f`  
> 日期: 2026-11-05  
> 里程碑: P1 完整开发周期收官交付 (Closing P1 Release Lifecycle)

---

## 1. 概述与背景

随着 P0、P1、P1-B、P1-C、P1-D、P1-E、P1-F、P1-G、P1-H 系列里程碑的全部推进完成，Photo Atelier 已经具备了工业级的桌面图像处理管线与完整的审美验收体系。

作为 P1 最终的闭环里程碑，**P1-I（技术债整理与测试脚手架加固）** 针对在持续迭代中发现的底层工程痛点进行了彻底排查与根治：
1. **测试与自检的前向兼容防护**：解决自检脚本中过硬的配方版本断言对未来扩展的阻碍；
2. **`ui_smoke.sh` 自动化测试 Harness 去 flakiness**：消除了由于 macOS 锁屏挂起、NSOpenPanel 键盘模拟偶发失焦、以及检查器 4×2 网格布局重构导致的 AX 树元素识别偏差；
3. **证据链哈希严格绑定**：自动化证据完整记录 Git 提交、可执行文件 mtime 与 SHA-256 哈希，运行中发生二进制变更时即时熔断；
4. **文档与实现全盘一致性校准**：更新开发交接文档与全局架构状态，正式宣布 P1 里程碑 100% 达成。

---

## 2. 核心改进与修复

### 2.1 自检前向兼容性加固 (SmokeHarness Forward-Compatibility)
- **问题排查**：
  在 `Sources/PhotoAtelier/SmokeHarness.swift:204`、`324`，`PortraitSmokeHarness.swift:96`，以及 `StyleWorkflowSmokeHarness.swift:170`、`182` 中，旧逻辑对配方版本做了等值断言 `restored.version == 9`。
  当现代功能（如证件照换背景 v12、基础妆容 v13、增强妆容 v14）使配方自动升级版本时，过硬的 `== 9` 会阻断应用自检。
- **解决方案**：
  在保持原有语义（五区微调与自动意图要求配方版本不低于 9）的前提下，将所有刚性断言统一重构为前向兼容的 `>= 9`。
  自检通过：`PORTRAIT_CONTRACT_SELF_CHECK PASS` 与 `APP_SMOKE PASS · 36 checks · 2 exported · 1 isolated`。

### 2.2 `ui_smoke.sh` 稳定性与去 flakiness (De-flaking Automation Harness)
- **锁屏状态前置探测**：
  macOS 屏幕锁定时，UI 自动化（`System Events` AX 树与按键模拟）会失效或挂起。脚本前置集成 `ioreg` 状态检测：
  `ioreg -n Root -d1 -a 2>/dev/null | grep -q "<key>CGSSessionScreenIsLocked</key>"`
  检测到锁屏时立即友好输出明确提示并以 exit 2（前置条件缺失）优雅退出，避免长时间无意义超时。
- **双模导入与直接 `--open-folder` CLI 模式**：
  新增 `UI_SMOKE_OPEN_METHOD`（`auto`、`cli`、`dialog`）：
  支持直接通过 `open "$APP" --args --open-folder "$INPUT"` 启动并导入测试夹具，完全跳过易受焦点干扰的 NSOpenPanel 键盘模拟；在 `auto` 模式下，若两次对话框自动化未完成，自动平滑回退至 CLI 导入。
- **InspectorTabBar 4×2 网格 AX 元素精准定位**：
  P1 布局优化（`90e95c2`）将检查器单行 Segmented Picker 重构为 4×2 的 `InspectorTabBar`（`AXOpaqueProviderGroup`）以彻底消除小屏幕裁切。但旧 `ui_smoke.sh` 仅抓取 `AXRadioGroup`，误将左侧挑图筛选栏（4 按钮）当作检查器页签，导致报 `expected at least 7 inspector tabs, got 4`。
  在 `ContentView.swift` 中为页签按钮补充原生 `.help(tab.title)` tooltip，并在 `Scripts/ui_smoke.sh` 中增加对 `AXOpaqueProviderGroup` 8 格网格与 legacy `AXRadioGroup` 的双模兼容识别，支持按属性与索引双重容灾寻址。
- **Fast 模式键控滚动判据修复**：
  修复了 `UI_SMOKE_FAST=1` 下 `SCROLLED_KEYBOARD` 返回值未转换为 `SCROLLED:keyboard` 导致的断言偏差，确保在各种运行模式下均稳健通过。

### 2.3 严谨的防篡改证据绑定
- 证据文件 `artifacts/p1i-verify/ui-smoke/ui-smoke.json` 完整录入：
  - `appExecutableMTime`: 1793874733
  - `appExecutableSHA256`: `305260a08c0b43325fb97ef51424f63b8b3027dcee14debad7b65c5942f2c7a2`
  - `commit`: `026ac7f`
  - `openMethod`: `cli`
  - `tabs`: 8 个标准页签（`分析`、`基础`、`局部`、`人像`、`追色`、`导出`、`调色`、`证件照`）
  - `scrolledSections`: 7 个深度滚动区段全覆盖
  - 18 张全分辨率真实渲染截图

---

## 3. 验收与验证证据

| 检查项 | 命令 | 退出码 | 关键结果 |
|---|---|---|---|
| 单元与集成测试 | `swift test -j 2` | `0` | **540/540** 100% 通过（耗时 139.4s，远低于 10min 门禁） |
| 应用自检与契约测试 | `.build/debug/PhotoAtelier --self-test ...` | `0` | `APP_SMOKE PASS`（36 checks 全绿通过） |
| Universal 双架构打包 | `bash Scripts/build_app.sh --universal` | `0` | `Architectures in the fat file: x86_64 arm64`，代码签名完成 |
| App 包体合规性验证 | `python3 Scripts/verify_app.py build/PhotoAtelier.app` | `0` | 4 signed x86_64 dylibs, 55 XML profiles, 可移植路径校验通过 |
| 严格代码签名自检 | `codesign --verify --deep --strict build/PhotoAtelier.app` | `0` | 签名完整无篡改 |
| 端到端 UI 冒烟测试 | `bash Scripts/ui_smoke.sh artifacts/p1i-verify/ui-smoke` | `0` | 8 个页签、18 张截图、7 个滚动区段、1/3 尝试首次直接通过 |

---

## 4. P1 阶段整体完成总结

至此，Photo Atelier P1 开发路线图中的全部 10 个子里程碑均已圆满交付：
- **P0**: 格式基建、人像修复 v1、AI 追色、导出增强
- **P1**: HSL/曲线/颜色分级、面部液化美型、文字图片水印
- **P1-B**: 证件照换背景、修复画笔/仿制图章、本地客户交付页
- **P1-C**: 启发式质量分析 AI 挑图、基础妆容、有界并行批处理
- **P1-D**: 项目库管理、历史步骤面板、元数据非破坏性持久化
- **P1-E**: 交付页多主题切换、离线隐私合规审计、局域网 HTTP 手机预览
- **P1-F**: 眼线/睫毛/美瞳/眼神光/高光/修容精修增强妆容（v14 配方门禁）
- **P1-G**: Universal 原生双架构构建与 24MP 全画幅基准 v5 测评
- **P1-H**: 真实照片审美验收体系、6 大题材 5 维量化准则与自动化切片评测
- **P1-I**: 技术债全盘整理、测试脚手架去 flakiness 与前向兼容加固

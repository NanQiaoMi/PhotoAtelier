# PhotoAtelier 工程指南（AGENTS.md）

> 面向接手开发与协作的工程师及 AI Agent，提供项目地图、常用命令、CI 门禁与工程红线。

---

## 1. 项目概览

**PhotoAtelier（光屿）** 是一款离线优先（Offline-first）的 macOS 原生摄影调色与人像精修桌面应用（SwiftPM，最低支持 macOS 13.0，主处理管线工作在 extended-linear sRGB 色彩空间）。

---

## 2. 目录与模块地图

| 路径 | 职责说明 |
| --- | --- |
| `Sources/PhotoCore/` | 核心图像处理与业务引擎：`PhotoEngine.swift`（主处理管线）、`Models.swift`（配方结构与 v1–v33 版本门禁）、色彩/曲线/LUT/创意效果/局部蒙版/人像精修与五官骨相微雕/景深/天空/批处理/交付服务 |
| `Sources/PhotoAtelier/` | SwiftUI 原生界面与交互状态：`ContentView.swift`、`AppModel.swift`、`PhotoCanvas.swift`、`PortraitRetouchPanel.swift`、`PresetShelfView.swift` 及各专项面板与冒烟脚本入口 |
| `Sources/CLensfunBridge/` | Lensfun 0.3.4 C 语言动态库桥接层（依赖 `.dependencies/lensfun`） |
| `Tests/PhotoCoreTests/` | 单元、像素兼容与回归测试集（当前共 **817** 项测试） |
| `Scripts/` | `prepare_lensfun.py`（固定 wheel 拉取与校验）、`build_app.sh` / `verify_app.py`（签名打包与合规校验）、`ui_smoke.sh`（GUI 冒烟）、`evaluate_aesthetic.swift`（审美切片评测） |
| `.github/workflows/ci.yml` | GitHub Actions macOS 构建与全量测试工作流 |
| `docs/` | 差距分析、实拍自然度复盘（`p2-face-naturalness-gap-analysis.md`）、RAW 评估（`raw-engine-evaluation.md`）、开发交接（`development-handover.md`）与关键架构决策（`DECISIONS.md`） |

---

## 3. 常用命令速查

```bash
# 1. 准备并校验 Lensfun 原生依赖（生成 .dependencies/lensfun，已 gitignore）
python3 Scripts/prepare_lensfun.py
python3 Scripts/prepare_lensfun.py --verify

# 2. 本地构建与测试（需本机安装完整 Xcode.app）
swift build -j 2          # 或 make build
swift test -j 2           # 或 make test
make check                # build + test

# 3. 定向测试
swift test -j 2 --filter PortraitRetouchTests

# 4. 本机仅安装 CommandLineTools、缺少 Xcode.app 时的静态语法预检
swiftc -parse Sources/PhotoCore/<File>.swift Tests/PhotoCoreTests/<Test>.swift

# 5. 生产打包与包校验（需 Xcode.app）
bash Scripts/build_app.sh
python3 Scripts/verify_app.py build/PhotoAtelier.app
codesign --verify --deep --strict build/PhotoAtelier.app
```

---

## 4. CI 与分支交付规范

- **远端 CI（`.github/workflows/ci.yml`）**：在 `macos-15`（Apple Silicon，完整 Metal GPU）+ Rosetta `arch -x86_64` 下使用系统通用二进制 `/usr/bin/python3` 与 `/usr/bin/swift` 依次执行 Lensfun 准备、`swift build -j 2` 与 `swift test -j 2`。
- **交付纪律**：
  - 严禁直接提交或推送 `main`，所有改动必须基于最新 `origin/main` 切出标准命名功能分支（`feat/`、`fix/`、`docs/`、`ci/` 等）。
  - 所有 PR 必须盯梢至远端 `CI/macOS Build & Test` 全绿后，由人工拍板合并（推荐 Squash Merge 并清理分支）。
  - 架构级变更或核心流程调整需同步更新本文件、`docs/DECISIONS.md` 与 `docs/development-handover.md`。

---

## 5. 工程红线与禁止事项

1. **配方前后兼容底线**：修改配方字段或管线阶段顺序时，必须同步更新 `Models.swift` 版本门禁及兼容回归测试，严禁静默改变旧版本配方（v1–v33）的像素输出。
2. **禁止提交私密与衍生文件**：严禁将真实用户照片、`.env`/密钥、`.dependencies/`、`artifacts/`、`build/`、`.build/` 提交进 Git 仓库。
3. **测试 `CIContext` 构造规范**：严禁在 `XCTestCase` 实例属性中非惰性创建 `CIContext` 或 `PhotoEngine`；统一使用 `private static let` 惰性共享，防止 XCTest 套件发现阶段并发创建大量 GPU 上下文触发 `IOAccelerator` 崩溃。
4. **测试断言红线**：严禁为了“让测试变绿”而删改、跳过或放宽合理断言；如遇跨后端浮点精度差异，应排查着色器数值实现（参考 `TonalCurve.swift` 的 `refinedReciprocal` 与 `* 0.0625`）。

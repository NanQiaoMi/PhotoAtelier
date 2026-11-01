# 本机实现与验证记录

日期：2026-11-01。运行范围：Intel x86_64、macOS 13.7.8、Swift 5.8.1、Xcode 14.3.1 / SDK 13.3。记录只覆盖实际执行范围，不代表全部相机、所有 macOS 或公开发行验收。

## 目标与范围

用户最初确认原生桌面文件夹批处理、JPEG / PNG / TIFF；随后明确授权项目内 Lensfun 原生库与离线数据库。2026-11-01 补充要求真实像素/内容/拍摄信息分析、相机 JPEG 与 RAW、多种自动结果、选择后细调。本次实现已按该补充扩展，目标没有被替换。

验收项：

- [x] 原生照片库、预览、前后对比、内置及导入 `.cube`、配方保存/载入。
- [x] 线性工作空间与显式 LUT 编码/解码、域外淡出、亮度/中性/肤色保护；数值与图像测试。
- [x] 曝光、有限自动白平衡、色温/色调、基础 tone、水平/透视、三类局部蒙版。
- [x] 真正 Lensfun 标定映射、唯一自动匹配、手动覆盖、歧义/不兼容明确跳过；不将通用旋转称为镜头校正。
- [x] 实际像素/元数据分析与本机 Vision 标签；三种处理预览、选定后细调、按每张照片重算并叠加细调。
- [x] 完整 RAW 解码路径及坏 RAW 隔离；真实 Canon CR2 全尺寸预览、三方案、批量导出，以及修正后的亮度参考重验均已执行。
- [x] 不覆盖、目录隔离、符号链接防护、取消、坏文件隔离、原图哈希不变、原子 JSON 清单。
- [x] 最终 Release 包、脱离源码目录运行、签名及 payload 完整性复核。
- [ ] 原生鼠标键盘、文件选择器及退出确认交互。CUA 服务启动失败，尚未实际执行；用户已选择人工验收后再合并。

## Git、分级与现场

- **大型变更**：符合用户 AGENTS.md 3.1 的新增功能/模块、跨模块实现、依赖/构建/打包调整及大于 150 行等条款。
- 稳定分支 `main`；当前功能分支 `feature/photo-atelier`，沿用前阶段创建的分支，没有在 `main` 直接开发。
- 建分支时 HEAD 与基线均为 `837ec592c5428e4e4cd360e91f2592d69321f92d`，`chore: baseline`。初始基线只有 README 与 `.gitignore`，没有既有构建/测试入口，未发现可复跑的基线失败。
- 当前工作均为本任务实现；开始时没有用户未提交文件、没有 stash、没有远程。已再次检查 `git status --porcelain -uall`、`git diff --cached --name-only`、`git stash list`、`git remote -v` 与 `git rev-parse main`。
- 实现提交：`959038d1dfbdd75c710171d428b84482bb6659d1`，`feat(atelier): add analyzed RAW batch photo grading`。最终检查、打包与下述 `output-final` 流程均在该实现提交后执行；后续提交只补充本验证文档。
- 不推送、不创建 PR、不发布，只有本地仓库。目前未合并 `main`，功能分支保留。依赖、测试照片、缓存与应用产物都被忽略，不纳入 Git。
- 用户于 2026-11-01 明确选择“保留已提交功能分支，人工验收后再合并”。按此决定保留 `feature/photo-atelier`，人工验收通过前不执行本地合并。源代码回滚用 `git revert <commit>`，不重写历史；打包会保留旧 `.app` 的带时间戳副本。

## 实际验证命令与结果

以下命令工作目录为项目根，单独标注的 `/tmp` 运行除外。失败是本次开发中发现的问题，未声称为基线失败。

| 完整命令 / 工具动作 | 退出码 | 关键结果 |
|---|---:|---|
| `python3 Scripts/prepare_lensfun.py --verify` | 0 | 本机原生 C API：948 cameras / 1304 lenses；指定 Canon 相机 1 个、旧版 24–70 镜头 2 个，证明歧义必须跳过。 |
| `make check`（加入分析/RAW 前） | 0 | `swift build -j 2` + `swift test -j 2`，40 tests / 0 failures。 |
| `swift Scripts/make_demo.swift artifacts/acceptance-20261101/input --include-broken` | 0 | 生成两张合成图及一个故意损坏文件，没有访问用户照片。 |
| `.build/debug/PhotoAtelier --self-test artifacts/acceptance-20261101/input artifacts/acceptance-20261101/output-debug artifacts/acceptance-20261101/evidence-debug`（拷入 RAW 前） | 0 | `APP_SMOKE PASS · 8 checks · 2 exported · 1 isolated`；原图 SHA-256 不变，实际 Lensfun 变换、蒙版、16 位 P3 TIFF 与清单。 |
| `bash Scripts/build_app.sh`（第一轮） | 1 | Release 编译成功；包检查发现上游 dylib 自身 ID `/DLC/lensfunpy/...`，没有绕过门禁。已改为在全新 staging 中核对原始 SHA、规范化自身 ID、签名后记录与复核。 |
| `make check`（加入分析/RAW 后） | 0 | 51 tests / 0 failures，包含实际自动唯一匹配、白平衡与跳过、三方案、旧配方兼容及逐张自动参数/证据。首次 Vision 初始化导致首个分析测试约 17 秒；分析运行在后台。 |
| `swift build -j 2 && .build/debug/PhotoAtelier --self-test artifacts/acceptance-20261101/input artifacts/acceptance-20261101/output-analysis-debug artifacts/acceptance-20261101/evidence-analysis-debug` | 0 | `12 checks · 3 exported · 1 isolated`，144.94 秒；4272×2848 CR2 全尺寸导出和逐张分析成功。**这一轮仅证明命令流程；视觉复核发现 RAW 偏暗，不能作为最终图像验收。** |
| `swift artifacts/acceptance-20261101/raw-source/diagnose-ciraw.swift` | 0 | 同样 534×356 / extendedLinearSRGB buffer：默认解码 P50 0.12018；线性直接输出 0.07309；额外颜色转换后 0.00634。多余转换额外降低约 3.53 EV，已删除。 |
| `make check`（RAW 颜色转换修复后） | 0 | 51 tests / 0 failures，4.73 秒；构建 11.20 秒。仍保留系统 kernel 弃用警告。 |
| `bash Scripts/build_app.sh`（修复后） | 0 | Release 编译 51.38 秒；签前源 SHA 匹配、4 个库自身 ID 正规化、签后 SHA / 签名 / 架构 / 加载路径 / 55 XML 与许可精确集合全部通过。旧应用保留为 `build/PhotoAtelier.previous-20261101-103105.app`。 |
| `env -u PROJECT_ROOT /usr/bin/time -l '/Users/mimi/project/ai调色/build/PhotoAtelier.app/Contents/MacOS/PhotoAtelier' --self-test '/Users/mimi/project/ai调色/artifacts/acceptance-20261101/input' '/Users/mimi/project/ai调色/artifacts/acceptance-20261101/output-release' '/Users/mimi/project/ai调色/artifacts/acceptance-20261101/evidence-release'`（工作目录 `/tmp`） | 0 | `APP_SMOKE PASS · 13 checks · 3 exported · 1 isolated`；进程 real 28.99 秒、最大 RSS 916,324,352 bytes、peak footprint 1,239,134,208 bytes、0 swaps。清除开发目录环境变量，使用包内库与数据库。 |
| `make check`（提交 `959038d` 后） | 0 | 最终实现快照：构建 3.20 秒；51 tests / 0 failures，3.816 秒。日志：`artifacts/acceptance-20261101/evidence-release/final-check.log`。 |
| `bash Scripts/build_app.sh`（提交 `959038d` 后） | 0 | Release 增量编译 12.29 秒；4 个签名 x86_64 动态库、55 XML、许可精确集合、portable paths 全通过。旧包保留为 `build/PhotoAtelier.previous-20261101-103533.app`。日志：`artifacts/acceptance-20261101/evidence-release/final-build.log`。 |
| `env -u PROJECT_ROOT /usr/bin/time -l '/Users/mimi/project/ai调色/build/PhotoAtelier.app/Contents/MacOS/PhotoAtelier' --self-test '/Users/mimi/project/ai调色/artifacts/acceptance-20261101/input' '/Users/mimi/project/ai调色/artifacts/acceptance-20261101/output-final' '/Users/mimi/project/ai调色/artifacts/acceptance-20261101/evidence-final'`（工作目录 `/tmp`） | 0 | 对刚重建的最终应用重新验收：`APP_SMOKE PASS · 13 checks · 3 exported · 1 isolated`。harness 9.94 秒、进程 real 11.51 秒；最大 RSS 938,774,528 bytes、peak footprint 1,248,780,288 bytes、0 swaps。完整日志：`artifacts/acceptance-20261101/evidence-final/final-smoke.log`。 |
| `PYTHONOPTIMIZE=1 python3 Scripts/verify_app.py build/PhotoAtelier.app` | 0 | 4 signed x86_64 dylibs / 55 XML / exact licenses / portable paths；优化模式仍执行门禁。 |
| `codesign --verify --deep --strict build/PhotoAtelier.app` | 0 | 最终包严格签名校验通过。 |
| `du -sh build/PhotoAtelier.app` | 0 | 应用约 14 MB；测试照片、导出 TIFF 不在应用包中。 |
| `cua.getApp("PhotoAtelier")` | 工具错误 | `Sky Computer Use service startup request failed`；未使用其他技术绕过原生 UI 自动化。 |
| `cua.rewriteDocumentation()` 后 `cua.getApp('/Users/mimi/project/ai调色/build/PhotoAtelier.app')`（最终包复验） | 工具错误 | 文档恢复成功，原生服务仍返回 `Sky Computer Use service startup request failed`。鼠标键盘、系统文件对话框及退出确认仍为未执行，没有将自动 smoke 视为人工验收。 |

`make check` 是项目完整检查入口（build + test），没有独立的 lint/typecheck 入口；Swift 编译覆盖类型检查。`make app` 等价调用 `bash Scripts/build_app.sh`，由最终打包记录覆盖；`make run` 的真实 Finder/启动交互未执行。没有使用 `--no-verify`、禁用用例或跳过失败测试。

### 本次发现与修复

- 先前透视边缘插值造成透明线：改为有效内部裁剪与 clamp 后缩放，图像测试通过。
- 目录祖先遍历在 Foundation 的 `/` 上退到 `/..`：显式根路径停止，批处理重叠测试通过。
- 冷暖正号反向：以实际像素验证后修正，全局与局部测试通过。
- 切目录旧预览、切镜头旧分析及旧方案图：取消 token / generation 隔离并清空过期结果。
- 退出模态提示期间批处理完成：确认后重新检查任务状态，避免等待一个不会再到来的完成通知。该路径已代码复核，真实点击仍待验收。
- 重复打包可能混入旧 XML、Python `assert` 可被优化关闭：改为全新 staging、资源精确集合与显式异常门禁；独立验证器也检查主程序及动态库加载路径。
- RAW 重复色彩转换：第一轮真实 CR2 的线性中位亮度约 0.00638。对照诊断定位到多余的 `matchedToWorkingSpace`，已移除；由 CIContext 对带标签的图像转换一次，并保留相机基准曝光归一化。下方记录了最终数值和图像重验结果。

### 最终文件与图像复核

最终实际 CR2 分析中位亮度为 **0.07319**，与独立原生线性解码参考 **0.07309** 一致；逐张批处理实际曝光分别为 +1.390、+0.828、+1.498 EV，证明没有把第一张的 EV 固定套给整批。真实 RAW 自动命中其 EF-S 18–55mm IS II 镜头配置。图像复核确认晨雾与主体可见，没有前一轮的异常黑图，三方案预览存在可见差异。

使用 ImageIO 对最终包的三个导出文件重新读取，命令入口 `swift - artifacts/acceptance-20261101/output-final`（标准输入程序见下）；退出 0。两张合成图为 1600×1067，Canon 为 4272×2848；全部 16-bit、Display P3、orientation 1。完整流程的源文件 SHA-256 一致。再次执行 `codesign --verify --deep --strict build/PhotoAtelier.app` 与 `PYTHONOPTIMIZE=1 python3 Scripts/verify_app.py build/PhotoAtelier.app` 均退出 0。

```swift
import Foundation
import ImageIO
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "tiff" }.sorted { $0.path < $1.path }
guard files.count == 3 else { fatalError("Expected three exports") }
for url in files {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { fatalError("Unreadable export") }
    let width = p["PixelWidth"] as? Int ?? 0, height = p["PixelHeight"] as? Int ?? 0
    let depth = p["Depth"] as? Int ?? 0, orientation = p["Orientation"] as? Int ?? 0
    let profile = p["ProfileName"] as? String ?? "missing"
    guard depth == 16, orientation == 1, profile.contains("P3") else { fatalError("Export contract failed") }
    if url.lastPathComponent.contains("Canon") { guard width == 4272 && height == 2848 else { fatalError("RAW was not full resolution") } }
    print("\(url.lastPathComponent): \(width)x\(height), \(depth)-bit, \(profile), orientation \(orientation)")
}
```

对包验证器做过一次必要的反例：在临时副本加入额外 XML，在 `PYTHONOPTIMIZE=1` 下仍退出 1 并指出 `untracked-test.xml`；外层验证脚本退出 0，原应用未改。实际命令 `python3 -` 的程序如下：

```python
import os, shutil, subprocess, sys, tempfile
from pathlib import Path
with tempfile.TemporaryDirectory(prefix='photo-atelier-verifier-') as folder:
    copy = Path(folder) / 'PhotoAtelier.app'
    shutil.copytree('build/PhotoAtelier.app', copy)
    (copy / 'Contents/Resources/Lensfun/db/untracked-test.xml').write_text('<test/>')
    result = subprocess.run([sys.executable, 'Scripts/verify_app.py', '--record', str(copy)],
                            env=dict(os.environ, PYTHONOPTIMIZE='1'), text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if result.returncode != 1 or 'untracked-test.xml' not in result.stdout:
        raise SystemExit('Verifier did not reject the extra XML: ' + result.stdout)
    print('PASS: extra XML rejected under PYTHONOPTIMIZE=1; verifier exit=1')
    print(result.stdout.strip())
```

最终本地证据（不入库）：`artifacts/acceptance-20261101/evidence-final/01-empty.png`、`02-library.png`、`02-analysis.png`、`03-mask.png`、`04-export.png`、`05-raw-analysis.png`、`app-smoke.json`、`final-smoke.log`；对应逐张 JSON 清单位于 `output-final/`。已再次查看最终 `05-raw-analysis.png`：RAW 晨雾、树木与道路正常可见，三种方案可比较，分析面板显示真实像素指标与 Vision 标签。旧 `evidence-release/` 证据保留。自动命令及本应用自己的 SwiftUI 视图渲染，不能替代真实鼠标/键盘与系统文件对话框操作。

### 待执行的原生交互清单

下列项目均未执行，不计入已通过验收。用户已明确选择保留已提交功能分支，人工验收后再合并，因此当前不合并 `main`。

- [ ] 从 Finder 打开 `build/PhotoAtelier.app`，通过系统文件选择器打开文件夹，取消一次后再正常选择。
- [ ] 鼠标切换 JPEG / RAW，采用三个方案中的任一个，并在“基础”修改参数；切换照片后显示本张分析与候选结果。
- [ ] 拖动前后对比分隔线、缩放/平移，并绘制和修改局部画笔/渐变/径向蒙版。
- [ ] 通过系统对话框导入 `.cube`、保存/载入配方及保存分析 JSON，检查取消不破坏当前状态。
- [ ] 选择独立输出文件夹并批处理；运行中取消，以及运行中退出后分别选择继续工作/确认退出，确保状态明确且原图保留。

## 真实 RAW 夹具

样本来自 [pixls.us record 1744](https://raw.pixls.us/getfile.php/1744/nice/Canon%20-%20EOS%201100D%20-%20RAW%20(3%3A2).CR2)，站点标记 CC0 1.0。Canon EOS 1100D、EF-S 18–55mm f/3.5–5.6 IS II、55mm；15,716,187 bytes，SHA-256 `8f0ff8956ecf58de9fddda4b20d32f61576c46fa36460d358b83c42eee8d5fa8` 与站点一致。来源及许可依据保存在忽略的 `artifacts/acceptance-20261101/raw-source/source.txt`，照片不进入版本库。

RAW 的 6635 K / +11.8 是该解码器提供的白点估计，和 JPEG 缺失 Kelvin 时的“未知”分别展示。解码容器位深/配置不冒充原始传感器 ADC 位深/相机 ICC。没有用内嵌 JPEG 代替 RAW。

## 修改文件清单

修改：`.gitignore`、`README.md`。

新增：

```text
LICENSE
Makefile
Package.swift
Resources/Info.plist
THIRD_PARTY_NOTICES.md
Scripts/build_app.sh
Scripts/make_demo.swift
Scripts/make_icon.swift
Scripts/prepare_lensfun.py
Scripts/verify_app.py
Sources/CLensfunBridge/CLensfunBridge.c
Sources/CLensfunBridge/include/CLensfunBridge.h
Sources/PhotoAtelier/AnalysisPanel.swift
Sources/PhotoAtelier/AppModel.swift
Sources/PhotoAtelier/ContentView.swift
Sources/PhotoAtelier/LensPicker.swift
Sources/PhotoAtelier/PhotoAtelierApp.swift
Sources/PhotoAtelier/PhotoCanvas.swift
Sources/PhotoAtelier/SmokeHarness.swift
Sources/PhotoCore/AutomaticProcessing.swift
Sources/PhotoCore/BatchProcessor.swift
Sources/PhotoCore/HorizonEstimator.swift
Sources/PhotoCore/LUTCube.swift
Sources/PhotoCore/LensCorrection.swift
Sources/PhotoCore/Models.swift
Sources/PhotoCore/PhotoAnalysis.swift
Sources/PhotoCore/PhotoEngine.swift
Sources/PhotoCore/PhotoIO.swift
Tests/PhotoCoreTests/AnalysisTests.swift
Tests/PhotoCoreTests/AutomaticTests.swift
Tests/PhotoCoreTests/BatchTests.swift
Tests/PhotoCoreTests/EngineTests.swift
Tests/PhotoCoreTests/IOTests.swift
Tests/PhotoCoreTests/LUTTests.swift
Tests/PhotoCoreTests/LensTests.swift
docs/lensfun-api.md
docs/lensfun-build.md
docs/opensource-research.md
docs/validation.md
```

没有删除文件。打包产物、动态库、数据库、照片和日志均未暂存。

## 已知限制、风险与下一步

- 本机试用范围为 macOS 13 Intel；尚未验收 Apple Silicon、其他系统版本、全部相机型号或大批真实照片。当前只有一款真实 Canon RAW 的端到端样本，不能称为全相机画质验收。
- RAW 相机覆盖由系统决定；不支持的变体明确失败。当前不是逐感光单元分析、AI 降噪或专用 RAW 高光重建工具。
- 镜头畸变映射限制为 40 MP（单个 RG float map 约 320 MB），超限会保留照片并警告跳过镜头校正；其他流程上限为 120 MP。没有启用 Lensfun 暗角/横向色差功能。
- 三方案来自实测像素与有限规则；不能仅凭中位亮度断言曝光错误。内容分类/人脸检测可能误判；肤色保护不是语义分割，蒙版不跟踪跨照片主体。
- LUT 需明确同输入输出空间；不支持 Log / HDR / ACES / HaldCLUT 或跨 gamut 技术变换。输出为 SDR JPEG / PNG / TIFF。
- Core Image 运行时 kernel 源码 API 在本机工作，但已被 Apple 弃用，编译保留警告；后续系统升级需重验并规划 Metal kernel 迁移。测试元数据的异构字典也有 Swift 推断提示，不影响当前测试运行。
- 应用为本地临时签名，未公证、未公开发布。公开二进制分发前，还需备齐 LGPL 对应源码与构建材料，见第三方说明。
- 下一步：用户人工检查文件选择、导入/保存对话框、拖画/缩放/对比和运行中退出确认。按已确认决定，人工验收通过后再本地合并 `main` 并运行合并后回归；这不等于全部相机或公开发行验收。

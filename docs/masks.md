# 局部蒙版与整体协调

## 本次目标与验收

范围：在现有本机试用版上完善选区、区域测量、局部调整和配方兼容；不新增下载或运行依赖。继续遵循用户已确认的“保留功能分支，人工验收后再合并”。

验收清单（自动检查与应用命令流程；真实鼠标交互单列）：

- [x] 径向、渐变、画笔、亮度范围与颜色范围已实现；加选、减选与交集通过实际像素测试。
- [x] 实际权重覆盖预览包含羽化、范围、反选与强度；几何控制点、连续多笔修边和撤回步骤已实现、编译并复核，实际拖动仍待人工验收。
- [x] 根据实际有效选区测量亮度及覆盖，提供限幅的局部光线建议；空选区不提供虚假建议。
- [x] 局部光线、颜色与锐化可调整；高光保护不妨碍压暗，色彩保护不妨碍纯曝光或去饱和。
- [x] 新蒙版默认经过共同 LUT，选区不随局部调整或 LUT 变化而反馈；旧配方保持原处理顺序。
- [x] 完整 `make check`、Release 构建、包验证及真实 RAW/坏图批处理回归。
- [ ] 原生鼠标、画笔、控制点与对话框人工验收；此项通过前不合并。

## 操作流程

1. 打开照片，在“局部”中选择工具；也可从“快速起点”创建暗部细节、高光过渡、主体提亮或取样颜色选区。
2. 几何工具点击“在照片上新建选区”，在照片上拖动。画笔可单击点涂。亮度/颜色工具直接建立范围选区，颜色工具随后在照片中取样。
3. 选中蒙版后选择“加选 / 减选 / 交集”并绘制，可以连续多笔修边。每笔记住当时的半径与柔边，能撤回最后一步或删除某一步。
4. 打开“实际覆盖区域”检查粉色权重。它包含所有修边、羽化、范围与强度；显示透明度只影响检查视图，不影响导出。
5. 在“选区与边缘”限定亮度或颜色，编辑径向/渐变控制点。径向中心拖动会保留椭圆大小；控制点只编辑基础形状，已画修边保留原位。
6. 查看“区域实测与建议”，可选择采用光线建议，再调整曝光、高光、阴影、对比、锐化、饱和度、冷暖和绿/洋红偏色。关闭覆盖后判断实际照片效果。
7. 用启用开关和整体强度比较效果；可重命名、复制、排列、重置调整参数或删除蒙版。配方保存所有选区与调整数据。

## 选区与色彩约定

- 几何坐标基于镜头/旋转/透视校正后的照片，原点在左下，按画幅比例保存。预览与导出使用同一算法。
- 修边按列表顺序合成：加选取较大权重；减选乘以反权重；交集相乘。因此在半透明羽化区域，减选也平滑过渡。
- 几何选区先合成和反转，再与亮度、颜色限制取交集。纯亮度/颜色范围蒙版的反选作用于范围与修边的最终结果；之后统一乘以强度。
- 亮度/颜色判断依据全局基础与几何校正后的固定参考图，不受局部调整或 LUT 影响。亮度控制为 0–1 的 sRGB 显示亮度；颜色容差使用 CIELAB Delta E 76 距离 / 100，并支持边界柔化。
- 颜色取样来自同一参考图的有效小邻域，不从已被 LUT 染色的屏幕图反推。透明位置没有有效像素时明确提示。
- 新蒙版默认在 LUT 之前调整，局部与全图一起接受统一风格及其亮度/中性/肤色保护。也可选择在 LUT 之后进行局部收尾。每个阶段内按列表顺序叠加，重叠处会累积调整。
- 高光保护用于减少亮部继续提亮，不限制压暗高光。色彩保护限制高彩度区域新增色度，保留纯曝光与去饱和的方向。两者是可调限制，不能替代关闭覆盖后检查照片。
- 旧配方缺少新字段时读为 LUT 后调整，关闭新增保护，并保留旧渲染路径。新版保存配方版本 2，同时读取版本 1 / 2；旧应用会拒绝版本 2，避免忽略新增字段后悄悄产生不同效果。

兼容边界：旧画笔在长边超过 2048 像素时的羽化比例也同步修复；读取版本 1 保留处理顺序和默认参数，不承诺该修复前后所有画笔边缘逐像素相同。

## 区域建议与使用边界

建议根据选区权重、区域与全图的亮度及高光/阴影比例计算，曝光变化限制在 ±0.6 EV。它是保守起点，不是“最佳审美”的评分；不会自动改变参数，用户采用后仍可细调。几何主体起点不是语义主体识别；颜色范围也不是肤色或天空分割。

整批照片仍使用同一份局部配方：几何位置固定，亮度/颜色选区逐张重新计算；区域建议采用后的局部参数固定，不逐图重新优化或跟踪主体。构图差异大时应分组处理，避免把手绘区域套到错误位置。

最多 16 个蒙版、所有蒙版合计 64 个修边组件、单笔 4096 点、总共 32768 点。选区栅格最长边最多 2048 像素后缩放到目标尺寸，以限制内存；细小边缘需要检查全分辨率导出。锐化不是 AI 纹理重建或降噪。

## 分支与验证记录

- 分级：大型变更，符合 AGENTS.md 3.1 的新增功能、跨模块实现及数据格式扩展。
- 分支：`feature/local-mask-harmony`；建分支 HEAD / 本次基线：`6d8d7ca9517756c468c47a8b522335646beb1526`，原稳定分支 `main` 为 `837ec59`。
- 现有试用版的实现和测试基线见 [原验证记录](validation.md)。本次开始时工作区干净，无暂存内容、无 stash；不合并、不推送、不发布。
- 回滚采用 `git revert` 撤销本次提交；应用构建会保留上一版 `.app`，不覆盖原片或已有导出。
- 本次开始时源码基线与上一轮交付一致；变化只有已验证记录，未发现用户未提交改动。未将任何本次失败称为基线已有失败。

### 实际验证

命令默认工作目录 `/Users/mimi/project/ai调色`，证据目录被 Git 忽略。运行环境为 macOS 13.7.8 Intel x86_64、Swift 5.8.1。`make check` 是完整既有检查入口，包含 `swift build -j 2` 和 `swift test -j 2`，没有独立 lint 入口。

| 完整命令 | 退出码 | 关键输出 / 证据 |
|---|---:|---|
| `swiftc -frontend -parse Sources/PhotoAtelier/AppModel.swift Sources/PhotoAtelier/MaskInspector.swift Sources/PhotoAtelier/ContentView.swift Sources/PhotoAtelier/PhotoCanvas.swift` | 0 | 画布与界面语法解析成功；之后完整构建再次覆盖类型检查。 |
| `swift build -j 2` | 0 | 首轮编译 25.05 秒；`artifacts/acceptance-masks-20261101/build.log`。 |
| `swift test -j 2`（首轮） | 1 | 67 tests / 7 assertions failed，均在新增用例；原有 51 项通过。失败为取色放大、颜色选区不匹配及 JSON Double 精度断言，未跳过。`tests-first.log`。 |
| `make check`（修正取色与透明度后） | 0 | 69 tests / 0 failures；`check-second.log`。 |
| `make check`（最终，保留独立取色回归） | 0 | **70 tests / 0 failures**，测试 4.914 秒；其中新增蒙版 19 项 / 0 failures。`check-final.log`。 |
| `/usr/bin/time -l .build/debug/PhotoAtelier --self-test artifacts/acceptance-20261101/input artifacts/acceptance-masks-20261101/output-debug artifacts/acceptance-masks-20261101/evidence-debug` | 1 | 180 秒超时，14 项完成、3 图导出、1 坏图隔离；真实 RAW 导出完成，切回 RAW 的最终预览未在期限内完成。`debug-smoke.log`。 |
| `/usr/bin/sample 27448 1 10 -file artifacts/acceptance-masks-20261101/sample-debug-optimized.txt` | 0 | 1 秒采样定位当时批处理线程在 `PhotoLoader.load → LensCorrection.correct`，Debug 的逐像素映射循环仍占主要 CPU；未把此采样作为 Release 性能结论。 |
| `/usr/bin/time -l .build/debug/PhotoAtelier --self-test artifacts/acceptance-20261101/input artifacts/acceptance-masks-20261101/output-debug-optimized artifacts/acceptance-masks-20261101/evidence-debug-optimized` | 0 | **16 checks · 3 exported · 1 isolated**，163.74 秒；RSS 918,396,928 bytes、peak footprint 1,220,501,504 bytes、0 swaps。`debug-optimized-smoke.log`。 |
| `bash Scripts/build_app.sh` | 0 | Release 编译 38.19 秒；4 个签名 x86_64 动态库、55 XML、许可及可迁移加载路径均通过。`release-build.log`；上一版保留为 `build/PhotoAtelier.previous-20261101-112251.app`。 |
| `env -u PROJECT_ROOT /usr/bin/time -l '/Users/mimi/project/ai调色/build/PhotoAtelier.app/Contents/MacOS/PhotoAtelier' --self-test '/Users/mimi/project/ai调色/artifacts/acceptance-20261101/input' '/Users/mimi/project/ai调色/artifacts/acceptance-masks-20261101/output-release' '/Users/mimi/project/ai调色/artifacts/acceptance-masks-20261101/evidence-release'`（工作目录 `/tmp`） | 0 | **16 checks · 3 exported · 1 isolated**，应用自身流程 14.75 秒、进程 real 15.84 秒；RSS 931,385,344 bytes、peak footprint 1,244,844,032 bytes、0 swaps。`release-smoke.log`。 |
| `codesign --verify --deep --strict build/PhotoAtelier.app` | 0 | 最终应用包严格签名校验通过。 |
| `PYTHONOPTIMIZE=1 python3 Scripts/verify_app.py build/PhotoAtelier.app` | 0 | 优化模式下仍验证 4 个签名 x86_64 库、55 XML、许可精确集合及主程序/库加载路径。 |
| `swift - artifacts/acceptance-masks-20261101/output-release`（标准输入程序见下） | 0 | 三张导出均为 16-bit、Display P3、orientation 1；两张 1600×1067，真实 Canon RAW 为 4272×2848。 |
| `python3 -`（标准输入程序见下） | 0 | 配方版本 2、LUT 前蒙版与一条减选组件保留；3 图成功、1 坏图隔离、16 项应用检查。 |
| `cua.getApp('/Users/mimi/project/ai调色/build/PhotoAtelier.app')` | 工具错误 | 本轮最终包重试仍返回 `Sky Computer Use service startup request failed`，原生指针与系统对话框未执行。 |

既有入口对照：`make build` / `make test` 已由 `make check` 覆盖，`make app` 的命令体已由 `bash Scripts/build_app.sh` 覆盖；`make run` 的 Finder/真实交互未执行，原因是原生自动化服务不可用。合并后主分支回归未执行，原因是用户要求人工验收前保留功能分支、不合并。没有跳过测试、禁用用例或使用 `--no-verify`。

最终 Release 应用的自动流程核对了有效覆盖、减选后覆盖下降、复制/排列/删除、配方往返、异步参考色取样、真实 RAW 分析/三方案/全尺寸导出、逐图分析证据及原片哈希不变。几何位置在整批中保持一致，未声称自动跟踪。实际查看 `evidence-release/03-mask-refined.png` 与 `05-raw-analysis.png`：减选槽和羽化可见，RAW 晨雾、树和道路正常可见。最终截图和 `app-smoke.json` 均来自上述 Release 包；应用自动渲染不代替人工操作。

导出元数据复读的完整命令：

```bash
swift - artifacts/acceptance-masks-20261101/output-release <<'SWIFT'
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
SWIFT
```

配方与应用证据复读的完整命令：

```bash
python3 - <<'PY'
import json
from pathlib import Path
root = Path('artifacts/acceptance-masks-20261101')
files = list((root / 'output-release').glob('batch-*.json'))
if len(files) != 1:
    raise SystemExit('Expected one batch manifest')
data = json.loads(files[0].read_text())
if data['recipe']['version'] != 2:
    raise SystemExit('Expected recipe version 2')
masks = data['recipe']['adjustments']['masks']
if len(masks) != 1 or masks[0]['stage'] != 'beforeLook':
    raise SystemExit('Expected one before-look mask')
components = masks[0]['components']
if len(components) != 1 or components[0]['operation'] != 'subtract':
    raise SystemExit('Subtractive refinement was not retained')
entries = data['entries']
if len(entries) != 4 or sum(e['status'] == 'completed' for e in entries) != 3 or sum(e['status'] == 'failed' for e in entries) != 1:
    raise SystemExit('Unexpected batch outcome')
smoke = json.loads((root / 'evidence-release/app-smoke.json').read_text())
if smoke['status'] != 'passed' or len(smoke['assertions']) != 16:
    raise SystemExit('Incomplete application checks')
print('PASS: recipe v2, one before-look mask, subtractive refinement, 3 completed / 1 isolated, 16 application checks')
PY
```

独立 Foundation 探针（`swift -`，退出 0）复现：`JSONEncoder/JSONDecoder` 把 `0.07` 从 `0.070000000000000007` 解析为 `0.070000000000000034`；`0.0625` 完全往返一致。全字段配方测试改用二进制可精确表示的 `.0625`，保留整份配方相等断言；没有更改实际产品参数或放宽颜色像素断言。

```bash
swift - <<'SWIFT'
import Foundation
struct Probe: Codable { var value: Double }
for value in [0.07, 0.0625] {
    let data = try JSONEncoder().encode(Probe(value: value))
    let decoded = try JSONDecoder().decode(Probe.self, from: data).value
    print(String(format:"input=%.17g decoded=%.17g",value,decoded), value == decoded)
}
SWIFT
```

### 本次发现与修复

- 取色路径的 `CIContext` 明确输出未预乘 RGBA，旧实现再次除以 alpha，导致放大颜色。改为直读 RGB、以 alpha 加权平均；半透明区域分析也按可见权重统计，避免透明边缘污染。
- 高光保护原先削弱所有局部变化，色彩保护也削弱纯曝光；已分别限制为正向提亮与额外色度，高光负 EV、去饱和及合法 +8 EV 有像素回归。
- 纯范围蒙版原先“反转全白基础”会变空；现在范围与修边的最终结果求补集。几何选区仍保持先反转、再限定范围的约定。
- 空画笔反选的覆盖图原先可能全白但实际处理跳过；现在处理、覆盖及区域检查统一为空。零容差颜色范围也包含精确同色边界。
- 修正画笔在 2048 栅格上限之后羽化比例，以及大图锐化的绝对半径截断；预览与全图使用相对尺寸。
- 纯几何蒙版不再读取整张参考照片作为覆盖图输入，减少 RAW 分支重复执行；复测 Debug 完整流程通过，但不将两轮总时间差单独归因于这一个改动。
- 新配方版本 2 阻止旧应用静默忽略新增字段；版本 1 / 2 的真实批处理入口及未知版本拒绝均有测试。

### 变更文件

修改：

```text
README.md
Sources/PhotoAtelier/AppModel.swift
Sources/PhotoAtelier/ContentView.swift
Sources/PhotoAtelier/PhotoCanvas.swift
Sources/PhotoAtelier/SmokeHarness.swift
Sources/PhotoCore/BatchProcessor.swift
Sources/PhotoCore/Models.swift
Sources/PhotoCore/PhotoEngine.swift
docs/validation.md
```

新增：

```text
Sources/PhotoAtelier/MaskInspector.swift
Sources/PhotoCore/LocalMaskEngine.swift
Tests/PhotoCoreTests/LocalMaskTests.swift
docs/masks.md
```

无删除文件。未暂存照片、数据库、动态库、应用、日志或采样产物。

### 待人工验收与限制

按用户已确认的决定，保留功能分支，人工验收通过后再考虑合并并执行合并后回归；本次不合并、不推送、不发布。

- [ ] 在缩放/平移后的照片中点涂、连续绘制、减选和交集，检查鼠标位置与真实覆盖对齐。
- [ ] 拖动径向中心/边缘与渐变两端，检查中心平移不改变椭圆大小、修边保持原位。
- [ ] 切换工具、蒙版或照片，按 Escape，检查草稿与旧覆盖不会残留。
- [ ] 对真实用户照片比较局部调整与整体风格，关闭粉色覆盖查看边缘；保存/重载配方后复查。
- [ ] 系统文件对话框、处理取消与运行中退出确认；本轮 CUA 原生服务重试仍不可用，没有用替代技术绕过。

自动快照仅是本应用自身视图的渲染，不是鼠标/键盘交互测试。仍未验收 Apple Silicon、其他系统/相机、超大批量或语义天空/发丝/主体分割。Debug 全尺寸镜头校正明显较慢；面向试用的产物应使用 Release 应用。新增蒙版 kernel 沿用项目的 Core Image source kernel API，本机可运行但该 API 已被 Apple 弃用，编译保留警告；后续系统升级仍需重验并规划 Metal 迁移。

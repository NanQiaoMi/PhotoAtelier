# 整体／局部颜色协调与 LUT 兼容

后续自动曝光/白平衡约束与原尺寸阈值检查见 [自动调整记录](automatic-safety.md)。下方为本轮之前的颜色协调快照，保留其历史验证事实。

## 目标、范围与验收

在已有本机文件夹批处理、真实 RAW 分析与局部蒙版基础上，测量照片原有色彩，减少全局、局部和 LUT 叠加引入的强染色，并统一预览与导出的目标色域。不新增下载或安装依赖。

继续遵循用户确认的“保留已提交功能分支，人工验收后再合并”。本轮是可回滚的本地功能提交；自动验证与真实鼠标验收分别记录。

- [x] 从实际像素统计整体颜色与九个位置区域；报告透明像素、冷暖及测量边界。
- [x] 新增全局高饱和保护，并在所有局部和 LUT 叠加后再次约束颜色；纯曝光、去饱和、alpha 与非零画布原点有像素回归。
- [x] 可调整防染色、细节与高彩度保护；统计保护和输出映射前后的实际变化。
- [x] 支持 P3 LUT 原色转换、独立 Rec.709 OETF 和 Gamma 2.4，以及合法的 `LUT_3D_INPUT_RANGE`。
- [x] 按目标 sRGB / P3 做 SDR 色域映射；主预览、三方案和导出共用目标；16 位导出复读有像素对照。
- [x] 保存配方版本 3，读取版本 1 / 2 / 3，拒绝未知版本；缺少保护字段的旧配方保持原路径。
- [x] 最终源码的现有 `make check` 完整通过：103 tests / 0 failures；没有跳过或禁用测试。
- [x] 最终 Release 包、真实 RAW 与合成图批处理、报告和导出属性检查：20 项应用检查、3 张成功／1 张坏图隔离。
- [ ] 原生鼠标、系统对话框及真实用户照片的审美比较；完成前不合并。

## 操作与算法

### 1. 先观察照片的整体感觉

“分析”页沿用真实曝光、白平衡证据、相机元数据和本机 Vision 标签，新增整体颜色概况及九个位置区域。优先显示最暗、最浓色、最亮的不同区域，其余位置可展开查看。

- 最长边不超过 192 像素且不放大，以 alpha 加权。亮暗使用 extended linear sRGB 的 Y：暗部 ≤0.12、亮部 ≥0.72。
- 以线性 RGB 的 HSV 类比值统计色相和彩度：中性 S≤0.12，高彩度 S≥0.55；暖色 H<70° 或 H≥330°，其余有色样本归入冷色族。这是粗略色相分组，不是测温或白平衡误差检测。
- 色相分散度为 12 桶归一化 Shannon entropy。数值高表示色相覆盖广，不能据此宣布画面杂乱或强行去色。
- 九宫格给出明暗和彩度的观察方向；不把 Vision 的全图标签当成对象边界。暗区可以保持暗调，亮区可以保持高调，建议不自动改动局部参数。
- “明亮通透”方案在原有高彩度覆盖较大时减少额外饱和度；保守还原与柔和氛围仍可并排比较。

### 2. 在所有调整叠加后检查颜色

新配方默认启用整体与局部协调，强度、细节保护和高彩度保护均为 0.65。“采用温和保护”会明确设为 0.75 / 0.8 / 0.8；“滤镜减弱 20%”将当前 LUT 强度乘以 0.8。

处理顺序：

```text
系统解码／ICC → 线性工作空间 → 全局光线和白平衡
→ 全局新增高饱和保护 → 几何校正 → 固定局部参考
→ LUT 前局部 → LUT 及亮度／肤色／中性保护 → LUT 后局部
→ 整体／局部最终颜色保护 → 目标 SDR 色域映射 → ICC 编码导出
```

最终保护在 OKLab 中比较候选与固定参考：

- 按亮度比例的立方根匹配参考色度，避免把纯曝光当成染色；保留已有冷暖和用户全局白平衡方向。
- 对新增色度、中性染色和明显色相偏移做平滑限幅。候选已经去饱和时，不强行恢复参考的原有彩度。
- 参考图的高通能量决定边缘／纹理权重，Gaussian 半径为短边的 3%，预览和全图使用同一相对尺度。细节处可提高保护，避免重叠调整在纹理中堆积颜色。
- 全图高彩度、中性、暗亮分布和色相分散度参与权重；局部按像素判断，重叠蒙版完成后还有一次整体约束。
- 调整色度后恢复候选的线性 Y；不在此阶段夹断扩展 RGB。输出映射单独承担色域边界。
- 禁用或强度为零时，保护函数返回原候选图。新配方仍保留末端目标色域映射；旧配方保护字段缺失时保留旧路径。

这是可调的启发式保护，不能保证最佳审美。刻意换色或强风格可能被减弱，可降低强度或关闭后对比。白平衡、全局冷暖与现有输入色偏仍需要先根据照片意图确定。

### 3. LUT 空间与输入范围

| 选项 | LUT 的原色／曲线 |
|---|---|
| sRGB | sRGB / sRGB |
| Linear sRGB | sRGB / 线性 |
| Display P3 | Display P3 / sRGB |
| Rec.709 Gamma 2.4 | Rec.709 / 纯 Gamma 2.4，旧 `rec709` 含义不变 |
| Rec.709 摄像机 OETF | Rec.709 / BT.709 OETF |

P3 LUT 在查表前做线性 sRGB→P3 原色转换，再编码；输出反编码后做 P3→线性 sRGB。不能在 P3 处理之前先挤入 sRGB。最终导出选 P3 时保留其更宽边界。

新版使用无 ICC 的 Float 数值表和八节点显式三线性查表，保持源表全部折点，不把低阶表平滑重采样成另一种函数。非零原点、半透明、非节点颜色与自定义 domain 均进入同一路径。`colorHarmony` 非空的配方以及新增 P3／OETF 模式使用此查表；缺少或显式为 `null` 的保护字段保留三种旧空间的原查表方式，即使随后保存成版本 3 也不悄悄切换。开启保护后才采用新版路径。

标准 `.cube` 可用 `DOMAIN_MIN/MAX` 或一个 `LUT_3D_INPUT_RANGE min max`，后者为三轴相同范围；两种写法混用、重复、非有限或不安全范围均拒绝。超出 domain 时平滑减弱 LUT 权重。1D/shaper 仍不支持。

表格诊断最多采样 9³ 个节点和 33 个灰阶点，提示输出超出 0–1、灰阶染色、亮度反转、低阶过渡及自定义输入范围。它是表格检查，不是照片曝光诊断或用途认证；创意 LUT 可以刻意触发这些提示。

`.cube` 不声明原色、Log 或 HDR，不能从文件名／TITLE 确认空间。当前只支持输入输出使用相同 RGB 空间及曲线的创意 LUT；Log、HDR、ACES 或跨空间技术变换需先正确转换，不能换一个菜单选项就宣称兼容。

### 4. 输出色域与报告

新版采用 OKLab 固定色相／明度、14 次二分收敛色度至所选 sRGB 或 P3 SDR 边界，域内像素直接通过。超 SDR 明度只能有限收敛，不能恢复过曝细节或替代 HDR 色调映射。预览和三个方案以导出 ICC 显示，切换目标空间会刷新预览缓存。

每张报告的 `colorQuality` 记录新增高色度、明显色相变化、中性染色和目标域外像素比例。参考为全局及几何之后的图像；before 为局部／LUT 叠加后，after 包括最终保护和目标映射。最长边 128 采样、alpha 加权，阈值变化是复核线索，不是审美分数，也不等于精确逐像素污染率。报告不把全局高饱和保护的第一次变化混入这个前后比较。

报告保留 `lutCompatibility`；自动批量记录还保留每张原图的 `analysis.colorScene`。所有测量不额外重复除 alpha。系统上下文明确输出直 RGB，alpha 仅作统计权重。

## 分级、分支与回滚

- 大型变更：符合用户 AGENTS.md 3.1 的新增功能、跨模块实现、配方格式和默认处理行为变化。
- 当前分支由 `git symbolic-ref --short HEAD` 实测为 `codex/color-harmony`；原集成分支为 `main`。
- 建分支 HEAD／已验证基线：`9e8f791d549ac58814cbd1f9176355cb26f9a4d0`。本轮开始时 `make check` 返回 0：70 tests / 0 failures。
- `main` 保持 `837ec592c5428e4e4cd360e91f2592d69321f92d`；没有 remote，仅本地。原 `feature/local-mask-harmony` 保留。
- 开工工作区、暂存区和 stash 为空；未清理、隐藏或改写用户现场。不执行 fetch/pull、安装、推送、PR 或发布。
- 采用三个 GPT‑6 Luna / max 子代理分别实现颜色保护、场景统计及独立空间兼容测试；文件写范围分离，主代理统一编译和验证，另行完成只读交叉审查。
- 回滚使用 `git revert <本轮提交>`；原片与已有导出不覆盖。打包脚本保留上一版应用。

## 实际验证与失败修正

命令默认工作目录 `/Users/mimi/project/ai调色`。本机 macOS 13.7.8 Intel x86_64 / Swift 5.8.1；证据位于忽略的 `artifacts/acceptance-colors-20261102/`。`make check` 是全部既有编译／类型检查／测试入口，无独立 lint。

| 完整命令 | 退出码 | 实际输出／证据 |
|---|---:|---|
| `make check`（开工基线） | 0 | 70 tests / 0 failures，5.453 秒；构建 12.77 秒。 |
| `swift build -j 2`（首轮） | 0 | 29.27 秒；`build-first.log`。 |
| `swift test -j 2`（首轮） | 1 | 99 tests / 5 failed assertions；`tests-first.log`。 |
| `swift test -j 2`（第二轮） | 1 | 99 tests / 1 failure，7.626 秒；`tests-second.log`。 |
| `make check`（第一轮完整通过） | 0 | 100 tests / 0 failures，7.393 秒；构建 16.79 秒；`check-final.log`。随后继续处理非节点 LUT 数值偏差与界面复核。 |
| `bash Scripts/build_app.sh`（首包） | 0 | Release 编译 49.25 秒；4 个签名 x86_64 库、55 XML、精确许可集合及可迁移加载路径通过；`release-build.log`。 |
| `swift test -j 2 --filter ColorCompatibilityTests.testSparseP3LUTMatchesCPUAtOffGridInputs`（使用增强表的首个非节点用例） | 0 | 1 test / 0 failures，1.168 秒；`sparse-before.log`。该表不同于最初失败变换，随后换回原变换继续复现。 |
| `swift test -j 2 --filter ColorCompatibilityTests.testSparseP3LUTMatchesCPUAtOffGridInputs`（换回原始失败变换） | 1 | 1 test / 1 failure，2³ 非节点 G 为 0.42837042，独立 CPU 为 0.42352936，超出 0.004 容差；`sparse-reproduced.log`。 |
| `swift test -j 2 --filter ColorCompatibilityTests`（加入显式查表，首轮） | 1 | 12 tests / 3 failed assertions；G 偏差消除，但发现 atlas 蓝轴方向颠倒；`precise-lut.log`。 |
| `swift test -j 2 --filter ColorCompatibilityTests`（蓝轴修正后） | 0 | 12 tests / 0 failures，4.758 秒；2/3/4/6/9/16/17/33 阶同一原始非节点 G 均为 0.42352933；`precise-lut-fixed.log`。 |
| `make check`（增加混合轴与最大表测试后） | 2 | 103 tests / 3 failed assertions，89.565 秒；仅 128³ 末节点错误，混合轴／domain／alpha／extent 通过；`check-delivery.log`。 |
| `swift test -j 2 --filter ColorCompatibilityTests.testMaximumDimensionLUTAddressesLastNode`（改为平铺后） | 0 | 1 test / 0 failures，77.409 秒，包含解析 2,097,152 行 LUT 及实际末节点渲染；`max-lut-tiled.log`。 |
| `make check`（平铺首轮） | 2 | 103 tests / 4 failed assertions，76.904 秒；最大表通过，6／9 阶的非节点对照暴露平铺列边界问题；`check-final-delivery.log`。 |
| `swift test -j 2 --filter 'ColorCompatibilityTests.testSparseP3LUTMatchesCPUAtOffGridInputs\|ColorCompatibilityTests.testPreciseLUTPreservesMixedAxisFunctionDomainAlphaAndExtent'` | 0 | 修正整数边界后 2 tests / 0 failures，9.709 秒；八种阶数非节点、混合三轴、分段折点、domain、alpha 与 extent 均通过；`tile-boundary-fixed.log`。 |
| `make check`（最终修复快照） | 0 | **103 tests / 0 failures**，116.447 秒，构建 3.81 秒；其中 128³ 解析及末节点渲染 96.674 秒；`check-verified.log`。 |
| `bash Scripts/build_app.sh`（最终源码包） | 0 | Release 编译 45.41 秒，包内库、数据库、许可、签名与可迁移路径均通过；`release-final-build.log`。上一包保留为 `build/PhotoAtelier.previous-20261102-010621.app`。 |

首轮失败均涉及新增测试或本次实现，未宣称是基线问题：

- 中性染色约束不够、细节保护强度方向不充分：调整平滑异常权重与细节放大系数，保留严格像素断言；曝光与去饱和回归也通过。
- 场景测试夹具未显式标为线性色彩空间：改为与测量定义相同的 extended linear sRGB，不改产品阈值。
- P3 差分 LUT 初始颜色差异不足；增强独立 CPU 可预测的原色差异。第二轮 2³ 仿射表有一个 G 通道 GPU／CPU 对照超 0.004 容差：先用 17³ 精确节点隔离矩阵，随后恢复原始非节点失败变换继续排查，没有以换夹具结束验证。
- 独立探针直接把已知码值交给系统 `CIColorCube`，源输入复读无误，查表 G 为 0.6738358，手算为 0.670398；改用 `CIColorCubeWithColorSpace` 的空空间也未消除。新版改用 atlas 上的显式三线性插值；同一原始失败样本最终 G 误差约 4e-8，且八种尺寸得到相同函数。不把低阶表盲目重采样，因为它可能抹去不对齐节点的折点。
- atlas 初次实现的蓝轴颠倒被 P3 identity 及有色表回归发现；按位图顶部行与 Core Image 坐标方向修正，严格原色断言保持。
- 最大 128³ 表使用 N² 宽条带时，末节点测试发现错误输出；改为蓝色切片平铺，最长边不超过 1536，保留全部原表节点。末节点实测通过；原始非节点回归进一步将容差从 0.004 收紧至 0.0003。
- 平铺后，6／9 阶测试发现部分蓝切片边界寻址错误；独立节点探针确认系统 kernel 的整除／取模近似会把 3/3 的结果落到 1 以下。已在整数节点编号的分块计算中加入安全边界裕量，并用相减计算余数，不修改 LUT 颜色或放宽断言。
- 交叉审查发现新配方关闭保护时显示的旧色域滑杆无效：仅对 `colorHarmony == nil` 的旧配方显示。新输出映射不读取该旧参数。
- 全局高饱和保护加入后，蒙版参考也必须走同一全局路径；已补充参考与处理像素一致测试。
- 应用自身快照发现分析长段重复与调色画面保留形状线；精简顶部概要，详细测量仍在专门面板与 JSON 中；流程快照关闭覆盖与形状线，并补充独立颜色协调控件布局快照。

保留 Core Image source kernel API 的系统弃用警告，不掩盖或临时禁用。后续系统升级需重验并规划 Metal 迁移。

基线失败：无；开工基线全部通过。本轮过程中发现的失败均已记录并修复，最终没有未解决的自动测试失败。最大表测试主要覆盖 2,097,152 行的解析及真实寻址，其耗时不能作为普通照片处理速度的基准。

### 最终包和导出验证

最终源码包从 `/tmp` 运行，清除开发目录环境变量，使用包内动态库及镜头库。验证输入沿用两张合成 PNG、一张坏 PNG 与已有真实 Canon EOS 1100D CR2；没有下载新照片。

| 完整命令 | 退出码 | 结果 |
|---|---:|---|
| `env -u PROJECT_ROOT /usr/bin/time -l '/Users/mimi/project/ai调色/build/PhotoAtelier.app/Contents/MacOS/PhotoAtelier' --self-test '/Users/mimi/project/ai调色/artifacts/acceptance-20261101/input' '/Users/mimi/project/ai调色/artifacts/acceptance-colors-20261102/output-final' '/Users/mimi/project/ai调色/artifacts/acceptance-colors-20261102/evidence-final'`（工作目录 `/tmp`） | 0 | **APP_SMOKE PASS · 20 checks · 3 exported · 1 isolated**；自身流程 18.149 秒、进程 real 19.39 秒，最大 RSS 925,577,216 bytes、peak footprint 1,249,492,992 bytes、0 swaps；`release-final-smoke.log`。 |
| `codesign --verify --deep --strict build/PhotoAtelier.app` | 0 | 最终包严格签名验证。 |
| `PYTHONOPTIMIZE=1 python3 Scripts/verify_app.py build/PhotoAtelier.app` | 0 | 4 个签名 x86_64 库、55 XML、精确许可集合及可迁移加载路径；Python 优化模式未跳过检查。 |
| `swift artifacts/acceptance-colors-20261102/verify_release.swift artifacts/acceptance-colors-20261102/output-final` | 0 | ImageIO 完整复读 3 张 TIFF，均 16-bit、Display P3、orientation 1；两张 1600×1067，真实 RAW 4272×2848；`export-properties-final.log`。 |
| `python3 artifacts/acceptance-colors-20261102/verify_reports.py artifacts/acceptance-colors-20261102/output-final artifacts/acceptance-colors-20261102/evidence-final` | 0 | 配方 v3、LUT 前蒙版及减选步骤保留；每张都有九区分析、保护及 LUT 诊断，所有比例有限；3 成功／1 隔离、20 项应用检查；`reports-final.log`。 |
| `python3 artifacts/acceptance-colors-20261102/audit_delivery.py` | 0 | 27 个变更文件，空白／疑似凭据／大文件／本地文档链接检查通过，记录 44 项源码指纹。 |
| `python3 -`（复读指纹，程序见下） | 0 | 最终包构建后 44 项源码指纹与完整检查快照一致。 |

长命令的标准输出实际通过 `set -o pipefail` 与 `2>&1 | tee <上述日志>` 留证；表中退出码取被测命令／流水线的真实结果。临时验证脚本与日志仅保留在忽略的证据目录，未混入产品提交。

指纹复读程序：

```python
import hashlib, json
from pathlib import Path
root = Path.cwd()
expected = json.loads(Path('artifacts/acceptance-colors-20261102/source-sha256.json').read_text())
actual = {
    str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
    for d in ['Sources', 'Tests', 'Scripts', 'Resources']
    for p in sorted((root / d).rglob('*'))
    if p.is_file() and '__pycache__' not in p.parts
}
if actual != expected:
    raise SystemExit('Source fingerprint changed')
print(f'PASS: {len(expected)} source fingerprints match validated source snapshot')
```

最终清单中的 P3 域外采样分别从 0.9467%、12.8309%、0.2206% 收敛为 0%。这是该三张样本、最长边 128 采样的统计，不作为全部照片的画质保证。原片 SHA-256 不变由应用流程再次检查。

已实际查看最终 `03-color-harmony-controls.png`、`03-color-harmony.png` 与 `05-raw-analysis.png`：保护开关、三个强度、实测与 LUT 诊断入口可见，文字无重叠；调色照片中形状／粉色覆盖已关闭；RAW 晨雾及道路保持可见，顶部概要精简，重点区域提示可见。快照由本应用视图渲染，不能替代鼠标验收。

既有入口对照：`make build`／`make test` 由最终 `make check` 完整覆盖；`make app` 由最终 `bash Scripts/build_app.sh` 覆盖。`make run` 的 Finder／真实交互、鼠标／系统选择器／退出确认**未执行**，本轮无可调用的原生自动化工具；保留人工清单。合并和合并后 `main` 回归**未执行**，按用户已确认的安排保留功能分支。没有使用 `--no-verify`，没有跳过用例。

首包命令（工作目录 `/tmp`）为：

```bash
env -u PROJECT_ROOT /usr/bin/time -l '/Users/mimi/project/ai调色/build/PhotoAtelier.app/Contents/MacOS/PhotoAtelier' --self-test '/Users/mimi/project/ai调色/artifacts/acceptance-20261101/input' '/Users/mimi/project/ai调色/artifacts/acceptance-colors-20261102/output-release' '/Users/mimi/project/ai调色/artifacts/acceptance-colors-20261102/evidence-release'
```

退出 0，`APP_SMOKE PASS · 20 checks · 3 exported · 1 isolated`；应用自身 20.863 秒，进程 real 22.46 秒，最大 RSS 952,954,880 bytes、peak footprint 1,258,430,464 bytes、0 swaps。`release-smoke.log`。这轮不含之后的精确 LUT 查表修复与独立颜色控件快照，不能代替最终包验证。

该首包另行执行 `codesign --verify --deep --strict build/PhotoAtelier.app` 和 `PYTHONOPTIMIZE=1 python3 Scripts/verify_app.py build/PhotoAtelier.app`，均退出 0；后者仍检查 4 个签名库、55 XML、许可与加载路径。

复核过首包自己的 `03-mask-refined.png`、`03-color-harmony.png` 和 `05-raw-analysis.png`：减选槽、羽化可见，真实 RAW 中的晨雾、树与路可见；同时发现形状线未关闭、主概要重复及完整页面截屏无法展示下方颜色控件，因此补充最终快照与上述 UI 修正。此复核不是用户照片的审美验收。

### 变更文件

修改：

```text
README.md
Sources/PhotoAtelier/AnalysisPanel.swift
Sources/PhotoAtelier/AppModel.swift
Sources/PhotoAtelier/ContentView.swift
Sources/PhotoAtelier/MaskInspector.swift
Sources/PhotoAtelier/SmokeHarness.swift
Sources/PhotoCore/AutomaticProcessing.swift
Sources/PhotoCore/BatchProcessor.swift
Sources/PhotoCore/LUTCube.swift
Sources/PhotoCore/Models.swift
Sources/PhotoCore/PhotoAnalysis.swift
Sources/PhotoCore/PhotoEngine.swift
Tests/PhotoCoreTests/EngineTests.swift
Tests/PhotoCoreTests/LocalMaskTests.swift
docs/masks.md
docs/validation.md
```

新增：

```text
Sources/PhotoAtelier/ColorHarmonyPanel.swift
Sources/PhotoCore/ColorHarmony.swift
Sources/PhotoCore/ColorQuality.swift
Sources/PhotoCore/ColorSceneAnalysis.swift
Sources/PhotoCore/LUTCompatibility.swift
Sources/PhotoCore/OutputGamut.swift
Tests/PhotoCoreTests/ColorCompatibilityTests.swift
Tests/PhotoCoreTests/ColorHarmonyTests.swift
Tests/PhotoCoreTests/ColorPipelineTests.swift
Tests/PhotoCoreTests/ColorSceneTests.swift
docs/color-harmony.md
```

无删除文件；照片、动态库、镜头库、应用、日志、诊断脚本与截图不进入提交。

## 已知边界与人工验收

- 未新增语义天空、头发、主体或皮肤分割；局部修边使用原有蒙版。整批几何位置不跟踪构图变化，颜色／亮度范围逐张重算，局部调整参数统一。
- 尚未验收 Apple Silicon、其他系统、其他真实相机 RAW 或大批量长时运行；一款 Canon CR2 不能代表所有 RAW。
- 原生自动化工具当前环境不可用；应用自身命令与视图快照不能替代鼠标、系统选择器、快捷键和退出确认验证。沿用用户决定保留功能分支，不合并。
- 真实用户照片的风格偏好、边缘与纹理效果仍需人工检查。保护可调，输出为 SDR，不承诺自动得到最佳画质。

建议人工复核：

- [ ] 在高彩度花草、肤色、中性墙面、暗部纹理、逆光照片上比较保护开／关及三种自动方案。
- [ ] 重叠 LUT 前／后蒙版，改变饱和度与冷暖，检查细节与周围区域的连贯性；关闭覆盖色再判断。
- [ ] sRGB／P3 切换后，主图与三种方案同步更新；在支持 P3 的显示器中比较 16 位导出。
- [ ] 导入作者说明明确的 P3、Rec.709 OETF、Gamma 2.4 LUT；保存、重载新旧配方。
- [ ] 完成原蒙版页列出的画笔、控制点、文件选择器、取消与退出交互验收。

全部人工项通过后再按用户决定合并，并执行主分支回归。当前没有需要重新确认的技术选型或依赖安装。

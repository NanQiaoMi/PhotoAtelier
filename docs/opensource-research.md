# 开源色彩与 RAW 组件调研

**资料快照：2026-11-01。** 项目版本、最新提交和许可证状态按调研当日公开 GitHub feeds 与仓库文件记录；之后可能变化。匿名 GitHub REST API 当时受到 rate limit，版本信息改用公开 Atom feeds 核对，源码和许可证按提交 SHA 固定引用。本文是技术选型资料，不代表本应用已集成或验证这些项目。

## 候选组件

| 项目 | 近期版本与维护情况 | 许可证 | 适用判断 |
|---|---|---|---|
| [darktable](https://github.com/darktable-org/darktable) | 稳定版 [5.6.2](https://github.com/darktable-org/darktable/releases/tag/release-5.6.2)（2026-10-06）；[最新提交](https://github.com/darktable-org/darktable/commit/58c75cfe8b51b8c11b3e1cc62f3f89afd5a74881)（10-31），另有 10-30 nightly | GPL-3.0 | 高质量的 RAW、颜色管线、3D LUT 和逐节点蒙版参考；不是可直接嵌入的库。 |
| [RawTherapee](https://github.com/RawTherapee/RawTherapee) | [5.13](https://github.com/RawTherapee/RawTherapee/releases/tag/5.13)（2026-07-26）；[最新提交](https://github.com/RawTherapee/RawTherapee/commit/b2ee504c47e5e6d5e054395aa12bf1fe43bd1c3c)（10-13） | GPL-3.0 | HaldCLUT 导入和色彩处理可作参考；是完整应用，不作为运行时依赖。 |
| [OpenColorIO](https://github.com/AcademySoftwareFoundation/OpenColorIO) | [2.6.0](https://github.com/AcademySoftwareFoundation/OpenColorIO/releases/tag/v2.6.0)（2026-10-01）；[最新提交](https://github.com/AcademySoftwareFoundation/OpenColorIO/commit/22dd9c4faa0d1b7cfb3d64d1a6e9cb454acc6cfd)（10-01） | BSD-3-Clause | 适合需要明确管理 scene/display、Log、ACES、多个 3D LUT 和显示视图的产品；本版不需要整套引入。 |
| [LibRaw](https://github.com/LibRaw/LibRaw) | [0.22.3](https://github.com/LibRaw/LibRaw/releases/tag/0.22.3)（2026-10-26）；[最新提交](https://github.com/LibRaw/LibRaw/commit/2caab57e269cc7fce17c3189e4d4d7e3e5861875)（10-20） | LGPL-2.1 或 CDDL-1.0，仓库 `COPYRIGHT` 明示双授权 | 可在系统 RAW 解码覆盖不足时评估为独立解码后端；必须固定线性输出、色彩空间和伽马参数。 |
| [rawpy](https://github.com/letmaik/rawpy) | [0.27.1](https://github.com/letmaik/rawpy/releases/tag/v0.27.1)（2026-08-30）；[最新提交](https://github.com/letmaik/rawpy/commit/c60c4fc933bfd3d50ec1d1e41797e5ae3d536e43)（10-29） | MIT wrapper；依赖 LibRaw，分发时还须核对 LibRaw 许可 | 适合作为 Python 原型或图像对照工具，不适合作为 Swift app 的运行时。 |
| [Lensfun](https://github.com/lensfun/lensfun) | 最新正式版 [v0.3.4](https://github.com/lensfun/lensfun/releases/tag/v0.3.4)（2023-07-12）；[最新提交](https://github.com/lensfun/lensfun/commit/bc5615d6278cb5fb75dd53e74015367453d5591d)（2026-10-28） | `libs/` LGPL-3.0；示例 app GPL-3.0；镜头数据库 CC BY-SA 3.0 | 提供镜头标定数据和畸变、横向色差、暗角修正能力；采用时要分别履行库与数据库的许可条件。 |
| [colour-science/colour](https://github.com/colour-science/colour) | [0.4.7](https://github.com/colour-science/colour/releases/tag/v0.4.7)（2025-12-06）；[develop 最新提交](https://github.com/colour-science/colour/commit/3ecbd61e785079a45948fb2fa4167628b4468d6e)（2026-10-27） | BSD-3-Clause | 作为传递函数和颜色计算的参考实现或 Python 测试 oracle；不作为 app 运行时。 |

## 可借鉴的处理设计

### LUT 要有明确输入与输出色彩合同

darktable 的 [`src/iop/lut3d.c`](https://github.com/darktable-org/darktable/blob/58c75cfe8b51b8c11b3e1cc62f3f89afd5a74881/src/iop/lut3d.c#L57-L78) 将 LUT 空间区分为 sRGB、Adobe RGB、gamma Rec.709、linear Rec.709/2020/ProPhoto，并将插值方法单独配置。[处理函数](https://github.com/darktable-org/darktable/blob/58c75cfe8b51b8c11b3e1cc62f3f89afd5a74881/src/iop/lut3d.c#L1142-L1168) 在工作空间与 LUT 空间之间显式转换，查表后转换回工作空间。

应用自定义 LUT 时应记录输入/输出 gamut、transfer function、domain/range、插值方式和 alpha 规则。不能把显示编码 LUT 当作 scene-linear LUT，也不应让一次 LUT 操作改变后续照片的工作空间或共享批处理状态。OpenColorIO 的 [`FileTransform`](https://github.com/AcademySoftwareFoundation/OpenColorIO/blob/22dd9c4faa0d1b7cfb3d64d1a6e9cb454acc6cfd/docs/guides/authoring/transforms.rst#L137-L149) 明确表示 LUT 文件变换；其配置提供了将色彩合同关联到颜色空间的机制。

RawTherapee 的 [`rtengine/clutstore.cc`](https://github.com/RawTherapee/RawTherapee/blob/b2ee504c47e5e6d5e054395aa12bf1fe43bd1c3c/rtengine/clutstore.cc#L21-L64) 展示了 Hald 图片的载入与工作空间转换。但它的 Hald 路径默认按 sRGB 处理，或从文件名后缀推断 profile（[`#L130-L140`](https://github.com/RawTherapee/RawTherapee/blob/b2ee504c47e5e6d5e054395aa12bf1fe43bd1c3c/rtengine/clutstore.cc#L130-L140)、[`#L292-L305`](https://github.com/RawTherapee/RawTherapee/blob/b2ee504c47e5e6d5e054395aa12bf1fe43bd1c3c/rtengine/clutstore.cc#L292-L305)）。这适合作为兼容既有素材的约定，不应当成通用 LUT 的可靠色彩元数据。

### Scene/display 变换要与调色阶段分开

OpenColorIO 的 [`colorspaces.rst`](https://github.com/AcademySoftwareFoundation/OpenColorIO/blob/22dd9c4faa0d1b7cfb3d64d1a6e9cb454acc6cfd/docs/guides/authoring/colorspaces.rst#L26-L35) 以 scene-reference 定义颜色空间关系；[`#L85-L96`](https://github.com/AcademySoftwareFoundation/OpenColorIO/blob/22dd9c4faa0d1b7cfb3d64d1a6e9cb454acc6cfd/docs/guides/authoring/colorspaces.rst#L85-L96) 展示 scene-reference 到 sRGB 的 display-only LUT，并在 [`#L209-L249`](https://github.com/AcademySoftwareFoundation/OpenColorIO/blob/22dd9c4faa0d1b7cfb3d64d1a6e9cb454acc6cfd/docs/guides/authoring/colorspaces.rst#L209-L249) 分类 scene-linear、display-linear、Log、SDR/HDR-video encoding。Look 还声明自己的 `process_space`，应用按 input → process → output 转换（[`looks.rst#L25-L34`](https://github.com/AcademySoftwareFoundation/OpenColorIO/blob/22dd9c4faa0d1b7cfb3d64d1a6e9cb454acc6cfd/docs/guides/authoring/looks.rst#L25-L34)）。

这说明创意 LUT 与最终显示变换是不同步骤。LUT 应按自身声明的输入空间执行；预览和导出再按目标显示器或嵌入配置文件转换，不能把所有 LUT 都放到显示变换后或全部当作线性场景 LUT。

### 蒙版应绑定到对应的调色节点与混合空间

darktable 的 [`pixelpipe_hb.c`](https://github.com/darktable-org/darktable/blob/58c75cfe8b51b8c11b3e1cc62f3f89afd5a74881/src/develop/pixelpipe_hb.c#L1863-L1963) 先处理模块，再混合该模块输出；[`blend.c`](https://github.com/darktable-org/darktable/blob/58c75cfe8b51b8c11b3e1cc62f3f89afd5a74881/src/develop/blend.c#L1631-L1689) 为 Raw、RGB display、RGB scene 和 Lab 选择不同混合实现。可借鉴的模型是每个局部调色节点管理自己的 mask 与 blend space，而不是把所有蒙版统一放在 LUT 前或显示变换后。若几何变换改变图像坐标，应让蒙版按约定的规范化坐标重映射。

### 畸变校正依赖相机与镜头标定数据

Lensfun 的 [`README.md`](https://github.com/lensfun/lensfun/blob/bc5615d6278cb5fb75dd53e74015367453d5591d/README.md#L33-L59) 区分库、app 和镜头数据库许可；[`lfModifier` API](https://github.com/lensfun/lensfun/blob/bc5615d6278cb5fb75dd53e74015367453d5591d/include/lensfun/lensfun.h.in#L2114-L2162) 要求镜头标定数据，并接收图像尺寸、crop factor 和焦距相关参数。darktable 也通过相机与镜头查询匹配 profile，并传入 crop、focal、aperture、distance（[`src/iop/lens.cc#L1066-L1095`](https://github.com/darktable-org/darktable/blob/58c75cfe8b51b8c11b3e1cc62f3f89afd5a74881/src/iop/lens.cc#L1066-L1095)）。没有准确 profile 时，应提示无匹配、跳过或允许用户选择 profile；通用 radial warp 不等同于镜头标定校正。

### RAW 解码、色彩计算和应用运行时可以分层

LibRaw 的 [`libraw/libraw.h`](https://github.com/LibRaw/LibRaw/blob/2caab57e269cc7fce17c3189e4d4d7e3e5861875/libraw/libraw.h#L89-L164) 分开提供 open/unpack/process 和输出色彩、位深、gamma 控制；其 [`COPYRIGHT`](https://github.com/LibRaw/LibRaw/blob/2caab57e269cc7fce17c3189e4d4d7e3e5861875/COPYRIGHT#L5-L12) 给出双授权。rawpy README 展示输出 16-bit linear TIFF 时明确使用 `gamma=(1,1)` 和关闭自动亮度（[`README.md#L26-L31`](https://github.com/letmaik/rawpy/blob/c60c4fc933bfd3d50ec1d1e41797e5ae3d536e43/README.md#L26-L31)）；它本身是 LibRaw 的 Python wrapper（[`README.md#L5-L6`](https://github.com/letmaik/rawpy/blob/c60c4fc933bfd3d50ec1d1e41797e5ae3d536e43/README.md#L5-L6)）。

`colour-science/colour` 的 [`sRGB transfer function`](https://github.com/colour-science/colour/blob/3ecbd61e785079a45948fb2fa4167628b4468d6e/colour/models/rgb/transfer_functions/srgb.py#L54-L100) 引用 IEC 61966-2-1 并实现 EOTF 与 inverse，可用于测试参考值；Python 包不必成为 macOS app 的依赖。

## 本版实际采用与未集成边界

- 本版运行时采用 Swift、Core Image、ColorSync、ImageIO、本机 Vision，以及通过原生 C ABI 动态加载的 Lensfun 0.3.4 与离线数据库。输入为 JPEG / PNG / 单页 TIFF 和系统 CIRAWFilter 支持的相机 RAW。没有复制 darktable 或 RawTherapee 的 GPL 源码；借鉴的是有源码证据的处理流程和色彩约定。
- 当前界面支持 sRGB、Rec.709 Gamma 2.4、linear sRGB；当前蒙版为径向、线性和画笔蒙版。蒙版是几何/绘制工具，不是语义识别或 AI 主体选择。
- 批处理使用同一归一化配方应用于所选照片。本版尚不支持 Log、ACES 或 HaldCLUT 工作流。这里列出的项目能力不应被表述为本版已实现。
- 本版不直接集成 LibRaw、rawpy、OpenColorIO 或 `colour-science/colour`。LUT 的 transfer、domain 映射、域外保护和 alpha 由本版图像引擎实现并测试；肤色约束属于启发式保护，不保证任意 LUT 的画质。本调研不能代替图像验证。

## Lensfun 实际接入与后续边界

用户已授权在项目内准备 Lensfun。固定 x86_64 原生库和 55 个 XML 文件可离线加载 948 款相机、1304 个镜头配置。自动模式只接受唯一、兼容的相机和镜头匹配；信息不足或歧义会跳过并记录警告，也可手动选择并提供真实焦距和裁切系数。默认关闭镜头校正以避免重复处理机内已校正 JPEG。实际启用的是标定畸变映射与安全缩放，未启用暗角和横向色差；大于 40 MP 时跳过此项。详细测试及打包结果以 [验证报告](validation.md) 为准，合成图测试不等于真实相机画质验收。

| 候选扩展 | 当前边界 | 引入前需要完成 |
|---|---|---|
| Lensfun | 已接入 C bridge、离线数据库、自动/手动配置与实际畸变变换；细节见 [lensfun-api.md](lensfun-api.md)。 | 后续扩充真实相机样片、较大照片内存验收，以及暗角/横向色差的独立验证；公开分发前备齐对应源码/构建材料。 |
| LibRaw | 未集成；当前 RAW 采用系统 CIRAWFilter 全分辨率解码。 | 系统缺少相机覆盖或需独立去马赛克控制时再评估；明确 LGPL-2.1 或 CDDL-1.0 路径，并定义线性 float、gamut、white balance、gamma 与曝光行为。 |
| OpenColorIO | 未集成；当前不支持 Log、ACES 或 HaldCLUT 工作流。 | 只有需要多套 scene/display transforms 或兼容外部专业配置时再评估；先版本化配置与 LUT 合同，并验证与 Core Image/Metal 的互操作。 |
| rawpy、colour-science/colour | 未集成；可作为 Python 侧的图像对照工具或 transfer-function 参考。 | 不作为 app 运行时；使用其测试素材或依赖时需分别核对样片与 LibRaw 许可。 |
| HaldCLUT | 当前不支持。 | 先规定 Hald level、输入/输出 gamut 与 transfer 的元数据规则及缺失信息提示，再核对每个素材包自身许可证。 |

Lensfun 代码与离线数据库属于不同授权对象，详见上表与 [Lensfun API / 分发说明](lensfun-api.md)。本版没有公开发布二进制。

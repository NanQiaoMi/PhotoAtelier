# Lensfun C API 核查与接入合同

**核查快照：2026-11-01。** 本文固定对比 Lensfun 0.3.4 tag commit [`101c745e`](https://github.com/lensfun/lensfun/commit/101c745e847a5de4a1e569a94368ce2027198598) 与当时 HEAD commit [`bc5615d`](https://github.com/lensfun/lensfun/commit/bc5615d6278cb5fb75dd53e74015367453d5591d)。C API 在两个版本之间有重命名和签名变化，必须将 bridge 头文件与 dylib 固定为同一版本。

## 版本差异

| 能力 | Lensfun 0.3.4 | 2026-11-01 HEAD |
|---|---|---|
| 数据库创建 | `lf_db_new()` / `lf_db_destroy()` | `lf_db_create()` / `lf_db_destroy()` |
| 离线数据库装载 | `lf_db_load_file(db, filename)` 读单个 XML；`lf_db_load_directory(db, dirname)` 读目录内 XML | `lf_db_load_path(db, pathname)`，`pathname` 可为 XML 文件或目录；不传路径的 `lf_db_load(db)` 会按系统路径搜索，不适合 app 内固定的离线资源 |
| 相机查询 | `lf_db_find_cameras(db, maker, model)` 或 `lf_db_find_cameras_ext(db, maker, model, sflags)` | 相同 |
| 镜头查询 | `lf_db_find_lenses_hd(db, camera, lensMaker, lensModel, sflags)` | `lf_db_find_lenses(db, camera, lensMaker, lensModel, sflags)` |
| modifier 创建 | `lf_modifier_new(lens, crop, width, height)`，再调用 `lf_modifier_initialize(...)` | `lf_modifier_create(lens, imgfocal, imgcrop, width, height, pixel_format, reverse)`，然后逐项 enable；没有 `lf_modifier_initialize` |
| Distortion / vignetting / scaling | 在 `flags` 中组合 `LF_MODIFY_DISTORTION`、`LF_MODIFY_VIGNETTING`、`LF_MODIFY_SCALE` 等 | `lf_modifier_enable_distortion_correction`、`lf_modifier_enable_vignetting_correction`、`lf_modifier_enable_scaling` |
| 镜头标定可用性 | `lf_lens_interpolate_distortion(lens, focal, &model)` | `lf_lens_available_modifications(lens, crop)`，或 `lf_lens_interpolate_distortion(lens, crop, focal, &model)` |

0.3.4 的 C API 声明见 [`lf_db_*` 与查询函数](https://github.com/lensfun/lensfun/blob/101c745e847a5de4a1e569a94368ce2027198598/include/lensfun/lensfun.h.in#L1675-L1745) 和 [`lf_modifier_*`](https://github.com/lensfun/lensfun/blob/101c745e847a5de4a1e569a94368ce2027198598/include/lensfun/lensfun.h.in#L2562-L2632)。HEAD 对应声明在 [`lf_db_*`](https://github.com/lensfun/lensfun/blob/bc5615d6278cb5fb75dd53e74015367453d5591d/include/lensfun/lensfun.h.in#L1857-L1914)、[`lf_modifier_*`](https://github.com/lensfun/lensfun/blob/bc5615d6278cb5fb75dd53e74015367453d5591d/include/lensfun/lensfun.h.in#L2703-L2755)。

### 0.3.4 初始化签名

```c
lfDatabase *lf_db_new(void);
lfError lf_db_load_file(lfDatabase *db, const char *filename);
cbool lf_db_load_directory(lfDatabase *db, const char *dirname);

lfModifier *lf_modifier_new(const lfLens *lens, float crop,
                            int width, int height);
int lf_modifier_initialize(lfModifier *modifier, const lfLens *lens,
                           lfPixelFormat format,
                           float focal, float aperture, float distance,
                           float scale, lfLensType target_geometry,
                           int flags, cbool reverse);
```

如需畸变与自动缩放，`flags` 必须同时包含 `LF_MODIFY_DISTORTION | LF_MODIFY_SCALE`，并将 `scale` 设为 `0.0f`。初始化先尝试加入畸变坐标 callback，再调用 scale callback；零值会通过 `GetAutoScale()` 根据已有坐标 callback 估算缩放，无需另行手动设置 callback。未包含 `LF_MODIFY_SCALE` 时，`scale=0` 不会启用缩放；函数返回的是实际启用的 `LF_MODIFY_*` 位掩码，应检查返回值中是否包含所需位。`LF_MODIFY_VIGNETTING` 才使用 `aperture` 和 `distance`；只做畸变时无需猜测这两个值。

### HEAD 创建与启用签名

```c
lfDatabase *lf_db_create(void);
lfError lf_db_load_path(lfDatabase *db, const char *pathname);

lfModifier *lf_modifier_create(const lfLens *lens, float imgfocal,
                               float imgcrop, int imgwidth, int imgheight,
                               lfPixelFormat pixel_format, bool reverse);
int lf_modifier_enable_distortion_correction(lfModifier *modifier);
int lf_modifier_enable_scaling(lfModifier *modifier, float scale);
int lf_modifier_enable_vignetting_correction(lfModifier *modifier,
                                              float aperture, float distance);
```

HEAD 中先创建 modifier、启用畸变，再用 `lf_modifier_enable_scaling(modifier, 0.0f)` 加自动缩放。实现将 `scale == 0` 转为 `GetAutoScale(reverse)`；若没有可用坐标回调或自动缩放返回零，该调用可能不启用 scaling。可查看 [HEAD modifier 实现](https://github.com/lensfun/lensfun/blob/bc5615d6278cb5fb75dd53e74015367453d5591d/libs/lensfun/modifier.cpp#L90-L149) 与 [0.3.4 scale callback](https://github.com/lensfun/lensfun/blob/101c745e847a5de4a1e569a94368ce2027198598/libs/lensfun/mod-coord.cpp#L209-L225)。

## 离线数据库

本地 app bundle 应传入明确的 XML 文件或数据库目录，不调用 `lf_db_load()` 的系统路径自动搜索。

- 0.3.4 `lf_db_load_directory()` 扫描目录顶层的 `*.xml`，不是递归遍历；它返回是否有数据库文件成功加载，并忽略单个 XML 文件的加载错误。因此应在打包/启动检查中确认预期镜头记录确实可查。
- HEAD `lf_db_load_path()` 内部区分文件和目录；目录加载逻辑同样读取其中 XML。对应实现见 [`database.cpp`](https://github.com/lensfun/lensfun/blob/bc5615d6278cb5fb75dd53e74015367453d5591d/libs/lensfun/database.cpp#L104-L153)。
- `lfError` 两版均为 `LF_NO_ERROR = 0`、`LF_WRONG_FORMAT`、`LF_NO_DATABASE`。0.3.4 `lf_db_load_directory()` 另返回 `cbool`；不要把它当成可报告每个 XML 解析错误的状态。
- Lensfun **库**由 `libs/` 下的 LGPL-3.0 覆盖；镜头数据库由 CC BY-SA 3.0 覆盖。仓库 README 明确区分这两类许可及 `apps/` 的 GPL-3.0，见 [`README.md`](https://github.com/lensfun/lensfun/blob/bc5615d6278cb5fb75dd53e74015367453d5591d/README.md#L33-L59)。离线 DB 必须单独保留来源、版本和许可说明。

## EXIF 匹配与歧义处理

相机 profile 使用 EXIF `Make` / `Model`：

```c
const lfCamera **cameras = lf_db_find_cameras(db, make, model);
// 需要搜索多语言名称时，才考虑较慢的 _ext 版本。
```

镜头 profile 使用相机候选、EXIF `LensMake`（没有则传 `NULL`）和完整 `LensModel`：

```c
// 0.3.4
const lfLens **lenses = lf_db_find_lenses_hd(
    db, camera, lens_make_or_null, lens_model, LF_SEARCH_SORT_AND_UNIQUIFY);

// HEAD
const lfLens **lenses = lf_db_find_lenses(
    db, camera, lens_make_or_null, lens_model, LF_SEARCH_SORT_AND_UNIQUIFY);
```

返回值为 `NULL` 或者 NULL 终止的候选数组。数组由调用方用 `lf_free((void *)array)` 释放；`lfCamera`、`lfLens` 对象归数据库所有，不能单独释放，且在数据库修改/销毁后不能继续使用。`lf_free()` 用于 Lensfun 分配的内存，避免跨 allocator 释放。C++ 文档说明相机/镜头查找按 score 排序，镜头列表是最可能到最不可能，但没有产品可直接采用的 confidence 阈值；`LF_SEARCH_LOOSE` 会放宽匹配，不能用于静默自动选镜头。`LF_SEARCH_SORT_AND_UNIQUIFY` 用于 UI 候选列表或确认是否仅剩一个镜头名称。参见 [search flags](https://github.com/lensfun/lensfun/blob/101c745e847a5de4a1e569a94368ce2027198598/include/lensfun/lensfun.h.in#L1319-L1340) 及 [`FindLenses` 说明](https://github.com/lensfun/lensfun/blob/101c745e847a5de4a1e569a94368ce2027198598/include/lensfun/lensfun.h.in#L1541-L1597)。

查找函数返回的候选指针数组是单独分配的，应以 `lf_free((void *)array)` 释放；其中相机和镜头对象本身仍归数据库所有。`lf_db_get_cameras()`、`lf_db_get_lenses()` 与 `lf_db_get_mounts()` 返回数据库持有的只读 NULL 终止列表，不要释放数组；列表在数据库修改前有效，数据库销毁后不可再访问。尤其不要把 `lf_db_get_lenses()` 的借用列表与 `lf_db_find_lenses_hd()` 的分配型候选列表混用释放规则。参见 0.3.4 的 [`GetLenses` / `FindLenses` 文档](https://github.com/lensfun/lensfun/blob/101c745e847a5de4a1e569a94368ce2027198598/include/lensfun/lensfun.h.in#L1541-L1615) 及 HEAD 的 [`GetLenses` 文档](https://github.com/lensfun/lensfun/blob/bc5615d6278cb5fb75dd53e74015367453d5591d/include/lensfun/lensfun.h.in#L1700-L1740)。

**Mount 兼容性：** 0.3.4 没有公开的 `lf_lens_check_compatibility()` 或 camera/lens mount 兼容性布尔函数。已选定相机 profile 时，应将该 `lfCamera *` 传给 `lf_db_find_lenses_hd()`；该 API 会用相机的 `Mount` 与 `CropFactor` 过滤镜头，并按数据库 mount compatibility 规则展开兼容卡口。不要只比较 `lfCamera.Mount` 与 `lfLens.Mounts` 中的字符串是否完全相等：前者是单个 mount 名，后者是 NULL 终止列表，兼容 mount 关系也可能使名称不同但实际可用。若产品只需查询而不需完整名称匹配，可用 `lf_db_find_lenses()` 的 `lfLens` 查询模板，但同样不要自行重写兼容性判断。详见 [`lfCamera` / `lfLens` 字段](https://github.com/lensfun/lensfun/blob/101c745e847a5de4a1e569a94368ce2027198598/include/lensfun/lensfun.h.in#L320-L333) 和 [`FindLenses(camera, maker, model)` 文档](https://github.com/lensfun/lensfun/blob/101c745e847a5de4a1e569a94368ce2027198598/include/lensfun/lensfun.h.in#L1541-L1575)。

应用应将候选数量、相机 `Variant` / crop factor、镜头 maker/model 展示给用户。严格匹配后无结果或候选不唯一时，跳过自动校正、写入原因并提供手动选择；不要仅因第一候选排序在前就自动套用。

`lfCamera` 两版均公开 `Maker`、`Model`、`Variant`、`Mount`、`CropFactor` 和内部搜索 `Score`，没有 `SensorFormat` 字段。`lfLens` 包含 `Maker`、`Model`、焦段/光圈范围、mount、投影类型和标定信息；其中 `CropFactor` 对镜头表示标定 crop。HEAD 已将 `lfLens` 的旧 `Mounts`、`CropFactor`、`AspectRatio`、`Calib*` 字段标为 deprecated，应使用 `lf_lens_get_mount_names`、`lf_lens_available_modifications` 及带 crop 参数的 `lf_lens_interpolate_*` API。数据结构见 [0.3.4 `lfCamera`](https://github.com/lensfun/lensfun/blob/101c745e847a5de4a1e569a94368ce2027198598/include/lensfun/lensfun.h.in#L320-L333)、[0.3.4 `lfLens`](https://github.com/lensfun/lensfun/blob/101c745e847a5de4a1e569a94368ce2027198598/include/lensfun/lensfun.h.in#L801-L848)、[HEAD `lfLens`](https://github.com/lensfun/lensfun/blob/bc5615d6278cb5fb75dd53e74015367453d5591d/include/lensfun/lensfun.h.in#L1010-L1056)。

**EXIF 数值合同：** `FocalLength` 必须使用实际物理焦距毫米数；不要用 `FocalLengthIn35mmFilm` 替代。相机 `CropFactor` 来自 camera profile。`f-number` 与对焦距离（米）只供暗角模型插值；缺失时跳过暗角校正，不要伪造数值。畸变 profile 是否能在当前 crop/focal 插值，应检查 `lf_modifier_enable_distortion_correction()` 返回位或调用相应的 `lf_lens_interpolate_distortion()`；返回不可用则跳过并告知用户。

## modifier、target geometry 与采样 map

`LF_MODIFY_DISTORTION` 是普通镜头畸变校正。`LF_MODIFY_GEOMETRY` / HEAD 的 `lf_modifier_enable_projection_transform(modifier, target_projection)` 是单独的投影变换，例如鱼眼转 rectilinear；除非产品明确提供该控制，不要自动将投影转换与普通 distortion correction 混为一项。

`target_geometry` 的类型是 `lfLensType`，不是 union。枚举包括 `LF_UNKNOWN`、`LF_RECTILINEAR`、`LF_FISHEYE`、`LF_PANORAMIC`、`LF_EQUIRECTANGULAR` 及鱼眼投影类型。若 0.3.4 只启用 `LF_MODIFY_DISTORTION | LF_MODIFY_SCALE`，初始化中的 `target_geometry` 不参与变换，因为投影转换只有在 `flags` 包含 `LF_MODIFY_GEOMETRY` 时才会执行；这时传 `LF_UNKNOWN` 不会额外关闭 distortion，也不代表一个可用的目标投影。

像素格式为 `lfPixelFormat`，0.3.4 与 HEAD 都包括 `LF_PF_U8/U16/U32/F32/F64`；用 float 像素时为 `LF_PF_F32`。普通 geometry-map API 不读写像素，因此其 `pixel_format` 不影响 map 坐标。若后续直接用 `lf_modifier_apply_color_modification()` 做暗角，需另传 `comp_role`；RGBA 可用 `LF_CR_4(RED,GREEN,BLUE,UNKNOWN)` 让 Lensfun 不碰 alpha，`row_stride` 的单位是**字节**。

普通畸变 map 的 C API 两版一致：

```c
cbool lf_modifier_apply_geometry_distortion(
    lfModifier *modifier, float xu, float yu,
    int width, int height, float *res);
```

`xu/yu` 是输出（未畸变）目标块在整张图坐标系中的起点，`width/height` 是块尺寸。Lensfun 为目标块每个像素输出一个原图 source `(x,y)` 浮点坐标对，`res` 至少有 `width * height * 2` floats；该坐标是像素坐标而非归一化 UV。调用方用这些 source 坐标从原始畸变图采样，完成逆向重映射；这样能避免正向变换产生空洞。几何 API **没有行 stride 参数**，map 是连续坐标数组；bridge 对像素源/目标缓冲区必须使用自身的 `bytesPerRow`。Header 文档还要求 map 缓冲区至少 16-byte 对齐；返回 `cbool` 表示 map 是否已填充。

若同时要做横向色差校正，使用 `lf_modifier_apply_subpixel_geometry_distortion()`：每像素输出红、绿、蓝各自的 `(x,y)`，至少 `width * height * 6` floats；文档指出它将 geometry 与 subpixel/TCA 坐标合并，避免分两次重采样。普通 distortion-only 使用 2-float map。详见 [geometry map 文档与声明](https://github.com/lensfun/lensfun/blob/101c745e847a5de4a1e569a94368ce2027198598/include/lensfun/lensfun.h.in#L2315-L2423) 和 [C 声明](https://github.com/lensfun/lensfun/blob/101c745e847a5de4a1e569a94368ce2027198598/include/lensfun/lensfun.h.in#L2617-L2632)。

### Autoscale 与有效区域

Lensfun 提供 `GetAutoScale(reverse)` / `lf_modifier_get_auto_scale(modifier, reverse)`，要求先设置坐标畸变 callbacks。文档说明它会近似寻找一个不取到无效图像范围的缩放值，但不保证强畸变下没有黑角。两版的 `scale = 0` callback 会自动计算该值：0.3.4 用 `lf_modifier_initialize(... scale=0, flags 包含 LF_MODIFY_SCALE ...)`；HEAD 用 `lf_modifier_enable_scaling(modifier, 0)`。

在 0.3.4 与本次核对的 HEAD header/source 中，未发现 `mapValidBounds`、valid rectangle 或 auto-crop 返回 API。若产品需要精确有效区域，应基于同一 geometry map 检查 source 坐标是否落在 `[0,width-1] × [0,height-1]`，再生成有效 mask 或计算可显示裁切矩形；不要把 Lensfun autoscale 当成严格边界证明。对图块处理，要在创建 modifier 时传整图原始宽高，map 的 `xu/yu` 使用整图目标坐标，不要只传 tile 尺寸并把 tile-local 坐标当整图坐标。

## JPEG/TIFF 重复校正策略

Lensfun API 按相机/镜头标定参数计算 profile 校正；它不判断 JPEG/TIFF 是否已由相机固件或上游软件 baked-in 校正。EXIF 仍然可能保留 camera/lens 字段，所以只匹配到 lens profile 并不能证明图像未校正。

JPEG/PNG/TIFF 的校正开关默认 **关闭**，避免重复处理机内已校正的照片。用户显式开启后，`Auto` 只在相机/镜头配置可靠且唯一时应用；缺失或歧义会说明原因，也可手动选择配置。PNG 或缺失 Make/Model/LensModel/FocalLength 的文件不猜测。当前也已加入系统 CIRAWFilter 全尺寸 RAW 解码，并关闭其自带镜头变换；RAW 同样保留显式启用开关，开启后执行相同的严格 Lensfun 匹配，尚未采用与 raster 不同的自动默认策略。

本节记录 API 能力与接入合同；Lensfun bridge、离线数据打包和照片效果在完成构建及目标样片验收前均为待验证。

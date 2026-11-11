# Lensfun 本机依赖

首版依赖固定为 Lensfun 0.3.4.0，面向 macOS 13 及以上的 x86_64。准备脚本从一个固定哈希的 PyPI wheel 提取原生库和该 wheel 随附的离线 XML 数据库，不安装 lensfunpy、NumPy、GLib、CMake、pkg-config 或 Homebrew。应用运行时只调用 Lensfun 的公开 C API，不需要 Python。

## 准备与校验

在目标 Mac 上运行：

```sh
python3 Scripts/prepare_lensfun.py
python3 Scripts/prepare_lensfun.py --verify
```

第一次运行下载 wheel、Lensfun 0.3.4 官方头文件模板和许可文本。脚本核对来源 SHA-256，生成以下被 `.gitignore` 忽略的项目内目录：

```text
.dependencies/lensfun/
  include/lensfun/lensfun.h
  lib/liblensfun.0.3.4.dylib
  lib/libglib-2.0.0.dylib
  lib/libpcre2-8.0.dylib
  lib/libintl.8.dylib
  db/*.xml
  licenses/*
  manifest.json
```

脚本使用 `ctypes.CDLL` 加载本机 dylib，再通过 Lensfun 0.3.4 的公开 C API 创建数据库、加载 `db` 目录并查询相机和镜头；测试不导入 lensfunpy，也不访问照片。成功结果记录在 manifest 中。`--verify` 只校验现有文件并重跑该查询，不下载文件。若目标目录存在但没有由脚本生成的有效 manifest，脚本会停止，不覆盖现有内容。

## 固定来源与体积

| 组件 | 固定来源 | 版本与 SHA-256 | 许可 |
| --- | --- | --- | --- |
| 原生库、离线 DB、lensfunpy MIT 许可文本 | [PyPI lensfunpy 1.18.0 wheel](https://pypi.org/project/lensfunpy/1.18.0/) | `lensfunpy-1.18.0-cp311-cp311-macosx_13_0_x86_64.whl`, 1,646,049 bytes; `be571910cce193dbd98cdbc4ca3f96c42e590c526f4820cbe9ec018989b95e71` | wheel 中的 Python wrapper 为 MIT；其 Python 扩展不复制进应用 |
| C API 头文件模板 | [Lensfun v0.3.4 `lensfun.h.in`](https://github.com/lensfun/lensfun/blob/v0.3.4/include/lensfun/lensfun.h.in) | commit `101c745e847a5de4a1e569a94368ce2027198598`; `6bdef77b5d2102269aca6351cbb0e169f2b23128599c9f5861f38c4fd33c1cc8` | LGPL-3.0-or-later，见随包许可文件 |
| Lensfun 许可文本 | [Lensfun v0.3.4 `docs/lgpl-3.0.txt`](https://github.com/lensfun/lensfun/blob/v0.3.4/docs/lgpl-3.0.txt) | `a853c2ffec17057872340eee242ae4d96cbf2b520ae27d903e1b2fef1a5f9d1c` | LGPL-3.0-or-later |
| LGPL-3.0 中引用的 GPL-3.0 文本 | [Lensfun v0.3.4 `docs/gpl-3.0.txt`](https://github.com/lensfun/lensfun/blob/v0.3.4/docs/gpl-3.0.txt) | `8ceb4b9ee5adedde47b31e975c1d90c73ad27b6b165a1dcd80c7c545eb65b903` | GPL-3.0 |
| 数据库许可文本 | [Lensfun v0.3.4 `docs/cc-by-sa-3.0.txt`](https://github.com/lensfun/lensfun/blob/v0.3.4/docs/cc-by-sa-3.0.txt) | `0e15ce5245342be97a03846ed605c2ff76c926719b759262df8c698be2af2bb7` | CC BY-SA 3.0 |

实际随项目准备的原生库与数据库的哈希如下。DB 是压缩 wheel 中的 XML 原样解压；manifest 逐个记录每个 XML 的哈希。

| 输出文件 | 大小 | SHA-256 | 许可 / 许可来源 |
| --- | ---: | --- | --- |
| `lib/liblensfun.0.3.4.dylib` | 154,288 bytes | `5a3e6081ae89903d13fbef3ef0c9fad75374b551ca7b3691d77b4ff665d3df9c` | LGPL-3.0-or-later; binary pinned to the wheel above, reports version 0.3.4 |
| `lib/libglib-2.0.0.dylib` | 1,753,840 bytes | `d97ffeba800f131cc7bcaf17b02ee13cd06555ff2135e20a29b72e95719b0c29` | LGPL-2.1-or-later; [GLib license](https://github.com/GNOME/glib/blob/main/LICENSES/LGPL-2.1-or-later.txt), SHA-256 `fa6f36630bb1e0c571d34b2bbdf188d08495c9dbf58f28cac112f303fc1f58fb` |
| `lib/libpcre2-8.0.dylib` | 771,712 bytes | `b13cbac155828bbeaed46b4def1a5c037fc7c24816e3da08d4f349e7fe44a87d` | BSD-3-Clause with PCRE2 exception; [PCRE2 license](https://github.com/PCRE2Project/pcre2/blob/main/LICENCE.md), SHA-256 `197d8a73ffee0d6b09adba2f9c677b5f5aede24edf89258a68e48248d010d811` |
| `lib/libintl.8.dylib` | 171,984 bytes | `d0e587167ffaf852d95c74c5ebabaf1e7e76ab08152e0177a325d056bf6d2c02` | LGPL-2.1-or-later; [gettext `COPYING.LIB`](https://github.com/autotools-mirror/gettext/blob/master/gettext-runtime/intl/COPYING.LIB), SHA-256 `20e50fe7aae3e56378ebf0417d9de904f55a0e61e4df315333e632a4d3555d95` |
| `include/lensfun/lensfun.h` | 96,917 bytes | `c5b7f093dd6509ccf0ed23ca02b95a94b58632afbc27abe2d5f5a3cfd0861d7d` | Generated from the fixed Lensfun header template above |
| `db/*.xml` | 55 files; 4,249,579 bytes | Individual hashes are in manifest | CC BY-SA 3.0; pinned to the wheel SHA above |

准备脚本也查询 wheel 内依赖暴露的版本信息，并将实测值写入 manifest 的 `native_dependency_versions`：`pcre2_config_8(PCRE2_CONFIG_VERSION, ...)` 返回 PCRE2 `10.47 2025-10-21`，返回长度 17 包含结尾 NUL；`libintl.8.dylib` 导出 `libintl_version` 整数符号，当前值为 `5636`（十六进制 `0x1604`）。gettext 这个符号不是可读版本字符串，脚本不把它推断为 gettext 发布版本；这两个二进制的精确来源仍由上面的 wheel SHA-256 固定。`--verify` 会重新查询并比较 manifest 中的值。

`.dependencies/lensfun/licenses/` 包含以上许可全文及 wheel 内的 `lensfunpy` MIT 许可文件。MIT 文件的 SHA-256 为 `bcf22e2bce762266d9588d2b39955930016a3892868bb9579189fe626253b947`；对应的 Python 扩展本身没有复制。

wheel 的 55 个 XML 文件共 4,249,579 bytes，4 个 dylib 共 2,851,824 bytes。准备后的全部文件（不含 `manifest.json`）为 7,284,504 bytes。数据库版本来源就是 wheel 1.18.0 中的 `db_files` 快照，并由 wheel SHA-256 固定；脚本不从 Lensfun 当前分支另取数据库，避免库与数据混版。每个提取文件的 SHA-256、许可源和 C API 查询结果写入 `manifest.json`。

原生依赖许可证如下，许可全文也放在 `licenses/`：

- `liblensfun.0.3.4.dylib`：LGPL-3.0-or-later。Lensfun v0.3.4 README 将库标为 LGPL v3；头文件自身也允许 LGPL v2 或之后版本。
- `db/*.xml`：CC BY-SA 3.0。应用分发时应保留 Lensfun 数据库署名和相同许可声明。
- `libglib-2.0.0.dylib`：LGPL-2.1-or-later，wheel 中查询到 GLib 2.79.1。
- `libpcre2-8.0.dylib`：BSD-3-Clause with PCRE2 exception，公开配置 API 返回版本 `10.47 2025-10-21`。
- `libintl.8.dylib`：LGPL-2.1-or-later；导出的 `libintl_version` 整数值为 `5636`，没有据此宣称可读的 gettext 发布版本。
- wheel 内的 lensfunpy wrapper 许可是 MIT；应用不带它的 Python 扩展或 NumPy 依赖。

GLib、PCRE2 与 gettext 许可文本来源和哈希记录在 manifest 中。分发包含 LGPL 动态库的应用时，发行包需要满足相应的许可、源代码获取和用户替换/重链接条件；打包发布前应确认这些材料随应用交付。

## C API 和应用包路径

生成的 `include/lensfun/lensfun.h` 来自上述官方 v0.3.4 模板，只配置版本宏为 `0.3.4.0`。桥接代码应包含这个文件，并使用其声明的 `lf_db_new`、`lf_db_load_directory`、`lf_db_get_cameras`、`lf_db_get_lenses`、`lf_db_find_cameras`、`lf_db_find_lenses_hd` 和 `lf_db_destroy` 等公开接口。

所有 dylib 必须放在同一个目录，因为 Lensfun 的 GLib、gettext 和 PCRE2 依赖使用 `@loader_path`。当前 `.dependencies` 路径用于开发；应用包使用：

```text
MyApp.app/Contents/Frameworks/Lensfun/liblensfun.0.3.4.dylib
MyApp.app/Contents/Frameworks/Lensfun/libglib-2.0.0.dylib
MyApp.app/Contents/Frameworks/Lensfun/libpcre2-8.0.dylib
MyApp.app/Contents/Frameworks/Lensfun/libintl.8.dylib
MyApp.app/Contents/Resources/Lensfun/db/*.xml
MyApp.app/Contents/Resources/Lensfun/licenses/*
```

桥接层应通过 dylib 的实际路径 `dlopen`，并将数据库资源目录显式传给 `lf_db_load_directory`。wheel 中 dylib 的自身 `LC_ID_DYLIB` 带有构建机绝对路径；打包时先将四个库与本机已验证 manifest 的源 SHA-256 对照，再把自身 install ID 规范化为 `@loader_path/<库文件名>`。库依赖项仍逐一检查，不会因修正自身 ID 而放宽加载路径门禁。签名后 manifest 另记录 bundle 内 dylib 的哈希。

打包后的 app 会把本指南和准备脚本复制到 `Contents/Resources/docs/lensfun-build.md` 与 `Contents/Resources/Scripts/prepare_lensfun.py`，第三方声明中的相对链接可在 app 资源目录中打开。当前构建仅面向本机验证：其中的 wheel 和准备脚本记录了固定二进制来源及提取过程，但 app 不包含 GLib、PCRE2、gettext 等每个 LGPL 库的完整对应源码树或完整发行构建环境。公开分发前仍需单独准备并随发行物提供各许可要求的对应源码、修改记录和构建材料；本机 app 不应被视为公开发行包。

## Universal 双架构构建说明

主应用 `PhotoAtelier` 支持构建为 Universal 二进制（`x86_64` + `arm64`，通过 `bash Scripts/build_app.sh --universal` 打包），在 Intel Mac 及 Apple Silicon Mac 原生运行。Lensfun 运行时当前动态库保持固定来源的 `x86_64` 构建，在 Apple Silicon 上由系统通过 Rosetta 2 动态兼容加载或待后续引入原生 arm64 wheel 升级。

## 本机实测

准备脚本的本机 C API 查询结果：`lf_db_load_directory` 返回成功；数据库枚举出 948 个相机和 1304 个镜头；`Canon EOS 5D Mark IV` 查询命中 1 个相机，`Canon EF 24-70mm f/2.8L USM` 命中 2 个镜头。查询加载的是 `.dependencies/lensfun/db` 中由 wheel 固定的 XML 文件。

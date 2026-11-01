# Third-party notices

Photo Atelier's original application and bridge code is MIT licensed. The application
uses macOS system frameworks under Apple's platform terms and bundles the native
open source components below. No darktable or RawTherapee GPL source or UI assets
have been copied into this application.

## Bundled components

| Component | Copyright / source | License |
| --- | --- | --- |
| Lensfun 0.3.4 | Lensfun contributors, [source](https://github.com/lensfun/lensfun/tree/v0.3.4) | LGPL-3.0-or-later |
| Lensfun camera/lens database | Lensfun database contributors and the authors credited in individual XML files, [project](https://lensfun.github.io/) | CC BY-SA 3.0 |
| GLib | GLib/GNOME contributors, [source](https://gitlab.gnome.org/GNOME/glib) | LGPL-2.1-or-later |
| PCRE2 | University of Cambridge, Philip Hazel, Zoltan Herczeg and PCRE2 contributors, [source](https://github.com/PCRE2Project/pcre2) | BSD-3-Clause with PCRE2 exception |
| GNU gettext libintl | Free Software Foundation and gettext contributors, [source](https://www.gnu.org/software/gettext/) | LGPL-2.1-or-later |

Native dylibs and the exact, unmodified database XML snapshot are extracted from the
SHA-256 pinned [lensfunpy 1.18.0 macOS x86_64 wheel](https://pypi.org/project/lensfunpy/1.18.0/).
The Python extension and NumPy are not bundled or used. The wheel's MIT license is
retained as an additional provenance notice. Source build recipes are available in
the [lensfunpy project](https://github.com/letmaik/lensfunpy/tree/v1.18.0).

Full license texts, original XML attribution, exact source URLs, artifact hashes and
version information are included in the app at:

```
Contents/Resources/Lensfun/licenses/
Contents/Resources/Lensfun/db/
Contents/Resources/Lensfun/source-manifest.json
```

The database has not been modified; it remains CC BY-SA 3.0. If distributing a
modified database, retain attribution and distribute those modifications under
the same license. The original XML files include their contributor notices.

## Replacing the LGPL libraries

Libraries remain separate dynamic files under `Contents/Frameworks/Lensfun/`.
Photo Atelier uses the public Lensfun C ABI via `dlopen`; it does not statically
merge the libraries into its executable. Users may replace them with ABI-compatible
x86_64 builds of the named libraries for their own use. Local code signatures may
need to be renewed after replacement. No technical lock in the app prevents this,
and LGPL rights, including reverse engineering for debugging such modifications,
are not restricted by the application's MIT license.

The bundled build guide and pinned preparation recipe are available at
[docs/lensfun-build.md](docs/lensfun-build.md) and
[Scripts/prepare_lensfun.py](Scripts/prepare_lensfun.py). In the app these files are
at `Contents/Resources/docs/lensfun-build.md` and
`Contents/Resources/Scripts/prepare_lensfun.py`. The recipe records the pinned
binary inputs and extraction steps; it is not a complete copy of every upstream
library source tree. A public redistribution must include the corresponding source
and build materials required by each license. This package is for local validation
only and has not been prepared for public binary distribution.

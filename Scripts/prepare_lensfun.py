#!/usr/bin/env python3
"""Fetch and verify the pinned native Lensfun runtime and offline database.

This only extracts native libraries and XML data from a pinned wheel. It does
not install lensfunpy, NumPy, GLib, CMake, or any Python runtime into the app.
"""

from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
import platform
import shutil
import sys
import tempfile
import urllib.request
from pathlib import Path, PurePosixPath
from zipfile import BadZipFile, ZipFile


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / ".dependencies" / "lensfun"

WHEEL_FILENAME = "lensfunpy-1.18.0-cp311-cp311-macosx_13_0_x86_64.whl"
WHEEL_URL = (
    "https://files.pythonhosted.org/packages/20/51/674d24a7eccf33597ba575c0edda82ce789e24eee6bd20befade635072d9/"
    + WHEEL_FILENAME
)
WHEEL_SHA256 = "be571910cce193dbd98cdbc4ca3f96c42e590c526f4820cbe9ec018989b95e71"
WHEEL_SIZE = 1_646_049
WHEEL_RELEASE = "https://pypi.org/project/lensfunpy/1.18.0/"

LENSFUN_TAG = "v0.3.4"
LENSFUN_COMMIT = "101c745e847a5de4a1e569a94368ce2027198598"
HEADER_TEMPLATE_URL = (
    "https://raw.githubusercontent.com/lensfun/lensfun/"
    + LENSFUN_TAG
    + "/include/lensfun/lensfun.h.in"
)
HEADER_TEMPLATE_SHA256 = "6bdef77b5d2102269aca6351cbb0e169f2b23128599c9f5861f38c4fd33c1cc8"

LICENSE_ASSETS = {
    "LICENSE-GPL-3.0.txt": {
        "url": "https://raw.githubusercontent.com/lensfun/lensfun/v0.3.4/docs/gpl-3.0.txt",
        "sha256": "8ceb4b9ee5adedde47b31e975c1d90c73ad27b6b165a1dcd80c7c545eb65b903",
        "license": "GPL-3.0",
        "applies_to": ["License terms referenced by LGPL-3.0-or-later"],
    },
    "LICENSE-Lensfun-LGPL-3.0.txt": {
        "url": "https://raw.githubusercontent.com/lensfun/lensfun/v0.3.4/docs/lgpl-3.0.txt",
        "sha256": "a853c2ffec17057872340eee242ae4d96cbf2b520ae27d903e1b2fef1a5f9d1c",
        "license": "LGPL-3.0-or-later",
        "applies_to": ["liblensfun.0.3.4.dylib", "lensfun.h"],
    },
    "LICENSE-Lensfun-DB-CC-BY-SA-3.0.txt": {
        "url": "https://raw.githubusercontent.com/lensfun/lensfun/v0.3.4/docs/cc-by-sa-3.0.txt",
        "sha256": "0e15ce5245342be97a03846ed605c2ff76c926719b759262df8c698be2af2bb7",
        "license": "CC-BY-SA-3.0",
        "applies_to": ["db/*.xml"],
    },
    "LICENSE-GLib-LGPL-2.1-or-later.txt": {
        "url": "https://raw.githubusercontent.com/GNOME/glib/main/LICENSES/LGPL-2.1-or-later.txt",
        "sha256": "fa6f36630bb1e0c571d34b2bbdf188d08495c9dbf58f28cac112f303fc1f58fb",
        "license": "LGPL-2.1-or-later",
        "applies_to": ["libglib-2.0.0.dylib"],
    },
    "LICENSE-PCRE2-BSD-3-Clause-with-exception.md": {
        "url": "https://raw.githubusercontent.com/PCRE2Project/pcre2/main/LICENCE.md",
        "sha256": "197d8a73ffee0d6b09adba2f9c677b5f5aede24edf89258a68e48248d010d811",
        "license": "BSD-3-Clause WITH PCRE2-exception",
        "applies_to": ["libpcre2-8.0.dylib"],
    },
    "LICENSE-gettext-LGPL-2.1-or-later.txt": {
        "url": "https://raw.githubusercontent.com/autotools-mirror/gettext/master/gettext-runtime/intl/COPYING.LIB",
        "sha256": "20e50fe7aae3e56378ebf0417d9de904f55a0e61e4df315333e632a4d3555d95",
        "license": "LGPL-2.1-or-later",
        "applies_to": ["libintl.8.dylib"],
    },
}

WHEEL_LICENSE_PATH = "lensfunpy-1.18.0.dist-info/licenses/LICENSE"
WHEEL_LICENSE_OUTPUT = "LICENSE-lensfunpy-MIT.txt"
WHEEL_LICENSE_SHA256 = "bcf22e2bce762266d9588d2b39955930016a3892868bb9579189fe626253b947"
MAX_LICENSE_BYTES = 1_000_000

EXPECTED_DYLIBS = {
    "liblensfun.0.3.4.dylib",
    "libglib-2.0.0.dylib",
    "libpcre2-8.0.dylib",
    "libintl.8.dylib",
}
EXPECTED_DB_XML_COUNT = 55
EXPECTED_DB_BYTES = 4_249_579


class PreparationError(RuntimeError):
    pass


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def fetch_pinned(url: str, expected_sha256: str, expected_size: int | None = None) -> bytes:
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "PhotoAtelier-Lensfun-preparer/1.0"},
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            limit = expected_size if expected_size is not None else MAX_LICENSE_BYTES
            chunks: list[bytes] = []
            total = 0
            while True:
                block = response.read(min(64 * 1024, limit - total + 1))
                if not block:
                    break
                chunks.append(block)
                total += len(block)
                if total > limit:
                    raise PreparationError("Download exceeded the pinned size limit for {}".format(url))
            data = b"".join(chunks)
    except Exception as error:
        raise PreparationError("Download failed for {}: {}".format(url, error)) from error
    actual_sha256 = sha256_bytes(data)
    if actual_sha256 != expected_sha256:
        raise PreparationError(
            "SHA256 mismatch for {}: expected {}, got {}".format(
                url, expected_sha256, actual_sha256
            )
        )
    if expected_size is not None and len(data) != expected_size:
        raise PreparationError(
            "Size mismatch for {}: expected {}, got {}".format(
                url, expected_size, len(data)
            )
        )
    return data


def ensure_target_platform() -> None:
    if sys.platform != "darwin":
        raise PreparationError("This pinned runtime is for macOS x86_64 only.")
    if platform.machine() != "x86_64":
        raise PreparationError(
            "This pinned runtime is x86_64; run the preparer with an x86_64 Python process."
        )
    version = platform.mac_ver()[0]
    try:
        major, minor = (int(part) for part in version.split(".")[:2])
    except (ValueError, TypeError):
        raise PreparationError("Could not determine the macOS version.")
    if (major, minor) < (13, 0):
        raise PreparationError("The pinned wheel requires macOS 13.0 or newer.")


def safe_archive_name(name: str) -> PurePosixPath:
    path = PurePosixPath(name)
    if path.is_absolute() or ".." in path.parts or not path.parts:
        raise PreparationError("Unsafe path in pinned wheel: {}".format(name))
    return path


def extract_pinned_payload(wheel_bytes: bytes, stage: Path) -> dict[str, object]:
    dylib_prefix = "lensfunpy/.dylibs/"
    db_prefix = "lensfunpy/db_files/"
    copied_dylibs: set[str] = set()
    copied_db: list[str] = []
    total_db_bytes = 0

    try:
        from io import BytesIO

        archive = ZipFile(BytesIO(wheel_bytes))
    except BadZipFile as error:
        raise PreparationError("The pinned PyPI artifact is not a valid ZIP wheel.") from error

    with archive:
        for member in archive.infolist():
            relative = safe_archive_name(member.filename)
            if member.is_dir():
                continue
            if relative.parts[0] == "lensfunpy" and relative.parts[-1].endswith(".dylib"):
                if relative.parts[:2] != ("lensfunpy", ".dylibs"):
                    continue
                name = relative.name
                if name not in EXPECTED_DYLIBS:
                    raise PreparationError("Unexpected native library in wheel: {}".format(name))
                destination = stage / "lib" / name
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(archive.read(member))
                copied_dylibs.add(name)
            elif member.filename.startswith(db_prefix) and member.filename.lower().endswith(".xml"):
                name = relative.name
                destination = stage / "db" / name
                destination.parent.mkdir(parents=True, exist_ok=True)
                data = archive.read(member)
                destination.write_bytes(data)
                copied_db.append(name)
                total_db_bytes += len(data)

        try:
            wrapper_license = archive.read(WHEEL_LICENSE_PATH)
        except KeyError as error:
            raise PreparationError("The pinned wheel is missing its MIT license file.") from error

    if copied_dylibs != EXPECTED_DYLIBS:
        raise PreparationError(
            "Native library set differs from the audited wheel: {}".format(
                sorted(copied_dylibs)
            )
        )
    if len(copied_db) != EXPECTED_DB_XML_COUNT or total_db_bytes != EXPECTED_DB_BYTES:
        raise PreparationError(
            "Bundled Lensfun DB payload changed: {} XML files, {} bytes".format(
                len(copied_db), total_db_bytes
            )
        )
    if sha256_bytes(wrapper_license) != WHEEL_LICENSE_SHA256:
        raise PreparationError("The wheel's MIT license file failed SHA256 verification.")

    license_path = stage / "licenses" / WHEEL_LICENSE_OUTPUT
    license_path.parent.mkdir(parents=True, exist_ok=True)
    license_path.write_bytes(wrapper_license)

    return {
        "dylib_names": sorted(copied_dylibs),
        "db_files": sorted(copied_db),
        "db_total_bytes": total_db_bytes,
        "wheel_license": {
            "path": "licenses/" + WHEEL_LICENSE_OUTPUT,
            "source_path": WHEEL_LICENSE_PATH,
            "sha256": WHEEL_LICENSE_SHA256,
            "size_bytes": len(wrapper_license),
            "license": "MIT",
            "note": "The lensfunpy Python extension is not copied or used by the app.",
        },
    }


def build_header(stage: Path) -> dict[str, object]:
    template = fetch_pinned(HEADER_TEMPLATE_URL, HEADER_TEMPLATE_SHA256)
    text = template.decode("utf-8")
    replacements = (
        ("@VERSION_MAJOR@", "0"),
        ("@VERSION_MINOR@", "3"),
        ("@VERSION_MICRO@", "4"),
        ("@VERSION_BUGFIX@", "0"),
    )
    for token, value in replacements:
        count = text.count(token)
        if count != 1:
            raise PreparationError("Expected exactly one {} in official header template.".format(token))
        text = text.replace(token, value)
    if "@VERSION_" in text:
        raise PreparationError("Unconfigured Lensfun version placeholder remains in header.")
    output = stage / "include" / "lensfun" / "lensfun.h"
    output.parent.mkdir(parents=True, exist_ok=True)
    encoded = text.encode("utf-8")
    output.write_bytes(encoded)
    return {
        "source_url": HEADER_TEMPLATE_URL,
        "source_sha256": HEADER_TEMPLATE_SHA256,
        "source_commit": LENSFUN_COMMIT,
        "generated_sha256": sha256_bytes(encoded),
        "size_bytes": len(encoded),
        "version_macros": {"major": 0, "minor": 3, "micro": 4, "bugfix": 0},
    }


def fetch_licenses(stage: Path) -> list[dict[str, object]]:
    results: list[dict[str, object]] = []
    directory = stage / "licenses"
    directory.mkdir(parents=True, exist_ok=True)
    for filename, metadata in sorted(LICENSE_ASSETS.items()):
        data = fetch_pinned(metadata["url"], metadata["sha256"])
        target = directory / filename
        target.write_bytes(data)
        results.append(
            {
                "path": "licenses/" + filename,
                "source_url": metadata["url"],
                "sha256": sha256_bytes(data),
                "size_bytes": len(data),
                "license": metadata["license"],
                "applies_to": metadata["applies_to"],
            }
        )
    return results


def count_array(array: ctypes.POINTER(ctypes.c_void_p), limit: int = 200_000) -> int:
    if not array:
        return 0
    for index in range(limit):
        if not array[index]:
            return index
    raise PreparationError("Lensfun returned an unterminated pointer array.")


def native_dependency_versions(stage: Path) -> dict[str, object]:
    """Query version metadata exposed by the bundled native dependencies."""
    pcre2_path = stage / "lib" / "libpcre2-8.0.dylib"
    gettext_path = stage / "lib" / "libintl.8.dylib"
    try:
        pcre2 = ctypes.CDLL(str(pcre2_path))
        config = pcre2.pcre2_config_8
        config.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
        config.restype = ctypes.c_int
        version = ctypes.create_string_buffer(128)
        # PCRE2_CONFIG_VERSION is 11 in the public PCRE2 API. For this string
        # option, pcre2_config_8 returns the number of bytes including NUL.
        version_length = config(11, ctypes.cast(version, ctypes.c_void_p))
        version_text = version.value.decode("ascii")
    except (OSError, AttributeError, UnicodeDecodeError) as error:
        raise PreparationError("Could not query bundled PCRE2 version: {}".format(error)) from error
    if version_length <= 1 or version_length != len(version_text.encode("ascii")) + 1:
        raise PreparationError(
            "PCRE2_CONFIG_VERSION returned an invalid version string (length {}).".format(
                version_length
            )
        )

    try:
        gettext = ctypes.CDLL(str(gettext_path))
        gettext_version = ctypes.c_uint32.in_dll(gettext, "libintl_version").value
    except (OSError, ValueError) as error:
        raise PreparationError(
            "Could not query bundled gettext libintl_version symbol: {}".format(error)
        ) from error

    return {
        "pcre2": {
            "library_path": "lib/libpcre2-8.0.dylib",
            "query": "pcre2_config_8(PCRE2_CONFIG_VERSION=11, buffer)",
            "return_value_bytes": version_length,
            "version": version_text,
        },
        "gettext": {
            "library_path": "lib/libintl.8.dylib",
            "exported_symbol": "libintl_version",
            "raw_integer_value": gettext_version,
            "note": "Exported integer marker; no readable version-string query was identified.",
        },
    }


def smoke_test_c_api(stage: Path) -> dict[str, object]:
    """Load the extracted dylib and query its public C API, without lensfunpy."""
    library_path = stage / "lib" / "liblensfun.0.3.4.dylib"
    database_path = stage / "db"
    try:
        mode = getattr(ctypes, "RTLD_LOCAL", 0) | getattr(os, "RTLD_NOW", 2)
        library = ctypes.CDLL(str(library_path), mode=mode)
    except OSError as error:
        raise PreparationError("dlopen of liblensfun failed: {}".format(error)) from error

    pointer = ctypes.c_void_p
    library.lf_db_new.argtypes = []
    library.lf_db_new.restype = pointer
    library.lf_db_load_directory.argtypes = [pointer, ctypes.c_char_p]
    library.lf_db_load_directory.restype = ctypes.c_int
    library.lf_db_get_cameras.argtypes = [pointer]
    library.lf_db_get_cameras.restype = ctypes.POINTER(pointer)
    library.lf_db_get_lenses.argtypes = [pointer]
    library.lf_db_get_lenses.restype = ctypes.POINTER(pointer)
    library.lf_db_find_cameras.argtypes = [pointer, ctypes.c_char_p, ctypes.c_char_p]
    library.lf_db_find_cameras.restype = ctypes.POINTER(pointer)
    library.lf_db_find_lenses_hd.argtypes = [
        pointer,
        pointer,
        ctypes.c_char_p,
        ctypes.c_char_p,
        ctypes.c_int,
    ]
    library.lf_db_find_lenses_hd.restype = ctypes.POINTER(pointer)
    library.lf_db_destroy.argtypes = [pointer]
    library.lf_db_destroy.restype = None

    database = library.lf_db_new()
    if not database:
        raise PreparationError("lf_db_new returned NULL.")
    try:
        loaded = library.lf_db_load_directory(database, os.fsencode(str(database_path)))
        if loaded != 1:
            raise PreparationError("lf_db_load_directory returned {}.".format(loaded))
        camera_count = count_array(library.lf_db_get_cameras(database))
        lens_count = count_array(library.lf_db_get_lenses(database))
        if camera_count == 0 or lens_count == 0:
            raise PreparationError("Lensfun DB loaded but returned no cameras or lenses.")

        cameras = library.lf_db_find_cameras(
            database, b"Canon", b"Canon EOS 5D Mark IV"
        )
        camera_matches = count_array(cameras)
        if camera_matches == 0:
            raise PreparationError("C API did not find the pinned sample camera.")
        lenses = library.lf_db_find_lenses_hd(
            database,
            cameras[0],
            b"Canon",
            b"Canon EF 24-70mm f/2.8L USM",
            0,
        )
        lens_matches = count_array(lenses)
        if lens_matches == 0:
            raise PreparationError("C API did not find the pinned sample lens.")
        return {
            "method": "ctypes.CDLL + Lensfun 0.3.4 public C API; no lensfunpy import",
            "db_load_directory": bool(loaded),
            "camera_count": camera_count,
            "lens_count": lens_count,
            "sample_camera": "Canon EOS 5D Mark IV",
            "sample_camera_matches": camera_matches,
            "sample_lens": "Canon EF 24-70mm f/2.8L USM",
            "sample_lens_matches": lens_matches,
        }
    finally:
        library.lf_db_destroy(database)


def list_output_files(stage: Path) -> list[dict[str, object]]:
    results: list[dict[str, object]] = []
    for path in sorted(stage.rglob("*")):
        if path.is_symlink():
            raise PreparationError("Symlinks are not allowed in prepared output: {}".format(path))
        if not path.is_file():
            continue
        relative = path.relative_to(stage).as_posix()
        if relative == "manifest.json":
            continue
        results.append(
            {
                "path": relative,
                "size_bytes": path.stat().st_size,
                "sha256": sha256_file(path),
            }
        )
    return results


def expected_sources() -> dict[str, object]:
    return {
        "target": {"os": "macOS", "minimum_version": "13.0", "architecture": "x86_64"},
        "lensfun": {
            "version": "0.3.4.0",
            "upstream_version_tag": LENSFUN_TAG,
            "source_artifact": WHEEL_FILENAME,
            "license": "LGPL-3.0-or-later",
            "library_path": "lib/liblensfun.0.3.4.dylib",
        },
        "wheel": {
            "filename": WHEEL_FILENAME,
            "url": WHEEL_URL,
            "release_page": WHEEL_RELEASE,
            "size_bytes": WHEEL_SIZE,
            "sha256": WHEEL_SHA256,
            "published": "2026-01-26",
            "license": "MIT for the lensfunpy wrapper; its Python extension is not copied.",
            "pypi_runtime_requirement": "numpy (not used by this native runtime)",
        },
        "database": {
            "version_source": "Exact db_files payload from the pinned lensfunpy wheel above; not current HEAD.",
            "license": "CC-BY-SA-3.0",
            "relative_directory": "db",
            "expected_xml_files": EXPECTED_DB_XML_COUNT,
            "expected_uncompressed_bytes": EXPECTED_DB_BYTES,
        },
        "header_template": {
            "url": HEADER_TEMPLATE_URL,
            "sha256": HEADER_TEMPLATE_SHA256,
            "source_commit": LENSFUN_COMMIT,
            "version_macros": {"major": 0, "minor": 3, "micro": 4, "bugfix": 0},
        },
        "license_sources": [
            {
                "filename": filename,
                "url": metadata["url"],
                "sha256": metadata["sha256"],
                "license": metadata["license"],
            }
            for filename, metadata in sorted(LICENSE_ASSETS.items())
        ],
        "wheel_license": {
            "path": WHEEL_LICENSE_PATH,
            "sha256": WHEEL_LICENSE_SHA256,
            "license": "MIT",
        },
    }


def manifest_from_stage(
    stage: Path,
    wheel_bytes: bytes,
    payload: dict[str, object],
    header: dict[str, object],
    license_files: list[dict[str, object]],
    smoke: dict[str, object],
    dependency_versions: dict[str, object],
) -> dict[str, object]:
    files = list_output_files(stage)
    library_files = [entry for entry in files if entry["path"].startswith("lib/")]
    return {
        "manifest_version": 1,
        "sources": expected_sources(),
        "header": header,
        "native_libraries": library_files,
        "database_payload": {
            "directory": "db",
            "files": payload["db_files"],
            "xml_count": len(payload["db_files"]),
            "uncompressed_bytes": payload["db_total_bytes"],
            "license": "CC-BY-SA-3.0",
            "source_artifact_sha256": WHEEL_SHA256,
        },
        "license_files": sorted(license_files + [payload["wheel_license"]], key=lambda item: item["path"]),
        "native_dependency_versions": dependency_versions,
        "smoke_test": smoke,
        "files": files,
        "total_uncompressed_bytes": sum(int(entry["size_bytes"]) for entry in files),
        "verified_source_wheel_sha256": sha256_bytes(wheel_bytes),
    }


def write_manifest(stage: Path, manifest: dict[str, object]) -> None:
    path = stage / "manifest.json"
    encoded = (json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")
    path.write_bytes(encoded)


def verify_output(path: Path) -> dict[str, object]:
    if path.is_symlink() or not path.is_dir():
        raise PreparationError("Prepared output path is not a normal directory: {}".format(path))
    manifest_path = path / "manifest.json"
    if not manifest_path.is_file() or manifest_path.is_symlink():
        raise PreparationError("Existing output lacks a regular manifest.json; refusing to overwrite it.")
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except Exception as error:
        raise PreparationError("Existing manifest.json is invalid: {}".format(error)) from error
    if manifest.get("sources") != expected_sources():
        raise PreparationError("Existing output uses different dependency pins; refusing to replace it.")

    expected = {entry["path"]: entry for entry in manifest.get("files", [])}
    actual_paths: set[str] = set()
    for entry in list_output_files(path):
        actual_paths.add(str(entry["path"]))
        if entry["path"] not in expected:
            raise PreparationError("Unexpected file in prepared output: {}".format(entry["path"]))
        pin = expected[entry["path"]]
        if entry["sha256"] != pin.get("sha256") or entry["size_bytes"] != pin.get("size_bytes"):
            raise PreparationError("Prepared file changed: {}".format(entry["path"]))
    if actual_paths != set(expected):
        missing = sorted(set(expected) - actual_paths)
        raise PreparationError("Prepared output is missing files: {}".format(", ".join(missing)))
    dependency_versions = native_dependency_versions(path)
    if manifest.get("native_dependency_versions") != dependency_versions:
        raise PreparationError("Prepared native dependency version metadata changed.")
    smoke = smoke_test_c_api(path)
    return smoke


def exclusive_rename(source: Path, destination: Path) -> None:
    system = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    renamex_np = system.renamex_np
    renamex_np.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    renamex_np.restype = ctypes.c_int
    result = renamex_np(os.fsencode(str(source)), os.fsencode(str(destination)), 0x00000004)
    if result != 0:
        error_number = ctypes.get_errno()
        raise OSError(error_number, os.strerror(error_number), str(destination))


def prepare() -> dict[str, object]:
    ensure_target_platform()
    if OUTPUT.exists():
        return verify_output(OUTPUT)

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=".lensfun-stage-", dir=str(OUTPUT.parent)))
    try:
        wheel_bytes = fetch_pinned(WHEEL_URL, WHEEL_SHA256, WHEEL_SIZE)
        payload = extract_pinned_payload(wheel_bytes, stage)
        header = build_header(stage)
        license_files = fetch_licenses(stage)
        dependency_versions = native_dependency_versions(stage)
        smoke = smoke_test_c_api(stage)
        manifest = manifest_from_stage(
            stage, wheel_bytes, payload, header, license_files, smoke, dependency_versions
        )
        write_manifest(stage, manifest)
        exclusive_rename(stage, OUTPUT)
        return smoke
    finally:
        if stage.exists():
            shutil.rmtree(stage)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--verify",
        action="store_true",
        help="verify the existing .dependencies/lensfun tree and run the C API smoke query without downloading",
    )
    args = parser.parse_args()
    try:
        if args.verify:
            smoke = verify_output(OUTPUT)
        else:
            smoke = prepare()
    except Exception as error:
        print("Lensfun preparation failed: {}".format(error), file=sys.stderr)
        return 1
    print("Lensfun runtime verified at {}".format(OUTPUT))
    print(json.dumps(smoke, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

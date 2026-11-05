#!/usr/bin/env python3
"""Verify a Photo Atelier app bundle and its bundled Lensfun runtime."""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path, PurePosixPath


EXPECTED_LIBS = {
    "liblensfun.0.3.4.dylib",
    "libglib-2.0.0.dylib",
    "libpcre2-8.0.dylib",
    "libintl.8.dylib",
}
SYSTEM_PREFIXES = ("/usr/lib/", "/System/Library/")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")


class VerificationError(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise VerificationError(message)


def digest(path):
    hasher = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(block)
    return hasher.hexdigest()


def run_tool(arguments):
    try:
        return subprocess.check_output(arguments, text=True, stderr=subprocess.STDOUT)
    except (OSError, subprocess.CalledProcessError) as error:
        detail = getattr(error, "output", "") or str(error)
        raise VerificationError("Command failed ({}): {}".format(arguments[0], detail.strip())) from error


def read_json(path, description):
    require(path.is_file() and not path.is_symlink(), "Missing regular {}: {}".format(description, path))
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise VerificationError("Invalid {} {}: {}".format(description, path, error)) from error


def safe_manifest_path(value):
    require(isinstance(value, str) and value != "", "Manifest path must be a non-empty string")
    require("\\" not in value, "Manifest path must use POSIX separators: {}".format(value))
    relative = PurePosixPath(value)
    require(not relative.is_absolute() and ".." not in relative.parts,
            "Unsafe path in manifest: {}".format(value))
    require(all(part not in ("", ".") for part in relative.parts),
            "Non-canonical path in manifest: {}".format(value))
    return Path(*relative.parts)


def source_entries(source):
    entries = source.get("files")
    require(isinstance(entries, list), "source manifest has no files list")
    by_path = {}
    for entry in entries:
        require(isinstance(entry, dict), "source manifest file entry is not an object")
        path_text = entry.get("path")
        relative = safe_manifest_path(path_text)
        checksum = entry.get("sha256")
        size = entry.get("size_bytes")
        require(isinstance(checksum, str) and SHA256_RE.match(checksum) is not None,
                "Invalid SHA-256 for source file: {}".format(path_text))
        require(isinstance(size, int) and size >= 0,
                "Invalid size for source file: {}".format(path_text))
        require(path_text not in by_path, "Duplicate source manifest path: {}".format(path_text))
        by_path[path_text] = {"relative": relative, "sha256": checksum, "size_bytes": size}
    return by_path


def regular_file(path, description):
    require(path.is_file() and not path.is_symlink(), "Missing regular {}: {}".format(description, path))


def exact_tree_files(directory, description):
    require(directory.is_dir() and not directory.is_symlink(),
            "Missing regular {} directory: {}".format(description, directory))
    found = set()
    for root, directories, filenames in os.walk(str(directory), followlinks=False):
        root_path = Path(root)
        for name in list(directories):
            child = root_path / name
            require(not child.is_symlink(), "Symlink in {} tree: {}".format(description, child))
        for name in filenames:
            child = root_path / name
            regular_file(child, description)
            found.add(child.relative_to(directory).as_posix())
    return found


def verify_resource_payloads(resources, source):
    lensfun_resources = resources / "Lensfun"
    entries = source_entries(source)
    expected_db = {
        path[len("db/"):]: entry
        for path, entry in entries.items()
        if path.startswith("db/")
    }
    expected_licenses = {
        path[len("licenses/"):]: entry
        for path, entry in entries.items()
        if path.startswith("licenses/")
    }
    require(expected_db, "source manifest has no database XML files")
    require(expected_licenses, "source manifest has no license files")

    database_directory = lensfun_resources / "db"
    license_directory = lensfun_resources / "licenses"
    actual_db = exact_tree_files(database_directory, "database")
    actual_licenses = exact_tree_files(license_directory, "license")
    require(actual_db == set(expected_db),
            "Bundled database file set differs from source manifest (missing: {}; extra: {})".format(
                sorted(set(expected_db) - actual_db), sorted(actual_db - set(expected_db))))
    require(actual_licenses == set(expected_licenses),
            "Bundled license file set differs from source manifest (missing: {}; extra: {})".format(
                sorted(set(expected_licenses) - actual_licenses),
                sorted(actual_licenses - set(expected_licenses))))

    for group, expected in (("db", expected_db), ("licenses", expected_licenses)):
        for name, entry in expected.items():
            path = lensfun_resources / group / name
            regular_file(path, "bundled {} file".format(group))
            require(path.stat().st_size == entry["size_bytes"] and digest(path) == entry["sha256"],
                    "Bundled {} changed: {}/{}".format(group, group, name))

    payload = source.get("database_payload")
    require(isinstance(payload, dict), "source manifest has no database_payload object")
    expected_names = sorted(expected_db)
    require(payload.get("xml_count") == len(expected_names), "Database XML count differs from source manifest")
    require(payload.get("files") == expected_names, "Database filename list differs from source manifest")
    require(payload.get("uncompressed_bytes") == sum(item["size_bytes"] for item in expected_db.values()),
            "Database byte count differs from source manifest")

    regular_file(resources / "THIRD_PARTY_NOTICES.md", "third-party notices")
    regular_file(resources / "LICENSE-MIT.txt", "application license")
    film_license = resources / "FilmLUTs" / "LICENSE-MIT.txt"
    regular_file(film_license, "film look MIT license")
    require(digest(film_license) == "c487b0f66664fc7141ea8764edfed92b2d8969efdf50778e5bbf5f7a530e966f",
            "Film look license differs from the pinned upstream notice")
    regular_file(resources / "FilmLUTs" / "ATTRIBUTION.md", "film look attribution and color contract")
    regular_file(resources / "docs" / "lensfun-build.md", "bundled Lensfun build guide")
    regular_file(resources / "Scripts" / "prepare_lensfun.py", "bundled Lensfun preparation recipe")
    return len(expected_db)


def verify_source_libraries(app, source_manifest_path):
    source = read_json(source_manifest_path, "verified source manifest")
    embedded_path = app / "Contents/Resources/Lensfun/source-manifest.json"
    regular_file(embedded_path, "embedded source manifest")
    require(digest(embedded_path) == digest(source_manifest_path),
            "Embedded source manifest differs from the manifest verified by prepare_lensfun.py")

    entries = source_entries(source)
    expected = {}
    for path, entry in entries.items():
        if path.startswith("lib/"):
            name = Path(path).name
            require(name in EXPECTED_LIBS, "Unexpected source library: {}".format(path))
            require(path == "lib/" + name, "Unexpected source library path: {}".format(path))
            require(name not in expected, "Duplicate source library basename: {}".format(name))
            expected[name] = entry
    require(set(expected) == EXPECTED_LIBS, "Source manifest has an unexpected dylib set")

    framework = app / "Contents/Frameworks/Lensfun"
    actual_names = {path.name for path in framework.glob("*.dylib")}
    require(actual_names == EXPECTED_LIBS,
            "Bundled dylib set differs (missing: {}; extra: {})".format(
                sorted(EXPECTED_LIBS - actual_names), sorted(actual_names - EXPECTED_LIBS)))
    for name in sorted(EXPECTED_LIBS):
        path = framework / name
        regular_file(path, "bundled dylib")
        entry = expected[name]
        require(path.stat().st_size == entry["size_bytes"] and digest(path) == entry["sha256"],
                "Dylib does not match verified source payload: {}".format(name))
    print("Unsigned bundle dylibs match the source manifest verified by prepare_lensfun.py.")


def is_system_path(path_text):
    return any(path_text == prefix[:-1] or path_text.startswith(prefix)
               for prefix in SYSTEM_PREFIXES)


def path_is_within(path, directory):
    path_text = os.path.realpath(str(path))
    directory_text = os.path.realpath(str(directory))
    try:
        return os.path.commonpath((path_text, directory_text)) == directory_text
    except ValueError:
        return False


def expand_loader_path(value, binary, executable_directory):
    if value == "@loader_path":
        return binary.parent
    if value.startswith("@loader_path/"):
        return binary.parent / value[len("@loader_path/"):]
    if value == "@executable_path":
        return executable_directory
    if value.startswith("@executable_path/"):
        return executable_directory / value[len("@executable_path/"):]
    if value.startswith("/"):
        return Path(value)
    return None


def load_rpaths(binary):
    output = run_tool(["/usr/bin/otool", "-l", str(binary)])
    paths = []
    lines = output.splitlines()
    for index, line in enumerate(lines):
        if line.strip() != "cmd LC_RPATH":
            continue
        for candidate in lines[index + 1:index + 6]:
            match = re.match(r"\s*path (.+) \(offset \d+\)\s*$", candidate)
            if match:
                paths.append(match.group(1))
                break
    return paths


def validate_rpaths(binary, rpaths, app, framework, executable_directory):
    for rpath in rpaths:
        expanded = expand_loader_path(rpath, binary, executable_directory)
        allowed = is_system_path(rpath)
        if expanded is not None and not is_system_path(str(expanded)):
            allowed = path_is_within(expanded, app / "Contents")
        require(allowed, "Nonportable LC_RPATH in {}: {}".format(binary.name, rpath))


def dependency_is_allowed(dependency, binary, app, framework, executable_directory, rpaths):
    if is_system_path(dependency):
        return True

    expanded = expand_loader_path(dependency, binary, executable_directory)
    if expanded is not None:
        limit = framework if binary.parent == framework else app / "Contents"
        return path_is_within(expanded, limit) and expanded.is_file()

    if dependency.startswith("@rpath/"):
        suffix = dependency[len("@rpath/"):]
        for rpath in rpaths:
            expanded_rpath = expand_loader_path(rpath, binary, executable_directory)
            if expanded_rpath is None:
                if is_system_path(rpath):
                    candidate_text = rpath.rstrip("/") + "/" + suffix
                    if is_system_path(candidate_text):
                        return True
                continue
            candidate = expanded_rpath / suffix
            if is_system_path(str(candidate)):
                return True
            if path_is_within(candidate, app / "Contents") and candidate.is_file():
                return True
    return False


def architecture_set(binary):
    output = run_tool(["/usr/bin/lipo", "-archs", str(binary)])
    return set(output.split())


def verify_binary_paths(app, framework):
    executable_directory = app / "Contents/MacOS"
    executable = executable_directory / "PhotoAtelier"
    binaries = [executable] + [framework / name for name in sorted(EXPECTED_LIBS)]
    for binary in binaries:
        regular_file(binary, "runtime binary")
        architectures = architecture_set(binary)
        if binary == executable:
            require(architectures in ({"x86_64", "arm64"}, {"x86_64"}),
                    "Incorrect runtime architecture for {}: {}".format(binary, sorted(architectures)))
        else:
            require(architectures == {"x86_64"},
                    "Incorrect runtime architecture for {}: {}".format(binary, sorted(architectures)))
        rpaths = load_rpaths(binary)
        validate_rpaths(binary, rpaths, app, framework, executable_directory)

        linked = run_tool(["/usr/bin/otool", "-L", str(binary)])
        lines = linked.splitlines()
        require(len(lines) >= 1, "otool returned no load commands for {}".format(binary))
        for line in lines[1:]:
            dependency = line.strip().split(" (", 1)[0]
            require(dependency != "", "Empty dependency entry in {}".format(binary))
            require(dependency_is_allowed(dependency, binary, app, framework,
                                          executable_directory, rpaths),
                    "Nonportable load path in {}: {}".format(binary.name, dependency))

    for name in sorted(EXPECTED_LIBS):
        dylib = framework / name
        output = run_tool(["/usr/bin/otool", "-D", str(dylib)])
        ids = [line.strip() for line in output.splitlines()[1:] if line.strip()]
        require(ids == ["@loader_path/" + name],
                "Unexpected dylib install ID for {}: {}".format(name, ids))


def verify_dylib_signatures(framework):
    for name in sorted(EXPECTED_LIBS):
        run_tool(["/usr/bin/codesign", "--verify", "--strict", str(framework / name)])


def write_bundle_record(app, framework, resources):
    record = resources / "Lensfun/bundle-manifest.json"
    require(not record.exists() and not record.is_symlink(),
            "Refusing to overwrite an existing bundle manifest: {}".format(record))
    files = []
    for name in sorted(EXPECTED_LIBS):
        path = framework / name
        files.append({
            "path": path.relative_to(app).as_posix(),
            "sha256": digest(path),
        })
    source_manifest = resources / "Lensfun/source-manifest.json"
    payload = {
        "note": "Post-signing dylib hashes; source provenance was checked before install-name normalization and signing.",
        "source_manifest_sha256": digest(source_manifest),
        "files": files,
    }
    record.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def verify_bundle_record(app, framework, resources):
    record_path = resources / "Lensfun/bundle-manifest.json"
    record = read_json(record_path, "signed bundle manifest")
    source_manifest = resources / "Lensfun/source-manifest.json"
    require(record.get("source_manifest_sha256") == digest(source_manifest),
            "Embedded source manifest changed after bundle recording")
    files = record.get("files")
    require(isinstance(files, list), "Bundle manifest has no files list")
    entries = {}
    for entry in files:
        require(isinstance(entry, dict), "Bundle manifest file entry is not an object")
        relative = safe_manifest_path(entry.get("path"))
        checksum = entry.get("sha256")
        require(isinstance(checksum, str) and SHA256_RE.match(checksum) is not None,
                "Invalid signed bundle SHA-256: {}".format(entry.get("path")))
        name = relative.name
        require(name not in entries, "Duplicate path in bundle manifest: {}".format(name))
        require(relative == Path("Contents/Frameworks/Lensfun") / name and name in EXPECTED_LIBS,
                "Unexpected signed bundle path: {}".format(relative))
        entries[name] = checksum
    require(set(entries) == EXPECTED_LIBS, "Signed bundle manifest dylib set differs")
    for name, checksum in entries.items():
        path = framework / name
        regular_file(path, "signed runtime dylib")
        require(digest(path) == checksum, "Signed bundle payload changed: {}".format(name))


def verify_app(app, record_mode):
    app = app.resolve()
    resources = app / "Contents/Resources"
    framework = app / "Contents/Frameworks/Lensfun"
    source_manifest_path = resources / "Lensfun/source-manifest.json"
    source = read_json(source_manifest_path, "embedded source manifest")

    actual_libs = {path.name for path in framework.glob("*.dylib")}
    require(actual_libs == EXPECTED_LIBS,
            "Bundled dylib set differs (missing: {}; extra: {})".format(
                sorted(EXPECTED_LIBS - actual_libs), sorted(actual_libs - EXPECTED_LIBS)))
    xml_count = verify_resource_payloads(resources, source)
    verify_binary_paths(app, framework)
    verify_dylib_signatures(framework)

    if record_mode:
        write_bundle_record(app, framework, resources)
    else:
        verify_bundle_record(app, framework, resources)
        run_tool(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])

    print("App bundle verified: 4 signed x86_64 dylibs, {} XML profiles, exact licenses, portable executable and dylib load paths".format(xml_count))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--record", action="store_true",
                        help="record hashes after dylib signing, before signing the app bundle")
    parser.add_argument("--check-source", action="store_true",
                        help="compare copied, unsigned dylibs with a manifest verified by prepare_lensfun.py")
    parser.add_argument("app", type=Path)
    parser.add_argument("source_manifest", nargs="?", type=Path,
                        help="required with --check-source; normally .dependencies/lensfun/manifest.json")
    args = parser.parse_args()
    try:
        if args.check_source:
            require(not args.record, "--check-source and --record cannot be combined")
            require(args.source_manifest is not None, "--check-source requires a source manifest path")
            verify_source_libraries(args.app.resolve(), args.source_manifest.resolve())
            return 0
        require(args.source_manifest is None, "A source manifest path is only valid with --check-source")
        verify_app(args.app, args.record)
        return 0
    except (OSError, VerificationError, ValueError, KeyError, TypeError) as error:
        print("App bundle verification failed: {}".format(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

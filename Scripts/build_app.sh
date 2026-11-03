#!/bin/bash
set -euo pipefail

TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"
python3 Scripts/prepare_lensfun.py --verify

swift build -c release -j 2
TASK_BIN="$(swift build -c release --show-bin-path)"
TASK_BUILD_ROOT="$TASK_ROOT/build"
TASK_APP="$TASK_BUILD_ROOT/PhotoAtelier.app"
mkdir -p "$TASK_BUILD_ROOT"
TASK_STAGE="$(mktemp -d "$TASK_BUILD_ROOT/.PhotoAtelier.stage.XXXXXX")"
TASK_STAGED_APP="$TASK_STAGE/PhotoAtelier.app"
TASK_RESOURCES="$TASK_STAGED_APP/Contents/Resources"
TASK_FRAMEWORK="$TASK_STAGED_APP/Contents/Frameworks/Lensfun"
TASK_SOURCE_MANIFEST="$TASK_ROOT/.dependencies/lensfun/manifest.json"

report_staging_path() {
    if [[ -d "${TASK_STAGE:-}" ]]; then
        printf 'Staging bundle retained for inspection: %s\n' "$TASK_STAGE" >&2
    fi
}
trap report_staging_path EXIT

mkdir -p "$TASK_STAGED_APP/Contents/MacOS" "$TASK_RESOURCES/Lensfun" "$TASK_FRAMEWORK"
cp "$TASK_BIN/PhotoAtelier" "$TASK_STAGED_APP/Contents/MacOS/PhotoAtelier"
cp Resources/Info.plist "$TASK_STAGED_APP/Contents/Info.plist"
ditto .dependencies/lensfun/lib "$TASK_FRAMEWORK"
ditto .dependencies/lensfun/db "$TASK_RESOURCES/Lensfun/db"
ditto .dependencies/lensfun/licenses "$TASK_RESOURCES/Lensfun/licenses"
cp "$TASK_SOURCE_MANIFEST" "$TASK_RESOURCES/Lensfun/source-manifest.json"
cp THIRD_PARTY_NOTICES.md "$TASK_RESOURCES/THIRD_PARTY_NOTICES.md"
cp LICENSE "$TASK_RESOURCES/LICENSE-MIT.txt"
ditto ThirdParty/FilmLUTs "$TASK_RESOURCES/FilmLUTs"
mkdir -p "$TASK_RESOURCES/docs" "$TASK_RESOURCES/Scripts"
cp docs/lensfun-build.md "$TASK_RESOURCES/docs/lensfun-build.md"
cp Scripts/prepare_lensfun.py "$TASK_RESOURCES/Scripts/prepare_lensfun.py"
swift Scripts/make_icon.swift "$TASK_RESOURCES"

# prepare_lensfun.py --verify validates the ignored source tree. Confirm ditto
# copied those exact unsigned dylibs before install_name_tool changes their IDs.
python3 Scripts/verify_app.py --check-source "$TASK_STAGED_APP" "$TASK_SOURCE_MANIFEST"

# The wheel records an absolute build-host LC_ID_DYLIB. Rewrite only each
# library's own ID; dependency load commands remain subject to strict checks.
for TASK_DYLIB in "$TASK_FRAMEWORK"/*.dylib; do
    TASK_DYLIB_NAME="$(basename "$TASK_DYLIB")"
    install_name_tool -id "@loader_path/$TASK_DYLIB_NAME" "$TASK_DYLIB"
done

for TASK_DYLIB in "$TASK_FRAMEWORK"/*.dylib; do
    codesign --force --sign - "$TASK_DYLIB"
done

# --record stores post-sign hashes only after the source-hash step above and
# the verifier's architecture, resource-set, install-ID, and load-path checks.
python3 Scripts/verify_app.py --record "$TASK_STAGED_APP"
codesign --force --sign - "$TASK_STAGED_APP"
codesign --verify --deep --strict "$TASK_STAGED_APP"
python3 Scripts/verify_app.py "$TASK_STAGED_APP"

# Preserve any previous app under a unique name. The new app is promoted only
# after every verification step has passed; no existing app is removed.
TASK_PREVIOUS=""
restore_previous_app() {
    if [[ -z "$TASK_PREVIOUS" ]]; then
        return 0
    fi
    if [[ -e "$TASK_APP" || -L "$TASK_APP" ]]; then
        printf 'Previous app remains preserved at %s because the destination now exists.\n' "$TASK_PREVIOUS" >&2
        return 0
    fi
    mv "$TASK_PREVIOUS" "$TASK_APP"
}

if [[ -e "$TASK_APP" || -L "$TASK_APP" ]]; then
    TASK_STAMP="$(date '+%Y%m%d-%H%M%S')"
    TASK_SUFFIX=0
    TASK_PREVIOUS="$TASK_BUILD_ROOT/PhotoAtelier.previous-$TASK_STAMP.app"
    while [[ -e "$TASK_PREVIOUS" || -L "$TASK_PREVIOUS" ]]; do
        TASK_SUFFIX=$((TASK_SUFFIX + 1))
        TASK_PREVIOUS="$TASK_BUILD_ROOT/PhotoAtelier.previous-$TASK_STAMP-$TASK_SUFFIX.app"
    done
    mv "$TASK_APP" "$TASK_PREVIOUS"
fi

if [[ -e "$TASK_APP" || -L "$TASK_APP" ]]; then
    printf 'Refusing to replace app created during promotion: %s\n' "$TASK_APP" >&2
    restore_previous_app
    exit 1
fi
if ! mv -n "$TASK_STAGED_APP" "$TASK_APP" || [[ -e "$TASK_STAGED_APP" ]]; then
    printf 'Could not promote staged app; staged bundle retained at %s\n' "$TASK_STAGED_APP" >&2
    restore_previous_app
    exit 1
fi

rmdir "$TASK_STAGE"
TASK_STAGE=""
if [[ -n "$TASK_PREVIOUS" ]]; then
    printf 'Previous app preserved: %s\n' "$TASK_PREVIOUS"
fi
printf 'Built and verified: %s\n' "$TASK_APP"

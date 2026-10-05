#!/usr/bin/env bash
# Execute the actual systemwide bundle-setup function against an isolated fixture.
set -euo pipefail

AGGREGATE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sotf-systemwide-notices.XXXXXX")"
trap 'rm -rf "$TEMP_ROOT"' EXIT

FIXTURE_ROOT="$TEMP_ROOT/all_of_sotf"
FIXTURE_DAW="$FIXTURE_ROOT/sotf-daw"
SOURCE_NOTICES="$AGGREGATE_ROOT/sotf-daw/assets/third-party/nnnoiseless"
mkdir -p "$FIXTURE_DAW/assets/third-party/nnnoiseless" "$FIXTURE_ROOT/sotf-systemwide"
cp "$SOURCE_NOTICES/MODEL_NOTICES.txt" "$FIXTURE_DAW/assets/third-party/nnnoiseless/"
cp "$SOURCE_NOTICES/nnnoiseless-COPYING.txt" "$FIXTURE_DAW/assets/third-party/nnnoiseless/"

source "$AGGREGATE_ROOT/sotf-daw/scripts/lib/nnnoiseless_model_notices.sh"
setup_function="$(sed -n '/^setup_systemwide_bundle() {/,/^}/p' \
    "$AGGREGATE_ROOT/sotf-systemwide/scripts/build-systemwide.sh")"
test -n "$setup_function"
eval "$setup_function"

PROJECT_ROOT="$FIXTURE_ROOT/sotf-systemwide"
APP_BUNDLE="$TEMP_ROOT/sotf-systemwide.app"
BUILD_DIR="$TEMP_ROOT/build"
SYSTEMWIDE_BINARY="sotf-systemwide"
mkdir -p "$BUILD_DIR" "$APP_BUNDLE/Contents/Resources"
printf 'fixture app binary\n' > "$BUILD_DIR/$SYSTEMWIDE_BINARY"
printf 'keep this app resource\n' > "$APP_BUNDLE/Contents/Resources/CustomResource.txt"
log_info() { :; }
log_success() { :; }

setup_systemwide_bundle
cmp "$SOURCE_NOTICES/MODEL_NOTICES.txt" \
    "$APP_BUNDLE/Contents/Resources/MODEL_NOTICES.txt"
cmp "$SOURCE_NOTICES/nnnoiseless-COPYING.txt" \
    "$APP_BUNDLE/Contents/Resources/nnnoiseless-COPYING.txt"
test "$(cat "$APP_BUNDLE/Contents/Resources/CustomResource.txt")" = "keep this app resource"

echo "systemwide app bundle notice staging test passed"

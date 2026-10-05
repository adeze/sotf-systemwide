#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/sotf-payload-arch.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT
SDK=$(xcrun --sdk macosx --show-sdk-path)
printf 'int main(void) { return 0; }\n' > "$TEST_ROOT/main.c"
for architecture in arm64 x86_64; do
    /usr/bin/clang -target "$architecture-apple-macos15.0" -isysroot "$SDK" \
        "$TEST_ROOT/main.c" -o "$TEST_ROOT/$architecture"
    test "$(sotf_payload_architecture "$TEST_ROOT/$architecture" "$TEST_ROOT/$architecture")" = "$architecture"
done
/usr/bin/lipo -create "$TEST_ROOT/arm64" "$TEST_ROOT/x86_64" -output "$TEST_ROOT/universal"
test "$(sotf_payload_architecture "$TEST_ROOT/universal" "$TEST_ROOT/universal")" = universal
if sotf_payload_architecture "$TEST_ROOT/arm64" "$TEST_ROOT/x86_64" >/dev/null 2>&1; then
    echo 'mixed architecture payload must fail' >&2
    exit 1
fi
if sotf_payload_architecture "$TEST_ROOT/arm64" "$TEST_ROOT/universal" >/dev/null 2>&1; then
    echo 'thin/fat payload mismatch must fail' >&2
    exit 1
fi
if sotf_payload_architecture "$TEST_ROOT/missing" >/dev/null 2>&1; then
    echo 'missing payload must fail' >&2
    exit 1
fi
cp "$TEST_ROOT/arm64" "$TEST_ROOT/not-executable"
chmod 644 "$TEST_ROOT/not-executable"
if sotf_payload_architecture "$TEST_ROOT/not-executable" >/dev/null 2>&1; then
    echo 'non-executable payload must fail' >&2
    exit 1
fi
printf 'not a Mach-O file\n' > "$TEST_ROOT/corrupt"
chmod 755 "$TEST_ROOT/corrupt"
if sotf_payload_architecture "$TEST_ROOT/corrupt" >/dev/null 2>&1; then
    echo 'invalid Mach-O payload must fail' >&2
    exit 1
fi
if sotf_payload_architecture >/dev/null 2>&1; then
    echo 'empty payload inventory must fail' >&2
    exit 1
fi

# Exercise the production staging function without building or installing HAL.
sed -n '/^copy_hal_driver() {$/,/^}$/p' "$SCRIPT_DIR/build-systemwide.sh" > "$TEST_ROOT/copy-hal-function.sh"
source "$TEST_ROOT/copy-hal-function.sh"
log_info() { :; }
log_success() { :; }
log_warning() { :; }
log_error() { :; }
PROJECT_ROOT="$TEST_ROOT/project"
DRIVER_BUNDLE="$TEST_ROOT/staged/SotFHAL.driver"
BUILD_HAL=true
if copy_hal_driver; then
    echo 'required missing HAL bundle must stop packaging' >&2
    exit 1
fi
test "$BUILD_HAL" = true
BUILD_HAL=false
copy_hal_driver
test ! -e "$DRIVER_BUNDLE"
BUILD_HAL=true
mkdir -p "$PROJECT_ROOT/target/dist/SotFHAL.driver/Contents/MacOS"
cp "$TEST_ROOT/arm64" "$PROJECT_ROOT/target/dist/SotFHAL.driver/Contents/MacOS/SotFHAL"
copy_hal_driver
cmp "$TEST_ROOT/arm64" "$DRIVER_BUNDLE/Contents/MacOS/SotFHAL"
printf 'stale payload\n' > "$DRIVER_BUNDLE/stale.txt"
copy_hal_driver
test ! -e "$DRIVER_BUNDLE/stale.txt"
cmp "$TEST_ROOT/arm64" "$DRIVER_BUNDLE/Contents/MacOS/SotFHAL"
echo 'payload architecture tests passed'

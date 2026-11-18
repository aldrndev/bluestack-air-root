#!/bin/bash

set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd -P)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bs-air-test.XXXXXX")"
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

fail() {
  printf '[FAIL] %s\n' "$*" >&2
  exit 1
}

assert_file() {
  [[ -f "$1" ]] || fail "Expected file missing: $1"
}

assert_contains() {
  local file="$1"
  local pat="$2"
  grep -qF "$pat" "$file" || fail "Expected '$pat' in $file"
}

assert_count() {
  local file="$1"
  local pat="$2"
  local expected="$3"
  local actual
  actual="$(grep -cF "$pat" "$file" || true)"
  [[ "$actual" -eq "$expected" ]] || fail "Expected $expected occurrences of '$pat' in $file, got $actual"
}

create_mock_apk() {
  local apk="$1"
  local d="$WORK_DIR/mock_apk"
  rm -rf "$d"
  mkdir -p "$d/lib/arm64-v8a" "$d/lib/armeabi-v7a" "$d/assets"
  printf 'dummy-magisk64' > "$d/lib/arm64-v8a/libmagisk64.so"
  printf 'dummy-magiskinit' > "$d/lib/arm64-v8a/libmagiskinit.so"
  printf 'dummy-magiskpolicy' > "$d/lib/arm64-v8a/libmagiskpolicy.so"
  printf 'dummy-busybox' > "$d/lib/arm64-v8a/libbusybox.so"
  printf 'dummy-magiskboot' > "$d/lib/arm64-v8a/libmagiskboot.so"
  printf 'dummy-magisk32' > "$d/lib/armeabi-v7a/libmagisk32.so"
  printf 'dummy-stub' > "$d/assets/stub.apk"
  printf "MAGISK_VER='31.0-kitsune'\nMAGISK_VER_CODE=31000\n" > "$d/assets/util_functions.sh"
  (cd "$d" && zip -qr "$apk" .)
}

create_mock_initrd() {
  local out="$1"
  local stage2_body="$2"
  local d="$WORK_DIR/mock_initrd"
  rm -rf "$d"
  mkdir -p "$d/boot"
  printf '%s\n' "$stage2_body" > "$d/boot/stage2.sh"
  chmod 755 "$d/boot/stage2.sh"
  printf '# stock init.bst.rc\n' > "$d/init.bst.rc"
  (cd "$d" && find . | cpio -H newc -o 2>/dev/null) | gzip -9 > "$out"
}

create_mock_app() {
  local app="$1"
  local ver="$2"
  local stage2_body="$3"
  mkdir -p "$app/Contents/img"
  cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleShortVersionString</key>
  <string>${ver}</string>
  <key>CFBundleVersion</key>
  <string>${ver}</string>
</dict>
</plist>
EOF
  create_mock_initrd "$app/Contents/img/initrd_hvf.img" "$stage2_body"
}

echo "=== Running root-bluestacks-air regression tests ==="

APK="$WORK_DIR/magisk.apk"
create_mock_apk "$APK"

# Test 1: Paths with spaces, SIP-safe -o mode, preserving `exec /init "$@"`
APP="$WORK_DIR/App With Spaces/BlueStacks.app"
OUT_DIR="$WORK_DIR/Out With Spaces"
BAK_DIR="$WORK_DIR/Bak With Spaces"
create_mock_app "$APP" "5.22.100.1001" '#!/bin/sh
echo "stage2"
exec /init "$@"'

bash "$BASE_DIR/root.sh" -y -a "$APK" -p "$APP" -o "$OUT_DIR/initrd_hvf.img" -b "$BAK_DIR" >/dev/null

assert_file "$OUT_DIR/initrd_hvf.img"
assert_file "$BAK_DIR/initrd_hvf.img"
assert_file "$BAK_DIR/initrd_hvf.img.meta"
assert_contains "$BAK_DIR/initrd_hvf.img.meta" "BLUESTACKS_VERSION=5.22.100.1001"

INSPECT1="$WORK_DIR/inspect1"
mkdir -p "$INSPECT1"
(cd "$INSPECT1" && gzip -dc "$OUT_DIR/initrd_hvf.img" | cpio -id 2>/dev/null)
assert_file "$INSPECT1/boot/magisk/magisk64"
assert_file "$INSPECT1/boot/magisk/magisk32"
assert_file "$INSPECT1/boot/magisk/magiskpolicy"
assert_file "$INSPECT1/boot/magisk/stub.apk"
assert_file "$INSPECT1/boot/magisk/env/busybox"
assert_file "$INSPECT1/boot/magisk/env/util_functions.sh"
assert_file "$INSPECT1/boot/magisk.rc"
assert_contains "$INSPECT1/boot/stage2.sh" 'exec /init "$@"'
assert_contains "$INSPECT1/boot/stage2.sh" '# BEGIN ROOT-BLUESTACKS-AIR'
assert_contains "$INSPECT1/boot/magisk.rc" '/boot/magisk/magisk64 --auto-selinux --setup-sbin'
sh -n "$INSPECT1/boot/stage2.sh" || fail "Patched stage2.sh syntax invalid"
echo "[PASS] Test 1: Paths with spaces, SIP-safe -o, exec args preserved, magisk32+64 bundled"

# Test 2: Idempotent re-patch directly on already-patched initrd without backup
cp "$OUT_DIR/initrd_hvf.img" "$WORK_DIR/already_patched.img"
bash "$BASE_DIR/root.sh" -y -a "$APK" -s "$WORK_DIR/already_patched.img" -o "$WORK_DIR/repatched.img" -b "$WORK_DIR/repatch_bak" >/dev/null
INSPECT2="$WORK_DIR/inspect2"
mkdir -p "$INSPECT2"
(cd "$INSPECT2" && gzip -dc "$WORK_DIR/repatched.img" | cpio -id 2>/dev/null)
assert_count "$INSPECT2/boot/stage2.sh" '# BEGIN ROOT-BLUESTACKS-AIR' 1
assert_count "$INSPECT2/boot/stage2.sh" 'exec /init "$@"' 1
echo "[PASS] Test 2: Idempotent re-patching avoids duplicate blocks"

# Test 3: BlueStacks update rotates stale backup instead of overwriting new stock initrd
create_mock_app "$APP" "5.23.200.2002" '#!/bin/sh
echo "stage2 v2"
exec /init'
bash "$BASE_DIR/root.sh" -y -a "$APK" -p "$APP" -o "$OUT_DIR/initrd_v2.img" -b "$BAK_DIR" >/dev/null
ls "$BAK_DIR"/initrd_hvf.img.prev.* >/dev/null 2>&1 || fail "Expected rotated backup after BlueStacks update"
assert_contains "$BAK_DIR/initrd_hvf.img.meta" "BLUESTACKS_VERSION=5.23.200.2002"
INSPECT3="$WORK_DIR/inspect3"
mkdir -p "$INSPECT3"
(cd "$INSPECT3" && gzip -dc "$OUT_DIR/initrd_v2.img" | cpio -id 2>/dev/null)
assert_contains "$INSPECT3/boot/stage2.sh" 'echo "stage2 v2"'
echo "[PASS] Test 3: BlueStacks update rotates old backup and patches new initrd"

# Test 4: Unroot restores stock initrd
TARGET_RESTORE="$WORK_DIR/target_initrd.img"
cp "$OUT_DIR/initrd_v2.img" "$TARGET_RESTORE"
bash "$BASE_DIR/unroot.sh" -y -b "$BAK_DIR" -t "$TARGET_RESTORE" -n >/dev/null
INSPECT4="$WORK_DIR/inspect4"
mkdir -p "$INSPECT4"
(cd "$INSPECT4" && gzip -dc "$TARGET_RESTORE" | cpio -id 2>/dev/null)
[[ ! -d "$INSPECT4/boot/magisk" ]] || fail "boot/magisk still present after unroot"
assert_contains "$INSPECT4/boot/stage2.sh" 'echo "stage2 v2"'
echo "[PASS] Test 4: unroot.sh cleanly restores stock initrd"

# Test 5: Invalid APK fails cleanly without touching target
printf 'not-a-zip' > "$WORK_DIR/bad.apk"
if bash "$BASE_DIR/root.sh" -y -a "$WORK_DIR/bad.apk" -s "$TARGET_RESTORE" -o "$WORK_DIR/should_not_exist.img" >/dev/null 2>&1; then
  fail "Expected failure on invalid APK"
fi
[[ ! -f "$WORK_DIR/should_not_exist.img" ]] || fail "Output file created despite invalid APK"
echo "[PASS] Test 5: Invalid APK rejected cleanly with no partial output"

# Test 6: Chrome config unblacklist & ROM library mismatch safety guard
CFG_IN="$WORK_DIR/config.db"
CFG_OUT="$WORK_DIR/config_user.db"
cat > "$CFG_IN" <<'EOF'
{
  "packages": [
    {
      "pkgname": "com.android.chrome",
      "rules": [
        {"blacklist": "*", "countries": "*", "oems": "nxt_mac2", "prodversion_gte": "5.0.0.0"},
        {"blacklist": "*", "countries": "*", "oems": "nxt", "android_images": "Rvc64"}
      ]
    }
  ]
}
EOF
python3 "$BASE_DIR/lib/bluestacks-chrome-fix.py" unblacklist-chrome --in "$CFG_IN" --out "$CFG_OUT"
assert_file "$CFG_OUT"
python3 - "$CFG_OUT" <<'EOF'
import json, sys
doc = json.load(open(sys.argv[1]))
rules = doc["packages"][0]["rules"]
assert len(rules) == 1 and rules[0]["oems"] == "nxt", rules
EOF
rc=0
python3 "$BASE_DIR/lib/bluestacks-chrome-fix.py" unblacklist-chrome --in "$CFG_OUT" --out "$CFG_OUT.2" || rc=$?
[[ $rc -eq 2 ]] || fail "Expected exit code 2 when Chrome already unblacklisted, got $rc"

printf 'not-matching-runtime' > "$WORK_DIR/rt.so"
printf 'not-matching-binder' > "$WORK_DIR/bd.so"
rc=0
python3 "$BASE_DIR/lib/bluestacks-chrome-fix.py" patch-libs \
  --runtime-in "$WORK_DIR/rt.so" --runtime-out "$WORK_DIR/rt.out" \
  --binder-in "$WORK_DIR/bd.so" --binder-out "$WORK_DIR/bd.out" 2>/dev/null || rc=$?
[[ $rc -eq 3 ]] || fail "Expected exit code 3 on mismatched ROM hashes, got $rc"
[[ ! -f "$WORK_DIR/rt.out" ]] || fail "Patched file created despite hash mismatch"
echo "[PASS] Test 6: Chrome unblacklist idempotent & ROM hash guard rejects mismatch"

echo "=== All regression tests passed ==="

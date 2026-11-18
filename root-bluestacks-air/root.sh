#!/bin/bash

set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
# shellcheck source=lib/common.sh
source "$BASE_DIR/lib/common.sh"

BLUESTACKS="${BLUESTACKS_APP:-/Applications/BlueStacks.app}"
ARCH="arm64-v8a"
ARCH32="armeabi-v7a"
APK_PATH=""
INITRD_SOURCE=""
INITRD_OUTPUT=""
BACKUP_DIR=""
INPLACE=1
RUN_ADB=1
AUTO_YES=0

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  -a <magisk.apk>     Path to Kitsune Mask APK (default: ./magisk.apk or <repo>/magisk.apk)
  -p <BlueStacks.app> Path to BlueStacks Air app bundle (default: /Applications/BlueStacks.app)
  -s <initrd_img>     Explicit source initrd_hvf.img (overrides <BlueStacks.app>/Contents/img/initrd_hvf.img)
  -o <output_img>     Write patched initrd_hvf.img to a custom path (SIP-safe mode)
  -b <backup_dir>     Directory to store original initrd backup and metadata
  -n                  Skip automatic ADB APK installation step after launching BlueStacks
  -y                  Skip confirmation prompt
  -h                  Show this help message
EOF
}

while getopts "ha:p:s:o:b:iny" opt; do
  case "$opt" in
    h)
      usage
      exit 0
      ;;
    a)
      APK_PATH="$(abspath "$OPTARG")"
      ;;
    p)
      BLUESTACKS="$(abspath "$OPTARG")"
      ;;
    s)
      INITRD_SOURCE="$(abspath "$OPTARG")"
      ;;
    o)
      INITRD_OUTPUT="$(abspath "$OPTARG")"
      INPLACE=0
      ;;
    b)
      BACKUP_DIR="$(abspath "$OPTARG")"
      ;;
    i)
      RUN_ADB=1
      ;;
    n)
      RUN_ADB=0
      ;;
    y)
      AUTO_YES=1
      ;;
    \?)
      usage >&2
      exit 1
      ;;
  esac
done

# Resolve APK path
if [[ -z "$APK_PATH" ]]; then
  if [[ -f "$PWD/magisk.apk" ]]; then
    APK_PATH="$PWD/magisk.apk"
  elif [[ -f "$BASE_DIR/magisk.apk" ]]; then
    APK_PATH="$BASE_DIR/magisk.apk"
  else
    log_err "magisk.apk not found in current directory or $BASE_DIR. Pass -a <path-to-apk>."
    exit 1
  fi
elif [[ ! -f "$APK_PATH" ]]; then
  log_err "Specified Magisk APK not found: $APK_PATH"
  exit 1
fi

# Resolve source initrd & BlueStacks version
BS_VERSION="unknown"
if [[ -n "$INITRD_SOURCE" ]]; then
  INITRD_PATH="$INITRD_SOURCE"
  if [[ -d "$BLUESTACKS" ]]; then
    BS_VERSION="$(detect_bluestacks_version "$BLUESTACKS")"
  fi
else
  if [[ ! -d "$BLUESTACKS" ]]; then
    log_err "BlueStacks Air not found at $BLUESTACKS (use -p or -s to specify path)"
    exit 1
  fi
  BS_VERSION="$(detect_bluestacks_version "$BLUESTACKS")"
  INITRD_PATH="$BLUESTACKS/Contents/img/initrd_hvf.img"
fi

if [[ ! -f "$INITRD_PATH" ]]; then
  log_err "initrd_hvf.img not found at: $INITRD_PATH"
  exit 1
fi

if [[ -n "$BACKUP_DIR" ]]; then
  mkdir -p "$BACKUP_DIR"
  INITRD_BACKUP="$BACKUP_DIR/initrd_hvf.img"
else
  INITRD_BACKUP="${INITRD_PATH}.bak"
fi
BACKUP_META="${INITRD_BACKUP}.meta"

if [[ -z "$INITRD_OUTPUT" ]]; then
  INITRD_OUTPUT="$INITRD_PATH"
else
  mkdir -p "$(dirname "$INITRD_OUTPUT")"
fi

echo "=================================================="
echo "**                                              **"
echo "**        BlueStacks Air Magisk Installer       **"
echo "**                                              **"
echo "=================================================="
echo ""
log_info "BlueStacks Air version : $BS_VERSION"
log_info "Magisk APK             : $APK_PATH"
log_info "Source initrd          : $INITRD_PATH"
log_info "Backup path            : $INITRD_BACKUP"
log_info "Output initrd          : $INITRD_OUTPUT"
echo ""

if [[ $INPLACE -eq 1 ]]; then
  echo "Checklist:"
  echo "* You have started BlueStacks Air at least once."
  echo "* BlueStacks Air will be closed before patching."
  echo ""
fi

if [[ $AUTO_YES -ne 1 ]]; then
  read -r -p "Continue? (y/n): " confirm
  if [[ ! "$confirm" =~ ^([yY]|[yY][eE][sS])$ ]]; then
    exit 0
  fi
fi

# Setup isolated temporary workspace
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bs-air-root.XXXXXX")"
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

# Validate Magisk APK contents
log_info "Validating Magisk APK..."
APK_LIST="$(unzip -Z1 "$APK_PATH" 2>/dev/null || true)"
if [[ -z "$APK_LIST" ]]; then
  log_err "Invalid or unreadable APK archive: $APK_PATH"
  exit 1
fi

for req in "lib/$ARCH/libmagisk64.so" "lib/$ARCH/libmagiskpolicy.so" "assets/stub.apk"; do
  if ! printf '%s\n' "$APK_LIST" | grep -qx "$req"; then
    log_err "APK is missing required entry '$req'. Ensure you are using a Kitsune Magisk APK."
    exit 1
  fi
done

if [[ $INPLACE -eq 1 && -z "$INITRD_SOURCE" ]]; then
  quit_bluestacks
fi

# Extract Magisk binaries + boot env files (so magiskd auto-populates /data/adb/magisk on first boot)
MAGISK_UNZIP_DIR="$WORK_DIR/apk"
MAGISK_BIN_DIR="$WORK_DIR/magisk-bin"
MAGISK_ENV_DIR="$MAGISK_BIN_DIR/env"
mkdir -p "$MAGISK_UNZIP_DIR" "$MAGISK_BIN_DIR" "$MAGISK_ENV_DIR"
unzip -oq "$APK_PATH" -d "$MAGISK_UNZIP_DIR"

for bin_name in magisk64 magiskinit magiskpolicy; do
  src="$MAGISK_UNZIP_DIR/lib/$ARCH/lib${bin_name}.so"
  if [[ -f "$src" ]]; then
    cp "$src" "$MAGISK_BIN_DIR/$bin_name"
    cp "$src" "$MAGISK_ENV_DIR/$bin_name"
  fi
done

# Bundle 32-bit binary alongside 64-bit if present in APK (never replacing magisk64 in magisk.rc)
if [[ -f "$MAGISK_UNZIP_DIR/lib/$ARCH32/libmagisk32.so" ]]; then
  cp "$MAGISK_UNZIP_DIR/lib/$ARCH32/libmagisk32.so" "$MAGISK_BIN_DIR/magisk32"
  cp "$MAGISK_UNZIP_DIR/lib/$ARCH32/libmagisk32.so" "$MAGISK_ENV_DIR/magisk32"
fi

# Bundle busybox, magiskboot, and Magisk helper scripts in boot/magisk/env/
for env_bin in busybox magiskboot; do
  src="$MAGISK_UNZIP_DIR/lib/$ARCH/lib${env_bin}.so"
  if [[ -f "$src" ]]; then
    cp "$src" "$MAGISK_ENV_DIR/$env_bin"
  fi
done
cp "$MAGISK_UNZIP_DIR/assets/stub.apk" "$MAGISK_BIN_DIR/stub.apk"
cp "$MAGISK_UNZIP_DIR/assets/stub.apk" "$MAGISK_ENV_DIR/stub.apk"
for sh_file in "$MAGISK_UNZIP_DIR/assets/"*.sh; do
  [[ -f "$sh_file" ]] && cp "$sh_file" "$MAGISK_ENV_DIR/"
done

chmod 700 "$MAGISK_BIN_DIR"/*
chmod 700 "$MAGISK_ENV_DIR"/*

# Detect initrd compression and inspect live initrd
INITRD_FMT="$(detect_initrd_compression "$INITRD_PATH")"
log_info "Detected initrd format: $INITRD_FMT"

LIVE_INSPECT_DIR="$WORK_DIR/inspect-live"
extract_initrd "$INITRD_PATH" "$LIVE_INSPECT_DIR" "$INITRD_FMT"

INITRD_WORK_DIR="$WORK_DIR/initrd"

if is_initrd_dir_patched "$LIVE_INSPECT_DIR"; then
  log_info "Source initrd is already patched."
  if [[ -f "$INITRD_BACKUP" ]]; then
    BAK_FMT="$(detect_initrd_compression "$INITRD_BACKUP")"
    BAK_INSPECT_DIR="$WORK_DIR/inspect-bak"
    extract_initrd "$INITRD_BACKUP" "$BAK_INSPECT_DIR" "$BAK_FMT"
    if ! is_initrd_dir_patched "$BAK_INSPECT_DIR"; then
      log_info "Using clean backup as base: $INITRD_BACKUP"
      INITRD_WORK_DIR="$BAK_INSPECT_DIR"
      INITRD_FMT="$BAK_FMT"
    else
      log_warn "Backup appears patched as well; cleaning previous Magisk injection from live initrd."
      INITRD_WORK_DIR="$LIVE_INSPECT_DIR"
    fi
  else
    log_warn "No backup found; cleaning previous Magisk injection from live initrd."
    INITRD_WORK_DIR="$LIVE_INSPECT_DIR"
  fi
else
  # Live initrd is clean/stock. Handle backup safely across BlueStacks updates.
  LIVE_SHA="$(sha256_file "$INITRD_PATH")"
  NEED_BACKUP=0

  if [[ ! -f "$INITRD_BACKUP" ]]; then
    NEED_BACKUP=1
  else
    BAK_SHA="$(sha256_file "$INITRD_BACKUP")"
    if [[ "$LIVE_SHA" != "$BAK_SHA" ]]; then
      log_warn "BlueStacks initrd changed since previous backup (app updated?). Rotating old backup."
      ROTATED="${INITRD_BACKUP}.prev.$(date +%Y%m%d%H%M%S)"
      cp -f "$INITRD_BACKUP" "$ROTATED"
      [[ -f "$BACKUP_META" ]] && cp -f "$BACKUP_META" "${ROTATED}.meta"
      NEED_BACKUP=1
    fi
  fi

  if [[ $NEED_BACKUP -eq 1 ]]; then
    log_info "Backing up stock initrd to $INITRD_BACKUP"
    if ! atomic_install_file "$INITRD_PATH" "$INITRD_BACKUP"; then
      log_err "Failed to write backup to $INITRD_BACKUP. Check permissions or use -b <backup_dir>."
      exit 1
    fi
    cat > "$BACKUP_META" <<EOF
BLUESTACKS_VERSION=$BS_VERSION
ORIGINAL_SHA256=$LIVE_SHA
CREATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
  else
    log_info "Stock backup already up to date: $INITRD_BACKUP"
  fi

  INITRD_WORK_DIR="$LIVE_INSPECT_DIR"
fi

# Clean any leftover Magisk artifacts from base dir
rm -rf "$INITRD_WORK_DIR/boot/magisk" "$INITRD_WORK_DIR/boot/magisk.rc"

# Locate stage2 script dynamically
STAGE2_FILE=""
if [[ -f "$INITRD_WORK_DIR/boot/stage2.sh" ]]; then
  STAGE2_FILE="$INITRD_WORK_DIR/boot/stage2.sh"
else
  STAGE2_FILE="$(grep -rIlE 'init\.bst\.rc|exec[[:space:]]+/init' "$INITRD_WORK_DIR/boot" "$INITRD_WORK_DIR" 2>/dev/null | head -n 1 || true)"
fi

if [[ -z "$STAGE2_FILE" || ! -f "$STAGE2_FILE" ]]; then
  log_err "Could not locate stage2 boot script inside initrd."
  exit 1
fi

log_info "Patching boot script: ${STAGE2_FILE#"$INITRD_WORK_DIR"/}"

# Copy Magisk binaries & magisk.rc into initrd
mkdir -p "$INITRD_WORK_DIR/boot"
cp -R "$MAGISK_BIN_DIR" "$INITRD_WORK_DIR/boot/magisk"
chmod 700 "$INITRD_WORK_DIR/boot/magisk"
chmod 700 "$INITRD_WORK_DIR/boot/magisk"/*
if [[ -d "$INITRD_WORK_DIR/boot/magisk/env" ]]; then
  chmod 700 "$INITRD_WORK_DIR/boot/magisk/env"/*
fi
cp "$BASE_DIR/magisk.rc" "$INITRD_WORK_DIR/boot/magisk.rc"
chmod 644 "$INITRD_WORK_DIR/boot/magisk.rc"

# Strip any previous injection block (idempotent)
STAGE2_CLEAN="$WORK_DIR/stage2.clean.sh"
awk -v b="$BS_ROOT_MARKER_BEGIN" -v e="$BS_ROOT_MARKER_END" '
  $0 == b { skip=1; next }
  $0 == e { skip=0; next }
  !skip { print }
' "$STAGE2_FILE" > "$STAGE2_CLEAN"

# Build the snippet to inject right before the final `exec ...` line
SNIPPET_FILE="$WORK_DIR/snippet.sh"
cat > "$SNIPPET_FILE" <<EOF
$BS_ROOT_MARKER_BEGIN
_bs_log() {
  if command -v log_echo >/dev/null 2>&1; then
    log_echo "\$1"
  else
    echo "\$1"
  fi
}
_bs_log "Installing magisk.rc"
_TARGET_RC="/init.bst.rc"
[ -f "\$_TARGET_RC" ] || _TARGET_RC="/init.rc"
if [ -f /boot/magisk.rc ] && [ -f "\$_TARGET_RC" ]; then
  if ! grep -q '/boot/magisk/magisk64' "\$_TARGET_RC" 2>/dev/null; then
    cat /boot/magisk.rc >> "\$_TARGET_RC"
    if command -v die_if_error >/dev/null 2>&1; then
      die_if_error "Cannot install magisk.rc"
    fi
  fi
fi
$BS_ROOT_MARKER_END
EOF

# Find line number of the last `exec ...` statement
LAST_EXEC_LINE="$(grep -nE '^[[:space:]]*exec[[:space:]]+' "$STAGE2_CLEAN" | tail -n 1 | cut -d: -f1 || true)"
STAGE2_PATCHED="$WORK_DIR/stage2.patched.sh"

if [[ -n "$LAST_EXEC_LINE" ]]; then
  awk -v target="$LAST_EXEC_LINE" -v snip="$SNIPPET_FILE" '
    NR == target {
      while ((getline line < snip) > 0) print line
      close(snip)
    }
    { print }
  ' "$STAGE2_CLEAN" > "$STAGE2_PATCHED"
else
  cat "$STAGE2_CLEAN" "$SNIPPET_FILE" > "$STAGE2_PATCHED"
fi

# Validate shell syntax of patched stage2 script
if ! sh -n "$STAGE2_PATCHED"; then
  log_err "Patched stage2 script failed shell syntax validation!"
  exit 1
fi

cp "$STAGE2_PATCHED" "$STAGE2_FILE"
chmod 755 "$STAGE2_FILE"

# Repack and verify
PATCHED_IMG="$WORK_DIR/initrd_hvf.img.patched"
log_info "Repacking and verifying initrd..."
pack_initrd "$INITRD_WORK_DIR" "$PATCHED_IMG" "$INITRD_FMT"

log_info "Writing patched initrd to $INITRD_OUTPUT..."
if ! atomic_install_file "$PATCHED_IMG" "$INITRD_OUTPUT"; then
  log_err "Failed to write $INITRD_OUTPUT (macOS SIP / App Management may block modifying $BLUESTACKS directly)."
  log_err "Grant Terminal 'App Management' permission in System Settings > Privacy & Security, OR run with:"
  log_err "  bash \"$0\" -o files/initrd_hvf.img -b files/backup"
  exit 1
fi

if [[ $INPLACE -eq 1 && -z "$INITRD_SOURCE" ]]; then
  log_info "Starting BlueStacks Air..."
  if [[ -n "${SUDO_USER:-}" ]]; then
    sudo -u "$SUDO_USER" open -n "$BLUESTACKS"
  else
    open -n "$BLUESTACKS"
  fi

  if [[ $RUN_ADB -eq 1 ]]; then
    echo ""
    log_info "Proceeding with 1-step ADB APK installation..."
    if ! bash "$BASE_DIR/adb-setup.sh" -a "$APK_PATH" -p "$BLUESTACKS"; then
      log_warn "ADB auto-install skipped or failed (is ADB enabled in BlueStacks Settings > Advanced?)."
      log_warn "You can install \"$APK_PATH\" manually inside BlueStacks, or enable ADB and run: bash \"$BASE_DIR/adb-setup.sh\""
    fi
  else
    log_info "Done."
    echo ""
    echo "=================================================="
    echo "Next steps:"
    echo "* Install \"$APK_PATH\" in BlueStacks Air (or run: bash \"$BASE_DIR/adb-setup.sh\")"
    echo "=================================================="
  fi
else
  log_info "Done."
  echo ""
  echo "=================================================="
  echo "Next steps:"
  echo "* Copy \"$INITRD_OUTPUT\" to \"$INITRD_PATH\" (replace original)"
  echo "* Start BlueStacks Air"
  echo "* Install \"$APK_PATH\" in BlueStacks Air (or run: bash \"$BASE_DIR/adb-setup.sh\")"
  echo "=================================================="
fi

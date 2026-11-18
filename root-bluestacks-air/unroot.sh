#!/bin/bash

set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
# shellcheck source=lib/common.sh
source "$BASE_DIR/lib/common.sh"

BLUESTACKS="${BLUESTACKS_APP:-/Applications/BlueStacks.app}"
BACKUP_DIR=""
INITRD_TARGET=""
NO_START=0
AUTO_YES=0

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  -b <backup_dir>     Directory containing initrd_hvf.img backup
  -p <BlueStacks.app> Path to BlueStacks Air app bundle (default: /Applications/BlueStacks.app)
  -t <target_img>     Explicit target initrd_hvf.img path to restore
  -n                  Do not launch BlueStacks Air after restoring
  -y                  Skip confirmation prompt
  -h                  Show this help message
EOF
}

while getopts "hb:p:t:ny" opt; do
  case "$opt" in
    h)
      usage
      exit 0
      ;;
    b)
      BACKUP_DIR="$(abspath "$OPTARG")"
      ;;
    p)
      BLUESTACKS="$(abspath "$OPTARG")"
      ;;
    t)
      INITRD_TARGET="$(abspath "$OPTARG")"
      ;;
    n)
      NO_START=1
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

if [[ -n "$INITRD_TARGET" ]]; then
  INITRD_PATH="$INITRD_TARGET"
else
  if [[ ! -d "$BLUESTACKS" ]]; then
    log_err "BlueStacks Air not found at $BLUESTACKS"
    exit 1
  fi
  INITRD_PATH="$BLUESTACKS/Contents/img/initrd_hvf.img"
fi

if [[ -n "$BACKUP_DIR" ]]; then
  INITRD_BACKUP="$BACKUP_DIR/initrd_hvf.img"
else
  INITRD_BACKUP="${INITRD_PATH}.bak"
fi
BACKUP_META="${INITRD_BACKUP}.meta"

if [[ ! -f "$INITRD_BACKUP" ]]; then
  log_err "Backup initrd not found at: $INITRD_BACKUP"
  exit 1
fi

BAK_FMT="$(detect_initrd_compression "$INITRD_BACKUP")"
verify_initrd "$INITRD_BACKUP" "$BAK_FMT" 0

if [[ -d "$BLUESTACKS" && -f "$BACKUP_META" ]]; then
  CUR_VER="$(detect_bluestacks_version "$BLUESTACKS")"
  BAK_VER="$(grep '^BLUESTACKS_VERSION=' "$BACKUP_META" | cut -d= -f2- || true)"
  if [[ -n "$BAK_VER" && "$CUR_VER" != "unknown" && "$BAK_VER" != "$CUR_VER" ]]; then
    log_warn "Backup was created for BlueStacks $BAK_VER, but current version is $CUR_VER."
    if [[ $AUTO_YES -ne 1 ]]; then
      read -r -p "Restore anyway? (y/n): " confirm
      if [[ ! "$confirm" =~ ^([yY]|[yY][eE][sS])$ ]]; then
        exit 0
      fi
    fi
  fi
fi

if [[ -z "$INITRD_TARGET" ]]; then
  quit_bluestacks
fi

log_info "Restoring initrd from $INITRD_BACKUP -> $INITRD_PATH"
if ! atomic_install_file "$INITRD_BACKUP" "$INITRD_PATH"; then
  log_err "Failed to restore $INITRD_PATH (SIP / App Management may block direct write)."
  log_err "Manually copy \"$INITRD_BACKUP\" to \"$INITRD_PATH\"."
  exit 1
fi

if [[ $NO_START -eq 0 && -z "$INITRD_TARGET" ]]; then
  log_info "Starting BlueStacks Air..."
  open -n "$BLUESTACKS"
fi

log_info "Unroot restore complete."
log_info "If you also want to remove /data/adb and Magisk app, uninstall Kitsune Mask from Android."

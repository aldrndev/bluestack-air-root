#!/bin/bash

# Shared helpers for BlueStacks Air Magisk root/unroot/adb scripts.
# Written for macOS /bin/bash (3.2+ compatible).

BS_ROOT_MARKER_BEGIN="# BEGIN ROOT-BLUESTACKS-AIR"
BS_ROOT_MARKER_END="# END ROOT-BLUESTACKS-AIR"

log_info() {
  printf '[*] %s\n' "$*"
}

log_warn() {
  printf '[!] %s\n' "$*" >&2
}

log_err() {
  printf '[ERROR] %s\n' "$*" >&2
}

abspath() {
  local target="$1"
  local dir base
  if [[ "$target" == /* ]]; then
    printf '%s\n' "$target"
    return 0
  fi
  dir="$(dirname "$target")"
  base="$(basename "$target")"
  if [[ -d "$dir" ]]; then
    (cd "$dir" && printf '%s/%s\n' "$(pwd -P)" "$base")
  else
    printf '%s/%s\n' "$(pwd -P)" "$target"
  fi
}

sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

detect_bluestacks_version() {
  local app_path="$1"
  local plist="$app_path/Contents/Info.plist"
  local short_ver=""
  local bundle_ver=""

  if [[ -f "$plist" ]]; then
    short_ver="$(defaults read "$plist" CFBundleShortVersionString 2>/dev/null || true)"
    bundle_ver="$(defaults read "$plist" CFBundleVersion 2>/dev/null || true)"
  fi

  if [[ -n "$bundle_ver" && -n "$short_ver" && "$bundle_ver" != "$short_ver" ]]; then
    printf '%s (%s)\n' "$bundle_ver" "$short_ver"
  elif [[ -n "$bundle_ver" ]]; then
    printf '%s\n' "$bundle_ver"
  elif [[ -n "$short_ver" ]]; then
    printf '%s\n' "$short_ver"
  else
    printf 'unknown\n'
  fi
}

bluestacks_running() {
  pgrep -f "BlueStacks\.app|BlueStacks Air multi-instance manager|HD-Player|BstkSVC|HD-LogCollector|BlueStacksAIRun" >/dev/null 2>&1
}

quit_bluestacks() {
  if ! bluestacks_running; then
    return 0
  fi

  log_info "Closing BlueStacks Air gracefully..."
  osascript -e 'tell application "BlueStacks" to quit' >/dev/null 2>&1 || true
  osascript -e 'tell application "BlueStacks Air multi-instance manager" to quit' >/dev/null 2>&1 || true

  local waited=0
  while bluestacks_running && [[ $waited -lt 10 ]]; do
    sleep 1
    waited=$((waited + 1))
  done

  if bluestacks_running; then
    log_warn "BlueStacks still running; sending SIGTERM..."
    pkill -TERM -x "BlueStacks" >/dev/null 2>&1 || true
    pkill -TERM -x "BlueStacks Air multi-instance manager" >/dev/null 2>&1 || true
    pkill -TERM -f "BlueStacks\.app/Contents/MacOS/qemu-system-aarch64|HD-Player|BstkSVC|HD-LogCollector|BlueStacksAIRun" >/dev/null 2>&1 || true
    sleep 2
  fi

  if bluestacks_running; then
    log_warn "BlueStacks did not exit cleanly; forcing termination..."
    pkill -KILL -x "BlueStacks" >/dev/null 2>&1 || true
    pkill -KILL -x "BlueStacks Air multi-instance manager" >/dev/null 2>&1 || true
    pkill -KILL -f "BlueStacks\.app/Contents/MacOS/qemu-system-aarch64|HD-Player|BstkSVC|HD-LogCollector|BlueStacksAIRun" >/dev/null 2>&1 || true
    sleep 1
  fi

  if bluestacks_running; then
    log_err "Unable to stop all BlueStacks processes. Please quit BlueStacks manually and retry."
    return 1
  fi
}

detect_initrd_compression() {
  local file="$1"
  local magic
  magic="$(od -An -tx1 -N4 "$file" | tr -d ' \n')"
  case "$magic" in
    1f8b*)
      printf 'gzip\n'
      ;;
    28b52ffd*)
      printf 'zstd\n'
      ;;
    02214c18*)
      printf 'lz4\n'
      ;;
    fd377a58*)
      printf 'xz\n'
      ;;
    30373037*)
      printf 'cpio\n'
      ;;
    *)
      # Fallback to `file` output if magic bytes didn't match standard headers
      local desc
      desc="$(file -b "$file" 2>/dev/null || true)"
      case "$desc" in
        *gzip*) printf 'gzip\n' ;;
        *Zstandard*) printf 'zstd\n' ;;
        *LZ4*) printf 'lz4\n' ;;
        *XZ*) printf 'xz\n' ;;
        *cpio*) printf 'cpio\n' ;;
        *)
          log_err "Unsupported or unrecognized initrd format ($magic / $desc)"
          return 1
          ;;
      esac
      ;;
  esac
}

decompress_initrd_stream() {
  local file="$1"
  local fmt="$2"
  case "$fmt" in
    gzip) gzip -dc "$file" ;;
    zstd) zstd -dc "$file" ;;
    lz4) lz4 -dc "$file" ;;
    xz) xz -dc "$file" ;;
    cpio) cat "$file" ;;
    *)
      log_err "Unsupported initrd compression: $fmt"
      return 1
      ;;
  esac
}

compress_initrd_stream() {
  local fmt="$1"
  case "$fmt" in
    gzip) gzip -9 ;;
    zstd) zstd -19 -q ;;
    lz4) lz4 -l -9 ;;
    xz) xz -9 --check=crc32 ;;
    cpio) cat ;;
    *)
      log_err "Unsupported initrd compression: $fmt"
      return 1
      ;;
  esac
}

extract_initrd() {
  local img="$1"
  local dest_dir="$2"
  local fmt="$3"

  mkdir -p "$dest_dir"
  (
    cd "$dest_dir"
    decompress_initrd_stream "$img" "$fmt" | cpio -id
  )
}

verify_initrd() {
  local img="$1"
  local fmt="$2"
  local require_magisk="${3:-0}"

  if [[ ! -s "$img" ]]; then
    log_err "Initrd image is missing or empty: $img"
    return 1
  fi

  if [[ "$fmt" == "gzip" ]] && ! gzip -t "$img" 2>/dev/null; then
    log_err "Initrd gzip integrity check failed: $img"
    return 1
  fi

  local listing
  if ! listing="$(decompress_initrd_stream "$img" "$fmt" | cpio -it 2>/dev/null)"; then
    log_err "Initrd cpio archive listing failed: $img"
    return 1
  fi

  if [[ -z "$listing" ]]; then
    log_err "Initrd archive contains no entries: $img"
    return 1
  fi

  if [[ "$require_magisk" -eq 1 ]]; then
    if ! printf '%s\n' "$listing" | grep -qE '(^|\./)boot/magisk/magisk64$'; then
      log_err "Verified initrd is missing boot/magisk/magisk64"
      return 1
    fi
    if ! printf '%s\n' "$listing" | grep -qE '(^|\./)boot/magisk\.rc$'; then
      log_err "Verified initrd is missing boot/magisk.rc"
      return 1
    fi
  fi
}

pack_initrd() {
  local src_dir="$1"
  local out_img="$2"
  local fmt="$3"
  local tmp_out="${out_img}.tmp.$$"

  (
    cd "$src_dir"
    find . | cpio -H newc -o
  ) | compress_initrd_stream "$fmt" > "$tmp_out"

  verify_initrd "$tmp_out" "$fmt" 1
  mv -f "$tmp_out" "$out_img"
}

is_initrd_dir_patched() {
  local dir="$1"
  if [[ -d "$dir/boot/magisk" || -f "$dir/boot/magisk.rc" ]]; then
    return 0
  fi
  if [[ -f "$dir/boot/stage2.sh" ]] && grep -q "$BS_ROOT_MARKER_BEGIN" "$dir/boot/stage2.sh"; then
    return 0
  fi
  return 1
}

atomic_install_file() {
  local src="$1"
  local dst="$2"
  local dst_dir dst_tmp
  dst_dir="$(dirname "$dst")"
  dst_tmp="${dst}.tmp.$$"

  if ! cp -f "$src" "$dst_tmp" 2>/dev/null; then
    rm -f "$dst_tmp" 2>/dev/null || true
    return 1
  fi
  if ! mv -f "$dst_tmp" "$dst" 2>/dev/null; then
    rm -f "$dst_tmp" 2>/dev/null || true
    return 1
  fi
  return 0
}

find_adb_bin() {
  if command -v adb >/dev/null 2>&1; then
    command -v adb
    return 0
  fi
  if [[ -x "$HOME/Library/Android/sdk/platform-tools/adb" ]]; then
    printf '%s\n' "$HOME/Library/Android/sdk/platform-tools/adb"
    return 0
  fi
  local app_path="${1:-/Applications/BlueStacks.app}"
  if [[ -x "$app_path/Contents/MacOS/hd-adb" ]]; then
    printf '%s\n' "$app_path/Contents/MacOS/hd-adb"
    return 0
  fi
  return 1
}

detect_bluestacks_adb_port() {
  local conf
  for conf in \
    "/Users/Shared/Library/Application Support/BlueStacks/bluestacks.conf" \
    "$HOME/Library/Application Support/BlueStacks/bluestacks.conf"; do
    if [[ -f "$conf" ]]; then
      local port
      port="$(grep -E '\.adb_port=' "$conf" | head -n 1 | sed -E 's/.*="([0-9]+)".*/\1/' || true)"
      if [[ -n "$port" && "$port" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$port"
        return 0
      fi
    fi
  done
  printf '5555\n'
}

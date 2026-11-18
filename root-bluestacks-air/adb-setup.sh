#!/bin/bash

set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
# shellcheck source=lib/common.sh
source "$BASE_DIR/lib/common.sh"

BLUESTACKS="${BLUESTACKS_APP:-/Applications/BlueStacks.app}"
APK_PATH=""
ADB_PORT=""
REZYGISK_ZIP=""
SKIP_ZYGISK=0
SKIP_CHROME_FIX=0
AUTO_REBOOT=1
TIMEOUT_SEC=90

REZYGISK_DEFAULT_URL="https://github.com/PerformanC/ReZygisk/releases/download/v1.0.0/ReZygisk-v1.0.0-release.zip"
RUNTIME_ORIG_SHA="f9c9745941b92a6350bc4490682de169c6716dd9d3e89b877b80056754e65df1"
RUNTIME_PATCHED_SHA="487dc1f4f69302e00aabe8c2b28b18d0d6324ad0d1b0f7de5583e325a677f5c2"
BINDER_ORIG_SHA="a26321bfe4a7a1199fc337d568fb870942ab16084a83467c331a12da35a763f7"
BINDER_PATCHED_SHA="7fd7862bcfd20ed971a33aeb1a794cf959bcd1e14b7b11ffd29f1920dfbdfafb"

usage() {
  cat <<EOF
Usage: $0 [options]

Connects to BlueStacks Air over ADB, installs Kitsune Mask APK,
seeds /data/adb/magisk, installs ReZygisk and the BlueStacks Chrome
AppZygote fix module, unblacklists Chrome updates in Play Store,
restarts BlueStacks Air once if modules changed, and verifies root/Zygisk.

Options:
  -a <magisk.apk>     Path to Kitsune Mask APK (default: ./magisk.apk or <repo>/magisk.apk)
  -p <BlueStacks.app> Path to BlueStacks Air app bundle (default: /Applications/BlueStacks.app)
  -P <port>           ADB TCP port (default: auto-detect from bluestacks.conf or 5555)
  -z <rezygisk.zip>   Path to ReZygisk module zip (default: local cache or GitHub v1.0.0 release)
  -Z                  Skip ReZygisk installation
  -C                  Skip Chrome AppZygote fix & Play Store unblacklist
  -R                  Skip automatic BlueStacks restart after staging modules
  -t <seconds>        Boot wait timeout in seconds (default: 90)
  -h                  Show this help message
EOF
}

while getopts "ha:p:P:z:ZCRt:" opt; do
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
    P)
      ADB_PORT="$OPTARG"
      ;;
    z)
      REZYGISK_ZIP="$(abspath "$OPTARG")"
      ;;
    Z)
      SKIP_ZYGISK=1
      ;;
    C)
      SKIP_CHROME_FIX=1
      ;;
    R)
      AUTO_REBOOT=0
      ;;
    t)
      TIMEOUT_SEC="$OPTARG"
      ;;
    \?)
      usage >&2
      exit 1
      ;;
  esac
done

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

if [[ -n "$REZYGISK_ZIP" && ! -f "$REZYGISK_ZIP" ]]; then
  log_err "Specified ReZygisk zip not found: $REZYGISK_ZIP"
  exit 1
fi

if ! ADB_BIN="$(find_adb_bin "$BLUESTACKS")"; then
  log_err "adb binary not found. Install Android platform-tools or set PATH."
  exit 1
fi

run_as_invoker() {
  if [[ -n "${SUDO_USER:-}" && "$(id -u)" -eq 0 ]]; then
    sudo -u "$SUDO_USER" "$@"
  else
    "$@"
  fi
}

run_adb() {
  run_as_invoker "$ADB_BIN" "$@"
}

# Wait until BlueStacks ADB is online and Android finished booting; prints serial on stdout.
wait_for_adb_boot() {
  local target_serial="$1"
  local timeout_sec="$2"
  local elapsed=0
  local serial=""
  local boot_done=""

  log_info "Waiting for BlueStacks ADB on $target_serial (timeout: ${timeout_sec}s)..." >&2
  while [[ $elapsed -lt $timeout_sec ]]; do
    run_adb connect "$target_serial" >/dev/null 2>&1 || true

    if run_adb -s "$target_serial" get-state 2>/dev/null | grep -qx "device"; then
      serial="$target_serial"
      break
    fi

    local fallback_serial
    fallback_serial="$(run_adb devices 2>/dev/null | awk 'NR>1 && $2=="device" {print $1; exit}')"
    if [[ -n "$fallback_serial" ]]; then
      serial="$fallback_serial"
      break
    fi

    sleep 2
    elapsed=$((elapsed + 2))
  done

  if [[ -z "$serial" ]]; then
    log_err "Timed out waiting for ADB connection. Ensure ADB is enabled in BlueStacks Air Settings > Advanced."
    return 1
  fi

  log_info "Connected to $serial. Waiting for Android boot completion..." >&2
  while [[ $elapsed -lt $timeout_sec ]]; do
    boot_done="$(run_adb -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r\n' || true)"
    if [[ "$boot_done" == "1" ]]; then
      printf '%s\n' "$serial"
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done

  log_err "Android did not finish booting within ${timeout_sec}s."
  return 1
}

verify_root_su() {
  local serial="$1"
  local su_out
  log_info "Verifying root access (if a Superuser prompt appears in BlueStacks Air, tap Grant)..."
  su_out="$(run_adb -s "$serial" shell "su -c id" 2>/dev/null | tr -d '\r\n' || true)"
  if [[ "$su_out" != *"uid=0(root)"* ]]; then
    log_warn "su did not return uid=0(root) (output: '$su_out')."
    log_warn "Ensure Root access is enabled and granted for Shell in Kitsune Mask, then re-run: bash \"$0\" -a \"$APK_PATH\""
    return 1
  fi
  log_info "Root verified: $su_out"
}

seed_magisk_env_if_needed() {
  local serial="$1"
  local unzip_dir="$WORK_DIR/apk"
  local seed_dir="$WORK_DIR/seed"
  mkdir -p "$unzip_dir" "$seed_dir"
  unzip -oq "$APK_PATH" -d "$unzip_dir"

  local expected_ver remote_ver
  expected_ver="$(grep -E '^MAGISK_VER=' "$unzip_dir/assets/util_functions.sh" | head -n 1 || true)"
  remote_ver="$(run_adb -s "$serial" shell "su -c 'grep -E \"^MAGISK_VER=\" /data/adb/magisk/util_functions.sh 2>/dev/null'" 2>/dev/null | tr -d '\r\n' || true)"

  if [[ -n "$expected_ver" && "$remote_ver" == "$expected_ver" ]]; then
    log_info "/data/adb/magisk already seeded ($remote_ver)."
    return 0
  fi

  local abi
  abi="$(run_adb -s "$serial" shell getprop ro.product.cpu.abi 2>/dev/null | tr -d '\r\n')"
  [[ -z "$abi" ]] && abi="arm64-v8a"

  local bin_name src
  for bin_name in busybox magiskboot magiskinit magiskpolicy magisk64; do
    src="$unzip_dir/lib/$abi/lib${bin_name}.so"
    if [[ -f "$src" ]]; then
      cp "$src" "$seed_dir/$bin_name"
    fi
  done
  if [[ -f "$unzip_dir/lib/armeabi-v7a/libmagisk32.so" ]]; then
    cp "$unzip_dir/lib/armeabi-v7a/libmagisk32.so" "$seed_dir/magisk32"
  fi
  cp "$unzip_dir/assets/"*.sh "$seed_dir/"
  cp "$unzip_dir/assets/stub.apk" "$seed_dir/stub.apk"

  local remote_tmp="/data/local/tmp/magisk_seed"
  log_info "Populating /data/adb/magisk via ADB..."
  run_adb -s "$serial" shell "rm -rf $remote_tmp && mkdir -p $remote_tmp"
  run_adb -s "$serial" push "$seed_dir/." "$remote_tmp/" >/dev/null
  run_adb -s "$serial" shell "su -c '
    mkdir -p /data/adb/magisk /data/adb/modules /data/adb/post-fs-data.d /data/adb/service.d &&
    chmod 700 /data/adb &&
    rm -rf /data/adb/magisk/* &&
    cp -af $remote_tmp/* /data/adb/magisk/ &&
    chmod 755 /data/adb/magisk/* &&
    chown -R 0:0 /data/adb/magisk &&
    rm -rf $remote_tmp
  '"
}

install_chrome_appzygote_fix() {
  local serial="$1"
  local helper="$BASE_DIR/lib/bluestacks-chrome-fix.py"
  if [[ ! -f "$helper" ]] || ! command -v python3 >/dev/null 2>&1; then
    log_warn "python3 or $helper missing; skipping Chrome AppZygote fix."
    return 0
  fi

  local state
  state="$(run_adb -s "$serial" shell "su -c '
    rt=\$(sha256sum /system/lib64/libandroid_runtime.so 2>/dev/null | cut -d\" \" -f1)
    bd=\$(sha256sum /system/lib64/libbinder.so 2>/dev/null | cut -d\" \" -f1)
    if [ -d /data/adb/modules/bsair_appzygote_fix ] && [ ! -f /data/adb/modules/bsair_appzygote_fix/disable ] && [ ! -f /data/adb/modules/bsair_appzygote_fix/remove ]; then
      mod_ok=1
    else
      mod_ok=0
    fi
    echo \"\${rt}|\${bd}|\${mod_ok}\"
  '" 2>/dev/null | tr -d '\r\n' || true)"

  local live_rt="${state%%|*}"
  local rest="${state#*|}"
  local live_bd="${rest%%|*}"
  local mod_ok="${rest#*|}"

  if [[ "$live_rt" == "$RUNTIME_PATCHED_SHA" && "$live_bd" == "$BINDER_PATCHED_SHA" && "$mod_ok" == "1" ]]; then
    log_info "Chrome AppZygote fix (bsair_appzygote_fix) already active."
    return 0
  fi

  if [[ "$live_rt" != "$RUNTIME_ORIG_SHA" || "$live_bd" != "$BINDER_ORIG_SHA" ]]; then
    if [[ "$live_rt" == "$RUNTIME_PATCHED_SHA" && "$live_bd" == "$BINDER_PATCHED_SHA" ]]; then
      log_warn "Patched Chrome libraries active, refreshing module flags."
      run_adb -s "$serial" shell "su -c 'rm -f /data/adb/modules/bsair_appzygote_fix/disable /data/adb/modules/bsair_appzygote_fix/remove'"
      NEEDS_REBOOT=1
      return 0
    fi
    log_warn "BlueStacks ROM library hashes differ from supported 5.21.790.7505 build; skipping Chrome AppZygote fix."
    return 0
  fi

  local cdir="$WORK_DIR/chrome_fix"
  mkdir -p "$cdir"
  log_info "Building Chrome/AppZygote fix Magisk module (bsair_appzygote_fix)..."
  run_adb -s "$serial" pull /system/lib64/libandroid_runtime.so "$cdir/libandroid_runtime.so" >/dev/null
  run_adb -s "$serial" pull /system/lib64/libbinder.so "$cdir/libbinder.so" >/dev/null

  local rc=0
  python3 "$helper" patch-libs \
    --runtime-in "$cdir/libandroid_runtime.so" \
    --runtime-out "$cdir/libandroid_runtime.patched.so" \
    --binder-in "$cdir/libbinder.so" \
    --binder-out "$cdir/libbinder.patched.so" || rc=$?

  if [[ $rc -ne 0 ]]; then
    log_warn "Chrome library patcher exited with code $rc; skipping bsair_appzygote_fix."
    return 0
  fi

  run_adb -s "$serial" shell "rm -rf /data/local/tmp/bsair_fix && mkdir -p /data/local/tmp/bsair_fix"
  cat > "$cdir/module.prop" <<EOF
id=bsair_appzygote_fix
name=BlueStacks Air AppZygote Chrome Fix
version=v1.0
versionCode=1
author=bluestack-air-root
description=Skips BstFilterAppsManager Binder IPC when SpecializeCommon or libnativeloader runs inside AppZygotes and isolated processes.
EOF
  cat > "$cdir/post-fs-data.sh" <<EOF
#!/system/bin/sh
MODDIR=\${0%/*}
check_lib() {
    cur=\$(sha256sum "\$1" 2>/dev/null | cut -d" " -f1)
    if [ -n "\$cur" ] && [ "\$cur" != "\$2" ] && [ "\$cur" != "\$3" ]; then
        touch "\$MODDIR/disable"
    fi
}
check_lib /system/lib64/libandroid_runtime.so $RUNTIME_ORIG_SHA $RUNTIME_PATCHED_SHA
check_lib /system/lib64/libbinder.so $BINDER_ORIG_SHA $BINDER_PATCHED_SHA
EOF

  run_adb -s "$serial" push "$cdir/libandroid_runtime.patched.so" /data/local/tmp/bsair_fix/libandroid_runtime.so >/dev/null
  run_adb -s "$serial" push "$cdir/libbinder.patched.so" /data/local/tmp/bsair_fix/libbinder.so >/dev/null
  run_adb -s "$serial" push "$cdir/module.prop" /data/local/tmp/bsair_fix/module.prop >/dev/null
  run_adb -s "$serial" push "$cdir/post-fs-data.sh" /data/local/tmp/bsair_fix/post-fs-data.sh >/dev/null

  run_adb -s "$serial" shell "su -c '
    MOD=/data/adb/modules/bsair_appzygote_fix
    mkdir -p \$MOD/system/lib64
    cp /data/local/tmp/bsair_fix/libandroid_runtime.so \$MOD/system/lib64/libandroid_runtime.so
    cp /data/local/tmp/bsair_fix/libbinder.so \$MOD/system/lib64/libbinder.so
    cp /data/local/tmp/bsair_fix/module.prop \$MOD/module.prop
    cp /data/local/tmp/bsair_fix/post-fs-data.sh \$MOD/post-fs-data.sh
    chmod 0644 \$MOD/module.prop
    chmod 0755 \$MOD/system/lib64/libandroid_runtime.so \$MOD/system/lib64/libbinder.so \$MOD/post-fs-data.sh
    chown -R 0:0 \$MOD
    rm -rf /data/local/tmp/bsair_fix \$MOD/disable \$MOD/remove
  '"
  log_info "Staged Magisk module bsair_appzygote_fix."
  NEEDS_REBOOT=1
}

unblacklist_chrome_updates() {
  local serial="$1"
  local helper="$BASE_DIR/lib/bluestacks-chrome-fix.py"
  if [[ ! -f "$helper" ]] || ! command -v python3 >/dev/null 2>&1; then
    return 0
  fi

  local src_path
  src_path="$(run_adb -s "$serial" shell "su -c '
    if [ -f /data/downloads/.config_user.db ]; then
      echo /data/downloads/.config_user.db
    elif [ -f /data/downloads/.config.db ]; then
      echo /data/downloads/.config.db
    fi
  '" 2>/dev/null | tr -d '\r\n' || true)"

  if [[ -z "$src_path" ]]; then
    log_info "BlueStacks Play Store config (.config.db) not present yet; skipping Chrome unblacklist."
    return 0
  fi

  local cfg_dir="$WORK_DIR/cfg"
  mkdir -p "$cfg_dir"
  run_adb -s "$serial" shell "su -c 'cp \"$src_path\" /data/local/tmp/bs_cfg.db && chmod 644 /data/local/tmp/bs_cfg.db'"
  run_adb -s "$serial" pull /data/local/tmp/bs_cfg.db "$cfg_dir/in.db" >/dev/null
  run_adb -s "$serial" shell "rm -f /data/local/tmp/bs_cfg.db"

  local rc=0
  python3 "$helper" unblacklist-chrome --in "$cfg_dir/in.db" --out "$cfg_dir/out.db" || rc=$?
  if [[ $rc -eq 2 ]]; then
    log_info "Play Store Chrome update rule already unblacklisted."
    return 0
  elif [[ $rc -ne 0 ]]; then
    log_warn "Unable to update .config.db (exit $rc); skipping Chrome unblacklist."
    return 0
  fi

  run_adb -s "$serial" push "$cfg_dir/out.db" /data/local/tmp/bs_cfg_out.db >/dev/null
  run_adb -s "$serial" shell "su -c '
    cp /data/local/tmp/bs_cfg_out.db /data/downloads/.config_user.db &&
    chown system:system /data/downloads/.config_user.db &&
    chmod 0644 /data/downloads/.config_user.db &&
    rm -f /data/local/tmp/bs_cfg_out.db
  '"
  log_info "Unblacklisted Google Chrome updates in /data/downloads/.config_user.db."
  NEEDS_REBOOT=1
}

resolve_rezygisk_zip() {
  if [[ -n "$REZYGISK_ZIP" ]]; then
    printf '%s\n' "$REZYGISK_ZIP"
    return 0
  fi

  local invoker_home=""
  if [[ -n "${SUDO_USER:-}" && "$(id -u)" -eq 0 && "$SUDO_USER" =~ ^[A-Za-z0-9._-]+$ ]]; then
    invoker_home="$(eval printf '%s' "~$SUDO_USER" 2>/dev/null || true)"
  else
    invoker_home="${HOME:-}"
  fi

  local candidate
  for candidate in \
    "$PWD/rezygisk.zip" \
    "$BASE_DIR/rezygisk.zip" \
    "$BASE_DIR/files/cache/rezygisk.zip" \
    "$BASE_DIR"/ReZygisk-*.zip \
    ${invoker_home:+"$invoker_home"/Downloads/ReZygisk-*.zip}; do
    if [[ -f "$candidate" ]] && unzip -tq "$candidate" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  if ! command -v curl >/dev/null 2>&1; then
    log_warn "curl not found and no local ReZygisk zip available; skipping ReZygisk auto-install."
    return 1
  fi

  local cache_dir="$BASE_DIR/files/cache"
  local dst_zip="$WORK_DIR/rezygisk.zip"
  if mkdir -p "$cache_dir" >/dev/null 2>&1 && [[ -w "$cache_dir" ]]; then
    if [[ -n "${SUDO_USER:-}" && "$(id -u)" -eq 0 ]]; then
      chown "$SUDO_USER" "$BASE_DIR/files" "$cache_dir" >/dev/null 2>&1 || true
    fi
    dst_zip="$cache_dir/rezygisk.zip"
  fi

  local tmp_dl="${dst_zip}.part.$$"
  log_info "Downloading ReZygisk v1.0.0 release..." >&2
  if ! run_as_invoker curl -fsSL -o "$tmp_dl" "$REZYGISK_DEFAULT_URL"; then
    rm -f "$tmp_dl"
    log_warn "Failed to download ReZygisk from $REZYGISK_DEFAULT_URL (offline?). Pass -z <rezygisk.zip> or -Z to skip."
    return 1
  fi
  if ! unzip -tq "$tmp_dl" >/dev/null 2>&1; then
    rm -f "$tmp_dl"
    log_warn "Downloaded ReZygisk archive failed zip verification; skipping."
    return 1
  fi
  mv -f "$tmp_dl" "$dst_zip"
  printf '%s\n' "$dst_zip"
}

install_rezygisk_if_needed() {
  local serial="$1"
  local existing
  existing="$(run_adb -s "$serial" shell "su -c '
    for d in /data/adb/modules/rezygisk /data/adb/modules/zygisksu /data/adb/modules/neozygisk /data/adb/modules_update/rezygisk; do
      if [ -d \"\$d\" ] && [ ! -f \"\$d/remove\" ]; then
        echo \"\$d\"
        break
      fi
    done
  '" 2>/dev/null | tr -d '\r\n' || true)"

  if [[ -n "$existing" ]]; then
    log_info "External Zygisk already present: $existing"
    return 0
  fi

  local zip_path
  if ! zip_path="$(resolve_rezygisk_zip)"; then
    return 0
  fi

  log_info "Installing ReZygisk module from $zip_path..."
  run_adb -s "$serial" push "$zip_path" /data/local/tmp/rezygisk.zip >/dev/null
  if ! run_adb -s "$serial" shell "su -c 'magisk --install-module /data/local/tmp/rezygisk.zip && rm -f /data/local/tmp/rezygisk.zip'"; then
    run_adb -s "$serial" shell "rm -f /data/local/tmp/rezygisk.zip" >/dev/null 2>&1 || true
    log_warn "magisk --install-module failed for ReZygisk; skipping."
    return 0
  fi
  log_info "Staged ReZygisk module."
  NEEDS_REBOOT=1
}

if [[ -z "$ADB_PORT" ]]; then
  ADB_PORT="$(detect_bluestacks_adb_port)"
fi

TARGET_SERIAL="127.0.0.1:${ADB_PORT}"
log_info "Using adb: $ADB_BIN"
connected_serial="$(wait_for_adb_boot "$TARGET_SERIAL" "$TIMEOUT_SEC")"

log_info "Installing $APK_PATH..."
if ! INSTALL_ERR="$(run_adb -s "$connected_serial" install -r -g "$APK_PATH" 2>&1)"; then
  if printf '%s' "$INSTALL_ERR" | grep -q "INSTALL_FAILED_UPDATE_INCOMPATIBLE"; then
    log_err "Existing Kitsune Mask APK has a different signature."
    log_err "Uninstall the existing Kitsune Mask app in BlueStacks Air and re-run: bash \"$0\" -a \"$APK_PATH\""
  else
    log_err "APK installation failed: $INSTALL_ERR"
  fi
  exit 1
fi

verify_root_su "$connected_serial"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bs-air-adb.XXXXXX")"
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

seed_magisk_env_if_needed "$connected_serial"

NEEDS_REBOOT=0
if [[ $SKIP_CHROME_FIX -eq 0 ]]; then
  install_chrome_appzygote_fix "$connected_serial"
  unblacklist_chrome_updates "$connected_serial"
fi

if [[ $SKIP_ZYGISK -eq 0 ]]; then
  install_rezygisk_if_needed "$connected_serial"
fi

if [[ $NEEDS_REBOOT -eq 1 ]]; then
  if [[ $AUTO_REBOOT -eq 1 && -d "$BLUESTACKS" ]]; then
    log_info "Restarting BlueStacks Air once to activate staged modules (ReZygisk / Chrome fix)..."
    quit_bluestacks "$BLUESTACKS"
    sleep 1
    run_as_invoker open -n "$BLUESTACKS"
    connected_serial="$(wait_for_adb_boot "$TARGET_SERIAL" "$TIMEOUT_SEC")"
    verify_root_su "$connected_serial"
  else
    log_warn "Staged changes require restarting BlueStacks Air to take effect."
  fi
fi

MAGISK_VER="$(run_adb -s "$connected_serial" shell "su -c 'magisk -v'" 2>/dev/null | tr -d '\r\n' || true)"
ZYGISK_PROC="$(run_adb -s "$connected_serial" shell "su -c 'ps -A | awk \"\\\$NF == \\\"zygiskd64\\\" {print \\\$NF; exit}\"'" 2>/dev/null | tr -d '\r\n' || true)"
CFG_PROP="$(run_adb -s "$connected_serial" shell getprop bst.config.config_file 2>/dev/null | tr -d '\r\n' || true)"

log_info "Magisk daemon active: ${MAGISK_VER:-unknown}"
if [[ -n "$ZYGISK_PROC" ]]; then
  log_info "External Zygisk active: $ZYGISK_PROC"
elif [[ $SKIP_ZYGISK -eq 0 ]]; then
  log_warn "External Zygisk daemon not detected yet (if just installed with -R, restart BlueStacks Air)."
fi
if [[ -n "$CFG_PROP" ]]; then
  log_info "BlueStacks config file: $CFG_PROP"
fi
log_info "ADB setup complete! Ready to use."

# Root BlueStacks Air macOS

Dynamic, 1-step Magisk rooting toolkit for **BlueStacks Air** on macOS (Apple Silicon), bundled with a custom-built **KitsuneMagisk** (`31.0-kitsune`).

![Screenshot](/images/bluestacks-air-root-magisk.png)

## Requirements

- [BlueStacks Air](https://www.bluestacks.com/mac) (started at least once before rooting)
- `magisk.apk` inside this folder (already built from `KitsuneMagisk`, or pass `-a /path/to/magisk.apk`)

## Rooting (1-Step)

1. Install BlueStacks Air, launch it once (optionally enable **ADB** in *Settings → Advanced*), then quit BlueStacks Air.
2. Open Terminal in this folder:

```bash
cd /Users/aldrnmrsd/Documents/Coding/bluestack-air-root/root-bluestacks-air
```

### Method 1: In-Place 1-Step (Recommended)

```bash
sudo bash root.sh
```

What this single command does:
1. Gracefully closes BlueStacks Air and backs up the stock `initrd_hvf.img` (auto-rotating backups when BlueStacks updates).
2. Patches `initrd_hvf.img` dynamically with Magisk binaries and `/boot/magisk/env` so `/data/adb/magisk` is auto-seeded on first boot (no *Requires Additional Setup* reboot hang).
3. Launches BlueStacks Air and—if ADB is enabled—runs `adb-setup.sh` to:
   - Install `magisk.apk` and verify `su`.
   - Install **ReZygisk** automatically (from local zip/cache or GitHub `v1.0.0` release) if no external Zygisk module is installed yet.
   - Install the systemless `bsair_appzygote_fix` Magisk module and unblacklist Chrome Play Store updates (`/data/downloads/.config_user.db`) when running on the supported BlueStacks Air `5.21.790.7505` ROM libraries so Google Chrome / AppZygotes work properly.
   - Restart BlueStacks Air once automatically if new modules/config were staged, then re-verify root and Zygisk.

*(Pass `-n` to `root.sh` if you want to skip the automatic ADB setup step, or run `bash adb-setup.sh -h` for granular flags `-z`, `-Z`, `-C`, `-R`.)*

### Method 2: SIP Enabled (Manual Copy Mode)

If macOS blocks writing directly to `/Applications/BlueStacks.app`:

```bash
bash root.sh -o files/initrd_hvf.img -b files/backup
```

- Copy `files/initrd_hvf.img` to `/Applications/BlueStacks.app/Contents/img/initrd_hvf.img`.
- Start BlueStacks Air.
- Install `magisk.apk` inside BlueStacks Air (or run `bash adb-setup.sh` with ADB enabled).

### Zygisk Support

KitsuneMagisk `31.0-kitsune` uses external Zygisk implementations instead of the deprecated legacy Zygisk. Install **ReZygisk** or **ZygiskNext** as a Magisk module—this fork ensures modules containing `zygisk/` are loaded whenever an external Zygisk provider is active.

## Unrooting

- **Method 1 (In-Place):** `sudo bash unroot.sh`
- **Method 2 (SIP Enabled):** Copy `files/backup/initrd_hvf.img` back to `/Applications/BlueStacks.app/Contents/img/initrd_hvf.img`.

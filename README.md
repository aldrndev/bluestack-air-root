# bluestack-air-root

Toolkit 1-command untuk me-root **BlueStacks Air** di Apple Silicon macOS menggunakan **KitsuneMagisk** (`31.0-kitsune`), lengkap dengan **ReZygisk** dan perbaikan **Chrome AppZygote** (`bsair_appzygote_fix`) agar Chrome versi modern (termasuk Chrome 157+) berjalan normal di dalam VM yang di-root.

File [`root-bluestacks-air/magisk.apk`](root-bluestacks-air/magisk.apk) sudah dikompilasi dan disertakan di repositori ini, sehingga kamu tidak perlu mengompilasi `KitsuneMagisk` dari source code sebelum melakukan root.

---

## Prasyarat

- **macOS (Apple Silicon)** dengan **BlueStacks Air** terpasang di `/Applications/BlueStacks.app` dan sudah pernah dijalankan minimal 1 kali (agar konfigurasi VM & ADB port dibuat).
- **Akses `sudo`** di macOS (untuk menimpa `initrd_hvf.img` di `/Applications/BlueStacks.app/Contents/img/initrd_hvf.img`, kecuali memakai mode SIP-safe `-o`).
- **Koneksi internet saat pertama kali menjalankan `adb-setup.sh`** (untuk mengunduh `ReZygisk-v1.0.0-release.zip` dari GitHub jika belum tersedia secara lokal, atau gunakan flag `-z <path-to-zip>`).
- **Perkakas macOS**: `bash`, `python3`, `unzip`, `cpio`, `gzip`, `curl`, `shasum`, serta `hd-adb` (bawaan BlueStacks Air) atau Android Platform Tools `adb` (untuk menonaktifkan ReZygisk gunakan `-Z`).

---

## Cara Pakai (1-Command Quick Start)

Clone repositori, masuk ke folder installer, lalu jalankan `root.sh`:

```bash
git clone https://github.com/aldrndev/bluestack-air-root.git
cd bluestack-air-root/root-bluestacks-air
sudo bash root.sh
```

> [!IMPORTANT]
> Saat muncul prompt **Superuser** di layar BlueStacks Air pada booting pertama, tekan **Grant / Izinkan** untuk **Shell** (`com.android.shell`), karena [`adb-setup.sh`](root-bluestacks-air/adb-setup.sh) memerlukan akses `su` untuk memasang modul dan menambal konfigurasi.

### Apa yang Otomatis Dikerjakan `sudo bash root.sh`?

1. Memvalidasi dan mengekstrak `magisk64`, `magisk32` (jika ada), `magiskinit`, `magiskpolicy`, `busybox`, `magiskboot`, `stub.apk`, serta skrip `.sh` dari [`root-bluestacks-air/magisk.apk`](root-bluestacks-air/magisk.apk).
2. Membackup `initrd_hvf.img` asli secara otomatis ke `initrd_hvf.img.bak` (beserta metadata `.meta`), lalu menyisipkan init Magisk ke `initrd_hvf.img`.
3. Menjalankan BlueStacks Air, menghubungkan ADB secara otomatis (membaca port dari `bluestacks.conf` atau default `5555`), lalu menjalankan [`root-bluestacks-air/adb-setup.sh`](root-bluestacks-air/adb-setup.sh):
   - Memasang aplikasi **Kitsune Mask** (`magisk.apk`) dan menginisialisasi `/data/adb/magisk`.
   - Mengunduh (atau memakai cache lokal) dan memasang modul **ReZygisk** (`v1.0.0`).
   - Memasang modul Magisk **`bsair_appzygote_fix`** untuk menambal `/system/lib64/libandroid_runtime.so` dan `/system/lib64/libbinder.so` pada BlueStacks Air `5.21.790.7505` agar `com.android.chrome_zygote` dan renderer sandbox tidak crash saat membuka `/dev/binder`.
   - Menghapus `com.android.chrome` dari blacklist update Play Store di `/data/downloads/.config.db` (atau `.config_user.db`) jika file tersebut ada.
   - Me-restart BlueStacks Air **1 kali** jika ada modul baru yang di-stage, lalu memverifikasi `su -c id`, status modul, dan daemon `zygiskd64`.

---

## Opsi Skrip & Mode Lain

### 1. Hanya Menjalankan Setup ADB / ReZygisk / Chrome Fix (VM Sudah Root)

Jika `initrd_hvf.img` sudah terpasang Magisk dan kamu hanya ingin memasang ulang APK, ReZygisk, atau perbaikan Chrome:

```bash
bash root-bluestacks-air/adb-setup.sh
```

Opsi berguna pada [`adb-setup.sh`](root-bluestacks-air/adb-setup.sh):
- `-a <magisk.apk>`: gunakan file Kitsune Mask APK custom.
- `-P <port>`: tentukan port TCP ADB secara manual (default auto-detect dari `bluestacks.conf` atau `5555`).
- `-z <rezygisk.zip>`: gunakan file zip ReZygisk lokal (tanpa mengunduh dari GitHub).
- `-Z`: lewati pemasangan ReZygisk.
- `-C`: lewati pemasangan `bsair_appzygote_fix` dan unblacklist Chrome di Play Store.
- `-R`: jangan restart BlueStacks Air otomatis setelah modul di-stage.
- `-t <detik>`: batas waktu tunggu booting ADB (default `90`).

### 2. Mode SIP-Safe (Tanpa Mengubah `/Applications/BlueStacks.app` Langsung)

Jika System Integrity Protection (SIP) atau kebijakan sistem memblokir penulisan ke dalam `/Applications/BlueStacks.app`:

```bash
cd root-bluestacks-air
bash root.sh -o ./build/initrd_hvf.img -b ./backup
```

Salin `./build/initrd_hvf.img` secara manual ke `/Applications/BlueStacks.app/Contents/img/initrd_hvf.img` setelah menutup BlueStacks Air, lalu jalankan `bash adb-setup.sh`.

Opsi lengkap [`root.sh`](root-bluestacks-air/root.sh): `-a <magisk.apk>`, `-p <BlueStacks.app>`, `-s <initrd_img>`, `-o <output_img>`, `-b <backup_dir>`, `-n` (lewati `adb-setup.sh`), `-y` (tanpa konfirmasi), `-h`.

### 3. Mengembalikan Root (Unroot)

Mengembalikan `initrd_hvf.img` dari backup `.bak`:

```bash
cd root-bluestacks-air
sudo bash unroot.sh
```

Jika backup disimpan di folder custom dengan `-b` saat rooting:

```bash
sudo bash unroot.sh -b ./backup
```

---

## Struktur Repositori

- [`root-bluestacks-air/`](root-bluestacks-air/) — skrip installer root/unroot, automasi ADB, helper patcher Chrome AppZygote, tes regresi, dan APK siap pakai:
  - [`root.sh`](root-bluestacks-air/root.sh) — penambal `initrd_hvf.img` + launcher automasi ADB.
  - [`adb-setup.sh`](root-bluestacks-air/adb-setup.sh) — instalasi Kitsune Mask, ReZygisk, `bsair_appzygote_fix`, dan unblacklist Chrome.
  - [`unroot.sh`](root-bluestacks-air/unroot.sh) — pemulihan `initrd_hvf.img` ke kondisi sebelum root.
  - [`lib/common.sh`](root-bluestacks-air/lib/common.sh) — helper bash (deteksi versi, kontrol proses BlueStacks, ADB wrapper, `initrd` pack/unpack).
  - [`lib/bluestacks-chrome-fix.py`](root-bluestacks-air/lib/bluestacks-chrome-fix.py) — patcher biner `libandroid_runtime.so` / `libbinder.so` (`patch-libs`) dan pembersih blacklist `.config.db` (`unblacklist-chrome`).
  - [`magisk.apk`](root-bluestacks-air/magisk.apk) — APK **Kitsune Mask** (`31.0-kitsune`) siap pakai yang sudah mendukung deteksi status ReZygisk/ZygiskSU/NeoZygisk di [`Info.kt`](KitsuneMagisk/app/src/main/java/com/topjohnwu/magisk/core/Info.kt).
  - [`tests/test_scripts.sh`](root-bluestacks-air/tests/test_scripts.sh) — rangkaian tes regresi untuk skrip dan patcher.
  - [`README.md`](root-bluestacks-air/README.md) — dokumentasi teknis ringkas installer.
- [`KitsuneMagisk/`](KitsuneMagisk/) — source code Magisk (Kitsune fork) dengan penyesuaian deteksi status Zygisk eksternal ([`Info.kt`](KitsuneMagisk/app/src/main/java/com/topjohnwu/magisk/core/Info.kt)) serta dukungan 14 submodule eksternal pada [`.gitmodules`](.gitmodules).

---

## Opsional: Build Ulang `KitsuneMagisk` dari Source

Kamu tidak perlu langkah ini kecuali ingin memodifikasi source [`KitsuneMagisk/`](KitsuneMagisk/). Jika ingin mem-build ulang setelah clone:

```bash
git submodule update --init --recursive
cd KitsuneMagisk
# Konfigurasi config.prop / NDK sesuai build.py, lalu:
python3 build.py all
```

Untuk dokumentasi upstream KitsuneMagisk, lihat [`KitsuneMagisk/README.MD`](KitsuneMagisk/README.MD).

---

## Pengujian & Verifikasi

Untuk memverifikasi sintaks skrip shell, kompilasi Python helper, dan tes regresi lokal (menguji patching dummy APK/initrd, CLI help, dan helper Chrome fix):

```bash
bash root-bluestacks-air/tests/test_scripts.sh
```

---

## Troubleshooting

- **Chrome tetap crash setelah root**: Pastikan modul `bsair_appzygote_fix` aktif (tidak memiliki file `disable` di `/data/adb/modules/bsair_appzygote_fix`) dan versi BlueStacks Air sesuai dengan build `5.21.790.7505`. Skrip [`adb-setup.sh`](root-bluestacks-air/adb-setup.sh) otomatis melewati patching jika hash library sistem ROM berbeda agar tidak merusak library yang tidak cocok.
- **Prompt `su` tidak muncul atau ADB timeout**: Pastikan **Android Debug Bridge (ADB)** aktif di **Settings -> Preferences** BlueStacks Air, buka jendela BlueStacks Air agar dialog Superuser bisa diklik **Grant**, lalu jalankan ulang `bash root-bluestacks-air/adb-setup.sh`.
- **ReZygisk gagal diunduh saat setup**: Unduh manual `ReZygisk-v1.0.0-release.zip` lalu jalankan `bash root-bluestacks-air/adb-setup.sh -z /path/ke/ReZygisk-v1.0.0-release.zip`.

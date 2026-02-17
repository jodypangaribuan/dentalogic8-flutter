# Panduan Instalasi & Pemilihan APK

Panduan ini ditujukan untuk pengguna yang mengunduh aplikasi secara manual. Karena Android memiliki berbagai jenis perangkat keras, kami menyediakan beberapa versi aplikasi agar lebih hemat kuota dan memori.

## 1. Pilih Versi yang Mana? (Ringkasan Cepat)

| Nama File APK | Cocok Untuk Siapa? | Contoh HP |
| :--- | :--- | :--- |
| **`app-arm64-v8a-release.apk`** | **90% Pengguna Modern** | Samsung S/A series (2018+), Xiaomi Redmi Note 7+, Oppo Reno, Vivo V series, Pixel, dll. |
| **`app-armeabi-v7a-release.apk`** | **HP Model Lama / Hemat Daya** | Samsung J series, HP entry-level di bawah 1.5 juta, Tablet lama. |
| **`app-x86_64-release.apk`** | **Emulator / PC** | Hanya untuk penggunaan di Laptop/PC menggunakan Emulator (Bluestacks, Nox, dll). |

> **Saran:** Jika bingung, unduh **`app-arm64-v8a-release.apk`** terlebih dahulu. Jika gagal diinstal, baru coba **`app-armeabi-v7a-release.apk`**.

---

## 2. Cara Mengetahui Tipe HP Anda (Detail)

Jika Anda ingin memastikan versi yang tepat sebelum mengunduh:

### Metode A: Cek Tanpa Aplikasi Tambahan
1. Buka menu **Settings (Pengaturan)** di HP Anda.
2. Cari menu **About Phone (Tentang Ponsel)**.
3. Lihat bagian **Model Number (Nomor Model)** atau **Chipset/Processor**.
4. Cari nama chipset tersebut di Google (contoh: "Snapdragon 665 specs").
    - Jika tertulis **64-bit**, pilih **arm64-v8a**.
    - Jika tertulis **32-bit**, pilih **armeabi-v7a**.

### Metode B: Menggunakan Aplikasi "CPU-Z" (Paling Akurat)
1. Unduh aplikasi **CPU-Z** dari Google Play Store.
2. Buka aplikasi dan lihat tab **SOC** atau **SYSTEM**.
3. Perhatikan baris **Kernel Architecture** atau **Instruction Set**:
    - `aarch64` / `arm64` ➔ Unduh **arm64-v8a**
    - `armv7` / `armeabi` ➔ Unduh **armeabi-v7a**
    - `x86` / `x86_64` ➔ Unduh **x86_64**

---

## 3. Cara Instalasi (Langkah demi Langkah)

Karena aplikasi ini tidak diunduh dari Play Store, Anda perlu memberikan izin khusus.

1. **Unduh file APK** yang sesuai dengan panduan di atas.
2. Ketuk notifikasi **"Download Complete"** atau buka aplikasi **File Manager** -> folder **Downloads**.
3. Ketuk file APK tersebut.
4. Jika muncul peringatan **"Install blocked"** atau **"For your security..."**:
    - Ketuk **Settings (Setelan)**.
    - Cari opsi **"Allow from this source" (Izinkan dari sumber ini)** dan aktifkan.
    - Tekan tombol **Back (Kembali)**.
5. Ketuk **Install**.
6. Tunggu hingga proses selesai dan ketuk **Open**.

---

## 4. Pemecahan Masalah (Troubleshooting)

**Masalah: "App not installed" (Aplikasi tidak terpasang)**
- **Penyebab:** Kemungkinan besar Anda mengunduh versi arsitektur yang salah (misal: install arm64 di HP lawas).
- **Solusi:** Coba unduh versi **`app-armeabi-v7a-release.apk`**.

**Masalah: "Parse Error" / "There was a problem parsing the package"**
- **Penyebab:** File APK korup (belum selesai download) atau versi Android HP Anda terlalu lama (di bawah Android 7.0).
- **Solusi:** Hapus file APK, unduh ulang dengan koneksi stabil. Pastikan OS Android Anda minimal versi 7.0 (Nougat).

**Masalah: "Update" gagal (Tanda tangan berbeda)**
- **Penyebab:** Anda sudah memiliki aplikasi versi lama yang diinstal dari sumber berbeda (misal debug version dari developer).
- **Solusi:** Hapus (Uninstall) aplikasi versi lama terlebih dahulu, lalu instal APK yang baru ini.

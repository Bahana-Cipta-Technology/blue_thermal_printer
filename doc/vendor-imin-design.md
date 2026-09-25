# Rancangan vendor iMin (`PrinterBackendImin`)

Status: **diimplementasikan (fase 1 & 2), belum diverifikasi di hardware iMin** — lihat checklist §8. Hasil cetak `onPrintResult` masih dilaporkan `unknown` sampai checklist itu selesai. Diperbarui 25 Sep 2026 terhadap kode saat ini (ESC/POS, Sunmi, Xcheng + `PrinterBackendFallback`, `detectBuiltInPrinterVendor`), dokumen resmi iMin, dan library resmi iMin. Revisi ini menggantikan draf sebelumnya, yang ditulis sebelum Xcheng ada.

Tujuan: menambah printer bawaan iMin SDK 2.0 di belakang kontrak `PrinterBackend`, dengan pola yang sama seperti Sunmi/Xcheng, sehingga **app konsumen cukup menambah satu label UI dan tidak perlu mengedit file Gradle apa pun**.

## 1. Target & cakupan

| Generasi | Perangkat | Jalur di plugin |
|---|---|---|
| **iMin SDK 2.0** | D4 Pro, Swift 1 Pro, Swift 2 / 2 Pro / 2 Ultra, Swan 2, Falcon 2 | **Backend baru `PrinterBackendImin`** (dokumen ini) |
| iMin SDK 1.0 | D1, D1 Pro, D1w, D4, M2-202/203, M2 Pro, M2 Max, Swift 1, Falcon 1 | **Tanpa kode baru**: printer virtual Bluetooth "InnerPrinter" lewat `PrinterBackendEscpos` |

Jenis kertas:
- **80 mm** (576 px, dengan cutter): Falcon 1/2, D4 Pro, Swan 2. Printer ini juga bisa memakai kertas 58 mm.
- **58 mm** (384 px, tanpa cutter): perangkat lainnya.

Label printing (Swan 2 versi label) di luar cakupan.

## 2. Fakta terverifikasi

### 2.1 Dokumen resmi

Sumber: *iMin Integrated Printer Developer Documentation*, SDK 2.0, revisi V1.0.4 (2024-09-30).

| Method | Bagian | Catatan |
|---|---|---|
| `int initPrinter(String packageName, IPrinterCallback)` | §3.1.1 | Mengembalikan `fd`, yang dipakai oleh semua method `INeoPrinterService.*(int fd, …)` |
| `String getServiceVersion(fd)` | §3.2.5 | |
| `int getPrinterStatus(fd)` | §3.3 | Kode resmi hanya **-1** (belum tersambung ke servis), **0** normal, **3** cover terbuka, **4** head overheat, **7** kertas habis |
| `int getPrinterPaperType(fd)` | §3.4.8 | `80` / `58` |
| `printAndFeedPaper(fd, value)` | §3.8.2 | `0 < value < 1016`, contoh `70` |
| `partialCut(fd)` | §3.9.1 | |
| `printBitmap(fd, Bitmap, IPrinterCallback)` | ada | |
| `enterPrinterBuffer(fd, clean)`, `exitPrinterBuffer(fd, commit)`, `exitPrinterBufferWithCallback(fd, commit, cb)` | §3.18.1, §3.18.3, §3.18.4 | Menurut §3.18, bila printer bermasalah (kertas habis, overheat), transaksi **dibatalkan**, tidak ditahan |

Bind (§2.1.1.2, `NeoPrinterManager`):
- action `com.imin.printerservice.NeoPrinterService`
- komponen `com.imin.printerservice/com.imin.printerservice.core.ApiAdapterManager.NeoPrinterService`
- flag `BIND_AUTO_CREATE`

⚠ **Kontradiksi `onPrintResult` di dokumen resmi:**
- Pendahuluan §3.18 menyebut `0` = sukses dan `1` = gagal.
- Deskripsi per method, termasuk §3.18.4 `exitPrinterBufferWithCallback`, menyebut `code=1 success 0 failure`.

Lihat §4.3 untuk cara menanganinya.

### 2.2 Library `iminsoftware/IminPrinterLibrary`

- **Integrasi yang direkomendasikan dokumen:** `implementation 'com.github.iminsoftware:IminPrinterLibrary:<versi>'` lewat JitPack.
- **Isi:** hanya stub Java hasil generate AIDL (`INeoPrinterService`, `IPrinterCallback`, `INeoPrinterCallback`), utilitas `NeoPrinterManager`/`PrinterHelper`, dan beberapa enum.
- **Dependency transitif:** tidak ada. `minSdk 21`, `compileSdk 33`, `consumer-rules.pro` kosong.
- **Ketersediaan:** artefak `V2.0.0.19` (tag terbaru, April 2026) tersedia di JitPack.
- **Lisensi:** repo **tidak punya LICENSE**. Memakai binary resmi lewat JitPack mengikuti anjuran dokumen iMin. Menyalin source/stub-nya ke repo ini tidak.
- **Stabilitas ABI:** daftar `TRANSACTION_*` di V1.0.0.6 (114 method), V1.0.0.15 (157), dan V2.0.0.19 (167) punya **prefix identik**, karena iMin hanya menambah method di akhir. Akibatnya:
  - versi library yang dipatok tetap cocok dengan servis yang lebih baru;
  - app yang juga memakai library iMin (versi lain) aman, karena Gradle memilih versi tertinggi.

## 3. Akses SDK: JitPack, repo disuntik plugin

Gradle me-resolve dependency plugin sebagai dependency transitif **app**, memakai daftar repository milik app. Blok `repositories {}` di dalam `build.gradle` plugin hanya berlaku saat plugin di-build sendirian. Supaya app konsumen tidak perlu diedit, plugin menyuntikkan repo lewat blok `rootProject.allprojects` yang sudah ada di `android/build.gradle`:

```groovy
rootProject.allprojects {
    repositories {
        google()
        mavenCentral()
        // Hanya artefak iMin yang di-resolve dari JitPack.
        maven {
            url 'https://jitpack.io'
            content { includeGroup 'com.github.iminsoftware' }
        }
    }
}

dependencies {
    // Versi dipatok tepat -- jangan `latest`/`-SNAPSHOT`.
    implementation 'com.github.iminsoftware:IminPrinterLibrary:V2.0.0.19'
}
```

Konsekuensi bagi **semua** app konsumen:

| Aspek | Efek |
|---|---|
| Build | Butuh akses ke jitpack.io sampai cache Gradle terisi. Bila JitPack down atau build offline dengan cache kosong, build gagal. |
| `dependencyResolutionManagement` | App dengan `FAIL_ON_PROJECT_REPOS` akan error. App dengan `PREFER_SETTINGS` akan mengabaikan repo plugin. Keduanya harus menambah repo JitPack (plus `includeGroup`) sendiri. Template Flutter default tidak memakai ini. |
| Supply chain | `includeGroup` mencegah dependency lain ikut di-resolve dari JitPack. Versi dipatok. |
| Ukuran APK | Kecil. Stub tanpa dependency; R8 membuang yang tidak dipakai. |

Status app konsumen yang diketahui: `parkways_valet` sudah memuat `maven { url = uri("https://jitpack.io") }` (untuk SDK Onstreet) dan tidak memakai `dependencyResolutionManagement`.

## 4. Keputusan desain

### 4.1 Standalone, mengikuti pola Sunmi/Xcheng

`PrinterBackendImin` ditulis berdiri sendiri. Backend yang sudah produksi dan terverifikasi hardware (Sunmi, Xcheng) tidak disentuh. Ekstraksi base class bersama dijadwalkan di fase 3 (§9).

### 4.2 Status: hanya kode resmi

| Kode | Arti (dokumen) | `PrinterStatus` | Memblokir cetak? |
|---|---|---|---|
| -1 | Belum tersambung ke servis | — (tidak terhubung) | ya, `Err` "belum terhubung" |
| 0 | Normal | semua baik | tidak |
| 3 | Cover terbuka | `coverClosed: false` | ya |
| 4 | Head overheat | `hasError: true` | ya |
| 7 | Kertas habis | `hasPaper: false` | ya |
| lainnya | — | `unknown` (di-log native) | tidak |

Draf sebelumnya memetakan 1/99 ke `hasError` dan 8 ke `paperNearEnd`. Kode-kode itu **tidak ada di dokumen SDK 2.0**, jadi sekarang jatuh ke `unknown`. Ini sesuai prinsip repo: jangan memblokir cetak tanpa bukti masalah.

### 4.3 Hasil cetak `onPrintResult`

Karena dokumen resmi kontradiktif (§2.1), aturannya sebagai berikut:
- Konstanta `PRINT_RESULT_SUCCESS` ditaruh di satu tempat di `IminPrinterBridge`, dan setiap kode yang diterima di-log.
- **Sampai terverifikasi di hardware, kode apa pun diperlakukan sebagai `unknown`.** Post-check status yang menentukan hasil. Setelah terverifikasi, pemetaan `printed`/`failed` diaktifkan.
- `onRaiseException` → `failed`.
- Fallback disalin dari `SunmiPrinterBridge`: bila callback tidak datang dalam 12 dtk, commit polos (`exitPrinterBuffer(fd, true)`) dan kembalikan `unknown`, lalu berhenti menunggu callback di sisa sesi.

### 4.4 Lebar kertas dibaca di setiap cetak

`getPrinterPaperType` dibaca di pre-check **setiap** cetakan, bukan hanya saat `connect()`, karena printer 80 mm bisa sedang memakai gulungan 58 mm.

| `paperType` | Lebar raster | `partialCut` |
|---|---|---|
| `80` | 576 px | ya |
| `58`, lainnya, `null` | 384 px | tidak |

### 4.5 Urutan deteksi printer bawaan

`_builtInDetectionOrder` = `[innerXcheng, innerImin, innerSunmi]`.
- iMin dicek sebelum Sunmi sesuai prinsip "paling spesifik dulu", untuk berjaga-jaga bila servis iMin juga mengekspos AIDL Woyou (diverifikasi di hardware, §8).
- Paket Xcheng dan iMin berbeda, jadi urutan di antara keduanya tidak berpengaruh.
- Di perangkat tanpa servis iMin, `bind` langsung `false`, sehingga probe gagal cepat.

## 5. Struktur kode

```text
android/build.gradle                         # repo JitPack (includeGroup) + dependency iMin
android/src/main/AndroidManifest.xml         # <queries><package android:name="com.imin.printerservice"/>
android/src/main/java/id/kakzaki/blue_thermal_printer/vendor/imin/
  IminPrinterBridge.java                     # bind, initPrinter→fd, status, paperType, printTransaction
  IminPrinterChannel.java                    # MethodChannel "blue_thermal_printer/imin"
lib/src/printer_backend_imin.dart            # kIminBuiltInDevice, iminStatusToStatus(), IminPrintOutcome, PrinterBackendImin
lib/src/printer_vendor.dart                  # enum + case + urutan deteksi
lib/printer_backend.dart                     # export
test/printer_backend_imin_test.dart
```

`IminPrinterChannel` didaftarkan di `BlueThermalPrinterPlugin.onAttachedToEngine` (dan di-`dispose` di `onDetachedFromEngine`), di samping Sunmi/Xcheng, tanpa menyentuh logic ESC/POS. Manifest library iMin tidak mendeklarasikan `<queries>`, jadi plugin harus menambahkannya sendiri (visibility paket Android 11+).

### 5.1 Native `IminPrinterBridge`

- **Bind/unbind** dengan intent pada §2.1. `ServiceConnection` ditulis sendiri, bukan lewat `NeoPrinterManager`, supaya polanya sama dengan Sunmi (`onBindingDied` → unbind + bind ulang, `onNullBinding`).
- **`onServiceConnected`:**
  - `INeoPrinterService.Stub.asInterface(binder)`.
  - Di executor (bukan main thread), `initPrinter(context.getPackageName(), noopCallback)` → `volatile int fd`. Nilai `< 0` berarti gagal.
  - Log `getServiceVersion(fd)`.
- **`status()`:** `getPrinterStatus(fd)`, atau `-1` bila servis/`fd` belum ada atau terjadi `RemoteException`. Nilai `-1` bersamaan dengan kode resmi "belum tersambung", jadi polling `connect()` di Dart otomatis menunggu handshake.
- **`paperType()`:** `Integer` 58/80, atau `null`.
- **`printTransaction(png, feedDistance, cut, callback)`**, di executor tunggal:
  1. `enterPrinterBuffer(fd, true)`: buang sisa transaksi sebelumnya.
  2. `printBitmap(fd, bitmap, null)`
  3. `printAndFeedPaper(fd, feedDistance)` (default `70`)
  4. `partialCut(fd)` bila `cut`
  5. `exitPrinterBufferWithCallback(fd, true, cb)`, lalu tunggu di mailbox `ArrayBlockingQueue` (12 dtk)

  Hasilnya `"printed"` / `"failed"` / `"unknown"` sesuai §4.3.

### 5.2 Method channel `blue_thermal_printer/imin`

| Method | Argumen | Hasil |
|---|---|---|
| `bind` | – | `bool`: permintaan bind diterima sistem |
| `unbind` | – | `null` |
| `status` | – | `int`, `-1` = belum siap |
| `paperType` | – | `int?` |
| `printTransaction` | `bytes` (PNG), `feedDistance`, `cut` | `"printed"` / `"failed"` / `"unknown"` |

Hasil `printTransaction` di-post ke main thread lewat `Handler`, seperti `XchengPrinterChannel`.

### 5.3 Dart

```dart
const kIminBuiltInDevice = PrinterDevice(name: 'Printer Bawaan', macAddress: 'imin-builtin');

PrinterStatus iminStatusToStatus(int code) => switch (code) {
  0 => const PrinterStatus(hasPaper: true, coverClosed: true, hasError: false),
  3 => const PrinterStatus(coverClosed: false),
  4 => const PrinterStatus(hasError: true),
  7 => const PrinterStatus(hasPaper: false),
  _ => PrinterStatus.unknown,
};

class PrinterBackendImin implements PrinterBackend {
  PrinterBackendImin({
    ReceiptRenderer renderer = const ReceiptRenderer(),
    Future<bool> Function()? bind,
    Future<void> Function()? unbind,
    Future<int> Function()? status,
    Future<int?> Function()? paperType,
    Future<IminPrintOutcome> Function(List<int> png, int feedDistance, bool cut)? printTransaction,
    Duration connectPollInterval = const Duration(milliseconds: 200),
    Duration printTimeout = const Duration(seconds: 30),
    Duration stuckAfter = const Duration(seconds: 30),
  });
}
```

- `displayName` `'Printer Bawaan iMin'`; `requiresPairing` `false`; `openSystemSettings` no-op.
- `isAvailable` = `status() != -1`. `connect` = `bind`, lalu polling 15× sambil menunggu `fd`.
- `printReceipt` memakai `PrintJobGate`. Alur `_send` identik dengan `PrinterBackendSunmi`:
  1. Pre-check status + `paperType`.
  2. Render dengan `ReceiptRenderer(width: paperType == 80 ? 576 : 384, fontFamily: renderer.fontFamily)`.
  3. Transaksi.
  4. Outcome atau post-check.

  Pesan galat diambil dari `PrinterStatus.problemMessage`.

`lib/src/printer_vendor.dart`:
- `enum PrinterVendor { innerSunmi, bluetooth, innerXcheng, innerImin }`. Nilai baru ditambahkan di akhir; nilai tersimpan app berdasarkan `name`, jadi pilihan lama aman.
- `innerImin => PrinterBackendImin()`.
- `_builtInDetectionOrder` sesuai §4.5.

## 6. Dampak ke app konsumen

Switch exhaustive atas `PrinterVendor` memaksa satu label baru. Hanya itu yang berubah di `parkways_valet`:
- `lib/features/config/presentation/widgets/printer_connection_sheet.dart` (`_overrideLabel`): `PrinterVendor.innerImin => AppStrings.printerBackendOverrideInnerImin`.
- `lib/core/constants/app_strings.dart`: `printerBackendOverrideInnerImin = 'Printer Bawaan (iMin)'`.
- `test/features/config/printer_connection_sheet_test.dart`: case `innerImin`.

Yang **tidak** berubah:
- bootstrap/DI (`detectBuiltInPrinterVendor` sudah generik);
- repository override dan entity ObjectBox;
- file Gradle app (lihat §3 untuk pengecualian `dependencyResolutionManagement`).

Di luar cakupan: preview struk di app memakai `ReceiptRenderer()` 384 px, jadi di perangkat 80 mm preview lebih sempit dari hasil cetak.

## 7. Test

- `test/printer_backend_imin_test.dart`:
  - `runPrinterBackendContract('iMin', …)` dengan `supportsUnknownStatus: true`;
  - tabel `iminStatusToStatus` untuk semua kode di §4.2;
  - `IminPrintOutcome.parse`;
  - `connect` menunggu `fd` (status `-1, -1, 0`);
  - lebar renderer 58/80/`null`, dan `cut` hanya untuk 80 mm;
  - outcome `failed`/`unknown` → pesan diambil dari status.
- `test/default_channel_wiring_test.dart`, grup `iMin (blue_thermal_printer/imin)`: nama method/argumen, plus channel tanpa handler → tidak tersedia.
- `test/printer_vendor_test.dart`:
  - `innerImin` membangun `PrinterBackendImin`;
  - urutan probe `[innerXcheng, innerImin, innerSunmi]`;
  - "bukan Xcheng/iMin → Sunmi".

## 8. Checklist verifikasi hardware iMin

- [ ] Bind + `initPrinter` saat boot dingin: catat lama sampai `fd` tersedia, dan nilai `getServiceVersion`.
- [ ] Kode `getPrinterStatus` nyata untuk: normal, cover terbuka, kertas habis, dan overheat (bila bisa direproduksi). Catat juga kode di luar tabel resmi.
- [ ] **Kode `onPrintResult` untuk cetak sukses vs kertas habis di tengah cetak.** Hasilnya menjawab kontradiksi §2.1 dan mengaktifkan pemetaan printed/failed (§4.3).
- [ ] Data yang dikirim saat kertas habis: dibatalkan sesuai §3.18 dokumen resmi, atau menumpuk seperti di Xcheng?
- [ ] `getPrinterPaperType` di perangkat 58 dan 80 mm (termasuk printer 80 mm dengan kertas 58 mm): lebar pas, tidak terpotong.
- [ ] Feed 70 cukup untuk tear bar. `partialCut` jalan di 80 mm dan tidak dipanggil di 58 mm.
- [ ] Servis iMin mengekspos AIDL Woyou (`woyou.aidlservice.jiuiv5`) atau tidak (validasi §4.5).
- [ ] Perangkat SDK 1.0 (mis. D1/M2): cetak lewat Bluetooth "InnerPrinter" dengan backend ESC/POS, termasuk dukungan `DLE EOT`.
- [ ] Regresi: Xcheng O1 tetap terdeteksi `innerXcheng` dan mencetak normal.

## 9. Fase implementasi

1. **Plugin:**
   1. `build.gradle` (JitPack + dependency).
   2. Native bridge/channel + manifest.
   3. Dart backend + enum + deteksi.
   4. Test.

   `flutter analyze` dan `flutter test` harus bersih.
2. **App konsumen:**
   - Bump submodule, lalu label/strings/test.
   - `flutter analyze`, `flutter test`, dan `flutter build apk --debug`. Build ini sekaligus membuktikan resolusi JitPack dari plugin.
   - `./gradlew :app:dependencies --configuration debugRuntimeClasspath | grep iminsoftware` menampilkan artefak iMin.
3. **Opsional, improvement lintas vendor** (setelah iMin stabil, sebelum vendor ke-5):
   - Ekstrak `BuiltInPrinterBackend`, template untuk poll connect, `checkStatus`, dan `_send` (outcome → post-check).
   - Ekstrak `PrintOutcome` generik. `SunmiPrintOutcome`/`XchengPrintOutcome`/`IminPrintOutcome` menjadi `typedef` supaya API publik tetap kompatibel.
   - Suite kontrak menjaga regresi.

## 10. Referensi

- iMin Printer SDK 2.0 Developer Documentation: <https://imin-sg-resources.oss-ap-southeast-1.aliyuncs.com/docs/demo/iMinPrinterSDK2.0%20Developer%20Documentation.pdf>
- iMin docs (Printer): <https://oss-sg.imin.sg/docs/en/Printer.html>
- `iminsoftware/IminPrinterLibrary` (`NeoPrinterManager`, `PrinterHelper`, `INeoPrinterService`): <https://github.com/iminsoftware/IminPrinterLibrary>
- Plugin Flutter resmi `imin_printer` (BSD-3-Clause), rujukan perilaku saja: <https://pub.dev/packages/imin_printer>

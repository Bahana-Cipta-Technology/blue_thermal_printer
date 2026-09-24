# Rancangan vendor iMin (`PrinterBackendImin`) — fase 2

Status: **rancangan**. Implementasi dijadwalkan di fase 2, setelah perbaikan audit fase 1 (`doc/audit-2026-09.md`) masuk.

## 1. Target & cakupan

| Generasi | Perangkat (contoh) | Android | Jalur di plugin |
|---|---|---|---|
| **iMin SDK 2.0** | D4 Pro, Swift 1 Pro, Swift 2 / 2 Pro / 2 Ultra, Swan 2, Falcon 2 | 13+ | **Backend baru `PrinterBackendImin`** (dokumen ini) |
| iMin SDK 1.0 | D1, D1 Pro, D1w, D4, M2-202/203, M2 Pro, M2 Max, Swift 1, Falcon 1 | ≤ 11 | **Tanpa kode baru**: printer virtual Bluetooth "InnerPrinter" lewat `PrinterBackendEscpos` yang sudah ada |

Kertas: 58 mm (384 px, tanpa cutter; mayoritas handheld) dan 80 mm (576 px, dengan cutter; D4 Pro, Swan 2, Falcon 1/2). Resolusi 8 dot/mm.

SDK 1.0 berbasis jar proprietary (SPI/USB, adaptasi per model), jadi sengaja **di luar cakupan**. Printer virtual Bluetooth bawaan iMin menerima ESC/POS standar, dan itu sudah ditangani backend ESC/POS.

## 2. Antarmuka servis (SDK 2.0)

Hasil telaah `iminsoftware/IminPrinterLibrary` (tag terbaru `V2.0.0.19`, April 2026) dan *iMin Printer SDK 2.0 Developer Documentation*:

- Paket servis: `com.imin.printerservice`
- Bind: action `com.imin.printerservice.NeoPrinterService`, komponen `com.imin.printerservice/.core.ApiAdapterManager.NeoPrinterService`, `BIND_AUTO_CREATE`
- AIDL: `com.imin.printer.INeoPrinterService` + callback `com.imin.printer.IPrinterCallback` (`onRunResult`, `onReturnString`, `onRaiseException`, `onPrintResult`)
- **Handshake wajib:** setelah tersambung, `int fd = initPrinter(packageName, callback)`. Semua method berikutnya menerima `fd`.

Method yang dipakai backend:

| Kebutuhan | Method |
|---|---|
| Status | `int getPrinterStatus(fd)` |
| Lebar kertas | `int getPrinterPaperType(fd)` → `58` / `80` |
| Transaksi | `enterPrinterBuffer(fd, clean)`, `exitPrinterBufferWithCallback(fd, commit, cb)`, `exitPrinterBuffer(fd, commit)` |
| Cetak | `printBitmap(fd, bitmap, cb)` |
| Feed / potong | `printAndFeedPaper(fd, distance)`, `partialCut(fd)` |

## 3. Keputusan terbuka: cara mengakses SDK (diputuskan di awal fase 2)

| Opsi | Kelebihan | Kekurangan |
|---|---|---|
| **(a) Dependency Maven JitPack** `com.github.iminsoftware:IminPrinterLibrary:V2.0.0.19`, dibungkus di `vendor/imin/` — **rekomendasi** | Status legal jelas (binary resmi iMin). Stub AIDL dijamin cocok dengan servis. | Tiap app konsumen wajib menambah `maven { url 'https://jitpack.io' }`. Siklus rilis di tangan iMin. Menyimpang dari pola "tanpa dependency pihak ketiga" (tapi itu aturan untuk `pubspec.yaml`, bukan artefak native). |
| (b) Rekonstruksi `.aidl` sendiri di `src/main/aidl/com/imin/printer/` | Nol dependency, pola sama dengan Sunmi | Repo iMin **tidak punya LICENSE** (status hak cipta stub tidak jelas). Urutan method AIDL harus identik dengan servis, dan salah satu posisi saja berarti memanggil method yang salah secara diam-diam. |

Apa pun pilihannya, **API publik Dart dan struktur `vendor/imin/` tidak berubah**. Pilihan hanya memengaruhi `android/build.gradle` dan asal kelas `INeoPrinterService`.

## 4. Struktur kode

Mengikuti cetakan Sunmi (lihat bagian "Menambah vendor baru" di `CLAUDE.md`):

```
android/src/main/java/id/kakzaki/blue_thermal_printer/vendor/imin/
  IminPrinterBridge.java    # bind, initPrinter→fd, status, paperType, printTransaction
  IminPrinterChannel.java   # MethodChannel "blue_thermal_printer/imin"
android/src/main/AndroidManifest.xml
  <queries><package android:name="com.imin.printerservice"/></queries>
lib/src/printer_backend_imin.dart
  kIminBuiltInDevice, iminStatusToStatus(), IminPrintOutcome, PrinterBackendImin
lib/src/printer_vendor.dart
  enum PrinterVendor { innerSunmi, innerImin, bluetooth }
test/printer_backend_imin_test.dart
  runPrinterBackendContract('iMin', …) + tabel status + outcome + lebar kertas
```

`IminPrinterChannel` didaftarkan di `BlueThermalPrinterPlugin.onAttachedToEngine`, di samping `SunmiPrinterChannel`, tanpa menyentuh logic ESC/POS.

### Channel native

| Method | Argumen | Hasil |
|---|---|---|
| `bind` | – | `bool`: permintaan bind diterima |
| `unbind` | – | – |
| `status` | – | `int` kode `getPrinterStatus`, `-1` bila belum tersambung/`fd` belum ada |
| `paperType` | – | `int` 58/80, atau `null` |
| `printTransaction` | `bytes` (PNG), `feedDistance`, `cut` | `"printed"` / `"failed"` / `"unknown"` |

Bridge menjalankan `initPrinter` di `onServiceConnected` (di executor, bukan main thread) dan menyimpan `fd` sebagai `volatile`. `status` mengembalikan `-1` sampai `fd` tersedia, jadi polling `connect()` di Dart otomatis menunggu handshake selesai.

### Dart

```dart
const kIminBuiltInDevice = PrinterDevice(name: 'Printer Bawaan', macAddress: 'imin-builtin');

PrinterStatus iminStatusToStatus(int code) => switch (code) {
  0 => const PrinterStatus(hasPaper: true, coverClosed: true, hasError: false),
  3 => const PrinterStatus(coverClosed: false),
  7 => const PrinterStatus(hasPaper: false),
  4 || 1 || 99 => const PrinterStatus(hasError: true),
  // 8 = kertas hampir habis -> peringatan, tidak memblokir (butuh S8: PrinterStatus.paperNearEnd)
  _ => PrinterStatus.unknown,
};

class PrinterBackendImin implements PrinterBackend {
  PrinterBackendImin({
    Future<bool> Function()? bind,
    Future<void> Function()? unbind,
    Future<int> Function()? status,
    Future<int?> Function()? paperType,
    Future<IminPrintOutcome> Function(List<int> png, int feedDistance, bool cut)? printTransaction,
    Duration connectPollInterval, Duration printTimeout, Duration stuckAfter,
  });
  // displayName 'Printer Bawaan iMin', requiresPairing false,
  // isAvailable: status() != -1, PrintJobGate untuk printReceipt.
}
```

Pola `_send` identik dengan `PrinterBackendSunmi` (pre-check → render → transaksi → outcome/post-check). Bedanya: **renderer dipilih saat `connect()`**, `ReceiptRenderer(width: paperType == 80 ? 576 : 384)`, dan `cut = paperType == 80`.

## 5. Status: tabel `getPrinterStatus`

| Kode | Arti (dokumen iMin) | `PrinterStatus` | Memblokir cetak? |
|---|---|---|---|
| -1 | Servis belum tersambung | — (tidak terhubung) | ya, `Err` "belum terhubung" |
| 0 | Normal | semua baik | tidak |
| 1 | Printer tidak tersambung / mati (SDK 1.0) | `hasError` | ya |
| 3 | Cover terbuka | `coverClosed: false` | ya |
| 4 | Head overheat | `hasError` | ya |
| 7 | Kertas habis | `hasPaper: false` | ya |
| 8 | Kertas hampir habis (SDK 1.0) | `paperNearEnd` (S8) | **tidak**, hanya peringatan |
| 99 | Galat lain | `hasError` | ya |
| lainnya | — | `unknown` | tidak |

Kode 1/8/99 hanya terdokumentasi untuk SDK 1.0. Tetap dipetakan secara defensif, lalu diverifikasi di hardware.

## 6. Alur cetak (mode transaksi)

1. `connect()` sudah menyimpan `paperType`, jadi renderer sudah benar.
2. Pre-check `getPrinterStatus`. Bila ada masalah yang diketahui → `Err`, tanpa data terkirim.
3. Native `printTransaction`:
   1. `enterPrinterBuffer(fd, true)`: buang sisa transaksi sebelumnya.
   2. `printBitmap(fd, bitmap, null)`
   3. `printAndFeedPaper(fd, 70)` (+ `partialCut(fd)` bila 80 mm)
   4. `exitPrinterBufferWithCallback(fd, true, cb)` → tunggu `onPrintResult` (timeout ±12 dtk)
4. Outcome → `PrinterResult` sama persis dengan Sunmi:
   - `printed` → `Ok`
   - `failed` → `Err` (pesan dari status bila diketahui)
   - `unknown` → post-check status

⚠ **Kontradiksi dokumen iMin:** bagian "Transaction printing" menyebut `onPrintResult` **0 = sukses, 1 = gagal**, sedangkan dokumentasi per-method menyebut **1 = sukses, 0 = gagal**. Aturan implementasi:
- Taruh konstanta `IMIN_PRINT_RESULT_SUCCESS` di satu tempat di `IminPrinterBridge`, dan log setiap kode yang diterima.
- **Sampai terverifikasi di hardware, perlakukan kode apa pun sebagai `unknown`** (post-check status menentukan). Baru setelah terverifikasi, aktifkan pemetaan `printed`/`failed`.
- Terapkan fallback "callback tidak pernah datang → commit polos + `unknown`, lalu jangan menunggu lagi di sesi itu" yang sama dengan Sunmi.

## 7. Dampak ke app konsumen (`parkways_valet`), wajib dalam satu rangkaian perubahan

Menambah `PrinterVendor.innerImin` akan **memecah kompilasi** app konsumen di tempat berikut. Ini disengaja, karena switch exhaustive memaksa semua titik di-update:
- `lib/features/config/presentation/widgets/printer_connection_sheet.dart:69` (`_overrideLabel`): tambah label, misalnya `AppStrings.printerBackendOverrideInnerImin`.
- `lib/app/bootstrap/app_bootstrap.dart:51-52` (probe Sunmi saat boot) dan `lib/app/di/core_providers.dart:93` (default vendor): generalisasi jadi deteksi printer bawaan berurutan **Sunmi → iMin → Bluetooth**.
  - Idealnya lewat helper plugin baru, misalnya `Future<PrinterVendor?> detectBuiltInPrinterVendor()`, yang mencoba `isAvailable()` tiap backend bawaan setelah `connect()` dengan batas waktu pendek.
- Test konsumen yang memakai `PrinterVendor.values` (lembar koneksi, repository override) perlu diperbarui.

## 8. Test

- `runPrinterBackendContract('iMin', …)` dari `test/support/printer_backend_contract.dart`. Semua invariant lintas vendor otomatis berlaku.
- Tabel `iminStatusToStatus` untuk semua kode di §5.
- Outcome `printed`/`failed`/`unknown`, pemilihan renderer 58/80 mm, dan `cut` hanya untuk 80 mm.
- `connect()` menunggu `fd` (status `-1` beberapa kali lalu `0`).
- Wiring channel default (`blue_thermal_printer/imin`): nama method dan argumen.

## 9. Checklist verifikasi hardware iMin

- [ ] Bind + `initPrinter` berhasil setelah boot dingin. Catat lama sampai `fd` tersedia.
- [ ] Kode status nyata untuk: normal, cover terbuka, kertas habis, overheat (bila bisa direproduksi), kertas hampir habis.
- [ ] **Kode `onPrintResult` untuk cetak sukses vs kertas habis di tengah cetak** (menjawab kontradiksi §6).
- [ ] `getPrinterPaperType()` di perangkat 58 mm dan 80 mm. Lebar cetak pas, tidak terpotong.
- [ ] Feed 70 cukup untuk tear bar. `partialCut` jalan di 80 mm dan tidak dipanggil di 58 mm.
- [ ] Perangkat SDK 1.0 (mis. D1/M2): cetak lewat Bluetooth "InnerPrinter" dengan backend ESC/POS, termasuk dukungan `DLE EOT`.

## 10. Referensi

- iMin Printer SDK 2.0 Developer Documentation: https://imin-sg-resources.oss-ap-southeast-1.aliyuncs.com/docs/demo/iMinPrinterSDK2.0%20Developer%20Documentation.pdf
- iMin docs (Printer): https://oss-sg.imin.sg/docs/en/Printer.html
- `iminsoftware/IminPrinterLibrary` (`NeoPrinterManager`, `PrinterHelper`, `INeoPrinterService`): https://github.com/iminsoftware/IminPrinterLibrary
- Plugin Flutter resmi `imin_printer` (BSD-3-Clause, v0.7.5), rujukan perilaku saja: https://pub.dev/packages/imin_printer

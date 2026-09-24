## Unreleased (fork Bahana-Cipta-Technology) — audit September 2026
Detail + checklist verifikasi hardware: `doc/audit-2026-09.md`.
* Sunmi: kode `updatePrinterState()` dipetakan sesuai tabel AIDL resmi (kertas habis = 4, bukan 3) lewat `sunmiStateToStatus()`.
* Sunmi: cetak memakai transaksi buffer + `exitPrinterBufferWithCallback`; hasil `printed`/`failed`/`unknown` dari `onPrintResult` (channel `printBitmap`/`enterBuffer`/`exitBuffer` diganti `printTransaction`). Struk di-feed 3 baris setelah bitmap.
* Sunmi: binding lebih tahan (`onBindingDied`/`onNullBinding`), polling `connect()` ±3 dtk.
* ESC/POS: thread baca tidak lagi mati saat tidak ada listener `onRead()`; koneksi mati dibersihkan otomatis sehingga reconnect setelah printer dimatikan-dinyalakan berhasil tanpa restart app.
* ESC/POS: byte respons `DLE EOT` divalidasi (`PrinterStatus.tryFromOfflineStatusByte`), XON/XOFF tidak lagi terbaca sebagai status.
* ESC/POS: semua write dipindah dari platform thread ke executor serial; `connect` paralel ditolak (`connect_in_progress`), `connect` ulang ke printer yang sama idempoten; `connect()` Dart single-flight.
* API lama: header raster `GS v 0` (`printImage`/`printImageBytes`/`printQRcode`) benar untuk gambar ≥256 px; piksel transparan tercetak putih (`RasterImageEncoder`).
* Baru: `PrintJobGate` (busy-lock + timeout + hard-timeout bersama semua backend); `ReceiptRenderer` menolak lebar bukan kelipatan 8.
* Baru: `PrinterVendor.innerXcheng` / `PrinterBackendXcheng` -- sensor kertas + hasil cetak nyata lewat antarmuka native servis Xcheng (`vendor/xcheng/`), dengan fallback otomatis ke Sunmi saat connect gagal (`PrinterBackendFallback`).
* Baru: `detectBuiltInPrinterVendor()` -- deteksi printer bawaan (Xcheng, lalu Sunmi) untuk default instalasi baru.
* Sunmi: callback transaksi tidak ditunggu bila AIDL disediakan servis klon (menghapus jeda ±12 dtk cetak pertama di perangkat Xcheng).
* ESC/POS: printer yang tidak pernah menjawab `DLE EOT` tidak ditanya lagi di sisa koneksi (menghapus ±3 dtk per cetak).
* Test: suite kontrak lintas vendor, 162 test Dart + JUnit untuk helper Java murni; hasil device testing 01 di `doc/audit-2026-09.md`.

## 1.2.3
* demonstrate using enum for readability
* drawer pin by erica
* fix bug on ios

## 1.2.2
* upgrading gradle

## 1.2.1
* fix android 12 permission

## 1.2.0
* fix web build issue

## 1.1.9
* fix bluetooth listener not working, add additional bluetooth state info, add get connected device function
* Issue #123 fix - app will now automatically disconnect if device is turned off
  thanks to knight-dev

## 1.1.8
* Fix bug on ios build

## 1.1.7

* dartdoc comments and Dart formatter

## 1.1.6

* Add print3Column method
* Add print4Column method
* Support format string

## 1.1.5

* Migrate to Android embedding v2

## 1.1.4

* Fix Error Null-Safety

## 1.1.3

* Fix Cast Error on getBondedDevices

## 1.1.2

* Migrate to null-safety

## 1.1.1

* Support different charset in print methods, thanks to danilof

## 1.1.0

* Add print image bytes method, thanks to mvanvu

## 1.0.9

* Avoiding activity null pointer, thanks to wmattei

## 1.0.8

* fix crash with "Methods marked with @UiThread must be executed on the main thread, thanks to ricardochen

## 1.0.7

* change documentation

## 1.0.6

* add size to printleftright

## 1.0.5

* fix bug

## 1.0.4

* fix bug

## 1.0.3

* Add print left + right

## 1.0.2

* Add Endline in QRCODE

## 1.0.1

* Add Doc.

## 1.0.0

* initial release.

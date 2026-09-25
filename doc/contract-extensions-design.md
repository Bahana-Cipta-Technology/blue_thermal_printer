# Rancangan perluasan kontrak `PrinterBackend`

Status: **diimplementasikan (fase 1–3), terverifikasi di device testing 01** (25 Sep 2026) — hasil di §7. Fase 4 (process ID ESC/POS) belum dikerjakan. Berlaku untuk empat backend: ESC/POS Bluetooth, Sunmi, Xcheng, dan iMin. `PrinterBackendFallback` ikut diperbarui.

## 1. Latar belakang

Kontrak `PrinterBackend` sekarang cukup untuk *mencetak*, tapi app konsumen pertama (`parkways_valet`) terpaksa menambal empat celah sendiri. Setiap app baru akan menulis ulang tambalan yang sama.

| # | Celah | Tambalan di app hari ini |
|---|---|---|
| 1 | `printReceipt` → `PrinterResult<void>`: `Ok` tidak membuktikan struk keluar | `receipt_print_page.dart` tidak pernah menampilkan "sukses" dan memakai flag `_attempted`. Padahal Xcheng (`onComplete`) dan Sunmi asli (`onPrintResult`) tahu kapan struk tercetak. |
| 2 | Tidak ada info kemampuan printer | App tidak tahu lebar kertas, apakah kertas dipotong otomatis, atau apakah deteksi kertas habis bisa dipercaya. |
| 3 | Pratinjau ≠ cetakan | `receipt_preview_dialog.dart` memakai `toPlainText()`, sedangkan yang dicetak raster 384/576 px. |
| 4 | Logika sambung otomatis ada di app | `printer_connection_providers.dart` (`_maybeAutoReconnect`, `_maybeAutoConnectBuiltIn`) harus memahami *deadlock* `isAvailable`-sebelum-`connect` di printer bawaan dan larangan memanggil `isConnected` secara pasif di Bluetooth. |

Rancangan ini menambah empat member kontrak untuk menutup celah-celah tersebut:
- `printReceipt` → `PrintDelivery`;
- `capabilities()`;
- `preview()`;
- `ensureConnected()`.

## 2. Audit sumber resmi per vendor

| Kebutuhan | Sunmi (AIDL Woyou) | Xcheng (`IPrinterService`) | iMin SDK 2.0 | ESC/POS Bluetooth |
|---|---|---|---|---|
| **Konfirmasi tercetak** | `onPrintResult` dari `exitPrinterBufferWithCallback`: "0 成功 1 失败" (`ICallback.aidl`). Butuh T1mini ≥ v2.4.1 / T2mini ≥ v1.0.0. Demo resmi memakai pola ini. | `onComplete()`: "Called when the given task completes" (Positivo Printer API v3 §2.1.4). **Terverifikasi hardware** O1: datang saat ada kertas, tidak datang saat kertas habis. | `onPrintResult` ada (PDF §3.18.4), tapi **kodenya kontradiktif** (0 vs 1 = sukses) — lihat `vendor-imin-design.md`. | Epson `GS ( H` fn=48: *"When the related data is printing data, the process ID response is transmitted when the printing is completed."* Belum ada di plugin; printer klon belum tentu mendukung. |
| **Lebar kertas** | `getPrinterPaper()`: **"0: 80mm 1: 58mm"**. Butuh T1 ≥ v2.4.0, T2/S2 ≥ v1.0.5, lainnya ≥ v4.1.2. Demo resmi: `== 1 ? "58mm" : "80mm"`. | Tidak ada API. Margin maksimum 1…384 dot (API v3 §4.4), jadi 58 mm. | `getPrinterPaperType()` → `58`/`80` (PDF §3.4.8). | Tidak ada query standar. Lebar dari konfigurasi renderer (default 384). |
| **Cutter** | **Tidak ada API deteksi.** Demo resmi: *"cuts paper and throws exception on machines without a cutter"*, jadi tidak boleh dipakai sebagai probe. Status 7/8 hanya muncul di model ber-cutter. | Tidak ada API potong kertas (handheld). | `partialCut(fd)` (§3.9.1). Model 80 mm ber-cutter (pendahuluan PDF). | Epson `GS I 2` Type ID: *"bit 1 … Autocutter installed"*. Query ini menulis ke printer, dan klon belum tentu menjawab. |
| **Deteksi kertas habis** | `updatePrinterState()` 4 = kertas habis. **Klon** (servis Xcheng) selalu 1, terverifikasi hardware. | `printerPaper()` → true/false (API v3 §1.1.11), terverifikasi hardware. | `getPrinterStatus` 7 (§3.3), belum diuji hardware. | `DLE EOT 2`, bit 5. `RPPInnerPrinter` tidak menjawab (terverifikasi hardware). |
| **Status koneksi pasif** | Status servis dari bridge, tanpa query ke printer. | Idem. | Idem (`fd` siap). | Native `connect` ke alamat yang sama saat masih terhubung langsung `success(true)` (idempoten, tanpa tulis byte). `isConnected()` **menulis** byte. |

**Prinsip hasil audit:** `capabilities()` menjelaskan **perilaku backend** (lebar yang akan dipakai, apakah backend memotong kertas), bukan menebak hardware. Nilai yang benar-benar tidak diketahui bertipe `bool?` (`null`). Dengan begitu tidak perlu probe yang berisiko, seperti `cutPaper` di Sunmi.

## 3. Tipe baru (`lib/src/`)

```dart
/// Hasil printReceipt yang sukses.
enum PrintDelivery {
  confirmed,  // printer melaporkan struk selesai tercetak
  unverified, // data terkirim & tidak ada bukti gagal, tapi tanpa konfirmasi
}

class PrinterCapabilities {
  const PrinterCapabilities({
    required this.paperWidthPx,   // lebar raster yang DIPAKAI printReceipt/preview saat ini
    required this.autoCut,        // backend memotong kertas setelah struk (false = sobek manual)
    this.reportsPaperOut,         // null = belum diketahui
    this.confirmsPrint,           // null = belum diketahui
  });
  static const fallback58 = PrinterCapabilities(paperWidthPx: 384, autoCut: false);
}
```

`PrinterFailure` mendapat field `requiresDeviceSelection` (default `false`). Field ini dipakai `ensureConnected` untuk memberi tahu app bahwa lembar pilih printer perlu dibuka. Ini sejalan dengan field `isPermissionDenied` yang sudah ada.

## 4. Perubahan kontrak `PrinterBackend`

```dart
Future<PrinterResult<PrintDelivery>> printReceipt(Receipt receipt); // dulu PrinterResult<void>
Future<PrinterCapabilities> capabilities();                         // tidak menulis ke printer
Future<Uint8List> preview(Receipt receipt);                         // PNG identik dengan cetakan
Future<PrinterResult<PrinterDevice>> ensureConnected({PrinterDevice? lastDevice});
```

Invariant baru, ditambahkan ke `test/support/printer_backend_contract.dart`:
1. `confirmed` hanya boleh muncul bila `capabilities().confirmsPrint == true`.
2. `preview(r)` punya lebar `capabilities().paperWidthPx`. Byte PNG yang dikirim `printReceipt(r)` ke native identik dengan `preview(r)`; untuk ESC/POS, raster berasal dari render yang sama.
3. `capabilities()` dan `preview()` tidak pernah mengirim data cetak (`sends() == 0`) dan tidak melempar.
4. `ensureConnected` bersifat idempoten dan single-flight: dua panggilan bersamaan menghasilkan satu percobaan native. Dependency yang melempar menjadi `Err`.
5. Semua invariant lama (pre-check, busy-lock, timeout) tetap berlaku dengan tipe hasil baru.

## 5. Rancangan per method

### 5.1 `printReceipt` → `PrintDelivery`

- `PrintJobGate.run` dibuat generik (`run<T>(Future<PrinterResult<T>> Function())`). Pesan busy/timeout tetap sama.
- `*PrintOutcome` per vendor tetap internal, dipetakan di `_send` masing-masing backend:

  | Vendor | `confirmed` | `unverified` |
  |---|---|---|
  | Xcheng | `printed` (`onComplete`) | `unknown` + post-check tanpa masalah |
  | Sunmi | `printed`, hanya dari paket asli | klon, timeout, `unknown` |
  | iMin | `printed`, hanya saat `PRINT_RESULT_CODE_VERIFIED` | selain itu |
  | ESC/POS | — (fase 4: process ID `GS ( H`) | selalu |

- Semua jalur `Err` tidak berubah.

### 5.2 `capabilities()`

| Field | Sunmi | Xcheng | iMin | ESC/POS |
|---|---|---|---|---|
| `paperWidthPx` | `getPrinterPaper()`: `1` → 384, `0` → 576; exception/versi lama → 384 | 384 (konstan) | `getPrinterPaperType()`: `80` → 576, selain itu 384 | lebar `renderer` (default 384) |
| `autoCut` | `false` (backend tidak memotong) | `false` | `true` bila 80 mm | `false` |
| `reportsPaperOut` | `true` bila paket asli, `false` bila klon | `true` | `true` (belum diuji hardware) | `null` sebelum query pertama, `true` bila pernah menjawab `DLE EOT`, `false` bila `_statusUnsupported` |
| `confirmsPrint` | paket asli dan callback transaksi belum pernah timeout → `true`; klon → `false` | `true` | `PRINT_RESULT_CODE_VERIFIED` | `false` |

- **Native Sunmi:** method channel `serviceInfo` mengembalikan `{paper: int?, genuine: bool?, transactionCallback: bool?}` dari `SunmiPrinterBridge`. `paper` dibaca lewat raw transact (`WoyouTransactions.GET_PRINTER_PAPER`) karena proxy AIDL bawaan mengabaikan hasil `transact`. `genuineSunmi` sudah dihitung di `onServiceConnected`; `transactionCallbackSupported` sudah ada.
- **Perbaikan ikutan Sunmi:** `_send` harus me-render dengan `paperWidthPx`. Hari ini Sunmi selalu mencetak 384 px, sehingga struk di Sunmi 80 mm (T2) tercetak sempit.
- **iMin:** `paperType` di channel sudah ada.
- **Xcheng:** tidak ada perubahan native.
- **ESC/POS:** hanya Dart, memakai state `_statusEverAnswered`/`_statusUnsupported` yang sudah ada.

### 5.3 `preview(Receipt)`

- Ekstrak satu helper privat per backend, `_rendererFor(PrinterCapabilities)` → `ReceiptRenderer(width: caps.paperWidthPx, fontFamily: _renderer.fontFamily)`. Helper ini dipakai bersama oleh `preview` dan `_send`, sehingga invariant 2 terjamin oleh konstruksi, bukan kebetulan.
- Saat belum terhubung, lebar diambil dari nilai terakhir yang diketahui (di-cache saat `capabilities()`/`_send`), atau 384 sebagai default. Pratinjau tetap bisa ditampilkan offline.
- ESC/POS: `preview` = `renderer.preview`, sedangkan `_encode` memakai `renderer.encode` dari renderer yang sama.

### 5.4 `ensureConnected({PrinterDevice? lastDevice})`

- **Printer bawaan (Sunmi/Xcheng/iMin)**, lewat satu helper bersama `ensureBuiltInConnected(backend, device)` di `lib/src/built_in_connection.dart`:
  - `isAvailable()` (query ke servis, bukan tulis ke printer) → `Ok(device)`;
  - selain itu `connect(device)`.
  - `lastDevice` diabaikan.
  - Ini menghilangkan *deadlock* yang dijelaskan di app.
- **ESC/POS:**
  1. Izin belum diberikan → `Err(isPermissionDenied)`, tanpa memicu dialog.
  2. Bluetooth mati → `Err`.
  3. `lastDevice == null` atau tidak ada di daftar bonded → `Err(requiresDeviceSelection: true)`.
  4. Selain itu `connect(lastDevice)`. Native idempoten untuk alamat yang sama, jadi **tidak pernah memanggil `isConnected()`**. Single-flight dari `_pendingConnect` sudah ada.
- **`PrinterBackendFallback`:** `primary.ensureConnected` → gagal → `primary.disconnect()` → `fallback.ensureConnected`. Pola ini sama dengan `connect`.
- **Tidak ada throttle di plugin.** App memanggil `ensureConnected` di titik niat (buka halaman cetak, tepat sebelum cetak, resume). Penyimpanan `lastDevice` tetap di app.

## 6. Dampak ke app `parkways_valet`

- `test/support/fakes.dart` `FakePrinterBackend`: tambah 3 member, dan `printResult` bertipe `PrinterResult<PrintDelivery>`.
- `receipt_print_page.dart`: tampilkan label berbeda untuk `confirmed` ("Struk tercetak") dan `unverified` ("Struk terkirim — periksa printer"). Tambah string di `app_strings.dart`.
- `receipt_preview_dialog.dart`: tampilkan `Image.memory(await backend.preview(receipt))`, dengan fallback ke teks bila gagal. `JoinedReceiptPreview` (kartu digital hasil desain UI) **tidak** diubah.
- `printer_connection_providers.dart`: `_maybeAutoReconnect` + `_maybeAutoConnectBuiltIn` diganti satu `_autoConnect()` yang memanggil `ensureConnected(lastDevice: …)` dari preferensi tersimpan. Guard sekali-per-backend (`_autoConnectAttemptedFor`) tetap dipakai. `requiresDeviceSelection` membuka lembar koneksi di halaman cetak.
- Pemanggil `fold(onOk: (_) …)` lain tetap terkompilasi.

## 7. Pengujian

**Unit/kontrak (plugin, `flutter test`):**
- invariant §4 untuk keempat backend + fallback;
- mapping `getPrinterPaper` Sunmi (0/1/exception);
- ESC/POS `reportsPaperOut` null → true/false;
- `ensureConnected` ESC/POS (tanpa izin, BT mati, tanpa `lastDevice`, tidak bonded, sukses);
- wiring channel Sunmi `serviceInfo`.

**Hardware — device testing 01** (Xchengtech O1, Android 9, servis `com.xcheng.printerservice` v1.1.12). Kondisi kertas dikonfirmasi dulu ke operator, karena kertas dipasang/dilepas secara fisik.

| Backend di O1 | Skenario | Harapan |
|---|---|---|
| Xcheng native | `capabilities()` | 384 / autoCut false / reportsPaperOut true / confirmsPrint true |
| | cetak dengan kertas | `Ok(confirmed)` |
| | cetak tanpa kertas | `Err` "Kertas printer habis.", tidak ada data menumpuk |
| | `ensureConnected()` saat boot dingin | `Ok`, tanpa interaksi pengguna |
| | `preview` vs struk fisik | lebar sama |
| Sunmi-compat (klon di servis Xcheng) | `getPrinterPaper()` di klon | **catat nilai aktual** (belum diketahui) |
| | `capabilities()` | reportsPaperOut false / confirmsPrint false |
| | cetak | `Ok(unverified)`, tidak pernah `confirmed` |
| Bluetooth `RPPInnerPrinter` (11:22:33:44:55:66) | `ensureConnected(lastDevice)` | `Ok`; panggilan kedua saat masih terhubung tidak memicu koneksi ulang / tulis byte |
| | `ensureConnected()` tanpa `lastDevice` | `Err(requiresDeviceSelection)` |
| | setelah 2 query status tak terjawab | `reportsPaperOut == false` |
| | cetak | `Ok(unverified)` |

**Hasil di O1 (25 Sep 2026)** — lewat app probe sementara yang memanggil API plugin langsung. Kondisi kertas dikonfirmasi operator di tiap tahap. Semua skenario sesuai harapan:

| Backend | Hasil |
|---|---|
| Deteksi | `detectBuiltInPrinterVendor()` → `innerXcheng` |
| Xcheng native | `capabilities()` 384/false/true/true. `ensureConnected` ×2 bersamaan → Ok (41 ms), ulang → Ok (3 ms). Cetak dengan kertas → `Ok(confirmed)` (±1,4 dtk), struk keluar penuh. Roll dilepas → `Err("Kertas printer habis.")` (2,3 dtk), dan tidak ada struk yang tercetak sendiri saat roll dipasang kembali. |
| Sunmi-klon (AIDL Woyou di `com.xcheng.printerservice`) | `serviceInfo` = `{paper: null, genuine: false, transactionCallback: false}`. **Servis klon tidak punya `getPrinterPaper`**: `transact` mengembalikan `false`. Proxy AIDL bawaan akan membacanya sebagai 0 = 80 mm, sedangkan jalur raw transact (`WoyouTransactions`) melaporkan `null`, sehingga lebarnya tetap 384. `capabilities()` 384/false/false/false. Cetak → `Ok(unverified)`. |
| iMin | `ensureConnected` → `Err` "tidak ditemukan" dalam 30 ms (tanpa servis iMin). |
| Bluetooth `RPPInnerPrinter` | Tanpa `lastDevice` → `Err(requiresDeviceSelection)`. Perangkat tak terpasang → `Err(requiresDeviceSelection)`. `ensureConnected(lastDevice)` ×2 → Ok (47 ms), ulang → Ok (24 ms). Cetak pertama → `Ok(unverified)` (3,1 dtk: dua query `DLE EOT` tak terjawab), lalu `reportsPaperOut == false`. Cetak kedua setelah `ensureConnected` → `Ok(unverified)` dalam **59 ms**: dukungan status yang sudah dipelajari tidak di-reset saat menyambung ulang ke printer yang sama. |

Checklist hardware di luar O1:
- [ ] Sunmi asli: `getPrinterPaper()` 58 vs 80 mm (T2/T1), `onPrintResult` → `confirmed`, dan timeout callback → `confirmsPrint` turun ke `false`.
- [ ] iMin: lihat checklist `vendor-imin-design.md` §8. Setelah kode `onPrintResult` terverifikasi, `confirmsPrint` menjadi `true`.
- [ ] Printer Epson TM (fase 4): respons process ID `GS ( H` fn=48 setelah struk selesai.

## 8. Fase implementasi

1. **Plugin:**
   - tipe baru;
   - `PrintJobGate` generik;
   - kontrak + 4 backend + fallback + helper built-in;
   - native Sunmi `capabilities`;
   - perbaikan lebar Sunmi;
   - invariant kontrak + unit test.

   `flutter analyze` + `flutter test` harus bersih.
2. **App:** fake, halaman cetak, success sheet, dialog pratinjau, dan provider koneksi. `flutter analyze` + `flutter test`, lalu `flutter build apk --debug`.
3. **Hardware:** tabel §7 di O1. Hasilnya dicatat di dokumen ini.
4. **Opsional (setelah 1–3):** konfirmasi ESC/POS lewat process ID `GS ( H` fn=48.
   - Native `ConnectedThread` perlu mengenali respons `37h 22h d1..d4 00h` (mailbox kedua, pola `EscPosStatus`).
   - `confirmsPrint` dipelajari saat runtime: `true` setelah satu respons, `false` setelah N cetak tanpa respons.
   - Harus diuji di printer Epson; `RPPInnerPrinter` diperkirakan tidak mendukung.

## 9. Referensi

- Sunmi: `android/src/main/aidl/woyou/aidlservice/jiuiv5/IWoyouService.aidl` dan `ICallback.aidl` (repo ini); demo resmi <https://github.com/shangmisunmi/SunmiPrinterDemo> (`SunmiPrintHelper.java`: `getPrinterPaper`, `cutpaper`, `printTrans`).
- Xcheng/Positivo: AIDL OEM dan *Positivo Printer Developer Documentation* v3 (2023-02-22), <https://github.com/joaodematejr/l300-positivo/tree/main/SDKPACKAGE/servico_de_impressao_l3>.
- iMin: `doc/vendor-imin-design.md` (dokumen resmi SDK 2.0 dan `IminPrinterLibrary`).
- Epson ESC/POS Command Reference: `GS I` (Transmit printer ID) dan `GS ( H` fn=48 (process ID response), <https://download4.epson.biz/sec_pubs/pos/reference_en/escpos/> (dibaca lewat arsip Wayback karena akses langsung diblokir).

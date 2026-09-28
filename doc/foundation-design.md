# Fondasi sebelum vendor ke-5

Status (28 Sep 2026):
- **F1 dan F3 diimplementasikan**, test Dart dan JUnit bersih. **F1 terverifikasi di Xcheng O1** (28 Sep 2026). F3 (LAN/USB) belum diverifikasi di hardware. Checklist ada di §5.
- **F2 dan F4 ditunda.** Keputusannya diambil setelah F1 dan F3 terverifikasi.

Plugin ini menjadi interface printer tunggal untuk semua app perusahaan. Roadmap vendornya: PAX → Urovo → Nexgo → Epson ePOS → Telpo/Newland. Dokumen ini merangkum fondasi yang dibutuhkan supaya penambahan vendor tidak menggelembungkan plugin atau mengulang kode.

| Fase | Isi | Status |
|---|---|---|
| F1 | `BuiltInPrinterBackend`: kerangka bersama printer bawaan | ✅ kode + test |
| F2 | Vendor add-on package (SDK proprietary opt-in saat build) | ⏸ ditunda |
| F3 | ESC/POS lewat LAN dan USB (`EscposTransport`) | ✅ kode + test, app: input IP |
| F4 | Deteksi printer bawaan berbasis merek perangkat | ⏸ ditunda |

Ketergantungan antarfase:
- F1 dan F3 independen.
- F2 paling diuntungkan oleh F1, karena backend Dart vendor add-on memakai base class F1, tapi tidak wajib menunggunya.
- F4 independen.

Download SDK vendor saat runtime **tidak** dipakai. Kebijakan Play (*Device and Network Abuse*) melarang app mengunduh kode yang bisa dieksekusi dari sumber selain Play. Play Feature Delivery butuh Play Store, sedangkan sebagian besar EDC tidak memilikinya, dan modul dinamisnya harus milik app, bukan plugin. Karena itu seleksi vendor dilakukan saat build (F2).

## 1. F1: `BuiltInPrinterBackend`

**Masalah:** backend Sunmi, Xcheng, dan iMin ±80% identik (poll connect, `ensureConnected`, pre-check → render → outcome → post-check, pesan galat), dan salinannya mulai menyimpang.

**Solusi:** `lib/src/built_in_printer_backend.dart`.
- `enum PrintOutcome { printed, failed, unknown }` netral vendor. `SunmiPrintOutcome`, `XchengPrintOutcome`, dan `IminPrintOutcome` kini `typedef` ke enum ini, jadi API publik tetap kompatibel.
- `abstract class BuiltInPrinterBackend` memegang alur bersama. Vendor mengisi hook berikut:

| Hook | Wajib | Arti |
|---|---|---|
| `bindService()` / `unbindService()` | ya | bind/unbind servis vendor |
| `probeReady()` | ya | servis siap menjawab (dasar `isAvailable`) |
| `readStatus()` | ya | status fisik; boleh melempar |
| `readCapabilities()` | ya | kemampuan; `null` atau melempar = pakai nilai terakhir |
| `sendRaster(png, caps)` | ya | satu pekerjaan cetak → `PrintOutcome` |
| `notFoundMessage` | tidak | pesan saat bind `false` |
| `capabilitiesRequireConnection` | tidak | `true` = `capabilities()` tidak melakukan query sebelum servis siap (iMin) |

- Invariant yang dijaga di satu tempat:
  - pre-check status sebelum data dikirim;
  - `unknown` tidak memblokir;
  - `confirmed` hanya bila `capabilities().confirmsPrint == true`;
  - capabilities dibaca ulang setiap cetak;
  - busy-lock `PrintJobGate`.
- Hasil: Sunmi 357 → 172 baris, Xcheng 257 → 120, iMin 322 → 168. Base class 272 baris, termasuk dokumentasi.
- **Satu perubahan perilaku yang disengaja:** di Sunmi, cabang `unknown` yang query status-nya melempar setelah data terkirim kini menghasilkan `Ok(unverified)`, bukan `Err("Tidak dapat mengirim struk")`. Perilakunya sekarang sama dengan Xcheng/iMin. Pesan lama menyesatkan karena data sudah terkirim. Tidak ada test lama yang mengunci perilaku lama.
- Tidak dipakai oleh backend yang punya pemilihan perangkat (ESC/POS BT/LAN/USB, kelak Epson ePOS): mereka mengimplementasikan `PrinterBackend` langsung.
- Ditunda: ekstraksi native `VendorPrinterChannel` (`runQuery`/`queryExecutor` yang tersalin di ketiga `*PrinterChannel.java`). Manfaatnya kecil dibanding risikonya menyentuh kode native yang sudah terverifikasi hardware.

## 2. F3: ESC/POS lewat LAN dan USB

**Dart:**
- `lib/src/escpos_transport.dart` memuat `EscposTransport`. Transport hanya memindahkan byte dan menjawab soal koneksinya sendiri. Semua logika ESC/POS (pre-/post-check `DLE EOT`, reset `ESC @`, pelacakan printer yang tidak menjawab status, single-flight connect, `PrintJobGate`) tetap satu di `PrinterBackendEscpos`.
- `ChannelEscposTransport` adalah dasar transport berbasis method channel, dengan kosakata bersama `disconnect`/`isConnected`/`writeBytes{bytes}`/`queryStatus{type}`.
- `PrinterBackendEscpos()` (constructor default, Bluetooth) **tidak berubah**, dan semua test lamanya lulus tanpa diubah. `PrinterBackendEscpos.withTransport(transport)` untuk transport lain.
- `NetworkEscposTransport` (`printer_backend_escpos_network.dart`):
  - `PrinterDevice.macAddress` = `host:port`, dan field itu kini berarti "alamat transport";
  - `parseNetworkAddress` menerima IPv4 atau hostname, dengan port default 9100; IPv6 belum didukung;
  - tanpa discovery: alamat tersimpan langsung disambung ulang.
- `UsbEscposTransport` (`printer_backend_escpos_usb.dart`):
  - kunci perangkat `usb:<vendorId>:<productId>`, stabil saat kabel dicabut-colok;
  - izin ditolak → `PrinterFailure.isPermissionDenied`;
  - printer yang dicabut → `requiresDeviceSelection`.
- `PrinterVendor` mendapat `lan` dan `usb` di akhir enum (nilai tersimpan berdasarkan `name`, jadi pilihan lama aman). Keduanya tidak ikut deteksi printer bawaan.

**Native** (terisolasi, `BlueThermalPrinterPlugin.java` hanya menambah registrasi):

| Channel | Kelas | Catatan |
|---|---|---|
| `blue_thermal_printer/escpos_net` | `transport/net/NetPrinterChannel` | `java.net.Socket`, connect timeout 5 dtk, `TCP_NODELAY` + keepalive; satu thread pembaca per socket dengan mailbox status (`EscPosStatus.indexOfRealtimeStatus`) |
| `blue_thermal_printer/escpos_usb` | `transport/usb/UsbPrinterChannel` | interface dipilih lewat `TransportSupport.usbInterfacePriority` (printer 7 > vendor 0xFF > CDC data 0x0A; mass storage/HID/audio ditolak); bulk OUT per 16 KB; status lewat bulk IN (bila ada) setelah buffer lama dikuras; izin via `PendingIntent` eksplisit + `FLAG_MUTABLE`, receiver `RECEIVER_NOT_EXPORTED` |

- Model thread untuk keduanya:
  - IO serial di `ioExecutor`, jadi query status tidak pernah menyela data struk;
  - `disconnect` di `controlExecutor` terpisah, karena menutup socket/koneksi USB dari thread lain adalah satu-satunya cara melepas tulis yang macet (`PrintJobGate.onStuck`).
- `TransportSupport` (Java murni, JUnit): `statusQueryCommand`, `usbInterfacePriority`, konstanta timeout.
- Manifest plugin: `INTERNET` (izin normal) dan `<uses-feature android.hardware.usb.host required="false">`.

**App `parkways_valet`:**
- Sheet koneksi printer punya kartu transport per jenis: Bluetooth, USB, atau LAN (LAN memakai pintasan Setelan Wi-Fi).
- Khusus LAN: field "Alamat Printer" + tombol Hubungkan, divalidasi dengan `parseNetworkAddress`. Alamat LAN tersimpan diisi ulang saat sheet dibuka, sedangkan MAC Bluetooth tersimpan tidak.
- Penyimpanan preferensi dan auto-connect memakai alur yang sudah ada. Preferensi milik transport lain gagal dengan tenang (`requiresDeviceSelection`).

**Batasan yang diketahui:**
- `DLE EOT` dijawab saat byte diterima, bukan saat tercetak, jadi `confirmsPrint` tetap `false` (sama dengan Bluetooth).
- Socket TCP ke printer yang mati tanpa FIN baru terdeteksi saat tulis atau query gagal.
- Tidak ada discovery LAN (mDNS/scan subnet).

## 3. F2: vendor add-on (ditunda, rancangan)

Backend Dart hanya berbicara lewat `MethodChannel`, jadi Dart **tidak** butuh SDK vendor. Rancangannya:
- Dart backend vendor proprietary (PAX, Nexgo, …) tetap di core.
- Native-nya di package Flutter terpisah `vendors/<nama>/` (mis. `blue_thermal_printer_pax`), yang di-opt-in app lewat satu baris pubspec.
- App tanpa add-on → channel tanpa handler → backend "tidak tersedia". Perilaku ini sudah dites di `default_channel_wiring_test.dart`.
- Artefak non-Maven:
  - bila EULA mengizinkan redistribusi: `vendors/<nama>/android/libs/` + SHA-256 + ringkasan EULA;
  - bila tidak: `compileOnly`.
- Kerangka pertama: Urovo, karena SDK-nya publik.
- Alternatif yang ditolak: Gradle property per vendor, karena butuh reflection, keep rule R8, dan manifest kondisional.

## 4. F4: deteksi berbasis merek (ditunda, rancangan)

- Channel `blue_thermal_printer/device` → `Build.MANUFACTURER`/`BRAND`/`MODEL`.
- Vendor yang cocok dengan merek di-probe lebih dulu, tapi **hasil tetap dari probe nyata**, dan Sunmi (AIDL Woyou generik) tetap di-probe setelah Xcheng/iMin.

## 5. Checklist verifikasi hardware

F1 (Xcheng O1, regresi). Diuji 28 Sep 2026 lewat app probe (plugin via `path:`) dan app `parkways_valet` debug. Kondisi kertas dikonfirmasi fisik oleh penguji.
- [x] `detectBuiltInPrinterVendor()` → `innerXcheng` (1,9 dtk). Diuji dari app yang baru dibuka, bukan boot dingin perangkat.
- [x] `innerXcheng` → backend aktif `PrinterBackendXcheng`; capabilities 384 px, `reportsPaperOut`/`confirmsPrint` `true`.
- [x] Cetak normal → `confirmed` (257 ms); cetak bersamaan → ditolak busy-lock; struk utuh.
- [x] Kertas habis → `Err("Kertas printer habis.")` sebelum kirim, termasuk pekerjaan yang sedang ditahan busy-lock; setelah kertas dipasang **tidak** ada struk yang menumpuk. Catatan: query sensor saat kertas habis ±2,2 dtk (saat ada kertas ±20 ms) -- perilaku servis, sama dengan sebelum refactor.
- [x] `PrinterBackendSunmi` di servis klon Xcheng → capabilities `reportsPaperOut`/`confirmsPrint` `false`, cetak → `unverified` (173 ms, tanpa jeda callback).
- [x] App: jenis printer tersimpan tetap, status "Printer bawaan siap", cetak struk transaksi sukses; tanpa kertas → pesan "Kertas printer habis", tidak ada struk menumpuk setelah kertas dipasang. Tidak ada crash/`E/flutter` di logcat.
- [ ] Sunmi asli: belum ada perangkat.

Temuan pra-ada (bukan dari refactor): `XchengPrinterBridge.feedQuietly` mengirim callback `null` ke `printWrapPaper`, dan servis Xcheng menulis log NPE `IPrinterCallback.onLength` yang ditangkap servis sendiri. Tidak berdampak; opsional diganti callback no-op.

F3 LAN (printer ESC/POS jaringan, port 9100):
- [ ] Input IP → terhubung; tutup lalu buka sheet → alamat terisi, auto-connect saat app dibuka ulang.
- [ ] Cetak struk 58 mm utuh.
- [ ] Kertas habis → pre-check `DLE EOT` menolak (bila printer mendukung); printer tanpa `DLE EOT` tetap mencetak (`unverified`).
- [ ] Printer dimatikan saat idle lalu cetak → galat jelas; printer dinyalakan → reconnect tanpa restart app.
- [ ] IP salah/tidak terjangkau → pesan "Gagal terhubung ke printer LAN" dalam ±5 dtk, UI tidak beku.

F3 USB (printer USB lewat OTG):
- [ ] Printer muncul di daftar; flashdisk/keyboard tidak.
- [ ] Dialog izin muncul sekali; "Tolak" → pesan izin ditolak; "Izinkan" → terhubung.
- [ ] Cetak struk utuh (struk panjang > 16 KB raster).
- [ ] Cabut kabel saat idle → cetak gagal jelas; colok lagi → pilih printer → cetak.
- [ ] Printer tanpa endpoint IN → status `unknown`, cetak tidak diblokir.

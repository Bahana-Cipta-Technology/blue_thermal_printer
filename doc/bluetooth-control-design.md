# Kontrol Bluetooth: nyala/mati, pencarian, pairing, prasyarat

Status (5 Okt 2026): **kode + test selesai** (Dart, JUnit `BluetoothRequirementPolicyTest`, widget test app `parkways_valet`). **Belum diverifikasi di hardware** — checklist ada di §6.

Sebelumnya jalur Bluetooth hanya bisa membaca `isOn`, membaca perangkat yang sudah dipasangkan, dan membuka Setelan Bluetooth. Petugas harus keluar app untuk menyalakan Bluetooth dan memasangkan printer baru. Fitur ini memindahkan seluruh alur itu ke dalam app, dan menambah satu API prasyarat yang menjelaskan apa yang kurang dan bagaimana menyelesaikannya.

## 1. Prasyarat per operasi

Sumber kebenaran: `BluetoothRequirementPolicy.java` (Java murni, dites JUnit). Tabel ini harus selalu sama dengan kode itu.

### 1a. Izin

| Operasi | API 23–28 (Android 6–9) | API 29–30 (Android 10–11) | API 31–32 (Android 12) | API 33+ (Android 13+) |
|---|---|---|---|---|
| Baca status adapter | `BLUETOOTH` | `BLUETOOTH` | — | — |
| Daftar perangkat terpasang | `BLUETOOTH` | `BLUETOOTH` | Perangkat sekitar* | Perangkat sekitar* |
| Nyalakan | `BLUETOOTH_ADMIN`, `enable()` langsung | sama | Perangkat sekitar*, `enable()` langsung | Perangkat sekitar* + dialog sistem `ACTION_REQUEST_ENABLE` |
| Matikan | `BLUETOOTH_ADMIN`, `disable()` | sama | Perangkat sekitar*, `disable()` | **tidak bisa dari app**, Setelan Bluetooth dibuka |
| Pencarian | `BLUETOOTH_ADMIN` + `ACCESS_FINE_LOCATION`* | + layanan Lokasi ON | Perangkat sekitar* | sama |
| Pairing | `BLUETOOTH_ADMIN` | sama | Perangkat sekitar* | sama |
| Koneksi SPP | `BLUETOOTH` | sama | Perangkat sekitar* | sama |

- `*` = izin runtime (dialog). Selain itu izin normal yang otomatis diberikan saat instal.
- "Perangkat sekitar" = `BLUETOOTH_SCAN` + `BLUETOOTH_CONNECT`. Keduanya satu grup dan muncul sebagai satu dialog, jadi plugin memperlakukannya sebagai satu prasyarat (`nearbyDevices`).
- Di API 33+, `enable()`/`disable()` selalu `false` untuk app biasa. Native tetap mencobanya dulu, karena app sistem/device owner di sebagian EDC masih diizinkan.

### 1b. Prasyarat non-izin

| Prasyarat (`id`) | Berlaku untuk | Penyelesaian |
|---|---|---|
| `hardware` | semua | tidak bisa; UI menyembunyikan Bluetooth |
| `activity` | operasi yang butuh dialog, hanya saat app tidak punya Activity | buka app |
| `nearbyDevices` / `location` | lihat 1a | dialog izin, atau Setelan aplikasi bila ditolak permanen |
| `adapter` | daftar terpasang, pencarian, pairing, koneksi | nyalakan Bluetooth |
| `locationService` | pencarian di API 29–30 | buka Setelan Lokasi |

Urutan penyelesaian selalu hardware → activity → izin → adapter → Lokasi.

### 1c. Manifest plugin

Manifest plugin ikut ter-merge ke **semua** app konsumen. Fitur ini **tidak menambah izin baru**; manifest justru dipersempit:

- `BLUETOOTH`, `BLUETOOTH_ADMIN`, `ACCESS_FINE_LOCATION`: `maxSdkVersion="30"`.
- `ACCESS_COARSE_LOCATION` **dihapus**. Di API 23–28 izin lokasi presisi sudah mencakup lokasi kasar, dan di API 29–30 presisi memang wajib.
- `BLUETOOTH_SCAN`: `usesPermissionFlags="neverForLocation"`. Android 12+ tidak lagi meminta lokasi.
- `BLUETOOTH_ADVERTISE` **dihapus** karena plugin tidak pernah advertise.
- Tambah `uses-feature android.hardware.bluetooth required="false"`.

Catatan untuk app konsumen:
- App yang butuh lokasi untuk keperluan lain mendeklarasikan izin lokasinya sendiri. Deklarasi app menang atas `maxSdkVersion` plugin.
- App yang menurunkan lokasi dari hasil scan Bluetooth harus memakai `tools:replace="android:usesPermissionFlags"` pada `BLUETOOTH_SCAN`.
- `neverForLocation` hanya berlaku untuk app dengan `targetSdk` ≥ 31.

Perubahan ini menuntut perubahan kode di API lama pada rilis yang sama. Izin yang tidak dideklarasikan selalu terbaca `DENIED` dan langsung ditolak saat diminta, jadi kode yang masih menanyakan lokasi kasar akan membuat Bluetooth gagal:
- `hasRequiredBluetoothPermissions()` (dipakai `isPermissionBluetoothGranted`) kini memakai `BluetoothRequirementPolicy.connectPermissions`. API 31+ butuh Perangkat sekitar, dan API ≤ 30 tidak butuh izin runtime. Pengecekan juga memakai application context, jadi tidak lagi NPE saat `activity == null`.
- `getBondedDevices` tidak lagi meminta lokasi (perangkat terpasang tidak butuh lokasi di versi mana pun). Di API 31+ ia tidak lagi meminta `ACCESS_FINE_LOCATION`, karena tanpa lokasi kasar yang dideklarasikan Android 12+ selalu menolak permintaan itu. Panggilan kedua saat dialog masih terbuka kini ditolak `request_in_progress` alih-alih menimpa `pendingResult`.

## 2. API Dart

Semua tipe diekspor dari `package:blue_thermal_printer/printer_backend.dart`.

`PrinterBackend` **tidak berubah**. Interface itu berupa `abstract interface class`, jadi menambah member akan mematahkan setiap implementasi dan fake di test. Fitur baru dibuat sebagai *kemampuan opsional* yang diambil lewat satu fungsi:

```dart
final power = printerFeature<TransportPowerControl>(backend);   // null bila tidak didukung
final scanner = printerFeature<PrinterDeviceScanner>(backend);
final prerequisites = printerFeature<TransportPrerequisites>(backend);
```

`printerFeature` adalah satu-satunya tempat yang tahu cara menembus `PrinterBackendEscpos` (ke transport-nya) dan `PrinterBackendFallback` (ke backend aktif). Printer bawaan, LAN, dan USB saat ini mengembalikan `null`. Transport lain bisa mengimplementasikan interface yang sama nanti, misalnya pencarian mDNS untuk LAN.

| Interface | Isi |
|---|---|
| `TransportPowerControl` (`transport_power.dart`) | `powerState()`, `watchPowerState()`, `setEnabled(bool)` → `PowerToggleOutcome` (`changed`, `alreadyInState`, `declinedByUser`, `openedSystemSettings`) |
| `PrinterDeviceScanner` (`device_scanner.dart`) | `scan({timeout})` → `Stream<ScanEvent>` (`ScanStarted`, `DeviceFound(DiscoveredPrinter)`, `ScanFinished(reason)`), `isScanning`, `stopScan()`, `pair(device)` |
| `TransportPrerequisites` (`transport_prerequisites.dart`) | `checkPrerequisites()` (tanpa dialog) → `PrerequisiteReport`, `resolve(item)` (maksimal satu dialog/layar Setelan) |

`PrerequisiteReport` menyediakan `requiredFor(op)` (untuk checklist), `missingFor(op)`, `isSatisfiedFor(op)`, dan `nextStepFor(op)` (satu langkah yang perlu ditampilkan UI). `Prerequisite.label` dan `.message` adalah teks Indonesia siap tampil.

Perilaku penting `BluetoothControl` (`bluetooth_control.dart`):
- Tidak ada method yang melempar. Platform tanpa channel (desktop, test) terbaca sebagai "tidak ada Bluetooth".
- `scan()` bersifat single-flight. Stream selalu diakhiri `ScanFinished`, dan prasyarat yang belum terpenuhi dilaporkan sebagai `ScanFinished(failed, failure)`. Pencarian berhenti bila pendengar terakhir berhenti mendengarkan.
- Pencarian **ditolak selama `printReceipt` berjalan**, karena discovery memangkas throughput SPP (`bindPrintActivity`, dipasang oleh `PrinterBackendEscpos`).
- `PrinterBackendEscpos.connect()` menghentikan pencarian yang sedang berjalan lebih dulu.
- `setEnabled(true)` dengan hasil `changed` menunggu radio benar-benar `on` (maksimal 5 dtk), supaya laporan prasyarat sesudahnya sudah akurat.
- `pair()` menunggu sampai 65 dtk. Native sendiri menyerah setelah 60 dtk, waktu yang cukup untuk mengetik PIN.
- Satu langganan `EventChannel` untuk semua instance. Tiap `receiveBroadcastStream` baru akan menimpa sink di native.
- `DiscoveredPrinter.isLikelyPrinter` (Class of Device Imaging/Printer, atau class kosong + nama khas printer) **hanya untuk pengurutan**, bukan penyaring. Printer murah sering melaporkan class kosong.

`PrinterBackend.discoverDevices()` tetap berarti perangkat yang sudah terpasang; perilaku lamanya tidak berubah.

## 3. Native

Paket `transport/bluetooth/`, terisolasi dari switch ESC/POS di `BlueThermalPrinterPlugin.java`. Plugin utama hanya mendaftarkannya dan meneruskan attach/detach Activity.

- `BluetoothControlChannel`: method `prerequisites`, `requestPermissions{permissions}`, `powerState`, `setEnabled{enabled}`, `startScan{timeoutMillis}`, `stopScan`, `pair{address}`, `openBluetoothSettings`, `openLocationSettings`, `openAppSettings`. Event (`.../bluetooth/events`): `power{state}`, `scanStarted`, `found{address,name,rssi,deviceClass,bonded}`, `scanFinished{reason}`, `bond{address,state}`.
- Kode galat: `permission_denied`, `adapter_off`, `location_off`, `no_activity`, `request_in_progress`, `pair_rejected`, `pair_timeout`, `pair_failed`, `scan_failed`, `unsupported`.
- Satu permintaan tertunda per jenis (izin, dialog nyalakan, pairing). Activity yang terlepas saat dialog terbuka menyelesaikan `Result` yang tertunda, jadi Dart tidak menunggu selamanya.
- Receiver sistem hanya terdaftar selama dibutuhkan (ada pendengar, sedang mencari, atau sedang pairing), dan dilepas di `dispose()`.
- Pencarian yang sudah berjalan dari luar (mis. Setelan) dipakai apa adanya, tidak dibatalkan. Membatalkannya akan memicu `DISCOVERY_FINISHED` yang langsung menutup pencarian app.
- Perangkat BLE-only dilewati karena SPP butuh Bluetooth Classic.
- Semua operasi cepat dan tidak memblokir, jadi dijalankan di main thread; hasilnya datang lewat broadcast.

**Batasan "ditolak permanen".** Android tidak punya API untuk ini. Plugin memakai pola umum: setelah dialog ditolak dan `shouldShowRequestPermissionRationale` tetap `false`, izin dicatat permanen di `SharedPreferences` sampai diberikan. Dialog yang ditutup tanpa memilih juga bisa tercatat permanen. UI tetap menawarkan "Buka Setelan Aplikasi", yang selalu bisa menyelesaikannya.

## 4. Pola UX (implementasi acuan: `parkways_valet`)

Ada di `lib/features/config/presentation/widgets/bluetooth_printer_panel.dart` dan file `bluetooth_power_tile.dart`, `printer_prerequisite_card.dart`, `printer_scan_section.dart`. Urutan dari atas mengikuti alur pengguna:

1. **Saklar Bluetooth.** Status hidup, termasuk perubahan dari luar app. Selama transisi, saklar diganti spinner. Mematikan saat printer tersambung meminta konfirmasi. Di Android 13+ Setelan dibuka, disertai pesan.
2. **Kartu prasyarat progresif.** Kartu berisi checklist dan **satu** tombol untuk langkah berikutnya saja. Izin tidak diminta hanya karena panel dibuka, hanya saat pengguna menekan aksi. Prasyarat khusus pencarian (lokasi di Android ≤ 11) baru muncul setelah "Cari Printer" ditekan, jadi printer yang sudah terpasang tetap bisa dipakai tanpa izin lokasi. Status diperiksa ulang saat app kembali dari Setelan.
3. **Printer terpasang.** Daftar lama, perilaku tetap.
4. **Printer baru.** "Cari Printer" menampilkan hasil bertahap: kemungkinan printer di atas, lalu sinyal terkuat. Perangkat tanpa nama dilipat. Tap memulai pairing (dialog PIN sistem, dengan petunjuk PIN umum 0000/1234), lalu otomatis menyambung. Pencarian berhenti saat panel ditutup atau app ke latar.

## 5. Test

- Plugin: `test/bluetooth_control_test.dart` (laporan prasyarat, nyala/mati, pencarian, pairing, `printerFeature`, integrasi dengan `PrinterBackendEscpos`) dan `default_channel_wiring_test.dart` (nama method/argumen sama dengan Java).
- JUnit: `BluetoothRequirementPolicyTest` (API 28/30/31/33, ditolak permanen, tanpa Activity).
- App: `test/features/config/bluetooth_printer_panel_test.dart`.

## 6. Checklist hardware

- [ ] **Xcheng O1 (Android 9, API 28):** saklar menyalakan/mematikan langsung tanpa dialog.
- [ ] O1: tanpa izin lokasi, "Cari Printer" memunculkan kartu prasyarat lokasi. Setelah diizinkan, printer BT eksternal ditemukan.
- [ ] O1: **regresi penghapusan `ACCESS_COARSE_LOCATION`**. Hanya dengan lokasi presisi, pencarian menemukan printer, dan printer yang sudah terpasang tetap bisa disambung + cetak.
- [ ] O1: pastikan apakah pencarian di API 28 menemukan perangkat saat **layanan Lokasi OFF**. Saat ini plugin hanya mewajibkan Lokasi ON di API 29–30. Bila di O1 hasilnya kosong, perluas `requiresLocationService` ke API 23+.
- [ ] O1: pairing dengan PIN (0000/1234), lalu otomatis tersambung dan bisa mencetak. PIN salah menampilkan "Pemasangan dibatalkan atau PIN salah."
- [ ] **Perangkat Android 13+:** nyalakan memunculkan dialog sistem; "Tolak" mengembalikan saklar dan menampilkan pesan. Matikan membuka Setelan + pesan.
- [ ] Android 13+: izin Perangkat sekitar ditolak dua kali memunculkan "Buka Setelan Aplikasi". Tidak ada permintaan lokasi sama sekali.
- [ ] Android 12+: daftar printer terpasang tetap muncul setelah `ACCESS_COARSE_LOCATION` dihapus.
- [ ] Android 10–11 (bila ada perangkatnya): Lokasi OFF membuat pencarian diblokir dengan tombol "Aktifkan Lokasi".
- [ ] Bluetooth dimatikan di tengah pencarian berakhir `adapterOff`, dan UI pulih. Bluetooth dimatikan saat tersambung: koneksi lama dibersihkan dan connect ulang setelah menyala berhasil.
- [ ] Cetak struk saat panel terbuka: tombol cari ditolak selama pengiriman.

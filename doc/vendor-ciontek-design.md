# Vendor Ciontek (`PrinterBackendCiontek`)

Status: **diimplementasikan dan diuji di Ciontek CS30** (16 Okt 2026), kecuali kertas dicabut di tengah cetak (§6).

Printer bawaan perangkat Ciontek (CS30 dan sejenisnya) dilayani system service `posmanager`
(`com.ciontek.ciontekposservice.ICiontekPosService`, app sistem `CiontekPosService`, uid system). Servis meneruskan
perintah lewat `libPosApi.so` ke MCU K21 di board, yang menggerakkan modul printer 58 mm. Jalurnya **bukan** Bluetooth atau USB.

## 1. Sumber resmi

Diunduh publik dari [developer.viva.com — Ciontek CS30 SDK](https://developer.viva.com/apis-for-point-of-sale/sdks/vw-one-sdk/):

| File | Isi |
|---|---|
| `ciontek-sdk-cs30Pro-sdk-v1.0.2-20210625.zip` | `sdk/aidl/.../ICiontekPosService.aidl` + `sdk/java/com/ctk/sdk/PosApiHelper.java` |
| `CS30Pro-SDK instructions V1.0.1.pdf` | Bab 3 (Print): urutan panggilan, kode hasil |
| `PosDemoCs32.zip` | Demo resmi, `PrintActivity.java` |

AIDL v1.0.2 berisi 57 method dan **identik** dengan servis `CiontekPosService` v1.0.6 di CS30 (Android 11). Semua kode transaksi
dicocokkan dari bytecode servis. File-nya disalin apa adanya ke `android/src/main/aidl/com/ciontek/ciontekposservice/`.

Ada wrapper Flutter pihak ketiga di pub.dev (`ciontek`, `ciontek_sdk_flutter`). Keduanya tidak resmi dan tidak dipakai.

## 2. Keputusan

- **AIDL resmi + bridge sendiri, tanpa `PosApiHelper`.** `PosApiHelper` adalah singleton dan menelan `RemoteException` menjadi -5555.
  Kelas itu juga mengekspos API sensitif (install ROM, tulis SN, daftar putih aplikasi). Cara mengambil servisnya tetap sama dengan
  `PosApiHelper`: refleksi `ServiceManager.getService("posmanager")`. Di CS30 cara ini lolos untuk app biasa, tanpa peringatan hidden API.
- **Descriptor dicek** (`getInterfaceDescriptor()`), supaya perangkat lain yang kebetulan punya servis bernama `posmanager` tidak terdeteksi.
- **Raster, bukan teks.** Struk dirender `ReceiptRenderer` (384 px), lalu dipecah per strip `STRIP_HEIGHT_PX = 480`. Batas resmi
  `Lib_PrnBmp` adalah tinggi ≤ 500 dan lebar ≤ 384. Tiap strip dikomposit ke latar putih.
- **Satu lock perangkat keras** (`CiontekPrinterBridge.hardwareLock`). Query status yang datang selama mencetak menjawab `null`
  (`unknown`) tanpa IPC, karena panduan resmi melarang proses cetak diganggu.
- **Urutan deteksi:** Xcheng → iMin → iMin USB → **Ciontek** → Sunmi.
- **Risiko:** app konsumen yang juga memasang SDK Ciontek (AIDL/jar dengan package `com.ciontek.ciontekposservice`) akan mendapat
  *duplicate class*. Bila itu terjadi, app tersebut cukup memakai backend plugin ini.

## 3. Alur cetak (`CiontekPrinterBridge.runPrint`)

`Lib_PrnInit` → `Lib_PrnBmp` per strip → `Lib_PrnStep(feedPixels = 96)` → `Lib_PrnStart`.

`Lib_PrnStart` berjalan sinkron dan kembali setelah kertas selesai tercetak: struk 120 baris butuh ±7,3 dtk. Bila `Lib_PrnBmp`
mengembalikan `-4008` (buffer penuh), isi buffer dicetak lebih dulu, lalu sisa struk dilanjutkan tanpa feed sehingga tetap menyambung.
Kasus ini tidak muncul pada struk 120/200 baris di CS30.

## 4. Kode hasil

`Lib_PrnCheckStatus` → `ciontekStatusToPrinterStatus` (Dart):

| Kode | Arti | `PrinterStatus` |
|---|---|---|
| 0 | normal | `hasPaper: true, hasError: false` |
| -1 | kertas habis | `hasPaper: false` |
| -2 / -3 | suhu tinggi / tegangan baterai rendah | `hasError: true` |
| ±1001 / ±1002 | gagal kirim / tidak ada balasan dari modul (§6) | `hasError: true` |
| lain / `null` | — | `unknown` (tidak memblokir) |

`Lib_PrnStart` → `CiontekResultCodes.startOutcome` (Java, JUnit):

| Kode | Hasil |
|---|---|
| 0 | `printed` |
| -1, -1014, -1015, -1021 (kertas), -2, -1022 (panas), -3 (tegangan), -1023, -1007..-1012 | `failed` |
| timeout, ±1001/±1002, 8/9, tak terdokumentasi | `unknown` → post-check status |

Kemampuan: `384 px, autoCut: false, reportsPaperOut: true, confirmsPrint: true`.

## 5. Hasil uji hardware (Ciontek CS30, Android 11, 16 Okt 2026)

App uji: salinan `example/` dengan `--dart-define`, grup `ciontek` dan `ciontekmanual` di `example/lib/harness.dart`.

| Kasus | Hasil |
|---|---|
| CK1 `detectBuiltInPrinterVendor()` | `innerCiontek`. Panggilan channel pertama di build debug ±4 dtk (cold start), probe-nya sendiri cepat |
| CK2 connect / isConnected / ensureConnected | lulus, 8–17 ms setelah hangat |
| CK3 status | kertas ada `0` (±85 ms); tanpa gulungan `-1` (±110 ms), terverifikasi penguji |
| CK4–CK5 capabilities, preview 384 px | lulus |
| CK6 struk lengkap | `confirmed`, 0,7 dtk |
| CK7 120 baris (multi-strip) | `confirmed`, 7,3 dtk, utuh menyambung |
| CK8 3 QR | ketiganya terbaca |
| CK9 cetak bersamaan | satu tercetak, satu `busy`; status selama cetak `unknown` dalam 4 ms |
| CK10 disconnect → Err → pulih | lulus, hanya struk "pulih" yang keluar |
| CK11 cetak tanpa kertas | ditolak 97 ms ("Kertas printer habis."), tanpa `PrnInit`/`Prn_Start` di log; tidak ada struk menyusul setelah kertas dipasang |
| CK12 kertas dicabut di tengah cetak | **belum teruji** (dilewati penguji) |

Penguji mengonfirmasi tepat 5 struk keluar di CK6–CK10, cetakan cukup hitam, dan baris terakhir melewati gigi sobek (feed 96 dot cukup).

## 6. Temuan: MCU printer bisa macet sampai perangkat di-restart

Dua kali selama sesi uji, MCU berhenti menjawab semua paket (log `VPOS`: `---resp err = -2500` per paket, 3–5 dtk).

- `Lib_PrnCheckStatus` butuh ±17,4 dtk lalu mengembalikan `-1002`.
- `Lib_PrnStart` mengembalikan `-1002` setelah ±6,5 dtk.
- Kondisi ini hanya pulih dengan restart perangkat.

Tanpa kertas, servis menjawab `-1` dari sensor tanpa bertanya ke MCU, sehingga kondisi macet ini tidak terlihat.

Pemicunya belum ditemukan. Yang sudah diuji dan **bukan** pemicu:

- layar mati 90 dtk;
- menganggur 2 menit dengan layar menyala;
- `adb install -r`;
- deteksi vendor + connect;
- memasang kertas kembali.

Setelah `adb reboot`, seluruh suite berjalan bersih tanpa satu pun timeout.

Mitigasi di plugin: `±1001/±1002` dari status = galat. Cetak ditolak dengan "Printer melaporkan galat." alih-alih dikirim lalu
dilaporkan `unverified`. Setiap query di kondisi ini tetap memakan ±17 dtk, karena panggilan binder tidak bisa dibatalkan.

## 7. Belum teruji / tindak lanjut

- Kertas habis di tengah cetak (kode `Lib_PrnStart` dan apakah sisa data ditahan servis).
- Suhu tinggi (-2) dan tegangan rendah (-3).
- Pemicu macetnya MCU (§6). Bila terulang di lapangan, kumpulkan `adb logcat -s VPOS` dan riwayat kejadian sebelum macet.
- Model Ciontek lain (CS30Pro, CS50C, CS20). `libposapi.jar` versi lebih baru (208 method, beredar di wrapper pihak ketiga)
  mempertahankan nomor transaksi ke-57 method pertama, jadi AIDL ini tampaknya append-only. Descriptor dan kode transaksi tetap
  perlu dicek ulang per model.

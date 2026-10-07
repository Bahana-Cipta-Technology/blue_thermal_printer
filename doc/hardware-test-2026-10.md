# Hasil uji hardware, 7 Okt 2026

Perangkat: iMin D1 (Android 11, SDK 30) lewat debug nirkabel. App uji: `example/` (lihat `example/README.md`).
Plugin diuji dari HEAD `434e457` ditambah perbaikan di bawah.

## Temuan dan perbaikan

**Scan, pairing, dan event nyala/mati Bluetooth tidak bekerja di Android < 13.**
`BluetoothControlChannel.updateReceiver()` mendaftarkan receiver broadcast sistem dengan `RECEIVER_NOT_EXPORTED`.
Di Android < 13 `ContextCompat` lalu memasang izin kustom `<paket>.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION`
pada receiver, dan sistem menolak broadcast dari proses Bluetooth:

```
W BroadcastQueue: Permission Denial: broadcasting Intent { act=android.bluetooth.device.action.FOUND ... }
  requires com.<app>.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION
```

Akibatnya `ScanStarted`/`DeviceFound` tidak pernah sampai, `isScanning` selalu false, dan `watchPowerState` bisu.
Perbaikan: `RECEIVER_EXPORTED`. Kelima aksi (`STATE_CHANGED`, `DISCOVERY_STARTED/FINISHED`, `FOUND`,
`BOND_STATE_CHANGED`) adalah broadcast sistem terlindungi, jadi tidak bisa dipalsukan app lain.
Sebelum perbaikan: F5 dan F6 gagal. Sesudahnya semua lulus dan tidak ada lagi baris `Permission Denial`.

## Hasil per kasus (setelah perbaikan)

| Grup | Kasus | Hasil |
|---|---|---|
| status, gate, receipt | S1, G1, R1 | lulus |
| vendor | V1 `detectBuiltInPrinterVendor()` | `null`: D1 tidak punya servis iMin SDK 2.0/Sunmi/Xcheng |
| vendor | V2, V3 | lulus. Backend bawaan mengembalikan `Err` bersih tanpa exception saat servis tidak ada |
| control | F1–F7 | lulus. Scan menemukan perangkat sekitar, `stopScan` berakhir `stopped`, `pair` pada printer ter-pairing OK |
| control (disruptif) | F8 | lulus: `turningOff → off → turningOn → on` |
| control (disruptif) | F9 | lulus: Bluetooth dimatikan di tengah scan berakhir `adapterOff` |
| control (disruptif) | F10 | lulus: tersambung, Bluetooth mati lalu nyala, `ensureConnected` pulih |
| core | C1–C13 | lulus |
| print | P1–P7 | data terkirim tanpa galat (`unverified`), tetapi **tidak ada struk keluar**: target P1–P7 adalah printer Bluetooth virtual D1 (lihat "Printer bawaan iMin D1") |
| lan (server palsu) | L1–L8 | lulus. Port kertas habis, cover terbuka, dan galat hanya menerima query status 19 byte, tanpa data struk. Port normal menerima ESC @ + 4 pita `GS v 0`. Port bisu tetap mencetak tanpa `GS I` |
| lan nyata (192.168.110.169:9100) | RL1–RL12 | lulus. Status terbaca (kertas ada, cover tertutup), auto-cut terdeteksi (`autoCut=true`), lebar otomatis 576 px. Struk keluar (dikonfirmasi penguji) |
| usb | U1 | lulus tanpa perangkat USB |
| legacy | H1 | lulus |

## Printer bawaan iMin D1

Struk dari jalur Bluetooth virtual tidak pernah keluar, walau `printReceipt` melaporkan `unverified` tanpa galat.
Penyebab dan jalur penggantinya ada di `doc/vendor-imin-design.md` §4.6. Ringkasnya:

| Kasus | Hasil |
|---|---|
| Uji cetak app resmi iMin (`com.imin.printer`) | keluar (pembanding; memakai USB langsung) |
| VB1 struk mini 2,4 KB lewat Bluetooth virtual | **tidak keluar**; log `VirtualBluetoothService` → `UsbDriver: Length -1` untuk setiap tulis, termasuk query status 3 byte |
| IU1 USB `discoverDevices` | `althicoA726` `usb:1305:8211` (+ adapter LAN USB yang tidak dipakai) |
| IU2 connect | dialog izin USB muncul, setelah OKE tersambung (±8 dtk termasuk dialog) |
| IU3 `checkStatus` | dijawab: kertas ada, cover tertutup, tanpa galat (±130 ms) |
| IU4 `capabilities` | 384 px, `autoCut=false`, `reportsPaperOut=true`; printer tidak menjawab `GS I 2` |
| IU5–IU9 cetak (lengkap, 120 baris, 3 QR, lebar ×3, bersamaan + pulih) | **8 struk keluar sesuai harapan** (dikonfirmasi penguji); struk 120 baris ±11,8 dtk |
| IB1 `detectBuiltInPrinterVendor()` | `innerIminUsb` dalam ±350 ms, tanpa dialog izin |
| IB2 `innerIminUsb.ensureConnected()` tanpa `lastDevice` | tersambung, status terbaca |
| IB3 `innerIminUsb.printReceipt` | terkirim |

Izin USB yang sudah diberikan tetap berlaku setelah app di-force-stop; diminta lagi setelah reboot atau printer dilepas.

## Catatan perilaku

- Printer SPP virtual D1 (`BluetoothPrinter`, 00:11:22:33:44:55) tidak menjawab `DLE EOT` dan tidak mencetak sama sekali (lihat atas).
  Kasus P1–P7 di tabel atas hanya membuktikan data terkirim ke layanan virtual, bukan struk keluar.
- Sebelum cetakan pertama pada koneksi baru, `capabilities()` masih `paperWidthPx=384, autoCut=false`; sesudah cetakan pertama
  printer LAN 80 mm berubah menjadi 576 px dan `autoCut=true` (sesuai desain).
- Waktu cetak (data terkirim): Bluetooth SPP 18–32 ms per struk pendek setelah tersambung, ±3 dtk pada cetakan pertama
  setelah connect (probe status). LAN asli ±1 dtk per struk.

## Belum teruji

- Printer bawaan iMin SDK 2.0, Sunmi, dan Xcheng: perangkat uji tidak punya servisnya.
- iMin SDK 1.0 selain D1 (ID USB printer bisa berbeda).
- USB dengan printer sungguhan.
- Pairing printer baru (butuh perangkat discoverable dengan PIN).
- Android 13+ (dialog nyalakan Bluetooth, izin Perangkat sekitar).

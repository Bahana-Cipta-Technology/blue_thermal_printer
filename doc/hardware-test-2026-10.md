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
| print | P1–P7 | data terkirim tanpa galat (`unverified`). **Kondisi kertas fisik menunggu konfirmasi penguji** |
| lan (server palsu) | L1–L8 | lulus. Port kertas habis, cover terbuka, dan galat hanya menerima query status 19 byte, tanpa data struk. Port normal menerima ESC @ + 4 pita `GS v 0`. Port bisu tetap mencetak tanpa `GS I` |
| lan nyata (192.168.110.169:9100) | RL1–RL12 | lulus. Status terbaca (kertas ada, cover tertutup), auto-cut terdeteksi (`autoCut=true`), lebar otomatis 576 px. Struk fisik menunggu konfirmasi penguji |
| usb | U1 | lulus tanpa perangkat USB |
| legacy | H1 | lulus |

## Catatan perilaku

- Printer SPP bawaan D1 (`BluetoothPrinter`, 00:11:22:33:44:55) tidak menjawab `DLE EOT`: `checkStatus()` mengembalikan
  semua `null` (unknown), `reportsPaperOut=null`, `autoCut=false`, lebar otomatis 384 px. Kertas habis tidak bisa dideteksi di jalur ini.
- Sebelum cetakan pertama pada koneksi baru, `capabilities()` masih `paperWidthPx=384, autoCut=false`; sesudah cetakan pertama
  printer LAN 80 mm berubah menjadi 576 px dan `autoCut=true` (sesuai desain).
- Waktu cetak (data terkirim): Bluetooth SPP 18–32 ms per struk pendek setelah tersambung, ±3 dtk pada cetakan pertama
  setelah connect (probe status). LAN asli ±1 dtk per struk.

## Belum teruji

- Printer bawaan iMin SDK 2.0, Sunmi, dan Xcheng: perangkat uji tidak punya servisnya.
- USB dengan printer sungguhan.
- Pairing printer baru (butuh perangkat discoverable dengan PIN).
- Android 13+ (dialog nyalakan Bluetooth, izin Perangkat sekitar).

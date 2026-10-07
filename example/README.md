# App uji hardware kontrak `PrinterBackend`

App ini menjalankan tiap fungsi kontrak plugin ke perangkat dan printer sungguhan.
Hasilnya tampil di layar dan dicetak ke logcat dengan format:

```
HARNESS|<grup>|<id>|<PASS/FAIL/SKIP/INFO>|<ms>ms|<catatan>
HARNESS|BATCH|<label>|SUMMARY|0ms|pass=.. fail=.. skip=.. info=..
```

## Menjalankan

```bash
cd example
flutter pub get
flutter build apk --debug && adb install -r build/app/outputs/flutter-apk/app-debug.apk
adb logcat -s flutter:V | grep HARNESS
```

Di Android 10–11 beri izin lokasi dan nyalakan layanan Lokasi supaya scan bisa jalan:

```bash
adb shell pm grant id.kakzaki.blue_thermal_printer_example android.permission.ACCESS_FINE_LOCATION
adb shell settings put secure location_mode 3
```

## Tombol

| Tombol | Isi |
|---|---|
| Aman | Semua kasus yang tidak mencetak, tidak mengubah Bluetooth, dan tidak butuh LAN: status, gate, receipt, vendor, kontrol Bluetooth (prasyarat, scan, pair), backend inti, USB, API lama |
| Cetak fisik | `P1`–`P7`: struk lengkap, bersamaan, panjang, QR, lebar kertas, beruntun, pulih setelah putus. Mengeluarkan beberapa struk dari printer Bluetooth |
| Disruptif | `F8`–`F10`: mematikan dan menyalakan Bluetooth perangkat, termasuk di tengah scan dan saat tersambung |
| LAN | `L1`–`L8` terhadap server TCP palsu (lihat bawah) |
| LAN nyata | `RL1`–`RL12` terhadap printer jaringan sungguhan; isi kolom "Host PC" dengan IP printer (port default 9100). Mencetak beberapa struk |

Kolom MAC Bluetooth boleh kosong: printer dipilih otomatis dari perangkat ter-pairing yang namanya mengandung "printer".

## Server printer palsu untuk uji LAN

`tool/fake_printer.py` membuka lima port yang menjawab query status `DLE EOT` dengan byte berbeda
(normal, kertas habis, cover terbuka, galat, bisu) dan menyimpan byte yang diterima:

```bash
python3 tool/fake_printer.py /tmp/lan-out        # port 19100..19104
for p in 19100 19101 19102 19103 19104; do adb reverse tcp:$p tcp:$p; done
```

Isi kolom host dengan `127.0.0.1:19100` lalu tekan LAN. `adb reverse` dipakai agar firewall PC tidak menghalangi.
Periksa `/tmp/lan-out/port*.bin`: port normal menerima `ESC @` + pita raster `GS v 0`; port kertas habis, cover, dan galat
hanya menerima query status (tidak ada data struk).

# CLAUDE.md

File ini berisi panduan untuk Claude Code (claude.ai/code) saat bekerja dengan kode di repository ini.

## Tentang project ini

Ini adalah fork internal dari paket pub.dev `blue_thermal_printer` (upstream: `kakzaki/blue_thermal_printer`), dikelola di `Bahana-Cipta-Technology/blue_thermal_printer`. Plugin ini **sama sekali tidak mengonsumsi SDK vendor/pabrikan printer apa pun** — semuanya dibangun dari komponen generik/universal: API Bluetooth Classic bawaan Android (`BluetoothSocket` lewat UUID SPP standar `00001101-0000-1000-8000-00805F9B34FB`) untuk koneksi, dan byte command ESC/POS (protokol terbuka, tidak terikat merek printer manapun) yang ditulis manual untuk semua data yang dikirim ke printer. Bitmap QR di-generate pakai ZXing, itu pun cuma buat rendering lokal, bukan komunikasi ke printer. Karena arsitektur ini, plugin bisa nyambung ke printer merek apa saja asal dia "ngerti" Bluetooth SPP + ESC/POS (cakup hampir semua printer thermal struk murah) — tapi plugin ini **tidak akan pernah** punya fitur yang butuh SDK proprietary pabrikan (misal callback sensor kertas/cover real-time, atau tuning kualitas cetak yang dijamin vendor). Pertahankan desain ini: jangan gabungkan SDK vendor ke dalam repo ini — kalau suatu saat dibutuhkan, itu harus jadi plugin terpisah yang berdiri di belakang interface `PrinterService` milik app konsumen.

Repo ini dipakai app `parkways_valet` (Flutter) lewat **git submodule + `path:` dependency** (bukan dipublish ke pub.dev). App itu cuma pakai 7 pemanggilan dari seluruh API yang ada: `isOn`, `getBondedDevices`, `isPermissionBluetoothGranted`, `connect`, `disconnect`, `isConnected`, `writeBytes` — dia bikin sendiri byte struk ESC/POS-nya dan sama sekali tidak menyentuh helper `print*`/`drawerPin*`/pencetakan gambar yang ada di plugin ini.

**Dukungan platform pada praktiknya cuma Android.** `ios/Classes/SwiftBlueThermalPrinterPlugin.swift` dan versi macOS-nya itu cuma stub registrasi yang mengabaikan `call.method` sepenuhnya — apa pun method yang dipanggil, dia selalu balikin string versi device. Artinya manggil apa pun (`isOn`, `connect`, dst) di iOS/macOS bakal balikin `String` padahal yang diharapkan `bool`/list/dst, dan bakal error/cast exception di sisi Dart. Anggap iOS/macOS **tidak fungsional** — tabel platform di README (yang menandai semua platform selain Android sebagai tidak didukung) itu yang benar. `pubspec.yaml` tidak lagi mendaftarkan plugin class untuk `ios`/`macos` (dihapus supaya metadata tooling konsisten dengan status "tidak fungsional" ini); kalau dua platform itu suatu saat diimplementasikan sungguhan, daftarkan lagi entrinya di `flutter.plugin.platforms`.

## Bahasa penamaan (naming)

Semua identifier — nama class, method, variable, parameter, nama file, dll., baik di Dart maupun Java — **wajib Bahasa Inggris**. Komentar dan dokumentasi (doc comment, README, isi CHANGELOG) boleh Bahasa Indonesia. Aturan ini cuma soal penamaan/identifier, bukan soal komentar.

## Command yang sering dipakai

```bash
flutter pub get                 # dijalankan di folder ini
flutter analyze                 # bersih (analysis_options.yaml berbasis flutter_lints)
flutter test                    # jalan; lihat test/blue_thermal_printer_test.dart untuk cakupan mock MethodChannel
cd example && flutter pub get && flutter run   # smoke test manual ke printer fisik
```

Repo ini sekarang punya `analysis_options.yaml` (berbasis `package:flutter_lints/flutter.yaml`, mengecualikan `example/**` karena itu project Flutter terpisah dengan pubspec/lockfile sendiri) tapi tetap tidak ada CI selain bot penutup issue basi (`.github/workflows/stale.yml`) — tidak ada yang otomatis jalanin test/build tiap push. `flutter test` sekarang cuma memvalidasi kontrak `MethodChannel` lewat mock (tanpa hardware); verifikasi behavior native (koneksi, tulis byte ke printer sungguhan) tetap harus lewat build app konsumen (`flutter build apk --debug` di `parkways_valet`) lalu tes ke printer fisik — karena Bluetooth Classic gak bisa dites di lingkungan VM `flutter test` maupun target desktop Linux.

## Arsitektur

Satu `MethodChannel` (`blue_thermal_printer/methods`) untuk semua pemanggilan request/response, plus dua `EventChannel`: `.../state` (broadcast adapter Bluetooth + status ACL connect/disconnect, diekspos lewat `onStateChanged()`) dan `.../read` (byte yang dibaca balik dari `InputStream` printer, diekspos lewat `onRead()`). Sisi Dart (`lib/blue_thermal_printer.dart`) itu singleton (`BlueThermalPrinter.instance`), bukan class static murni.

Semua logic native ada di satu file: `android/src/main/java/id/kakzaki/blue_thermal_printer/BlueThermalPrinterPlugin.java` (satu `switch` besar berdasarkan `call.method` di dalam `onMethodCall`), plus dua helper kecil — `PrinterCommands.java` (konstanta byte ESC/POS mentah: align, feed, potong kertas, buka laci kasir) dan `Utils.java` (konversi bitmap → raster ESC/POS buat cetak gambar/QR).

Model threading yang perlu diperhatikan kalau mau menyentuh kode native:
- `connect`/`disconnect` jalan lewat `AsyncTask.execute` (background thread), dijaga satu field `static ConnectedThread connectedThread` — artinya cuma ada **satu** koneksi aktif yang dilacak di level class, bukan per instance plugin.
- Semua method lain (`write`, `writeBytes`, `printCustom`, dst) jalan **synchronous di platform/UI thread** di dalam `onMethodCall` — channel ini tidak didaftarkan pakai `BinaryMessenger.TaskQueue`. Printer yang lambat/gak respon pas nulis bisa bikin UI thread app konsumen ikut macet.
- `ConnectedThread.run()` loop `inputStream.read()` dan kirim tiap byte ke `EventChannel` read; kalau gak ada yang dengerin (`readSink == null`), `NullPointerException` yang muncul bakal diam-diam mematikan thread baca itu selamanya (di-catch, loop-nya langsung `break`).

## Known issues

**Sudah diperbaiki di fork ini** (lihat riwayat commit — perbaikan ini wajib supaya plugin bisa dipakai sama sekali oleh konsumer Dart 3.x/AGP modern, atau buat menutup bug correctness yang nyata):
- `environment.sdk` sebelumnya `>=2.12.0 <3.0.0`, gak cocok sama app Flutter modern manapun; dinaikkan ke `<4.0.0`.
- `android/build.gradle` gak punya `namespace` AGP (wajib buat AGP 8+) dan `compileSdkVersion`-nya masih 31, yang bikin gagal di pengecekan AAR-metadata terhadap versi AndroidX transitif modern; keduanya sudah dinaikkan (`compileSdkVersion 36`).
- Cabang permintaan izin Android 12+ di `getBondedDevices()` pakai `requestCode` hardcode `1`, padahal `onRequestPermissionsResult` cuma cocok sama `REQUEST_COARSE_LOCATION_PERMISSIONS` (`1451`) — `Result` yang pending gak pernah ke-resolve, jadi percobaan pertama grant izin di API 31+ hang selamanya. Sekarang kedua cabang pakai request code yang sama.
- Ditambahkan `isPermissionBluetoothGranted` (native `hasRequiredBluetoothPermissions()` + getter Dart) — cara cek status izin tanpa efek samping memicu dialog permintaan izin, sesuai kebutuhan konsumer sebelum mencoba `connect()`.
- `com.android.support:multidex` (gak dipakai, dari grup support-library pre-AndroidX yang sudah *frozen*) sudah dihapus; `androidx.appcompat`, `com.google.zxing:core`, dan `com.journeyapps:zxing-android-embedded` sudah dinaikkan ke versi terbaru.
- `ConnectedThread.write(byte[])` dulu menelan `IOException` secara internal (cuma `printStackTrace()`, gak dilempar lagi), jadi `writeBytes`/`write`/`print*` di plugin ini manggil `result.success(true)` **tanpa syarat**, bahkan pas penulisan fisik ke socket-nya gagal. Sekarang `write(byte[])` mengembalikan `boolean` dan tiap pemanggil (semua method yang menulis ke printer) memeriksa hasilnya lewat helper `writeOrFail(...)`, mengembalikan `result.error("write_error", ...)` kalau tulis fisik gagal.
- `onRequestPermissionsResult` dulu cuma cek `grantResults[0]`, bukan seluruh array — grant sebagian (misal `BLUETOOTH_SCAN` diizinkan tapi `BLUETOOTH_CONNECT` ditolak) tetap dianggap granted penuh. Sekarang mensyaratkan semua elemen `grantResults` granted.
- Dulu gak ada timeout di sekitar pemanggilan blocking `socket.connect()`; device yang gak respon bisa bikin percobaan connect hang tanpa batas waktu. Sekarang dibungkus `ExecutorService`/`Future.get(CONNECT_TIMEOUT_MILLIS, ...)` (12 detik) yang menutup socket dan mengembalikan `result.error("connect_timeout", ...)` kalau kelamaan.
- Dulu gak ada fallback reflection ke `createRfcommSocket(1)` (channel 1) pas socket RFCOMM secure standar gagal — workaround yang dikenal luas di ekosistem Android BT Classic buat bug "read failed, socket might closed" yang muncul di sejumlah kombinasi device/printer. Sekarang dicoba otomatis (`attemptFallbackConnect`) begitu percobaan standar melempar exception (bukan saat timeout).
- File test bawaan `test/blue_thermal_printer_test.dart` dulu gagal kalau dijalankan (`setMockMethodCallHandler` dipanggil tanpa `TestWidgetsFlutterBinding.ensureInitialized()` duluan, dan channel-nya salah nama), dan satu-satunya assertion sungguhan di situ di-comment. Sekarang ditulis ulang: binding di-init, nama channel benar (`blue_thermal_printer/methods`), dan tiga test nyata memvalidasi `isOn`/`isPermissionBluetoothGranted`/`getBondedDevices` lewat mock `MethodChannel`.
- Repo sekarang punya `analysis_options.yaml` (`package:flutter_lints/flutter.yaml`) yang mengecualikan `example/**` — jadi kalau `flutter analyze`/`flutter test` dijalankan dari root plugin ini, folder `example/` (project Flutter terpisah dengan pubspec/lockfile sendiri) gak ikut dianalisis dan gak bikin gagal palsu.

**Masih terbuka / belum diperbaiki** — sengaja belum disentuh:
- Izin lokasi (`ACCESS_FINE_LOCATION`/`ACCESS_COARSE_LOCATION`) tetap diminta `getBondedDevices()` walau sebenarnya membaca daftar perangkat yang sudah dipasangkan gak butuh izin itu di Android — ini sengaja dipertahankan oleh konsumer yang sekarang buat rencana fitur active-discovery ke depan, bukan karena secara teknis wajib buat baca bonded devices.
- Blok `buildscript { classpath 'com.android.tools.build:gradle:3.5.4' }` di `android/build.gradle` kelihatan usang dibanding `compileSdkVersion 36` di file yang sama, tapi kemungkinan besar gak benar-benar dipakai saat plugin dikonsumsi sebagai submodule (versi AGP didikte `build.gradle`/`settings.gradle` level konsumer `parkways_valet`, bukan file ini). Belum diubah — butuh verifikasi terpisah terhadap build konsumer sebelum disentuh.

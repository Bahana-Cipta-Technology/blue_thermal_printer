import 'package:flutter/services.dart';

import 'built_in_printer_backend.dart';
import 'printer_capabilities.dart';
import 'printer_device.dart';
import 'printer_status.dart';

/// Satu-satunya "perangkat" backend printer bawaan Ciontek -- lihat
/// `kSunmiBuiltInDevice` untuk alasan entri sintetis ini.
const kCiontekBuiltInDevice = PrinterDevice(
  name: 'Printer Bawaan',
  macAddress: 'ciontek-builtin',
);

/// Hasil satu cetakan Ciontek, dari kode `Lib_PrnStart` yang sinkron (kembali
/// setelah selesai mencetak): `printed` = 0, `failed` = kode gagal yang
/// terdokumentasi (kertas habis, panas, tegangan rendah, ...), `unknown` =
/// timeout/kode tak terdokumentasi -- diverifikasi ulang lewat status. Tabel
/// lengkapnya di `CiontekResultCodes.java`.
typedef CiontekPrintOutcome = PrintOutcome;

/// Terjemahkan kode `Lib_PrnCheckStatus` jadi [PrinterStatus].
///
/// Tabel resmi (CS30Pro SDK instructions §3.3): 0 normal, -1 kertas habis,
/// -2 suhu tinggi, -3 tegangan baterai rendah. Servis tidak melaporkan cover,
/// jadi `coverClosed` selalu `null`.
///
/// Di luar tabel itu, `±1001`/`±1002` (gagal kirim / tidak ada balasan dari
/// modul printer, tabel `Lib_PrnStart` §3.2) = galat: di CS30 terbukti muncul
/// saat MCU printer macet (semua paket timeout, cetak juga tidak keluar sampai
/// perangkat di-restart). Menganggapnya `unknown` membuat cetak tetap dikirim
/// lalu dilaporkan "terkirim" padahal tidak ada struk.
///
/// `null` (belum terhubung, sedang mencetak, atau IPC gagal) dan kode lain =
/// [PrinterStatus.unknown], yang sengaja tidak memblokir cetak.
PrinterStatus ciontekStatusToPrinterStatus(int? code) => switch (code) {
  0 => const PrinterStatus(hasPaper: true, hasError: false),
  -1 => const PrinterStatus(hasPaper: false),
  -2 || -3 || -1001 || 1001 || -1002 || 1002 => const PrinterStatus(hasError: true),
  _ => PrinterStatus.unknown,
};

/// Implementasi [BuiltInPrinterBackend] untuk printer bawaan perangkat
/// Ciontek (mis. CS30) lewat AIDL resmi `ICiontekPosService` (system service
/// `posmanager`, SDK resmi CS30Pro v1.0.2), dibungkus native oleh
/// `CiontekPrinterBridge`/`CiontekPrinterChannel` (`android/.../vendor/ciontek/`).
///
/// Pre-check memakai `Lib_PrnCheckStatus`; hasil cetak dari kode
/// `Lib_PrnStart`. Rancangan dan hasil uji hardware:
/// `doc/vendor-ciontek-design.md`.
class PrinterBackendCiontek extends BuiltInPrinterBackend {
  PrinterBackendCiontek({
    super.renderer,
    Future<bool> Function()? bind,
    Future<void> Function()? unbind,
    Future<bool> Function()? isReady,
    Future<int?> Function()? status,
    Future<CiontekPrintOutcome> Function(List<int> png, int feedPixels)?
    printBitmap,
    super.connectPollInterval,
    super.printTimeout,
    super.stuckAfter,
  }) : _bind = bind ?? (() async => await _channel.invokeMethod<bool>('bind') ?? false),
       _unbind = unbind ?? (() => _channel.invokeMethod('unbind')),
       _isReady =
           isReady ?? (() async => await _channel.invokeMethod<bool>('isReady') ?? false),
       _status = status ?? (() => _channel.invokeMethod<int>('status')),
       _printBitmap =
           printBitmap ??
           ((png, feedPixels) async => CiontekPrintOutcome.parse(
             await _channel.invokeMethod<String>('printBitmap', {
               'bytes': Uint8List.fromList(png),
               'feedPixels': feedPixels,
             }),
           )),
       super(device: kCiontekBuiltInDevice);

  static const MethodChannel _channel = MethodChannel('blue_thermal_printer/ciontek');

  /// Dot kosong yang di-feed (`Lib_PrnStep`) setelah struk supaya baris
  /// terakhir melewati tear bar -- 8 dot/mm, jadi 96 = ±12 mm.
  static const feedPixels = 96;

  /// Kemampuan tetap backend ini: `Lib_PrnBmp` menerima lebar maksimal 384
  /// dot (58 mm), tanpa pemotong. Sensor kertas `Lib_PrnCheckStatus` dan hasil
  /// `Lib_PrnStart` terverifikasi di Ciontek CS30 (lihat doc).
  static const capabilitiesValue = PrinterCapabilities(
    paperWidthPx: 384,
    autoCut: false,
    reportsPaperOut: true,
    confirmsPrint: true,
  );

  final Future<bool> Function() _bind;
  final Future<void> Function() _unbind;
  final Future<bool> Function() _isReady;

  /// Kode `Lib_PrnCheckStatus`; `null` = belum terhubung / sedang mencetak /
  /// servis tidak menjawab.
  final Future<int?> Function() _status;
  final Future<CiontekPrintOutcome> Function(List<int> png, int feedPixels)
  _printBitmap;

  @override
  String get displayName => 'Printer Bawaan Ciontek';

  @override
  String get notFoundMessage =>
      'Printer bawaan Ciontek tidak ditemukan di perangkat ini.';

  @override
  Future<bool> bindService() => _bind();

  @override
  Future<void> unbindService() => _unbind();

  /// Servis `posmanager` sudah diambil dan prosesnya masih hidup (tanpa IPC).
  @override
  Future<bool> probeReady() => _isReady();

  @override
  Future<PrinterStatus> readStatus() async =>
      ciontekStatusToPrinterStatus(await _status());

  @override
  Future<PrinterCapabilities?> readCapabilities() async => capabilitiesValue;

  @override
  Future<PrintOutcome> sendRaster(Uint8List png, PrinterCapabilities caps) =>
      _printBitmap(png, feedPixels);
}

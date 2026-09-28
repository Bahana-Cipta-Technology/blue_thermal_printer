import 'package:flutter/services.dart';

import 'built_in_printer_backend.dart';
import 'printer_capabilities.dart';
import 'printer_device.dart';
import 'printer_status.dart';

/// Satu-satunya "perangkat" backend printer bawaan iMin -- lihat
/// `kSunmiBuiltInDevice` untuk alasan entri sintetis ini.
const kIminBuiltInDevice = PrinterDevice(
  name: 'Printer Bawaan',
  macAddress: 'imin-builtin',
);

/// Kode `getPrinterStatus()` resmi untuk "belum tersambung ke servis" --
/// dipakai juga oleh `IminPrinterBridge.STATUS_NOT_READY` selama servis/`fd`
/// belum siap, harus tetap sinkron dengan nilai itu.
const _statusNotReady = -1;

/// Terjemahkan kode `getPrinterStatus()` iMin SDK 2.0 jadi [PrinterStatus].
///
/// Hanya kode yang tercantum di dokumen resmi (§3.3) yang dipetakan: 0
/// normal, 3 cover terbuka, 4 head overheat, 7 kertas habis. Kode lain --
/// termasuk 1/8/99 yang hanya dikenal di SDK 1.0 -- jadi
/// [PrinterStatus.unknown] supaya tidak memblokir cetak tanpa bukti masalah.
/// -1 tidak dipetakan di sini: pemanggil memperlakukannya sebagai "tidak
/// terhubung", bukan status fisik.
PrinterStatus iminStatusToStatus(int code) => switch (code) {
  0 => const PrinterStatus(hasPaper: true, coverClosed: true, hasError: false),
  3 => const PrinterStatus(coverClosed: false),
  4 => const PrinterStatus(hasError: true),
  7 => const PrinterStatus(hasPaper: false),
  _ => PrinterStatus.unknown,
};

/// Hasil satu transaksi cetak iMin (`exitPrinterBufferWithCallback` →
/// `onPrintResult`): `failed` juga untuk `onRaiseException`; `unknown` bila
/// callback tidak datang dalam batas waktu, atau kode `onPrintResult` belum
/// terverifikasi di hardware (dokumen resmi kontradiktif soal 0 vs 1 =
/// sukses) -- hasil lalu diverifikasi ulang lewat query status.
typedef IminPrintOutcome = PrintOutcome;

/// Implementasi [BuiltInPrinterBackend] untuk printer bawaan iMin SDK 2.0 (D4 Pro,
/// Swift 1 Pro/2/2 Pro/2 Ultra, Swan 2, Falcon 2) lewat stub AIDL resmi
/// `IminPrinterLibrary`, dibungkus native oleh `IminPrinterBridge`/
/// `IminPrinterChannel` (`android/.../vendor/imin/`). Perangkat iMin SDK 1.0
/// memakai printer virtual Bluetooth "InnerPrinter" lewat
/// `PrinterBackendEscpos`. Rancangan lengkap: `doc/vendor-imin-design.md`.
///
/// Beda dari Sunmi: lebar kertas dibaca ulang tiap cetak
/// (`getPrinterPaperType`, 58/80) -- printer 80 mm (ber-cutter) juga bisa
/// memakai gulungan 58 mm -- lalu renderer dan pemotongan kertas mengikutinya.
class PrinterBackendImin extends BuiltInPrinterBackend {
  PrinterBackendImin({
    super.renderer,
    Future<bool> Function()? bind,
    Future<void> Function()? unbind,
    Future<int> Function()? status,
    Future<int?> Function()? paperType,
    Future<IminPrintOutcome> Function(List<int> png, int feedDistance, bool cut)?
    printTransaction,
    Future<bool> Function()? printResultVerified,
    super.connectPollInterval,
    super.printTimeout,
    super.stuckAfter,
  }) : _bind = bind ?? (() async => await _channel.invokeMethod<bool>('bind') ?? false),
       _unbind = unbind ?? (() => _channel.invokeMethod('unbind')),
       _status =
           status ??
           (() async =>
               await _channel.invokeMethod<int>('status') ?? _statusNotReady),
       _paperType = paperType ?? (() => _channel.invokeMethod<int>('paperType')),
       _printResultVerified =
           printResultVerified ??
           (() async =>
               await _channel.invokeMethod<bool>('printResultVerified') ?? false),
       _printTransaction =
           printTransaction ??
           ((png, feedDistance, cut) async => IminPrintOutcome.parse(
             await _channel.invokeMethod<String>('printTransaction', {
               'bytes': Uint8List.fromList(png),
               'feedDistance': feedDistance,
               'cut': cut,
             }),
           )),
       super(device: kIminBuiltInDevice);

  static const MethodChannel _channel = MethodChannel('blue_thermal_printer/imin');

  /// Jarak feed setelah struk (unit `printAndFeedPaper`, contoh dokumen
  /// resmi) supaya baris terakhir melewati tear bar/cutter.
  static const feedDistance = 70;

  /// Lebar raster (8 dot/mm) per jenis kertas `getPrinterPaperType`.
  static const paper58WidthPx = 384;
  static const paper80WidthPx = 576;

  final Future<bool> Function() _bind;
  final Future<void> Function() _unbind;
  final Future<int> Function() _status;

  /// Lebar kertas terpasang (58/80); `null` = tidak diketahui.
  final Future<int?> Function() _paperType;

  /// Satu transaksi buffer penuh di native: enter buffer → bitmap → feed →
  /// (cut) → `exitPrinterBufferWithCallback`.
  final Future<IminPrintOutcome> Function(List<int> png, int feedDistance, bool cut)
  _printTransaction;

  /// `IminPrinterBridge.PRINT_RESULT_CODE_VERIFIED`: kode `onPrintResult`
  /// sudah diverifikasi di hardware, jadi `printed` bisa dipercaya.
  final Future<bool> Function() _printResultVerified;

  @override
  String get displayName => 'Printer Bawaan iMin';

  @override
  String get notFoundMessage =>
      'Printer bawaan iMin tidak ditemukan di perangkat ini.';

  /// `getPrinterPaperType` hanya bermakna setelah handshake `initPrinter`.
  @override
  bool get capabilitiesRequireConnection => true;

  @override
  Future<bool> bindService() => _bind();

  @override
  Future<void> unbindService() => _unbind();

  @override
  Future<bool> probeReady() async => await _status() != _statusNotReady;

  @override
  Future<PrinterStatus> readStatus() async => iminStatusToStatus(await _status());

  /// Lebar dari `getPrinterPaperType`, dibaca ulang tiap kali -- printer
  /// 80 mm bisa memakai gulungan 58 mm.
  @override
  Future<PrinterCapabilities?> readCapabilities() async {
    final wide = await _paperTypeOrNull() == 80;
    bool verified;
    try {
      verified = await _printResultVerified();
    } catch (_) {
      verified = false;
    }
    return PrinterCapabilities(
      paperWidthPx: wide ? paper80WidthPx : paper58WidthPx,
      autoCut: wide,
      reportsPaperOut: true,
      confirmsPrint: verified,
    );
  }

  Future<int?> _paperTypeOrNull() async {
    try {
      return await _paperType();
    } catch (_) {
      return null;
    }
  }

  /// Pemotongan kertas mengikuti lebar kertas terpasang (hanya 80 mm).
  @override
  Future<PrintOutcome> sendRaster(Uint8List png, PrinterCapabilities caps) =>
      _printTransaction(png, feedDistance, caps.autoCut);
}

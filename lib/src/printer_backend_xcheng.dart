import 'package:flutter/services.dart';

import 'built_in_printer_backend.dart';
import 'printer_capabilities.dart';
import 'printer_device.dart';
import 'printer_status.dart';

/// Satu-satunya "perangkat" backend printer bawaan Xcheng -- lihat
/// `kSunmiBuiltInDevice` untuk alasan entri sintetis ini.
const kXchengBuiltInDevice = PrinterDevice(
  name: 'Printer Bawaan',
  macAddress: 'xcheng-builtin',
);

/// Hasil satu cetakan lewat antarmuka native Xcheng: `printed` = servis
/// memanggil `onComplete()` (struk benar-benar tercetak), `failed` =
/// `onException()`, `unknown` = tidak ada callback dalam batas waktu (di
/// hardware yang diuji: selalu terjadi saat kertas habis) -- sensor kertas
/// yang menentukan.
typedef XchengPrintOutcome = PrintOutcome;

/// Implementasi [BuiltInPrinterBackend] untuk printer bawaan perangkat Xcheng lewat
/// antarmuka native servisnya (`com.xcheng.printerservice.IPrinterService`),
/// dibungkus native oleh `XchengPrinterBridge`/`XchengPrinterChannel`
/// (`android/.../vendor/xcheng/`).
///
/// **Alternatif opsional, bukan default.** Perangkat Xcheng juga menyediakan
/// AIDL kompatibel Sunmi (dipakai [PrinterBackendSunmi]), tapi di hardware
/// yang diuji (Xcheng O1, servis v1.1.12) jalur itu tidak pernah melaporkan
/// kertas habis dan tidak pernah memanggil callback hasil cetak. Backend ini
/// memakai dua sinyal yang terbukti akurat di hardware yang sama: sensor
/// kertas `printerPaper()` (sebagai pre-check -- sekaligus mencegah struk
/// menumpuk di buffer servis selama kertas habis) dan callback `onComplete()`
/// dari `printBitmap`. Servis ini tidak melaporkan cover/overheat, jadi
/// field status selain `hasPaper` selalu `null`.
class PrinterBackendXcheng extends BuiltInPrinterBackend {
  PrinterBackendXcheng({
    super.renderer,
    Future<bool> Function()? bind,
    Future<void> Function()? unbind,
    Future<bool?> Function()? hasPaper,
    Future<XchengPrintOutcome> Function(List<int> png, int feedLines)?
    printBitmap,
    super.connectPollInterval,
    super.printTimeout,
    super.stuckAfter,
  }) : _bind = bind ?? (() async => await _channel.invokeMethod<bool>('bind') ?? false),
       _unbind = unbind ?? (() => _channel.invokeMethod('unbind')),
       _hasPaper = hasPaper ?? (() => _channel.invokeMethod<bool>('hasPaper')),
       _printBitmap =
           printBitmap ??
           ((png, feedLines) async => XchengPrintOutcome.parse(
             await _channel.invokeMethod<String>('printBitmap', {
               'bytes': Uint8List.fromList(png),
               'feedLines': feedLines,
             }),
           )),
       super(device: kXchengBuiltInDevice);

  static const MethodChannel _channel = MethodChannel('blue_thermal_printer/xcheng');

  /// Baris kosong yang di-feed setelah struk tercetak (lihat
  /// `PrinterBackendSunmi.feedLines`).
  static const feedLines = 3;

  /// Kemampuan tetap backend ini (lihat `doc/contract-extensions-design.md`
  /// §2): servis Xcheng tidak punya API lebar kertas (margin maksimum 384
  /// dot = 58 mm) maupun pemotong; sensor kertas `printerPaper()` dan
  /// `onComplete()` terverifikasi di hardware.
  static const capabilitiesValue = PrinterCapabilities(
    paperWidthPx: 384,
    autoCut: false,
    reportsPaperOut: true,
    confirmsPrint: true,
  );

  final Future<bool> Function() _bind;
  final Future<void> Function() _unbind;

  /// Sensor kertas; `null` = servis belum tersambung / tidak menjawab.
  final Future<bool?> Function() _hasPaper;
  final Future<XchengPrintOutcome> Function(List<int> png, int feedLines)
  _printBitmap;

  @override
  String get displayName => 'Printer Bawaan Xcheng';

  @override
  String get notFoundMessage =>
      'Printer bawaan Xcheng tidak ditemukan di perangkat ini.';

  @override
  Future<bool> bindService() => _bind();

  @override
  Future<void> unbindService() => _unbind();

  /// Tersedia bila servis tersambung DAN menjawab query sensor kertas --
  /// sekaligus memastikan antarmuka native-nya cocok dengan firmware ini.
  @override
  Future<bool> probeReady() async => await _hasPaper() != null;

  /// Servis ini tidak melaporkan cover/overheat, jadi field selain
  /// `hasPaper` selalu `null`.
  @override
  Future<PrinterStatus> readStatus() async {
    final paper = await _hasPaper();
    return paper == null ? PrinterStatus.unknown : PrinterStatus(hasPaper: paper);
  }

  @override
  Future<PrinterCapabilities?> readCapabilities() async => capabilitiesValue;

  /// Pre-check di [BuiltInPrinterBackend] wajib sebelum ini: servis Xcheng
  /// menahan data yang dikirim saat kertas habis lalu mencetak semuanya
  /// sekaligus begitu kertas dipasang (terbukti di hardware).
  @override
  Future<PrintOutcome> sendRaster(Uint8List png, PrinterCapabilities caps) =>
      _printBitmap(png, feedLines);
}

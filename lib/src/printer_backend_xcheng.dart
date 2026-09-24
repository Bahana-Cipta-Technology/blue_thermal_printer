import 'package:flutter/services.dart';

import 'print_job_gate.dart';
import 'printer_backend.dart';
import 'printer_device.dart';
import 'printer_status.dart';
import 'receipt.dart';
import 'receipt_renderer.dart';
import 'result.dart';

/// Satu-satunya "perangkat" backend printer bawaan Xcheng -- lihat
/// `kSunmiBuiltInDevice` untuk alasan entri sintetis ini.
const kXchengBuiltInDevice = PrinterDevice(
  name: 'Printer Bawaan',
  macAddress: 'xcheng-builtin',
);

/// Hasil satu cetakan lewat antarmuka native Xcheng.
enum XchengPrintOutcome {
  /// Servis memanggil `onComplete()` -- struk benar-benar tercetak.
  printed,

  /// Servis memanggil `onException()`.
  failed,

  /// Tidak ada callback dalam batas waktu (di hardware yang diuji: selalu
  /// terjadi saat kertas habis) -- sensor kertas yang menentukan.
  unknown;

  static XchengPrintOutcome parse(Object? raw) => switch (raw) {
    'printed' => printed,
    'failed' => failed,
    _ => unknown,
  };
}

/// Implementasi [PrinterBackend] untuk printer bawaan perangkat Xcheng lewat
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
class PrinterBackendXcheng implements PrinterBackend {
  PrinterBackendXcheng({
    ReceiptRenderer renderer = const ReceiptRenderer(),
    Future<bool> Function()? bind,
    Future<void> Function()? unbind,
    Future<bool?> Function()? hasPaper,
    Future<XchengPrintOutcome> Function(List<int> png, int feedLines)?
    printBitmap,
    Duration connectPollInterval = const Duration(milliseconds: 200),
    Duration printTimeout = const Duration(seconds: 30),
    Duration stuckAfter = const Duration(seconds: 30),
  }) : _renderer = renderer,
       _connectPollInterval = connectPollInterval,
       _gate = PrintJobGate(timeout: printTimeout, stuckAfter: stuckAfter),
       _bind = bind ?? (() async => await _channel.invokeMethod<bool>('bind') ?? false),
       _unbind = unbind ?? (() => _channel.invokeMethod('unbind')),
       _hasPaper = hasPaper ?? (() => _channel.invokeMethod<bool>('hasPaper')),
       _printBitmap =
           printBitmap ??
           ((png, feedLines) async => XchengPrintOutcome.parse(
             await _channel.invokeMethod<String>('printBitmap', {
               'bytes': Uint8List.fromList(png),
               'feedLines': feedLines,
             }),
           ));

  static const MethodChannel _channel = MethodChannel('blue_thermal_printer/xcheng');

  /// Baris kosong yang di-feed setelah struk tercetak (lihat
  /// `PrinterBackendSunmi.feedLines`).
  static const feedLines = 3;

  static const _connectPollAttempts = 15;

  final ReceiptRenderer _renderer;
  final Duration _connectPollInterval;
  final PrintJobGate _gate;
  final Future<bool> Function() _bind;
  final Future<void> Function() _unbind;

  /// Sensor kertas; `null` = servis belum tersambung / tidak menjawab.
  final Future<bool?> Function() _hasPaper;
  final Future<XchengPrintOutcome> Function(List<int> png, int feedLines)
  _printBitmap;

  @override
  String get displayName => 'Printer Bawaan Xcheng';

  @override
  bool get requiresPairing => false;

  /// Tersedia bila servis tersambung DAN menjawab query sensor kertas --
  /// sekaligus memastikan antarmuka native-nya cocok dengan firmware ini.
  @override
  Future<bool> isAvailable() async {
    try {
      return await _hasPaper() != null;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<List<PrinterDevice>> discoverDevices() async => const [
    kXchengBuiltInDevice,
  ];

  @override
  Future<PrinterResult<void>> connect(PrinterDevice device) async {
    try {
      if (!await _bind()) {
        return const PrinterErr(
          PrinterFailure('Printer bawaan Xcheng tidak ditemukan di perangkat ini.'),
        );
      }
      for (var attempt = 0; attempt < _connectPollAttempts; attempt++) {
        if (await isAvailable()) return const PrinterOk(null);
        await Future.delayed(_connectPollInterval);
      }
      return const PrinterErr(
        PrinterFailure('Printer bawaan tidak terdeteksi.'),
      );
    } catch (_) {
      return const PrinterErr(
        PrinterFailure('Gagal terhubung ke printer bawaan.'),
      );
    }
  }

  @override
  Future<void> disconnect() async {
    try {
      await _unbind();
    } catch (_) {
      // Belum/tidak lagi terbind -- aman diabaikan.
    }
  }

  @override
  Future<bool> isConnected() => isAvailable();

  Future<PrinterStatus> _rawStatus() async {
    final paper = await _hasPaper();
    return paper == null ? PrinterStatus.unknown : PrinterStatus(hasPaper: paper);
  }

  Future<PrinterStatus> _statusOrUnknown() async {
    try {
      return await _rawStatus();
    } catch (_) {
      return PrinterStatus.unknown;
    }
  }

  @override
  Future<PrinterResult<PrinterStatus>> checkStatus() async {
    if (!await isConnected()) {
      return const PrinterErr(PrinterFailure('Printer belum terhubung.'));
    }
    return PrinterOk(await _statusOrUnknown());
  }

  @override
  Future<PrinterResult<void>> printReceipt(Receipt receipt) =>
      _gate.run(() => _send(receipt));

  Future<PrinterResult<void>> _send(Receipt receipt) async {
    try {
      if (!await isConnected()) {
        return const PrinterErr(
          PrinterFailure('Printer belum terhubung. Buka Koneksi Printer.'),
        );
      }
      // Wajib sebelum mengirim data: servis Xcheng menahan data yang dikirim
      // saat kertas habis lalu mencetak semuanya sekaligus begitu kertas
      // dipasang (terbukti di hardware).
      final preStatus = await _rawStatus();
      if (preStatus.hasKnownProblem) {
        return PrinterErr(PrinterFailure(preStatus.problemMessage!));
      }
      final bytes = await _renderer.preview(receipt);
      switch (await _printBitmap(bytes, feedLines)) {
        case XchengPrintOutcome.printed:
          return const PrinterOk(null);
        case XchengPrintOutcome.failed:
          final status = await _statusOrUnknown();
          return PrinterErr(
            PrinterFailure(
              status.problemMessage ??
                  'Printer gagal mencetak. Periksa kertas sebelum mencoba ulang.',
            ),
          );
        case XchengPrintOutcome.unknown:
          final status = await _statusOrUnknown();
          if (status.hasKnownProblem) {
            return PrinterErr(PrinterFailure(status.problemMessage!));
          }
          return const PrinterOk(null);
      }
    } catch (_) {
      return const PrinterErr(
        PrinterFailure(
          'Tidak dapat mengirim struk. Periksa koneksi dan kertas sebelum mencoba ulang.',
        ),
      );
    }
  }

  @override
  Future<void> openSystemSettings() async {
    // Printer bawaan -- tidak ada pengaturan sistem yang relevan.
  }
}

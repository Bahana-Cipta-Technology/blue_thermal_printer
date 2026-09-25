import 'package:flutter/services.dart';

import 'print_job_gate.dart';
import 'printer_backend.dart';
import 'printer_device.dart';
import 'printer_status.dart';
import 'receipt.dart';
import 'receipt_renderer.dart';
import 'result.dart';

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
/// `onPrintResult`).
enum IminPrintOutcome {
  /// Printer melaporkan struk benar-benar tercetak.
  printed,

  /// Printer melaporkan transaksi gagal (atau `onRaiseException`).
  failed,

  /// Tidak ada jawaban pasti: callback tidak datang dalam batas waktu, atau
  /// kode `onPrintResult` belum terverifikasi di hardware (dokumen resmi
  /// kontradiktif soal 0 vs 1 = sukses). Hasil diverifikasi ulang lewat
  /// query status.
  unknown;

  static IminPrintOutcome parse(Object? raw) => switch (raw) {
    'printed' => printed,
    'failed' => failed,
    _ => unknown,
  };
}

/// Implementasi [PrinterBackend] untuk printer bawaan iMin SDK 2.0 (D4 Pro,
/// Swift 1 Pro/2/2 Pro/2 Ultra, Swan 2, Falcon 2) lewat stub AIDL resmi
/// `IminPrinterLibrary`, dibungkus native oleh `IminPrinterBridge`/
/// `IminPrinterChannel` (`android/.../vendor/imin/`). Perangkat iMin SDK 1.0
/// memakai printer virtual Bluetooth "InnerPrinter" lewat
/// `PrinterBackendEscpos`. Rancangan lengkap: `doc/vendor-imin-design.md`.
///
/// Beda dari Sunmi: lebar kertas dibaca ulang tiap cetak
/// (`getPrinterPaperType`, 58/80) -- printer 80 mm (ber-cutter) juga bisa
/// memakai gulungan 58 mm -- lalu renderer dan pemotongan kertas mengikutinya.
class PrinterBackendImin implements PrinterBackend {
  PrinterBackendImin({
    ReceiptRenderer renderer = const ReceiptRenderer(),
    Future<bool> Function()? bind,
    Future<void> Function()? unbind,
    Future<int> Function()? status,
    Future<int?> Function()? paperType,
    Future<IminPrintOutcome> Function(List<int> png, int feedDistance, bool cut)?
    printTransaction,
    Duration connectPollInterval = const Duration(milliseconds: 200),
    Duration printTimeout = const Duration(seconds: 30),
    Duration stuckAfter = const Duration(seconds: 30),
  }) : _renderer = renderer,
       _connectPollInterval = connectPollInterval,
       _gate = PrintJobGate(timeout: printTimeout, stuckAfter: stuckAfter),
       _bind = bind ?? (() async => await _channel.invokeMethod<bool>('bind') ?? false),
       _unbind = unbind ?? (() => _channel.invokeMethod('unbind')),
       _status =
           status ??
           (() async =>
               await _channel.invokeMethod<int>('status') ?? _statusNotReady),
       _paperType = paperType ?? (() => _channel.invokeMethod<int>('paperType')),
       _printTransaction =
           printTransaction ??
           ((png, feedDistance, cut) async => IminPrintOutcome.parse(
             await _channel.invokeMethod<String>('printTransaction', {
               'bytes': Uint8List.fromList(png),
               'feedDistance': feedDistance,
               'cut': cut,
             }),
           ));

  static const MethodChannel _channel = MethodChannel('blue_thermal_printer/imin');

  /// Jarak feed setelah struk (unit `printAndFeedPaper`, contoh dokumen
  /// resmi) supaya baris terakhir melewati tear bar/cutter.
  static const feedDistance = 70;

  /// Lebar raster (8 dot/mm) per jenis kertas `getPrinterPaperType`.
  static const paper58WidthPx = 384;
  static const paper80WidthPx = 576;

  /// Berapa kali [connect] memeriksa servis setelah bind -- bind async dan
  /// handshake `initPrinter` baru berjalan setelah servis tersambung.
  static const _connectPollAttempts = 15;

  final ReceiptRenderer _renderer;
  final Duration _connectPollInterval;
  final PrintJobGate _gate;
  final Future<bool> Function() _bind;
  final Future<void> Function() _unbind;
  final Future<int> Function() _status;

  /// Lebar kertas terpasang (58/80); `null` = tidak diketahui.
  final Future<int?> Function() _paperType;

  /// Satu transaksi buffer penuh di native: enter buffer → bitmap → feed →
  /// (cut) → `exitPrinterBufferWithCallback`.
  final Future<IminPrintOutcome> Function(List<int> png, int feedDistance, bool cut)
  _printTransaction;

  @override
  String get displayName => 'Printer Bawaan iMin';

  @override
  bool get requiresPairing => false;

  @override
  Future<bool> isAvailable() async {
    try {
      return await _status() != _statusNotReady;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<List<PrinterDevice>> discoverDevices() async => const [
    kIminBuiltInDevice,
  ];

  @override
  Future<PrinterResult<void>> connect(PrinterDevice device) async {
    try {
      if (!await _bind()) {
        return const PrinterErr(
          PrinterFailure('Printer bawaan iMin tidak ditemukan di perangkat ini.'),
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

  Future<PrinterStatus> _rawStatus() async => iminStatusToStatus(await _status());

  Future<PrinterStatus> _statusOrUnknown() async {
    try {
      return await _rawStatus();
    } catch (_) {
      return PrinterStatus.unknown;
    }
  }

  Future<int?> _paperTypeOrNull() async {
    try {
      return await _paperType();
    } catch (_) {
      return null;
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
      // Cek status sebelum satu bitmap pun dikirim; `unknown` sengaja tidak
      // memblokir (`hasKnownProblem` dirancang begitu).
      final preStatus = await _rawStatus();
      if (preStatus.hasKnownProblem) {
        return PrinterErr(PrinterFailure(preStatus.problemMessage!));
      }
      final wide = await _paperTypeOrNull() == 80;
      final renderer = ReceiptRenderer(
        width: wide ? paper80WidthPx : paper58WidthPx,
        fontFamily: _renderer.fontFamily,
      );
      final bytes = await renderer.preview(receipt);
      switch (await _printTransaction(bytes, feedDistance, wide)) {
        case IminPrintOutcome.printed:
          return const PrinterOk(null);
        case IminPrintOutcome.failed:
          // Printer sudah pasti gagal -- query status hanya untuk memberi
          // pesan yang lebih spesifik bila penyebabnya diketahui.
          final status = await _statusOrUnknown();
          return PrinterErr(
            PrinterFailure(
              status.problemMessage ??
                  'Printer gagal mencetak. Periksa kertas sebelum mencoba ulang.',
            ),
          );
        case IminPrintOutcome.unknown:
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

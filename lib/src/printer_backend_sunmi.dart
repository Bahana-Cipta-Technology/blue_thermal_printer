import 'dart:async';

import 'package:flutter/services.dart';

import 'printer_backend.dart';
import 'printer_device.dart';
import 'printer_status.dart';
import 'receipt.dart';
import 'receipt_renderer.dart';
import 'result.dart';

/// Satu-satunya "perangkat" yang pernah dikembalikan backend ini -- printer
/// bawaan tidak punya konsep pemasangan, jadi ini cuma penanda identitas
/// tetap. Publik supaya pemanggil (mis. probe deteksi hardware saat boot)
/// bisa memakainya tanpa perlu tahu isinya.
const kSunmiBuiltInDevice = PrinterDevice(
  name: 'Printer Bawaan',
  macAddress: 'sunmi-builtin',
);

/// Kode `updatePrinterState()` yang berarti servis belum tersambung/printer
/// tidak terdeteksi -- lihat `SunmiPrinterBridge.STATE_NOT_DETECTED` di sisi
/// native, harus tetap sinkron dengan nilai itu (505, angka asli dari AIDL
/// Sunmi untuk "printer tidak terdeteksi").
const _stateNotDetected = 505;

/// Implementasi [PrinterBackend] memakai servis printer bawaan Sunmi
/// ("Woyou") lewat AIDL, dibungkus native oleh `SunmiPrinterBridge`/
/// `SunmiPrinterChannel` (`android/.../vendor/sunmi/`).
///
/// Tidak ada konsep pemasangan/pairing sama sekali -- printer selalu berupa
/// satu perangkat sintetis yang sama ([requiresPairing] `false`). Setiap
/// pemanggilan dibungkus try/catch dan diperlakukan sebagai "tidak tersedia"
/// di platform yang tidak mengekspos channel ini (mis. Linux desktop), sama
/// seperti pola backend ESC/POS.
class PrinterBackendSunmi implements PrinterBackend {
  PrinterBackendSunmi({
    ReceiptRenderer renderer = const ReceiptRenderer(),
    Future<bool> Function()? bind,
    Future<void> Function()? unbind,
    Future<int> Function()? updateState,
    Future<bool> Function(List<int>)? doPrintBitmap,
  }) : _renderer = renderer,
       _bind = bind ?? (() async => await _channel.invokeMethod<bool>('bind') ?? false),
       _unbind = unbind ?? (() => _channel.invokeMethod('unbind')),
       _updateState =
           updateState ??
           (() async =>
               await _channel.invokeMethod<int>('updateState') ??
               _stateNotDetected),
       _doPrintBitmap =
           doPrintBitmap ??
           ((bytes) async =>
               await _channel.invokeMethod<bool>('printBitmap', {
                 'bytes': Uint8List.fromList(bytes),
               }) ??
               false);

  static const MethodChannel _channel = MethodChannel('blue_thermal_printer/sunmi');

  final ReceiptRenderer _renderer;
  final Future<bool> Function() _bind;
  final Future<void> Function() _unbind;
  final Future<int> Function() _updateState;
  final Future<bool> Function(List<int>) _doPrintBitmap;

  bool _busy = false;

  @override
  String get displayName => 'Printer Bawaan Sunmi';

  @override
  bool get requiresPairing => false;

  @override
  Future<bool> isAvailable() async {
    try {
      return await _updateState() != _stateNotDetected;
    } catch (_) {
      return false;
    }
  }

  /// Selalu mengembalikan satu-satunya slot printer bawaan, terlepas dari
  /// [isAvailable] saat ini -- backend ini baru benar-benar "available"
  /// SETELAH [connect] berhasil bind, jadi menggerbang di sini akan
  /// mencegah pemanggil (mis. auto-connect) pernah mendapat perangkat untuk
  /// dicoba sambungkan sama sekali.
  @override
  Future<List<PrinterDevice>> discoverDevices() async => const [
    kSunmiBuiltInDevice,
  ];

  @override
  Future<PrinterResult<void>> connect(PrinterDevice device) async {
    try {
      if (!await _bind()) {
        return const PrinterErr(
          PrinterFailure('Gagal terhubung ke printer bawaan.'),
        );
      }
      // bindService bersifat async (menunggu callback servis tersambung) --
      // beri jeda pendek dengan beberapa percobaan sebelum menyerah.
      for (var attempt = 0; attempt < 5; attempt++) {
        if (await isAvailable()) return const PrinterOk(null);
        await Future.delayed(const Duration(milliseconds: 200));
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
    final state = await _updateState();
    if (state == 1) {
      // NORMAL -- AIDL menyediakan status pasti, beda dari ESC/POS yang cuma
      // bisa menebak lewat byte offline status.
      return const PrinterStatus(hasPaper: true, coverClosed: true, hasError: false);
    }
    if (state == 3) return const PrinterStatus(hasPaper: false); // OUT_OF_PAPER
    if (state == 6) return const PrinterStatus(coverClosed: false); // OPEN_THE_LID
    if (state == 5 || state == 7) {
      return const PrinterStatus(hasError: true); // OVERHEATED / PAPER_CUTTER_ABNORMAL
    }
    return PrinterStatus.unknown;
  }

  @override
  Future<PrinterResult<PrinterStatus>> checkStatus() async {
    if (!await isConnected()) {
      return const PrinterErr(PrinterFailure('Printer belum terhubung.'));
    }
    try {
      return PrinterOk(await _rawStatus());
    } catch (_) {
      return const PrinterOk(PrinterStatus.unknown);
    }
  }

  @override
  Future<PrinterResult<void>> printReceipt(Receipt receipt) async {
    if (_busy) {
      return const PrinterErr(
        PrinterFailure('Printer masih memproses pengiriman sebelumnya.'),
      );
    }
    _busy = true;
    final operation = _send(receipt);
    unawaited(
      operation.then((_) {
        _busy = false;
      }),
    );
    return operation.timeout(
      const Duration(seconds: 30),
      onTimeout: () => const PrinterErr(
        PrinterFailure(
          'Pengiriman melewati batas waktu. Periksa kertas sebelum mencoba ulang.',
        ),
      ),
    );
  }

  Future<PrinterResult<void>> _send(Receipt receipt) async {
    try {
      if (!await isConnected()) {
        return const PrinterErr(
          PrinterFailure('Printer belum terhubung. Buka Koneksi Printer.'),
        );
      }
      final bytes = await _renderer.preview(receipt);
      if (!await _doPrintBitmap(bytes)) {
        return const PrinterErr(
          PrinterFailure(
            'Pengiriman gagal. Periksa kertas sebelum mencoba ulang.',
          ),
        );
      }
      final status = await _rawStatus();
      if (status.hasKnownProblem) {
        return PrinterErr(
          PrinterFailure(
            status.hasPaper == false
                ? 'Kertas printer habis.'
                : status.coverClosed == false
                ? 'Penutup printer terbuka.'
                : 'Printer melaporkan galat.',
          ),
        );
      }
      return const PrinterOk(null);
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
    // Printer bawaan tidak punya pengaturan sistem yang relevan (tidak ada
    // radio/pairing untuk dikonfigurasi) -- sengaja no-op.
  }
}

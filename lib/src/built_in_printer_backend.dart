import 'dart:typed_data';

import 'built_in_connection.dart';
import 'paper_width.dart';
import 'print_job_gate.dart';
import 'printer_backend.dart';
import 'printer_capabilities.dart';
import 'printer_device.dart';
import 'printer_status.dart';
import 'receipt.dart';
import 'receipt_renderer.dart';
import 'result.dart';

/// Hasil satu pekerjaan cetak native printer bawaan, netral vendor.
enum PrintOutcome {
  /// Printer/servis melaporkan struk benar-benar tercetak.
  printed,

  /// Printer/servis melaporkan pekerjaan gagal.
  failed,

  /// Tidak ada jawaban pasti (callback tidak datang dalam batas waktu, atau
  /// kodenya belum terverifikasi) -- hasil diverifikasi ulang lewat query
  /// status.
  unknown;

  /// Terjemahkan string hasil channel native (`"printed"`/`"failed"`/lainnya).
  static PrintOutcome parse(Object? raw) => switch (raw) {
    'printed' => printed,
    'failed' => failed,
    _ => unknown,
  };
}

/// Kerangka bersama [PrinterBackend] untuk printer bawaan yang diakses lewat
/// servis vendor (bind → siap → status → cetak raster), mis. Sunmi, Xcheng,
/// iMin.
///
/// Alur yang sama untuk semua vendor ada di sini SEKALI: poll connect,
/// `ensureConnected` single-flight, cache kemampuan, busy-lock
/// [PrintJobGate], pre-check status sebelum data dikirim, dan pemetaan
/// [PrintOutcome] → [PrintDelivery] (`confirmed` tidak pernah melampaui
/// [PrinterCapabilities.confirmsPrint]). Vendor baru cukup mengisi hook
/// abstrak di bawah -- invariant di atas tidak bisa terlupa.
///
/// Backend yang punya konsep pemasangan/pemilihan perangkat (mis. ESC/POS
/// Bluetooth/LAN/USB) tidak memakai kelas ini.
abstract class BuiltInPrinterBackend implements PrinterBackend {
  BuiltInPrinterBackend({
    required PrinterDevice device,
    ReceiptRenderer renderer = const ReceiptRenderer(),
    Duration connectPollInterval = const Duration(milliseconds: 200),
    Duration printTimeout = const Duration(seconds: 30),
    Duration stuckAfter = const Duration(seconds: 30),
  }) : _device = device,
       _renderer = renderer,
       _connectPollInterval = connectPollInterval,
       _gate = PrintJobGate(timeout: printTimeout, stuckAfter: stuckAfter);

  /// Berapa kali [connect] memeriksa servis setelah bind -- bind bersifat
  /// async dan di boot dingin servis vendor bisa butuh beberapa detik.
  static const connectPollAttempts = 15;

  final PrinterDevice _device;
  final ReceiptRenderer _renderer;
  final Duration _connectPollInterval;
  final PrintJobGate _gate;
  final _ensureFlight = SingleFlight<PrinterResult<PrinterDevice>>();

  /// Kemampuan terakhir yang diketahui -- dipakai [capabilities]/[preview]
  /// sebelum/tanpa koneksi.
  PrinterCapabilities _lastCapabilities = PrinterCapabilities.fallback58;

  // ---------------------------------------------------------------------
  // Hook vendor
  // ---------------------------------------------------------------------

  /// Minta sistem bind ke servis printer vendor. `false` = servis tidak ada
  /// di perangkat ini.
  Future<bool> bindService();

  /// Lepas bind servis. Boleh melempar bila belum terbind (diabaikan).
  Future<void> unbindService();

  /// Apakah servis sudah tersambung dan siap menjawab -- dasar
  /// [isAvailable]/[isConnected]. Boleh melempar (dianggap `false`).
  Future<bool> probeReady();

  /// Status fisik printer saat ini. Boleh melempar.
  Future<PrinterStatus> readStatus();

  /// Kemampuan printer saat ini; `null` bila belum bisa disimpulkan (nilai
  /// terakhir yang dipakai). Boleh melempar (nilai terakhir yang dipakai).
  Future<PrinterCapabilities?> readCapabilities();

  /// Kirim satu struk (PNG selebar [PrinterCapabilities.paperWidthPx]) ke
  /// printer sebagai satu pekerjaan native, lalu laporkan hasilnya.
  Future<PrintOutcome> sendRaster(Uint8List png, PrinterCapabilities caps);

  /// Pesan galat saat [bindService] mengembalikan `false`.
  String get notFoundMessage => 'Gagal terhubung ke printer bawaan.';

  /// `true` bila [readCapabilities] hanya bermakna setelah servis siap --
  /// [capabilities] lalu mengembalikan nilai terakhir tanpa query selama
  /// servis belum siap.
  bool get capabilitiesRequireConnection => false;

  // ---------------------------------------------------------------------
  // Template bersama
  // ---------------------------------------------------------------------

  ReceiptRenderer _rendererFor(PrinterCapabilities caps) =>
      ReceiptRenderer(width: caps.paperWidthPx, fontFamily: _renderer.fontFamily);

  @override
  bool get requiresPairing => false;

  /// Lebar kertas dibaca dari servis vendor ([readCapabilities]).
  @override
  bool get supportsPaperWidthSetting => false;

  @override
  void setPaperWidth(PaperWidthSetting setting) {}

  @override
  Future<bool> isAvailable() async {
    try {
      return await probeReady();
    } catch (_) {
      return false;
    }
  }

  /// Selalu mengembalikan satu-satunya slot printer bawaan, terlepas dari
  /// [isAvailable] saat ini -- backend ini baru benar-benar "available"
  /// SETELAH [connect] berhasil bind, jadi menggerbang di sini akan mencegah
  /// pemanggil (mis. auto-connect) pernah mendapat perangkat untuk dicoba.
  @override
  Future<List<PrinterDevice>> discoverDevices() async => [_device];

  @override
  Future<PrinterResult<void>> connect(PrinterDevice device) async {
    try {
      if (!await bindService()) {
        return PrinterErr(PrinterFailure(notFoundMessage));
      }
      for (var attempt = 0; attempt < connectPollAttempts; attempt++) {
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
  Future<PrinterResult<PrinterDevice>> ensureConnected({
    PrinterDevice? lastDevice,
  }) => _ensureFlight.run(() => ensureBuiltInConnected(this, _device));

  @override
  Future<PrinterCapabilities> capabilities() async {
    if (capabilitiesRequireConnection && !await isAvailable()) {
      return _lastCapabilities;
    }
    return _refreshCapabilities();
  }

  Future<PrinterCapabilities> _refreshCapabilities() async {
    try {
      final caps = await readCapabilities();
      if (caps != null) _lastCapabilities = caps;
    } catch (_) {
      // Channel tidak ada (mis. desktop) / servis tidak menjawab -- pakai
      // nilai terakhir.
    }
    return _lastCapabilities;
  }

  @override
  Future<Uint8List> preview(Receipt receipt) async =>
      _rendererFor(await capabilities()).preview(receipt);

  @override
  Future<void> disconnect() async {
    try {
      await unbindService();
    } catch (_) {
      // Belum/tidak lagi terbind -- aman diabaikan.
    }
  }

  @override
  Future<bool> isConnected() => isAvailable();

  Future<PrinterStatus> _statusOrUnknown() async {
    try {
      return await readStatus();
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
  Future<PrinterResult<PrintDelivery>> printReceipt(Receipt receipt) =>
      _gate.run(() => _send(receipt));

  Future<PrinterResult<PrintDelivery>> _send(Receipt receipt) async {
    try {
      if (!await isConnected()) {
        return const PrinterErr(
          PrinterFailure('Printer belum terhubung. Buka Koneksi Printer.'),
        );
      }
      // Cek status LEBIH DULU, sebelum satu bitmap pun dikirim, supaya data
      // tidak ikut nyangkut di buffer printer yang sudah bermasalah. Status
      // `unknown` sengaja tidak memblokir (`hasKnownProblem` dirancang begitu).
      final preStatus = await readStatus();
      if (preStatus.hasKnownProblem) {
        return PrinterErr(PrinterFailure(preStatus.problemMessage!));
      }
      // Dibaca ulang tiap cetak: lebar kertas bisa berubah (mis. printer
      // 80 mm iMin memakai gulungan 58 mm).
      final caps = await _refreshCapabilities();
      final bytes = await _rendererFor(caps).preview(receipt);
      switch (await sendRaster(bytes, caps)) {
        case PrintOutcome.printed:
          // `confirmed` tidak pernah melampaui kemampuan yang dilaporkan.
          return PrinterOk(
            caps.confirmsPrint == true
                ? PrintDelivery.confirmed
                : PrintDelivery.unverified,
          );
        case PrintOutcome.failed:
          // Printer sudah pasti gagal -- query status hanya untuk memberi
          // pesan yang lebih spesifik bila penyebabnya diketahui.
          final status = await _statusOrUnknown();
          return PrinterErr(
            PrinterFailure(
              status.problemMessage ??
                  'Printer gagal mencetak. Periksa kertas sebelum mencoba ulang.',
            ),
          );
        case PrintOutcome.unknown:
          // Tidak ada jawaban pasti -- data sudah terkirim, jadi verifikasi
          // ulang lewat status; query yang gagal = tidak ada bukti masalah.
          final status = await _statusOrUnknown();
          if (status.hasKnownProblem) {
            return PrinterErr(PrinterFailure(status.problemMessage!));
          }
          return const PrinterOk(PrintDelivery.unverified);
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
    // Printer bawaan tidak punya pengaturan sistem yang relevan (tidak ada
    // radio/pairing untuk dikonfigurasi) -- sengaja no-op.
  }
}

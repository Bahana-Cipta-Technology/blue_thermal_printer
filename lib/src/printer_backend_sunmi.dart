import 'package:flutter/services.dart';

import 'built_in_connection.dart';
import 'print_job_gate.dart';
import 'printer_backend.dart';
import 'printer_capabilities.dart';
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

/// Terjemahkan kode `updatePrinterState()` AIDL Sunmi jadi [PrinterStatus].
///
/// Tabel resmi (doc `IWoyouService.aidl`): 1 normal, 2 printer sedang
/// memperbarui status, 3 gagal membaca status, 4 kertas habis, 5 overheat,
/// 6 cover terbuka, 7 cutter abnormal, 8 cutter pulih, 505 printer tidak
/// terdeteksi, 507 upgrade firmware gagal. Kode transien/tak pasti (2, 3, 8,
/// 9, dan kode tak dikenal) sengaja jadi [PrinterStatus.unknown] supaya tidak
/// memblokir cetak tanpa bukti masalah. 505 tidak dipetakan di sini --
/// pemanggil memperlakukannya sebagai "tidak terhubung", bukan status fisik.
PrinterStatus sunmiStateToStatus(int code) => switch (code) {
  1 => const PrinterStatus(hasPaper: true, coverClosed: true, hasError: false),
  4 => const PrinterStatus(hasPaper: false),
  6 => const PrinterStatus(coverClosed: false),
  5 || 7 || 507 => const PrinterStatus(hasError: true),
  _ => PrinterStatus.unknown,
};

/// Info servis Woyou yang tidak memerlukan query ke printer fisik (channel
/// `serviceInfo`, `SunmiPrinterBridge`).
class SunmiServiceInfo {
  const SunmiServiceInfo({this.paper, this.genuine, this.transactionCallback});

  /// `getPrinterPaper()`: 0 = 80 mm, 1 = 58 mm; `null` bila tidak diketahui.
  final int? paper;

  /// AIDL disediakan paket Sunmi asli (`true`) atau klon (`false`); `null`
  /// selama servis belum tersambung.
  final bool? genuine;

  /// `false` setelah callback transaksi terbukti tidak didukung; `null`
  /// selama belum diketahui.
  final bool? transactionCallback;

  static SunmiServiceInfo fromMap(Object? raw) {
    if (raw is! Map) return const SunmiServiceInfo();
    return SunmiServiceInfo(
      paper: raw['paper'] as int?,
      genuine: raw['genuine'] as bool?,
      transactionCallback: raw['transactionCallback'] as bool?,
    );
  }
}

/// Terjemahkan [SunmiServiceInfo] jadi [PrinterCapabilities], atau `null`
/// bila servis belum tersambung (belum ada yang bisa disimpulkan).
///
/// Lebar 80 mm hanya dipercaya dari paket Sunmi asli: servis klon (mis.
/// Xcheng) terbukti melaporkan status yang tidak akurat, dan perangkatnya
/// handheld 58 mm. Konfirmasi cetak (`onPrintResult`) juga hanya dari paket
/// asli yang callback transaksinya belum pernah gagal datang.
PrinterCapabilities? sunmiCapabilities(SunmiServiceInfo info) {
  final genuine = info.genuine;
  if (genuine == null) return null;
  return PrinterCapabilities(
    paperWidthPx: genuine && info.paper == 0 ? 576 : 384,
    autoCut: false,
    reportsPaperOut: genuine,
    confirmsPrint: genuine && info.transactionCallback != false,
  );
}

/// Hasil satu transaksi cetak Sunmi (`exitPrinterBufferWithCallback` →
/// `onPrintResult`).
enum SunmiPrintOutcome {
  /// Printer melaporkan struk benar-benar tercetak (`onPrintResult` kode 0).
  printed,

  /// Printer melaporkan transaksi gagal (kode 1 atau `onRaiseException`).
  failed,

  /// Tidak ada jawaban pasti -- firmware lama/klon yang tidak mendukung
  /// callback transaksi, atau callback tidak datang dalam batas waktu. Data
  /// tetap sudah dikirim; hasil diverifikasi ulang lewat query status.
  unknown;

  static SunmiPrintOutcome parse(Object? raw) => switch (raw) {
    'printed' => printed,
    'failed' => failed,
    _ => unknown,
  };
}

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
    Future<SunmiPrintOutcome> Function(List<int> png, int feedLines)?
    printTransaction,
    Future<SunmiServiceInfo> Function()? serviceInfo,
    Duration connectPollInterval = const Duration(milliseconds: 200),
    Duration printTimeout = const Duration(seconds: 30),
    Duration stuckAfter = const Duration(seconds: 30),
  }) : _renderer = renderer,
       _connectPollInterval = connectPollInterval,
       _gate = PrintJobGate(timeout: printTimeout, stuckAfter: stuckAfter),
       _bind = bind ?? (() async => await _channel.invokeMethod<bool>('bind') ?? false),
       _unbind = unbind ?? (() => _channel.invokeMethod('unbind')),
       _updateState =
           updateState ??
           (() async =>
               await _channel.invokeMethod<int>('updateState') ??
               _stateNotDetected),
       _serviceInfo =
           serviceInfo ??
           (() async => SunmiServiceInfo.fromMap(
             await _channel.invokeMethod<Object?>('serviceInfo'),
           )),
       _printTransaction =
           printTransaction ??
           ((png, feedLines) async => SunmiPrintOutcome.parse(
             await _channel.invokeMethod<String>('printTransaction', {
               'bytes': Uint8List.fromList(png),
               'feedLines': feedLines,
             }),
           ));

  static const MethodChannel _channel = MethodChannel('blue_thermal_printer/sunmi');

  /// Baris kosong yang di-feed setelah struk supaya baris terakhir melewati
  /// tear bar (bitmap sendiri cuma punya margin bawah beberapa piksel).
  static const feedLines = 3;

  /// Berapa kali [connect] memeriksa servis setelah bind -- bind bersifat
  /// async dan di boot dingin servis Sunmi bisa butuh beberapa detik.
  static const _connectPollAttempts = 15;

  final ReceiptRenderer _renderer;
  final Duration _connectPollInterval;
  final PrintJobGate _gate;
  final Future<bool> Function() _bind;
  final Future<void> Function() _unbind;
  final Future<int> Function() _updateState;

  /// Satu transaksi buffer penuh di native: enter buffer → bitmap → feed →
  /// `exitPrinterBufferWithCallback`. Beda dari `printBitmap` polos yang
  /// callback-nya (`onRunResult`) menurut doc AIDL cuma menandakan panggilan
  /// API diterima, BUKAN struk tercetak.
  final Future<SunmiPrintOutcome> Function(List<int> png, int feedLines)
  _printTransaction;
  final Future<SunmiServiceInfo> Function() _serviceInfo;
  final _ensureFlight = SingleFlight<PrinterResult<PrinterDevice>>();

  /// Kemampuan terakhir yang diketahui saat servis tersambung -- dipakai
  /// [capabilities]/[preview] sebelum/tanpa koneksi.
  PrinterCapabilities _lastCapabilities = PrinterCapabilities.fallback58;

  ReceiptRenderer _rendererFor(PrinterCapabilities caps) =>
      ReceiptRenderer(width: caps.paperWidthPx, fontFamily: _renderer.fontFamily);

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
  Future<PrinterResult<PrinterDevice>> ensureConnected({
    PrinterDevice? lastDevice,
  }) => _ensureFlight.run(
    () => ensureBuiltInConnected(this, kSunmiBuiltInDevice),
  );

  @override
  Future<PrinterCapabilities> capabilities() async {
    try {
      final caps = sunmiCapabilities(await _serviceInfo());
      if (caps != null) _lastCapabilities = caps;
    } catch (_) {
      // Channel tidak ada (mis. desktop) -- pakai nilai terakhir.
    }
    return _lastCapabilities;
  }

  @override
  Future<Uint8List> preview(Receipt receipt) async =>
      _rendererFor(await capabilities()).preview(receipt);

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

  Future<PrinterStatus> _rawStatus() async =>
      sunmiStateToStatus(await _updateState());

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
      final preStatus = await _rawStatus();
      if (preStatus.hasKnownProblem) {
        return PrinterErr(PrinterFailure(preStatus.problemMessage!));
      }
      final caps = await capabilities();
      final bytes = await _rendererFor(caps).preview(receipt);
      final outcome = await _printTransaction(bytes, feedLines);
      switch (outcome) {
        case SunmiPrintOutcome.printed:
          // `printed` hanya datang dari callback transaksi paket asli; tetap
          // dijaga supaya `confirmed` tidak pernah melampaui capabilities.
          return PrinterOk(
            caps.confirmsPrint == true
                ? PrintDelivery.confirmed
                : PrintDelivery.unverified,
          );
        case SunmiPrintOutcome.failed:
          // Printer sudah pasti gagal -- query status hanya untuk memberi
          // pesan yang lebih spesifik bila penyebabnya diketahui.
          final status = await _statusOrUnknown();
          return PrinterErr(
            PrinterFailure(
              status.problemMessage ??
                  'Printer gagal mencetak. Periksa kertas sebelum mencoba ulang.',
            ),
          );
        case SunmiPrintOutcome.unknown:
          // Firmware tidak memberi jawaban pasti -- verifikasi ulang lewat
          // status seperti perilaku sebelum mode transaksi dipakai.
          final status = await _rawStatus();
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

  Future<PrinterStatus> _statusOrUnknown() async {
    try {
      return await _rawStatus();
    } catch (_) {
      return PrinterStatus.unknown;
    }
  }

  @override
  Future<void> openSystemSettings() async {
    // Printer bawaan tidak punya pengaturan sistem yang relevan (tidak ada
    // radio/pairing untuk dikonfigurasi) -- sengaja no-op.
  }
}

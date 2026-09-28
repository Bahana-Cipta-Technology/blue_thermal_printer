import 'package:flutter/services.dart';

import 'built_in_printer_backend.dart';
import 'printer_capabilities.dart';
import 'printer_device.dart';
import 'printer_status.dart';

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
/// `onPrintResult`): `printed` = kode 0, `failed` = kode 1 atau
/// `onRaiseException`, `unknown` = firmware lama/klon tanpa callback
/// transaksi, atau callback tidak datang dalam batas waktu.
typedef SunmiPrintOutcome = PrintOutcome;

/// Implementasi [BuiltInPrinterBackend] memakai servis printer bawaan Sunmi
/// ("Woyou") lewat AIDL, dibungkus native oleh `SunmiPrinterBridge`/
/// `SunmiPrinterChannel` (`android/.../vendor/sunmi/`).
///
/// Setiap pemanggilan native diperlakukan sebagai "tidak tersedia" di
/// platform yang tidak mengekspos channel ini (mis. Linux desktop), sama
/// seperti pola backend ESC/POS.
class PrinterBackendSunmi extends BuiltInPrinterBackend {
  PrinterBackendSunmi({
    super.renderer,
    Future<bool> Function()? bind,
    Future<void> Function()? unbind,
    Future<int> Function()? updateState,
    Future<SunmiPrintOutcome> Function(List<int> png, int feedLines)?
    printTransaction,
    Future<SunmiServiceInfo> Function()? serviceInfo,
    super.connectPollInterval,
    super.printTimeout,
    super.stuckAfter,
  }) : _bind = bind ?? (() async => await _channel.invokeMethod<bool>('bind') ?? false),
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
           )),
       super(device: kSunmiBuiltInDevice);

  static const MethodChannel _channel = MethodChannel('blue_thermal_printer/sunmi');

  /// Baris kosong yang di-feed setelah struk supaya baris terakhir melewati
  /// tear bar (bitmap sendiri cuma punya margin bawah beberapa piksel).
  static const feedLines = 3;

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

  @override
  String get displayName => 'Printer Bawaan Sunmi';

  @override
  Future<bool> bindService() => _bind();

  @override
  Future<void> unbindService() => _unbind();

  @override
  Future<bool> probeReady() async => await _updateState() != _stateNotDetected;

  @override
  Future<PrinterStatus> readStatus() async =>
      sunmiStateToStatus(await _updateState());

  @override
  Future<PrinterCapabilities?> readCapabilities() async =>
      sunmiCapabilities(await _serviceInfo());

  @override
  Future<PrintOutcome> sendRaster(Uint8List png, PrinterCapabilities caps) =>
      _printTransaction(png, feedLines);
}

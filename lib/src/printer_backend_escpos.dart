import 'dart:developer' as developer;
import 'dart:typed_data';

import 'package:app_settings/app_settings.dart';

import '../blue_thermal_printer.dart';
import 'built_in_connection.dart';
import 'escpos_transport.dart';
import 'printer_backend.dart';
import 'printer_capabilities.dart';
import 'printer_device.dart';
import 'print_job_gate.dart';
import 'printer_status.dart';
import 'receipt.dart';
import 'receipt_renderer.dart';
import 'result.dart';

/// Implementasi [PrinterBackend] untuk printer ESC/POS generik di atas satu
/// [EscposTransport]: Bluetooth Classic (constructor default, lewat
/// [BlueThermalPrinter] yang sudah ada di package ini), LAN, atau USB
/// ([PrinterBackendEscpos.withTransport]).
///
/// Pengiriman tunggal (busy-lock lewat [PrintJobGate]); timeout tidak
/// membatalkan pekerjaan native yang tertunda, tapi pekerjaan yang macet
/// terlalu lama memutus koneksi supaya write native terlepas. Setiap pemanggilan dibungkus try/catch dan
/// diperlakukan sebagai "tidak tersedia" di platform yang tidak didukung
/// plugin (mis. Linux desktop), sama seperti pola `DeviceCameraService` di
/// app konsumen.
class PrinterBackendEscpos implements PrinterBackend {
  /// Backend Bluetooth Classic (SPP). Parameter fungsi hanya untuk test.
  PrinterBackendEscpos({
    ReceiptRenderer renderer = const ReceiptRenderer(),
    Future<bool> Function()? isBluetoothOn,
    Future<bool> Function()? isPermissionGranted,
    Future<List<PrinterDevice>> Function()? discover,
    Future<bool> Function(PrinterDevice)? doConnect,
    Future<void> Function()? doDisconnect,
    Future<bool> Function()? connected,
    Future<bool> Function(List<int>)? write,
    Future<List<int>> Function(Receipt)? encode,
    Future<PrinterStatus> Function()? checkStatus,
    Future<void> Function()? openSettings,
    Duration printTimeout = const Duration(seconds: 30),
    Duration stuckAfter = const Duration(seconds: 30),
  }) : this.withTransport(
         _BluetoothEscposTransport(
           isBluetoothOn: isBluetoothOn,
           isPermissionGranted: isPermissionGranted,
           discover: discover,
           doConnect: doConnect,
           doDisconnect: doDisconnect,
           connected: connected,
           write: write,
           checkStatus: checkStatus,
           openSettings: openSettings,
         ),
         renderer: renderer,
         encode: encode,
         printTimeout: printTimeout,
         stuckAfter: stuckAfter,
       );

  /// Backend ESC/POS di atas [transport] mana pun (mis.
  /// `NetworkEscposTransport`, `UsbEscposTransport`).
  PrinterBackendEscpos.withTransport(
    EscposTransport transport, {
    ReceiptRenderer renderer = const ReceiptRenderer(),
    Future<List<int>> Function(Receipt)? encode,
    Duration printTimeout = const Duration(seconds: 30),
    Duration stuckAfter = const Duration(seconds: 30),
  }) : _transport = transport,
       _renderer = renderer,
       _encode = encode ?? renderer.encode {
    // Write native yang macet (socket tidak lagi dibaca printer) hanya bisa
    // dilepas dengan menutup koneksinya.
    _gate = PrintJobGate(
      timeout: printTimeout,
      stuckAfter: stuckAfter,
      onStuck: disconnect,
    );
  }

  final EscposTransport _transport;
  final ReceiptRenderer _renderer;
  final Future<List<int>> Function(Receipt) _encode;

  late final PrintJobGate _gate;

  /// Setelah berapa query status beruntun tanpa jawaban (dan belum pernah
  /// ada jawaban sejak terhubung) printer dianggap tidak mendukung `DLE EOT`.
  static const _unansweredStatusLimit = 2;

  int _unansweredStatusQueries = 0;
  bool _statusEverAnswered = false;

  /// `true` bila printer yang sedang terhubung terbukti tidak menjawab query
  /// status (mis. printer virtual `RPPInnerPrinter` di perangkat Xcheng) --
  /// query berikutnya dilewati sampai koneksi baru, supaya tiap cetak tidak
  /// membayar timeout native (±1,5 dtk per query, 2 query per cetak) tanpa
  /// hasil.
  bool get _statusUnsupported =>
      !_statusEverAnswered && _unansweredStatusQueries >= _unansweredStatusLimit;

  void _resetStatusSupport() {
    _unansweredStatusQueries = 0;
    _statusEverAnswered = false;
  }

  /// Alamat perangkat dari [connect] terakhir yang berhasil -- dukungan
  /// query status yang sudah dipelajari tetap berlaku saat menyambung ulang
  /// ke printer yang SAMA (mis. [ensureConnected] sebelum tiap cetak).
  String? _connectedAddress;

  final _ensureFlight = SingleFlight<PrinterResult<PrinterDevice>>();

  /// Query status lewat [_checkStatus], sambil belajar apakah printer ini
  /// mendukungnya. Jawaban `DLE EOT` yang sah selalu mengisi ketiga field;
  /// semua `null` berarti printer tidak menjawab.
  Future<PrinterStatus> _queryStatus() async {
    if (_statusUnsupported) return PrinterStatus.unknown;
    final status = await _transport.queryStatus();
    final answered =
        status.hasPaper != null ||
        status.coverClosed != null ||
        status.hasError != null;
    if (answered) {
      _statusEverAnswered = true;
      _unansweredStatusQueries = 0;
    } else {
      _unansweredStatusQueries++;
    }
    return status;
  }

  /// Percobaan koneksi yang sedang berjalan -- panggilan [connect] bersamaan
  /// (mis. auto-connect + tap pengguna) berbagi hasil yang sama alih-alih
  /// membuka dua socket ke printer.
  Future<PrinterResult<void>>? _pendingConnect;

  @override
  String get displayName => _transport.displayName;

  @override
  bool get requiresPairing => true;

  @override
  Future<bool> isAvailable() async {
    try {
      return await _transport.isEnabled();
    } catch (error) {
      _warn('Status transport tidak dapat diperiksa', error);
      return false;
    }
  }

  @override
  Future<List<PrinterDevice>> discoverDevices() async {
    try {
      return await _transport.discover();
    } catch (error) {
      _warn('Daftar perangkat gagal dibaca', error);
      return const <PrinterDevice>[];
    }
  }

  @override
  Future<PrinterResult<void>> connect(PrinterDevice device) {
    final pending = _pendingConnect;
    if (pending != null) return pending;
    final attempt = _connect(device);
    _pendingConnect = attempt;
    return attempt.whenComplete(() {
      if (identical(_pendingConnect, attempt)) _pendingConnect = null;
    });
  }

  Future<PrinterResult<void>> _connect(PrinterDevice device) async {
    try {
      final precondition = await _checkPreconditions();
      if (precondition != null) return PrinterErr(precondition);
      final failure = await _transport.connect(device);
      if (failure != null) return PrinterErr(failure);
      if (_connectedAddress != device.macAddress) _resetStatusSupport();
      _connectedAddress = device.macAddress;
      return const PrinterOk(null);
    } catch (error) {
      _warn('Koneksi printer gagal', error);
      return const PrinterErr(PrinterFailure('Gagal terhubung ke printer.'));
    }
  }

  /// Izin lalu transport aktif -- urutan ini penting: tanpa izin, status
  /// transport (mis. radio Bluetooth) pun belum tentu bisa dibaca.
  Future<PrinterFailure?> _checkPreconditions() async {
    if (!await _transport.isPermissionGranted()) {
      return PrinterFailure(
        _transport.permissionDeniedMessage,
        isPermissionDenied: true,
      );
    }
    if (!await _transport.isEnabled()) {
      return PrinterFailure(_transport.disabledMessage);
    }
    return null;
  }

  /// Sambung ke [lastDevice] tanpa interaksi pengguna. Native `connect` ke
  /// alamat yang sama selagi koneksi hidup langsung sukses tanpa menulis ke
  /// printer, jadi [isConnected] (yang menulis byte) tidak pernah dipakai.
  @override
  Future<PrinterResult<PrinterDevice>> ensureConnected({
    PrinterDevice? lastDevice,
  }) => _ensureFlight.run(() => _ensureConnected(lastDevice));

  Future<PrinterResult<PrinterDevice>> _ensureConnected(
    PrinterDevice? lastDevice,
  ) async {
    try {
      final precondition = await _checkPreconditions();
      if (precondition != null) return PrinterErr(precondition);
      if (lastDevice == null) {
        return const PrinterErr(
          PrinterFailure(
            'Pilih printer terlebih dahulu.',
            requiresDeviceSelection: true,
          ),
        );
      }
      var device = lastDevice;
      if (_transport.requiresDiscoveredDevice) {
        PrinterDevice? found;
        for (final candidate in await _transport.discover()) {
          if (candidate.macAddress == lastDevice.macAddress) {
            found = candidate;
            break;
          }
        }
        if (found == null) {
          return PrinterErr(
            PrinterFailure(
              _transport.deviceGoneMessage,
              requiresDeviceSelection: true,
            ),
          );
        }
        device = found;
      }
      final target = device;
      return (await connect(target)).map((_) => target);
    } catch (error) {
      _warn('Sambung otomatis printer gagal', error);
      return const PrinterErr(PrinterFailure('Gagal terhubung ke printer.'));
    }
  }

  @override
  Future<PrinterCapabilities> capabilities() async => PrinterCapabilities(
    paperWidthPx: _renderer.width,
    autoCut: false,
    reportsPaperOut: _statusEverAnswered
        ? true
        : _statusUnsupported
        ? false
        : null,
    // ESC/POS tidak mengonfirmasi struk tercetak (`DLE EOT` dijawab saat
    // byte diterima). Konfirmasi lewat process ID `GS ( H` fn=48 = fase 4.
    confirmsPrint: false,
  );

  @override
  Future<Uint8List> preview(Receipt receipt) => _renderer.preview(receipt);

  @override
  Future<void> disconnect() async {
    _resetStatusSupport();
    _connectedAddress = null;
    try {
      await _transport.disconnect();
    } catch (error) {
      _warn('Memutuskan koneksi printer gagal', error);
    }
  }

  @override
  Future<bool> isConnected() async {
    try {
      return await _transport.isConnected();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<PrinterResult<PrinterStatus>> checkStatus() async {
    if (!await isConnected()) {
      return const PrinterErr(PrinterFailure('Printer belum terhubung.'));
    }
    try {
      return PrinterOk(await _queryStatus());
    } catch (error) {
      _warn('Query status printer gagal', error);
      return const PrinterOk(PrinterStatus.unknown);
    }
  }

  @override
  Future<PrinterResult<PrintDelivery>> printReceipt(Receipt receipt) =>
      _gate.run(() => _send(receipt));

  Future<PrinterResult<PrintDelivery>> _send(Receipt receipt) async {
    try {
      if (!await _transport.isConnected()) {
        return const PrinterErr(
          PrinterFailure('Printer belum terhubung. Buka Koneksi Printer.'),
        );
      }
      // Cek status LEBIH DULU, sebelum satu byte pun terkirim -- untuk
      // skenario paling umum (kertas sudah habis sebelum operator mencoba
      // cetak), ini mencegah data ikut nyangkut di buffer printer sama
      // sekali. Status `unknown` (banyak printer clone tidak mendukung
      // `DLE EOT`) sengaja TIDAK memblokir -- `hasKnownProblem` sudah
      // dirancang begitu.
      final preStatus = await _queryStatus();
      if (preStatus.hasKnownProblem) {
        return PrinterErr(PrinterFailure(preStatus.problemMessage!));
      }
      final bytes = await _encode(receipt);
      if (!await _transport.write(bytes)) {
        return const PrinterErr(
          PrinterFailure(
            'Pengiriman gagal. Periksa kertas sebelum mencoba ulang.',
          ),
        );
      }
      // Penulisan ke socket/USB sukses selama koneksi masih hidup,
      // tanpa peduli printer sungguhan punya kertas/cover tertutup/dalam
      // kondisi error -- query status sekali lagi di sini supaya "byte
      // terkirim" tidak keliru dilaporkan sebagai "berhasil dicetak".
      final status = await _queryStatus();
      if (status.hasKnownProblem) {
        // Bersihkan buffer printer dari data yang baru saja gagal tercetak
        // sekarang juga -- best-effort, jangan sampai gagal di sini malah
        // menutupi pesan galat yang sebenarnya. Kalau operator tidak pernah
        // mencoba lagi, sisa data tidak menumpuk menunggu percobaan
        // berikutnya yang mungkin tidak pernah terjadi.
        try {
          await _transport.write(const [27, 64]); // ESC @ (Initialize Printer)
        } catch (_) {
          // Diabaikan -- ini cuma kebersihan, bukan penentu hasil.
        }
        return PrinterErr(PrinterFailure(status.problemMessage!));
      }
      return const PrinterOk(PrintDelivery.unverified);
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
    try {
      await _transport.openSettings();
    } catch (error) {
      _warn('Gagal membuka setelan transport', error);
    }
  }

  void _warn(String message, Object error) =>
      developer.log(message, name: 'PrinterBackendEscpos', error: error);
}

/// Transport Bluetooth Classic (SPP) lewat [BlueThermalPrinter] -- perilaku
/// backend ESC/POS sebelum transport bisa diganti, tidak berubah.
class _BluetoothEscposTransport extends EscposTransport {
  _BluetoothEscposTransport({
    Future<bool> Function()? isBluetoothOn,
    Future<bool> Function()? isPermissionGranted,
    Future<List<PrinterDevice>> Function()? discover,
    Future<bool> Function(PrinterDevice)? doConnect,
    Future<void> Function()? doDisconnect,
    Future<bool> Function()? connected,
    Future<bool> Function(List<int>)? write,
    Future<PrinterStatus> Function()? checkStatus,
    Future<void> Function()? openSettings,
  }) : _isBluetoothOn =
           isBluetoothOn ??
           (() async => await BlueThermalPrinter.instance.isOn ?? false),
       _isPermissionGranted =
           isPermissionGranted ??
           (() async =>
               await BlueThermalPrinter.instance.isPermissionBluetoothGranted ??
               false),
       _discover =
           discover ??
           (() async {
             final paired = await BlueThermalPrinter.instance
                 .getBondedDevices();
             return paired
                 .map(
                   (device) => PrinterDevice(
                     name: device.name ?? '',
                     macAddress: device.address ?? '',
                   ),
                 )
                 .toList();
           }),
       _doConnect =
           doConnect ??
           ((device) async {
             final connected = await BlueThermalPrinter.instance.connect(
               BluetoothDevice(device.name, device.macAddress),
             );
             return connected == true;
           }),
       _doDisconnect =
           doDisconnect ?? (() => BlueThermalPrinter.instance.disconnect()),
       _connected =
           connected ??
           (() async => await BlueThermalPrinter.instance.isConnected ?? false),
       _write =
           write ??
           ((bytes) async =>
               await BlueThermalPrinter.instance.writeBytes(
                 Uint8List.fromList(bytes),
               ) ??
               false),
       _checkStatus =
           checkStatus ??
           (() async {
             try {
               return escposOfflineStatus(
                 await BlueThermalPrinter.instance.queryPrinterStatus(
                   BlueThermalPrinter.statusTypeOffline,
                 ),
               );
             } catch (_) {
               return PrinterStatus.unknown;
             }
           }),
       _openSettings =
           openSettings ??
           (() => AppSettings.openAppSettings(type: AppSettingsType.bluetooth));

  final Future<bool> Function() _isBluetoothOn;
  final Future<bool> Function() _isPermissionGranted;
  final Future<List<PrinterDevice>> Function() _discover;
  final Future<bool> Function(PrinterDevice) _doConnect;
  final Future<void> Function() _doDisconnect;
  final Future<bool> Function() _connected;
  final Future<bool> Function(List<int>) _write;
  final Future<PrinterStatus> Function() _checkStatus;
  final Future<void> Function() _openSettings;

  @override
  String get displayName => 'Bluetooth ESC/POS';

  @override
  Future<bool> isEnabled() => _isBluetoothOn();

  @override
  Future<bool> isPermissionGranted() => _isPermissionGranted();

  @override
  Future<List<PrinterDevice>> discover() => _discover();

  /// Hanya perangkat yang masih dipasangkan yang disambung ulang otomatis.
  @override
  bool get requiresDiscoveredDevice => true;

  @override
  Future<PrinterFailure?> connect(PrinterDevice device) async =>
      await _doConnect(device)
      ? null
      : const PrinterFailure('Gagal terhubung ke printer.');

  @override
  Future<void> disconnect() => _doDisconnect();

  @override
  Future<bool> isConnected() => _connected();

  @override
  Future<bool> write(List<int> bytes) => _write(bytes);

  @override
  Future<PrinterStatus> queryStatus() => _checkStatus();

  @override
  Future<void> openSettings() => _openSettings();

  @override
  String get disabledMessage => 'Bluetooth belum aktif.';

  @override
  String get permissionDeniedMessage =>
      'Izin Bluetooth ditolak. Berikan izin lewat Setelan.';

  @override
  String get deviceGoneMessage =>
      'Printer terakhir tidak lagi dipasangkan. Pilih printer lagi.';
}

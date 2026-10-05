import 'dart:async';

import 'package:flutter/services.dart';

import 'device_scanner.dart';
import 'escpos_transport.dart';
import 'printer_device.dart';
import 'result.dart';
import 'transport_power.dart';
import 'transport_prerequisites.dart';

/// Kontrol adapter Bluetooth: prasyarat, nyala/mati, pencarian, dan pairing
/// lewat channel native `blue_thermal_printer/bluetooth`
/// (`transport/bluetooth/BluetoothControlChannel.java`).
///
/// Koneksi SPP dan cetak tetap lewat API lama (`BlueThermalPrinter`); kelas
/// ini hanya menyiapkan adapter dan menemukan/memasangkan perangkat. Tidak
/// ada method yang melempar -- platform tanpa channel ini (desktop, test)
/// terbaca sebagai "tidak ada Bluetooth".
class BluetoothControl
    implements
        TransportPowerControl,
        PrinterDeviceScanner,
        TransportPrerequisites {
  BluetoothControl({
    EscposChannelInvoke? invoke,
    Stream<Object?>? events,
    this.pairTimeout = const Duration(seconds: 65),
    this.scanGrace = const Duration(seconds: 5),
    this.powerOnTimeout = const Duration(seconds: 5),
  })  : _invoke = invoke ?? _defaultInvoke,
        _eventsOverride = events;

  static const channelName = 'blue_thermal_printer/bluetooth';
  static const eventsChannelName = 'blue_thermal_printer/bluetooth/events';

  static const _channel = MethodChannel(channelName);

  static Future<Object?> _defaultInvoke(
    String method, [
    Map<String, Object?>? arguments,
  ]) =>
      _channel.invokeMethod<Object?>(method, arguments);

  final EscposChannelInvoke _invoke;
  final Stream<Object?>? _eventsOverride;

  /// Batas tunggu pairing di sisi Dart (native sendiri menyerah setelah
  /// 60 dtk -- waktu untuk mengetik PIN).
  final Duration pairTimeout;

  /// Jeda setelah batas waktu pencarian sebelum Dart menutup sendiri
  /// pencarian yang tidak pernah dilaporkan selesai oleh native.
  final Duration scanGrace;

  /// Batas tunggu radio benar-benar menyala setelah [setEnabled] `changed`,
  /// sebelum [resolve] memeriksa ulang prasyarat.
  final Duration powerOnTimeout;

  /// Satu langganan native untuk semua instance dan pendengar -- tiap
  /// `receiveBroadcastStream` baru mengirim `listen` sendiri yang menimpa
  /// sink di native, dan `cancel`-nya memutus pendengar lain.
  static final Stream<Object?> _sharedEvents = const EventChannel(
    eventsChannelName,
  ).receiveBroadcastStream();

  late final Stream<Object?> _events = _eventsOverride ?? _sharedEvents;

  bool Function() _isPrinting = _never;
  static bool _never() => false;

  /// Dipasang `PrinterBackendEscpos`: pencarian ditolak selama struk
  /// dikirim, karena discovery memangkas throughput SPP.
  void bindPrintActivity(bool Function() isPrinting) =>
      _isPrinting = isPrinting;

  StreamController<ScanEvent>? _scan;
  StreamSubscription<Object?>? _scanSubscription;
  Timer? _scanGuard;

  @override
  bool get isScanning => _scan != null;

  // -------------------------------------------------------------------------
  // Prasyarat
  // -------------------------------------------------------------------------

  @override
  Future<PrerequisiteReport> checkPrerequisites() async {
    try {
      final raw = await _invoke('prerequisites');
      return raw is Map
          ? PrerequisiteReport.fromMap(raw)
          : PrerequisiteReport.unsupported;
    } catch (_) {
      return PrerequisiteReport.unsupported;
    }
  }

  @override
  Future<PrerequisiteReport> resolve(Prerequisite item) async {
    try {
      switch (item.resolution) {
        case PrerequisiteResolution.requestPermission:
          final raw = await _invoke('requestPermissions', {
            'permissions': item.permissions,
          });
          if (raw is Map) return PrerequisiteReport.fromMap(raw);
        case PrerequisiteResolution.enableTransport:
          await setEnabled(true);
        case PrerequisiteResolution.openAppSettings:
          await _invoke('openAppSettings');
        case PrerequisiteResolution.openLocationSettings:
          await _invoke('openLocationSettings');
        case PrerequisiteResolution.none:
          break;
      }
    } catch (_) {
      // Laporan terbaru di bawah tetap menunjukkan apa yang masih kurang.
    }
    return checkPrerequisites();
  }

  // -------------------------------------------------------------------------
  // Nyala / mati
  // -------------------------------------------------------------------------

  @override
  Future<TransportPowerState> powerState() async {
    try {
      return _parsePower(await _invoke('powerState')) ??
          TransportPowerState.unsupported;
    } catch (_) {
      return TransportPowerState.unsupported;
    }
  }

  @override
  Stream<TransportPowerState> watchPowerState() => _events
      .map((event) => event is Map && event['type'] == 'power'
          ? _parsePower(event['state'])
          : null)
      .where((state) => state != null)
      .cast<TransportPowerState>();

  @override
  Future<PrinterResult<PowerToggleOutcome>> setEnabled(bool enabled) async {
    try {
      // Pantau sebelum meminta, supaya transisi cepat tidak terlewat.
      // Tidak pernah gagal: timeout/stream galat = berhenti menunggu saja.
      final poweredOn = enabled
          ? watchPowerState()
              .firstWhere((state) => state == TransportPowerState.on)
              .timeout(powerOnTimeout)
              .then<void>((_) {}, onError: (Object _) {})
          : null;
      final raw = await _invoke('setEnabled', {'enabled': enabled});
      final outcome = PowerToggleOutcome.values.firstWhere(
        (value) => value.name == raw,
        orElse: () => PowerToggleOutcome.changed,
      );
      // Laporan prasyarat sesudahnya harus sudah melihat radio menyala.
      if (poweredOn != null && outcome == PowerToggleOutcome.changed) {
        await poweredOn;
      }
      return PrinterOk(outcome);
    } on PlatformException catch (error) {
      return PrinterErr(_failureFrom(error));
    } catch (_) {
      return const PrinterErr(PrinterFailure(_unsupportedMessage));
    }
  }

  // -------------------------------------------------------------------------
  // Pencarian
  // -------------------------------------------------------------------------

  @override
  Stream<ScanEvent> scan(
      {Duration timeout = PrinterDeviceScanner.defaultTimeout}) {
    final active = _scan;
    if (active != null) return active.stream;
    late final StreamController<ScanEvent> controller;
    var started = false;
    controller = StreamController<ScanEvent>.broadcast(
      onListen: () {
        if (started) return;
        started = true;
        unawaited(_startScan(controller, timeout));
      },
      // Tidak ada lagi yang mendengarkan: hentikan pencarian native juga.
      onCancel: () {
        if (controller.isClosed) return;
        _finishScan(controller, const ScanFinished(ScanEndReason.stopped));
        unawaited(_stopNative());
      },
    );
    _scan = controller;
    return controller.stream;
  }

  Future<void> _startScan(
    StreamController<ScanEvent> controller,
    Duration timeout,
  ) async {
    if (_isPrinting()) {
      _finishScan(
        controller,
        const ScanFinished(
          ScanEndReason.failed,
          failure: PrinterFailure(
              'Printer sedang mencetak. Cari lagi setelah selesai.'),
        ),
      );
      return;
    }
    _scanSubscription = _events.listen(
      (raw) {
        final event = _parseScanEvent(raw);
        if (event == null) return;
        if (event is ScanFinished) {
          _finishScan(controller, event);
        } else if (!controller.isClosed) {
          controller.add(event);
        }
      },
      onError: (Object _) => _finishScan(
        controller,
        const ScanFinished(ScanEndReason.failed,
            failure: PrinterFailure(_scanFailedMessage)),
      ),
    );
    try {
      await _invoke('startScan', {'timeoutMillis': timeout.inMilliseconds});
    } on PlatformException catch (error) {
      _finishScan(controller,
          ScanFinished(ScanEndReason.failed, failure: _failureFrom(error)));
      return;
    } catch (_) {
      _finishScan(
        controller,
        const ScanFinished(ScanEndReason.failed,
            failure: PrinterFailure(_unsupportedMessage)),
      );
      return;
    }
    if (controller.isClosed) return;
    _scanGuard = Timer(timeout + scanGrace, () {
      unawaited(_stopNative());
      _finishScan(controller, const ScanFinished(ScanEndReason.timedOut));
    });
  }

  void _finishScan(StreamController<ScanEvent> controller, ScanFinished event) {
    if (controller.isClosed) return;
    if (identical(_scan, controller)) {
      _scan = null;
      _scanGuard?.cancel();
      _scanGuard = null;
      unawaited(_scanSubscription?.cancel());
      _scanSubscription = null;
    }
    controller.add(event);
    unawaited(controller.close());
  }

  @override
  Future<void> stopScan() async {
    final active = _scan;
    if (active != null) {
      _finishScan(active, const ScanFinished(ScanEndReason.stopped));
    }
    await _stopNative();
  }

  Future<void> _stopNative() async {
    try {
      await _invoke('stopScan');
    } catch (_) {
      // Tidak ada pencarian / channel tidak ada -- tidak ada yang dihentikan.
    }
  }

  // -------------------------------------------------------------------------
  // Pairing
  // -------------------------------------------------------------------------

  @override
  Future<PrinterResult<PrinterDevice>> pair(PrinterDevice device) async {
    try {
      final raw = await _invoke('pair', {
        'address': device.macAddress,
      }).timeout(pairTimeout);
      return raw == 'bonded'
          ? PrinterOk(device)
          : const PrinterErr(PrinterFailure('Printer menolak pemasangan.'));
    } on PlatformException catch (error) {
      return PrinterErr(_failureFrom(error));
    } on TimeoutException {
      return const PrinterErr(PrinterFailure(_pairTimeoutMessage));
    } catch (_) {
      return const PrinterErr(PrinterFailure(_unsupportedMessage));
    }
  }

  // -------------------------------------------------------------------------
  // Parsing
  // -------------------------------------------------------------------------

  static TransportPowerState? _parsePower(Object? raw) {
    for (final state in TransportPowerState.values) {
      if (state.name == raw) return state;
    }
    return null;
  }

  static ScanEvent? _parseScanEvent(Object? raw) {
    if (raw is! Map) return null;
    switch (raw['type']) {
      case 'scanStarted':
        return const ScanStarted();
      case 'found':
        final address = raw['address'];
        if (address is! String || address.isEmpty) return null;
        return DeviceFound(
          DiscoveredPrinter(
            device: PrinterDevice(
              name: raw['name'] as String? ?? '',
              macAddress: address,
            ),
            rssi: raw['rssi'] as int?,
            deviceClass: raw['deviceClass'] as int?,
            isBonded: raw['bonded'] == true,
          ),
        );
      case 'scanFinished':
        final reason = ScanEndReason.values.firstWhere(
          (value) => value.name == raw['reason'],
          orElse: () => ScanEndReason.completed,
        );
        return ScanFinished(reason);
      default:
        return null;
    }
  }

  static const _unsupportedMessage = 'Perangkat ini tidak memiliki Bluetooth.';
  static const _scanFailedMessage =
      'Pencarian Bluetooth gagal dimulai. Coba lagi.';
  static const _pairTimeoutMessage = 'Pemasangan tidak selesai. Coba lagi.';

  static PrinterFailure _failureFrom(PlatformException error) =>
      switch (error.code) {
        'permission_denied' => const PrinterFailure(
            'Izin Bluetooth belum diberikan.',
            isPermissionDenied: true,
          ),
        'adapter_off' => const PrinterFailure('Bluetooth belum aktif.'),
        'location_off' => const PrinterFailure(
            'Lokasi belum aktif. Aktifkan Lokasi untuk mencari printer.',
          ),
        'no_activity' =>
          const PrinterFailure('Buka aplikasi untuk melanjutkan.'),
        'request_in_progress' =>
          const PrinterFailure('Permintaan sebelumnya masih diproses.'),
        'pair_rejected' =>
          const PrinterFailure('Pemasangan dibatalkan atau PIN salah.'),
        'pair_timeout' => const PrinterFailure(_pairTimeoutMessage),
        'pair_failed' => const PrinterFailure('Printer menolak pemasangan.'),
        'scan_failed' => const PrinterFailure(_scanFailedMessage),
        'unsupported' => const PrinterFailure(_unsupportedMessage),
        _ => const PrinterFailure('Operasi Bluetooth gagal. Coba lagi.'),
      };
}

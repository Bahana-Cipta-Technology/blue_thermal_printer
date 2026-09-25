import 'dart:typed_data';

import 'package:blue_thermal_printer/printer_backend.dart';

/// [PrinterBackend] palsu minimal untuk test komposisi (fallback, deteksi).
class FakeBackend implements PrinterBackend {
  FakeBackend({
    this.name = 'Fake',
    this.connectResult = true,
    this.connectThrows = false,
  });

  final String name;
  bool connectResult;
  final bool connectThrows;
  int connects = 0;
  int disconnects = 0;
  int prints = 0;
  int statusChecks = 0;
  int ensures = 0;

  @override
  String get displayName => name;

  @override
  bool get requiresPairing => false;

  @override
  Future<bool> isAvailable() async => connectResult;

  @override
  Future<List<PrinterDevice>> discoverDevices() async => [
    PrinterDevice(name: name, macAddress: '$name-builtin'),
  ];

  @override
  Future<PrinterResult<void>> connect(PrinterDevice device) async {
    connects++;
    if (connectThrows) throw Exception('probe error');
    return connectResult
        ? const PrinterOk(null)
        : PrinterErr(PrinterFailure('$name tidak terdeteksi.'));
  }

  @override
  Future<PrinterResult<PrinterDevice>> ensureConnected({
    PrinterDevice? lastDevice,
  }) async {
    ensures++;
    final device = PrinterDevice(name: name, macAddress: '$name-builtin');
    return (await connect(device)).map((_) => device);
  }

  @override
  Future<PrinterCapabilities> capabilities() async => PrinterCapabilities(
    paperWidthPx: 384,
    autoCut: false,
    confirmsPrint: name == 'Xcheng',
  );

  @override
  Future<Uint8List> preview(Receipt receipt) async =>
      Uint8List.fromList(name.codeUnits);

  @override
  Future<void> disconnect() async => disconnects++;

  @override
  Future<bool> isConnected() async => connectResult;

  @override
  Future<PrinterResult<PrinterStatus>> checkStatus() async {
    statusChecks++;
    return const PrinterOk(PrinterStatus.unknown);
  }

  @override
  Future<PrinterResult<PrintDelivery>> printReceipt(Receipt receipt) async {
    prints++;
    return PrinterErr(PrinterFailure('$name: Kertas printer habis.'));
  }

  @override
  Future<void> openSystemSettings() async {}
}

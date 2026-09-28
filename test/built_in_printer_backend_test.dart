import 'dart:typed_data';

import 'package:blue_thermal_printer/printer_backend.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/printer_backend_contract.dart';

/// Vendor fiktif minimal -- membuktikan kerangka [BuiltInPrinterBackend]
/// sendiri memenuhi kontrak, terlepas dari vendor konkret mana pun.
class _FakeVendorBackend extends BuiltInPrinterBackend {
  _FakeVendorBackend({
    required this.ready,
    this.status = PrinterStatus.unknown,
    this.caps,
    this.outcome = PrintOutcome.unknown,
    this.dependenciesThrow = false,
    this.requireConnection = false,
    this.onSend,
    super.printTimeout,
    super.stuckAfter,
  }) : super(
         device: const PrinterDevice(name: 'Printer Bawaan', macAddress: 'fake-builtin'),
         connectPollInterval: Duration.zero,
       );

  bool ready;
  PrinterStatus status;
  PrinterCapabilities? caps;
  PrintOutcome outcome;
  final bool dependenciesThrow;
  final bool requireConnection;
  final Future<void> Function()? onSend;

  int binds = 0;
  int sends = 0;
  int capabilityReads = 0;
  List<int>? lastPng;

  Never _fail() => throw Exception('channel error');

  @override
  String get displayName => 'Printer Bawaan Fake';

  @override
  bool get capabilitiesRequireConnection => requireConnection;

  @override
  Future<bool> bindService() async {
    if (dependenciesThrow) _fail();
    binds++;
    return ready;
  }

  @override
  Future<void> unbindService() async {
    if (dependenciesThrow) _fail();
  }

  @override
  Future<bool> probeReady() async => dependenciesThrow ? _fail() : ready;

  @override
  Future<PrinterStatus> readStatus() async => dependenciesThrow ? _fail() : status;

  @override
  Future<PrinterCapabilities?> readCapabilities() async {
    if (dependenciesThrow) _fail();
    capabilityReads++;
    return caps;
  }

  @override
  Future<PrintOutcome> sendRaster(Uint8List png, PrinterCapabilities caps) async {
    if (dependenciesThrow) _fail();
    sends++;
    lastPng = png;
    await onSend?.call();
    return outcome;
  }
}

void main() {
  const receipt = Receipt(lines: [ReceiptCenter('TES')]);
  const normal = PrinterStatus(hasPaper: true, coverClosed: true, hasError: false);

  runPrinterBackendContract('BuiltIn (kerangka)', ({
    required bool connected,
    ContractStatus status = ContractStatus.normal,
    bool dependenciesThrow = false,
    Future<void> Function()? onSend,
    Duration printTimeout = const Duration(seconds: 30),
    Duration stuckAfter = const Duration(seconds: 30),
  }) {
    final backend = _FakeVendorBackend(
      ready: connected,
      status: switch (status) {
        ContractStatus.normal => normal,
        ContractStatus.unknown => PrinterStatus.unknown,
        ContractStatus.paperOut => const PrinterStatus(hasPaper: false),
      },
      caps: const PrinterCapabilities(paperWidthPx: 384, autoCut: false),
      dependenciesThrow: dependenciesThrow,
      onSend: onSend,
      printTimeout: printTimeout,
      stuckAfter: stuckAfter,
    );
    return ContractHarness(
      backend: backend,
      sends: () => backend.sends,
      lastSentPng: () => backend.lastPng,
      connectAttempts: () => backend.binds,
    );
  });

  test('PrintOutcome.parse: hanya "printed"/"failed" yang dikenali', () {
    expect(PrintOutcome.parse('printed'), PrintOutcome.printed);
    expect(PrintOutcome.parse('failed'), PrintOutcome.failed);
    expect(PrintOutcome.parse('unknown'), PrintOutcome.unknown);
    expect(PrintOutcome.parse(null), PrintOutcome.unknown);
    expect(PrintOutcome.parse(1), PrintOutcome.unknown);
  });

  test('typedef outcome vendor adalah tipe yang sama', () {
    expect(SunmiPrintOutcome.parse('printed'), PrintOutcome.printed);
    expect(XchengPrintOutcome.failed, PrintOutcome.failed);
    expect(IminPrintOutcome.unknown, PrintOutcome.unknown);
  });

  test('capabilities() memakai nilai terakhir saat readCapabilities null/melempar', () async {
    const wide = PrinterCapabilities(paperWidthPx: 576, autoCut: true);
    final backend = _FakeVendorBackend(ready: true, caps: wide);
    expect(await backend.capabilities(), wide);

    backend.caps = null;
    expect(await backend.capabilities(), wide);

    expect(
      await _FakeVendorBackend(ready: true, dependenciesThrow: true).capabilities(),
      PrinterCapabilities.fallback58,
    );
  });

  test('capabilitiesRequireConnection: tidak query sebelum servis siap', () async {
    final backend = _FakeVendorBackend(
      ready: false,
      requireConnection: true,
      caps: const PrinterCapabilities(paperWidthPx: 576, autoCut: true),
    );
    expect(await backend.capabilities(), PrinterCapabilities.fallback58);
    expect(backend.capabilityReads, 0);

    backend.ready = true;
    expect((await backend.capabilities()).paperWidthPx, 576);
    expect(backend.capabilityReads, 1);
  });

  test('printReceipt membaca ulang capabilities tiap cetak', () async {
    final backend = _FakeVendorBackend(
      ready: true,
      status: normal,
      caps: const PrinterCapabilities(paperWidthPx: 576, autoCut: true),
    );
    await backend.printReceipt(receipt);
    expect(pngWidth(Uint8List.fromList(backend.lastPng!)), 576);

    backend.caps = const PrinterCapabilities(paperWidthPx: 384, autoCut: false);
    await backend.printReceipt(receipt);
    expect(pngWidth(Uint8List.fromList(backend.lastPng!)), 384);
  });

  test('outcome unknown + query status yang melempar setelah kirim = unverified', () async {
    var statusCalls = 0;
    final backend = _StatusThrowsAfterPreCheck(onStatus: () => statusCalls++);
    final result = await backend.printReceipt(receipt);
    expect(result.valueOrNull, PrintDelivery.unverified);
    expect(backend.sends, 1);
    expect(statusCalls, 2);
  });

  test('outcome printed: confirmed hanya bila confirmsPrint true', () async {
    PrinterBackend withConfirms(bool? confirms) => _FakeVendorBackend(
      ready: true,
      status: normal,
      outcome: PrintOutcome.printed,
      caps: PrinterCapabilities(
        paperWidthPx: 384,
        autoCut: false,
        confirmsPrint: confirms,
      ),
    );
    expect(
      (await withConfirms(true).printReceipt(receipt)).valueOrNull,
      PrintDelivery.confirmed,
    );
    for (final confirms in [false, null]) {
      expect(
        (await withConfirms(confirms).printReceipt(receipt)).valueOrNull,
        PrintDelivery.unverified,
        reason: '$confirms',
      );
    }
  });

  test('outcome failed: galat dengan pesan dari status bila diketahui', () async {
    final backend = _FakeVendorBackend(
      ready: true,
      status: normal,
      outcome: PrintOutcome.failed,
      caps: const PrinterCapabilities(paperWidthPx: 384, autoCut: false),
    );
    final generic = await backend.printReceipt(receipt);
    expect(generic.failureOrNull?.message, contains('Printer gagal mencetak'));

    // Pre-check lolos (status dibaca sebelum kirim), lalu kertas habis
    // terdeteksi setelah pekerjaan gagal.
    late final _FakeVendorBackend paperOut;
    paperOut = _FakeVendorBackend(
      ready: true,
      status: normal,
      outcome: PrintOutcome.failed,
      caps: const PrinterCapabilities(paperWidthPx: 384, autoCut: false),
      onSend: () async => paperOut.status = const PrinterStatus(hasPaper: false),
    );
    final result = await paperOut.printReceipt(receipt);
    expect(paperOut.sends, 1);
    expect(
      result.failureOrNull?.message,
      const PrinterStatus(hasPaper: false).problemMessage,
    );
  });

  test('bind gagal memakai notFoundMessage vendor', () async {
    final result = await _FakeVendorBackend(ready: false).connect(
      const PrinterDevice(name: 'x', macAddress: 'fake-builtin'),
    );
    expect(result.failureOrNull?.message, 'Gagal terhubung ke printer bawaan.');
  });
}

/// Pre-check sukses, tapi query status sesudah data terkirim melempar.
class _StatusThrowsAfterPreCheck extends _FakeVendorBackend {
  _StatusThrowsAfterPreCheck({required this.onStatus})
    : super(
        ready: true,
        caps: const PrinterCapabilities(paperWidthPx: 384, autoCut: false),
      );

  final void Function() onStatus;

  @override
  Future<PrinterStatus> readStatus() async {
    onStatus();
    if (sends > 0) throw Exception('channel error');
    return const PrinterStatus(hasPaper: true, coverClosed: true, hasError: false);
  }
}

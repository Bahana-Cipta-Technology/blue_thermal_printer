import 'package:blue_thermal_printer/printer_backend.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/printer_backend_contract.dart';

void main() {
  const receipt = Receipt(lines: []);

  runPrinterBackendContract('Ciontek', ({
    required bool connected,
    ContractStatus status = ContractStatus.normal,
    bool dependenciesThrow = false,
    Future<void> Function()? onSend,
    Duration printTimeout = const Duration(seconds: 30),
    Duration stuckAfter = const Duration(seconds: 30),
  }) {
    var sends = 0;
    var binds = 0;
    List<int>? sent;
    Never fail() => throw Exception('channel error');
    final code = switch (status) {
      ContractStatus.normal => 0,
      ContractStatus.unknown => null,
      ContractStatus.paperOut => -1,
    };
    return ContractHarness(
      backend: PrinterBackendCiontek(
        connectPollInterval: Duration.zero,
        printTimeout: printTimeout,
        stuckAfter: stuckAfter,
        bind: () async {
          if (dependenciesThrow) fail();
          binds++;
          return connected;
        },
        unbind: () async => dependenciesThrow ? fail() : null,
        isReady: () async {
          if (dependenciesThrow) fail();
          return connected;
        },
        status: () async {
          if (dependenciesThrow) fail();
          return connected ? code : null;
        },
        printBitmap: (png, __) async {
          if (dependenciesThrow) fail();
          sends++;
          sent = png;
          await onSend?.call();
          return CiontekPrintOutcome.unknown;
        },
      ),
      sends: () => sends,
      lastSentPng: () => sent,
      connectAttempts: () => binds,
    );
  });

  PrinterBackendCiontek backendWith({
    required List<int?> statusCodes,
    CiontekPrintOutcome outcome = CiontekPrintOutcome.printed,
    void Function()? onPrint,
  }) {
    var index = 0;
    return PrinterBackendCiontek(
      connectPollInterval: Duration.zero,
      isReady: () async => true,
      status: () async =>
          statusCodes[index < statusCodes.length ? index++ : statusCodes.length - 1],
      printBitmap: (_, __) async {
        onPrint?.call();
        return outcome;
      },
    );
  }

  group('ciontekStatusToPrinterStatus (tabel resmi Lib_PrnCheckStatus)', () {
    test('0 = normal; cover tidak dilaporkan', () {
      final status = ciontekStatusToPrinterStatus(0);

      expect(status.hasPaper, isTrue);
      expect(status.hasError, isFalse);
      expect(status.coverClosed, isNull);
      expect(status.hasKnownProblem, isFalse);
    });

    test('-1 = kertas habis', () {
      expect(ciontekStatusToPrinterStatus(-1).problemMessage, 'Kertas printer habis.');
    });

    test('-2 suhu tinggi dan -3 tegangan rendah = galat', () {
      expect(ciontekStatusToPrinterStatus(-2).hasError, isTrue);
      expect(ciontekStatusToPrinterStatus(-3).hasError, isTrue);
    });

    test('±1001/±1002 (modul printer tidak menjawab) = galat', () {
      for (final code in [-1001, 1001, -1002, 1002]) {
        expect(ciontekStatusToPrinterStatus(code).hasError, isTrue, reason: '$code');
      }
    });

    test('null dan kode tak dikenal = unknown (tidak memblokir)', () {
      expect(ciontekStatusToPrinterStatus(null).hasKnownProblem, isFalse);
      expect(ciontekStatusToPrinterStatus(-4001).hasKnownProblem, isFalse);
      expect(ciontekStatusToPrinterStatus(7).hasPaper, isNull);
    });
  });

  group('connect', () {
    test('perangkat tanpa servis posmanager: bind ditolak', () async {
      final backend = PrinterBackendCiontek(bind: () async => false);

      final result = await backend.connect(kCiontekBuiltInDevice);

      expect(
        result.failureOrNull?.message,
        'Printer bawaan Ciontek tidak ditemukan di perangkat ini.',
      );
    });

    test('servis tersambung tanpa status (sedang mencetak) tetap terhubung',
        () async {
      final backend = backendWith(statusCodes: [null]);

      expect(await backend.isConnected(), isTrue);
      expect((await backend.checkStatus()).valueOrNull?.hasKnownProblem, isFalse);
    });
  });

  group('printReceipt', () {
    test('kertas habis saat pre-check: tidak ada data terkirim', () async {
      var prints = 0;
      final backend = backendWith(statusCodes: [-1], onPrint: () => prints++);

      final result = await backend.printReceipt(receipt);

      expect(result.failureOrNull?.message, 'Kertas printer habis.');
      expect(prints, 0);
    });

    test('suhu tinggi saat pre-check: ditolak tanpa data', () async {
      var prints = 0;
      final backend = backendWith(statusCodes: [-2], onPrint: () => prints++);

      final result = await backend.printReceipt(receipt);

      expect(result.failureOrNull?.message, 'Printer melaporkan galat.');
      expect(prints, 0);
    });

    test('Lib_PrnStart 0 (printed) -> confirmed', () async {
      final backend = backendWith(statusCodes: [0]);

      expect((await backend.printReceipt(receipt)).valueOrNull, PrintDelivery.confirmed);
    });

    test('gagal + kertas habis sesudahnya -> pesan kertas habis', () async {
      final backend = backendWith(
        statusCodes: [0, -1],
        outcome: CiontekPrintOutcome.failed,
      );

      final result = await backend.printReceipt(receipt);

      expect(result.failureOrNull?.message, 'Kertas printer habis.');
    });

    test('gagal tanpa sebab diketahui -> pesan generik', () async {
      final backend = backendWith(
        statusCodes: [0],
        outcome: CiontekPrintOutcome.failed,
      );

      final result = await backend.printReceipt(receipt);

      expect(
        result.failureOrNull?.message,
        'Printer gagal mencetak. Periksa kertas sebelum mencoba ulang.',
      );
    });

    test('unknown (timeout servis) + status bersih -> unverified', () async {
      final backend = backendWith(
        statusCodes: [0],
        outcome: CiontekPrintOutcome.unknown,
      );

      expect((await backend.printReceipt(receipt)).valueOrNull, PrintDelivery.unverified);
    });

    test('mengirim PNG selebar 384 px + feedPixels', () async {
      List<int>? png;
      int? feed;
      final backend = PrinterBackendCiontek(
        isReady: () async => true,
        status: () async => 0,
        printBitmap: (bytes, feedPixels) async {
          png = bytes;
          feed = feedPixels;
          return CiontekPrintOutcome.printed;
        },
      );

      await backend.printReceipt(receipt);

      expect(png?.sublist(0, 8), [137, 80, 78, 71, 13, 10, 26, 10]);
      // Lebar IHDR (byte 16..19, big-endian) = 384.
      expect(png?.sublist(16, 20), [0, 0, 1, 128]);
      expect(feed, PrinterBackendCiontek.feedPixels);
    });
  });

  test('displayName, requiresPairing, dan kemampuan tetap', () async {
    final backend = PrinterBackendCiontek();

    expect(backend.displayName, 'Printer Bawaan Ciontek');
    expect(backend.requiresPairing, isFalse);
    expect(backend.supportsPaperWidthSetting, isFalse);
    expect(await backend.capabilities(), PrinterBackendCiontek.capabilitiesValue);
  });
}

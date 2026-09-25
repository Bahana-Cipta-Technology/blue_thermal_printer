import 'package:blue_thermal_printer/printer_backend.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/printer_backend_contract.dart';

void main() {
  const receipt = Receipt(lines: [ReceiptCenter('TES')]);

  runPrinterBackendContract('iMin', ({
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
      ContractStatus.unknown => 2, // di luar tabel resmi
      ContractStatus.paperOut => 7,
    };
    return ContractHarness(
      backend: PrinterBackendImin(
        connectPollInterval: Duration.zero,
        printTimeout: printTimeout,
        stuckAfter: stuckAfter,
        bind: () async {
          if (dependenciesThrow) fail();
          binds++;
          return connected;
        },
        unbind: () async => dependenciesThrow ? fail() : null,
        status: () async {
          if (dependenciesThrow) fail();
          return connected ? code : -1;
        },
        paperType: () async => dependenciesThrow ? fail() : 58,
        printResultVerified: () async => dependenciesThrow ? fail() : false,
        printTransaction: (png, __, ___) async {
          if (dependenciesThrow) fail();
          sends++;
          sent = png;
          await onSend?.call();
          return IminPrintOutcome.unknown;
        },
      ),
      sends: () => sends,
      lastSentPng: () => sent,
      connectAttempts: () => binds,
    );
  });

  PrinterBackendImin backendWith({
    required List<int> statusCodes,
    int? paperType = 58,
    IminPrintOutcome outcome = IminPrintOutcome.printed,
    void Function(List<int> png, int feedDistance, bool cut)? onPrint,
  }) {
    var index = 0;
    return PrinterBackendImin(
      connectPollInterval: Duration.zero,
      status: () async =>
          statusCodes[index < statusCodes.length ? index++ : statusCodes.length - 1],
      paperType: () async => paperType,
      printTransaction: (png, feedDistance, cut) async {
        onPrint?.call(png, feedDistance, cut);
        return outcome;
      },
    );
  }

  test('iminStatusToStatus memetakan hanya kode resmi SDK 2.0', () {
    final normal = iminStatusToStatus(0);
    expect(normal.hasKnownProblem, isFalse);
    expect(normal.hasPaper, isTrue);

    expect(iminStatusToStatus(3).coverClosed, isFalse);
    expect(iminStatusToStatus(4).hasError, isTrue);
    expect(iminStatusToStatus(7).hasPaper, isFalse);

    // Kode SDK 1.0 / tak dikenal tidak memblokir.
    for (final code in [1, 2, 8, 99, 505]) {
      expect(iminStatusToStatus(code).hasKnownProblem, isFalse, reason: '$code');
    }
  });

  test('IminPrintOutcome.parse', () {
    expect(IminPrintOutcome.parse('printed'), IminPrintOutcome.printed);
    expect(IminPrintOutcome.parse('failed'), IminPrintOutcome.failed);
    expect(IminPrintOutcome.parse('unknown'), IminPrintOutcome.unknown);
    expect(IminPrintOutcome.parse(null), IminPrintOutcome.unknown);
  });

  group('connect', () {
    test('perangkat tanpa servis iMin: bind ditolak', () async {
      final backend = PrinterBackendImin(bind: () async => false);

      final result = await backend.connect(kIminBuiltInDevice);

      expect(
        result.failureOrNull?.message,
        'Printer bawaan iMin tidak ditemukan di perangkat ini.',
      );
    });

    test('menunggu handshake initPrinter (status -1) selesai', () async {
      var polls = 0;
      final backend = PrinterBackendImin(
        connectPollInterval: Duration.zero,
        bind: () async => true,
        status: () async => ++polls < 3 ? -1 : 0,
      );

      expect((await backend.connect(kIminBuiltInDevice)).isOk, isTrue);
      expect(polls, 3);
    });

    test('fd tidak pernah siap -> tidak terdeteksi', () async {
      final backend = PrinterBackendImin(
        connectPollInterval: Duration.zero,
        bind: () async => true,
        status: () async => -1,
      );

      final result = await backend.connect(kIminBuiltInDevice);

      expect(result.failureOrNull?.message, 'Printer bawaan tidak terdeteksi.');
    });
  });

  group('lebar kertas', () {
    Future<(int width, bool cut)> printWith(int? paperType) async {
      late List<int> png;
      late bool cut;
      final backend = backendWith(
        statusCodes: [0],
        paperType: paperType,
        onPrint: (bytes, _, c) {
          png = bytes;
          cut = c;
        },
      );
      await backend.printReceipt(receipt);
      // Lebar PNG: big-endian di byte 16..19 chunk IHDR.
      final width = png[16] << 24 | png[17] << 16 | png[18] << 8 | png[19];
      return (width, cut);
    }

    test('80 mm -> 576 px dan kertas dipotong', () async {
      expect(await printWith(80), (PrinterBackendImin.paper80WidthPx, true));
    });

    test('58 mm -> 384 px tanpa potong', () async {
      expect(await printWith(58), (PrinterBackendImin.paper58WidthPx, false));
    });

    test('jenis kertas tidak diketahui -> 384 px tanpa potong', () async {
      expect(await printWith(null), (PrinterBackendImin.paper58WidthPx, false));
    });

    test('paperType yang melempar tidak menggagalkan cetak', () async {
      final backend = PrinterBackendImin(
        status: () async => 0,
        paperType: () async => throw Exception('channel error'),
        printTransaction: (_, __, cut) async {
          expect(cut, isFalse);
          return IminPrintOutcome.printed;
        },
      );

      expect((await backend.printReceipt(receipt)).isOk, isTrue);
    });

    test('feedDistance default dikirim ke native', () async {
      int? feed;
      final backend = backendWith(
        statusCodes: [0],
        onPrint: (_, f, __) => feed = f,
      );

      await backend.printReceipt(receipt);

      expect(feed, PrinterBackendImin.feedDistance);
    });
  });

  group('printReceipt', () {
    test('cover terbuka saat pre-check: tidak ada data terkirim', () async {
      var prints = 0;
      final backend = backendWith(
        statusCodes: [3],
        onPrint: (_, __, ___) => prints++,
      );

      final result = await backend.printReceipt(receipt);

      expect(result.failureOrNull?.message, 'Penutup printer terbuka.');
      expect(prints, 0);
    });

    test('printed -> sukses', () async {
      final backend = backendWith(statusCodes: [0]);

      expect((await backend.printReceipt(receipt)).isOk, isTrue);
    });

    test('unknown + kertas habis sesudahnya -> gagal', () async {
      // isConnected + pre-check normal; habis di tengah cetak.
      final backend = backendWith(
        statusCodes: [0, 0, 7],
        outcome: IminPrintOutcome.unknown,
      );

      final result = await backend.printReceipt(receipt);

      expect(result.failureOrNull?.message, 'Kertas printer habis.');
    });

    test('unknown + status normal -> sukses (tidak ada bukti gagal)', () async {
      final backend = backendWith(
        statusCodes: [0],
        outcome: IminPrintOutcome.unknown,
      );

      expect((await backend.printReceipt(receipt)).isOk, isTrue);
    });

    test('failed -> gagal, pesan generik bila status normal', () async {
      final backend = backendWith(
        statusCodes: [0],
        outcome: IminPrintOutcome.failed,
      );

      final result = await backend.printReceipt(receipt);

      expect(
        result.failureOrNull?.message,
        'Printer gagal mencetak. Periksa kertas sebelum mencoba ulang.',
      );
    });

    test('failed + overheat -> pesan galat printer', () async {
      final backend = backendWith(
        statusCodes: [0, 0, 4],
        outcome: IminPrintOutcome.failed,
      );

      final result = await backend.printReceipt(receipt);

      expect(result.failureOrNull?.message, 'Printer melaporkan galat.');
    });
  });
}

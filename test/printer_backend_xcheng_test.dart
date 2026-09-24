import 'package:blue_thermal_printer/printer_backend.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/printer_backend_contract.dart';

void main() {
  const receipt = Receipt(lines: []);

  runPrinterBackendContract('Xcheng', ({
    required bool connected,
    ContractStatus status = ContractStatus.normal,
    bool dependenciesThrow = false,
    Future<void> Function()? onSend,
    Duration printTimeout = const Duration(seconds: 30),
    Duration stuckAfter = const Duration(seconds: 30),
  }) {
    var sends = 0;
    Never fail() => throw Exception('channel error');
    final paper = switch (status) {
      ContractStatus.normal => true,
      ContractStatus.unknown => null,
      ContractStatus.paperOut => false,
    };
    return ContractHarness(
      backend: PrinterBackendXcheng(
        connectPollInterval: Duration.zero,
        printTimeout: printTimeout,
        stuckAfter: stuckAfter,
        bind: () async => dependenciesThrow ? fail() : connected,
        unbind: () async => dependenciesThrow ? fail() : null,
        hasPaper: () async {
          if (dependenciesThrow) fail();
          if (!connected) return null;
          return paper;
        },
        printBitmap: (_, __) async {
          if (dependenciesThrow) fail();
          sends++;
          await onSend?.call();
          return XchengPrintOutcome.unknown;
        },
      ),
      sends: () => sends,
    );
  }, supportsUnknownStatus: false);

  PrinterBackendXcheng backendWith({
    required List<bool?> paperReadings,
    XchengPrintOutcome outcome = XchengPrintOutcome.printed,
    void Function()? onPrint,
  }) {
    var index = 0;
    return PrinterBackendXcheng(
      connectPollInterval: Duration.zero,
      hasPaper: () async =>
          paperReadings[index < paperReadings.length ? index++ : paperReadings.length - 1],
      printBitmap: (_, __) async {
        onPrint?.call();
        return outcome;
      },
    );
  }

  test('XchengPrintOutcome.parse', () {
    expect(XchengPrintOutcome.parse('printed'), XchengPrintOutcome.printed);
    expect(XchengPrintOutcome.parse('failed'), XchengPrintOutcome.failed);
    expect(XchengPrintOutcome.parse('unknown'), XchengPrintOutcome.unknown);
    expect(XchengPrintOutcome.parse(null), XchengPrintOutcome.unknown);
  });

  group('status', () {
    test('sensor kertas null = servis belum tersambung / tidak cocok', () async {
      final backend = backendWith(paperReadings: [null]);

      expect(await backend.isAvailable(), isFalse);
      expect((await backend.checkStatus()).isErr, isTrue);
    });

    test('sensor kertas false dilaporkan sebagai kertas habis', () async {
      final backend = backendWith(paperReadings: [false]);

      final status = (await backend.checkStatus()).valueOrNull;

      expect(status?.hasPaper, isFalse);
      // Servis ini tidak melaporkan cover/galat.
      expect(status?.coverClosed, isNull);
      expect(status?.hasError, isNull);
    });
  });

  group('connect', () {
    test('perangkat tanpa servis Xcheng: bind ditolak', () async {
      final backend = PrinterBackendXcheng(bind: () async => false);

      final result = await backend.connect(kXchengBuiltInDevice);

      expect(
        result.failureOrNull?.message,
        'Printer bawaan Xcheng tidak ditemukan di perangkat ini.',
      );
    });

    test('menunggu servis tersambung setelah bind', () async {
      var polls = 0;
      final backend = PrinterBackendXcheng(
        connectPollInterval: Duration.zero,
        bind: () async => true,
        hasPaper: () async => ++polls < 4 ? null : true,
      );

      expect((await backend.connect(kXchengBuiltInDevice)).isOk, isTrue);
      expect(polls, 4);
    });
  });

  group('printReceipt', () {
    test('kertas habis saat pre-check: tidak ada data terkirim (cegah penumpukan)',
        () async {
      var prints = 0;
      final backend = backendWith(
        paperReadings: [false],
        onPrint: () => prints++,
      );

      final result = await backend.printReceipt(receipt);

      expect(result.failureOrNull?.message, 'Kertas printer habis.');
      expect(prints, 0);
    });

    test('onComplete (printed) -> sukses', () async {
      final backend = backendWith(paperReadings: [true]);

      expect((await backend.printReceipt(receipt)).isOk, isTrue);
    });

    test('tanpa callback + sensor kertas habis sesudahnya -> gagal', () async {
      // isConnected + pre-check melihat kertas; habis di tengah cetak.
      final backend = backendWith(
        paperReadings: [true, true, false],
        outcome: XchengPrintOutcome.unknown,
      );

      final result = await backend.printReceipt(receipt);

      expect(result.failureOrNull?.message, 'Kertas printer habis.');
    });

    test('tanpa callback + kertas masih ada -> sukses (tidak ada bukti gagal)',
        () async {
      final backend = backendWith(
        paperReadings: [true],
        outcome: XchengPrintOutcome.unknown,
      );

      expect((await backend.printReceipt(receipt)).isOk, isTrue);
    });

    test('onException -> gagal, pesan generik bila kertas masih ada', () async {
      final backend = backendWith(
        paperReadings: [true],
        outcome: XchengPrintOutcome.failed,
      );

      final result = await backend.printReceipt(receipt);

      expect(
        result.failureOrNull?.message,
        'Printer gagal mencetak. Periksa kertas sebelum mencoba ulang.',
      );
    });

    test('onException + kertas habis -> pesan kertas habis', () async {
      final backend = backendWith(
        paperReadings: [true, true, false],
        outcome: XchengPrintOutcome.failed,
      );

      final result = await backend.printReceipt(receipt);

      expect(result.failureOrNull?.message, 'Kertas printer habis.');
    });

    test('mengirim PNG hasil render + feedLines', () async {
      List<int>? png;
      int? feed;
      final backend = PrinterBackendXcheng(
        hasPaper: () async => true,
        printBitmap: (bytes, feedLines) async {
          png = bytes;
          feed = feedLines;
          return XchengPrintOutcome.printed;
        },
      );

      await backend.printReceipt(receipt);

      expect(png?.sublist(0, 8), [137, 80, 78, 71, 13, 10, 26, 10]);
      expect(feed, PrinterBackendXcheng.feedLines);
    });
  });

  test('displayName dan requiresPairing', () {
    final backend = PrinterBackendXcheng();

    expect(backend.displayName, 'Printer Bawaan Xcheng');
    expect(backend.requiresPairing, isFalse);
  });
}

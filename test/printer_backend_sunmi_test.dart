import 'dart:async';

import 'package:blue_thermal_printer/printer_backend.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/printer_backend_contract.dart';

void main() {
  const receipt = Receipt(lines: []);
  const device = PrinterDevice(name: 'Printer Bawaan', macAddress: 'sunmi-builtin');

  runPrinterBackendContract('Sunmi', ({
    required bool connected,
    ContractStatus status = ContractStatus.normal,
    bool dependenciesThrow = false,
    Future<void> Function()? onSend,
    Duration printTimeout = const Duration(seconds: 30),
    Duration stuckAfter = const Duration(seconds: 30),
  }) {
    var sends = 0;
    Never fail() => throw Exception('channel error');
    final code = switch (status) {
      ContractStatus.normal => 1,
      ContractStatus.unknown => 2,
      ContractStatus.paperOut => 4,
    };
    return ContractHarness(
      backend: PrinterBackendSunmi(
        connectPollInterval: Duration.zero,
        printTimeout: printTimeout,
        stuckAfter: stuckAfter,
        bind: () async => dependenciesThrow ? fail() : connected,
        unbind: () async => dependenciesThrow ? fail() : null,
        updateState: () async {
          if (dependenciesThrow) fail();
          return connected ? code : 505;
        },
        printTransaction: (_, __) async {
          if (dependenciesThrow) fail();
          sends++;
          await onSend?.call();
          return SunmiPrintOutcome.unknown;
        },
      ),
      sends: () => sends,
    );
  });

  group('sunmiStateToStatus (tabel updatePrinterState AIDL)', () {
    test('1 normal: semua kondisi baik', () {
      final status = sunmiStateToStatus(1);
      expect(status.hasPaper, isTrue);
      expect(status.coverClosed, isTrue);
      expect(status.hasError, isFalse);
    });

    test('4 kertas habis (dulu keliru dipetakan dari kode 3)', () {
      expect(sunmiStateToStatus(4).hasPaper, isFalse);
      expect(sunmiStateToStatus(4).problemMessage, 'Kertas printer habis.');
    });

    test('3 gagal membaca status BUKAN kertas habis, dianggap unknown', () {
      expect(sunmiStateToStatus(3).hasPaper, isNull);
      expect(sunmiStateToStatus(3).hasKnownProblem, isFalse);
    });

    test('6 cover terbuka', () {
      expect(sunmiStateToStatus(6).coverClosed, isFalse);
    });

    test('5 overheat, 7 cutter abnormal, 507 upgrade firmware gagal -> galat', () {
      for (final code in [5, 7, 507]) {
        expect(sunmiStateToStatus(code).hasError, isTrue, reason: 'kode $code');
      }
    });

    test('kode transien/tak dikenal tidak memblokir cetak', () {
      for (final code in [0, 2, 3, 8, 9, 42, -1]) {
        expect(
          sunmiStateToStatus(code).hasKnownProblem,
          isFalse,
          reason: 'kode $code',
        );
      }
    });
  });

  test('SunmiPrintOutcome.parse membaca nilai channel native', () {
    expect(SunmiPrintOutcome.parse('printed'), SunmiPrintOutcome.printed);
    expect(SunmiPrintOutcome.parse('failed'), SunmiPrintOutcome.failed);
    expect(SunmiPrintOutcome.parse('unknown'), SunmiPrintOutcome.unknown);
    expect(SunmiPrintOutcome.parse(null), SunmiPrintOutcome.unknown);
    expect(SunmiPrintOutcome.parse(true), SunmiPrintOutcome.unknown);
  });

  group('isAvailable/discoverDevices', () {
    test('tersedia saat updateState bukan 505 (tidak terdeteksi)', () async {
      final backend = PrinterBackendSunmi(updateState: () async => 1);

      expect(await backend.isAvailable(), isTrue);
      expect(await backend.discoverDevices(), [device]);
    });

    test('kode transien (2/3) tetap dianggap tersedia', () async {
      for (final code in [2, 3]) {
        final backend = PrinterBackendSunmi(updateState: () async => code);
        expect(await backend.isAvailable(), isTrue, reason: 'kode $code');
      }
    });

    test('tidak tersedia saat updateState 505', () async {
      final backend = PrinterBackendSunmi(updateState: () async => 505);

      expect(await backend.isAvailable(), isFalse);
      // discoverDevices() TETAP mengembalikan slot sintetisnya walau belum
      // available -- backend ini baru available SETELAH connect() berhasil
      // bind, jadi menggerbang di sini akan membuat pemanggil (mis.
      // auto-connect) tidak pernah punya perangkat untuk dicoba sambungkan.
      expect(await backend.discoverDevices(), [device]);
    });

    test('tidak tersedia saat updateState melempar galat', () async {
      final backend = PrinterBackendSunmi(
        updateState: () async => throw Exception('channel error'),
      );

      expect(await backend.isAvailable(), isFalse);
    });
  });

  group('connect', () {
    test('gagal bind mengembalikan PrinterErr', () async {
      final backend = PrinterBackendSunmi(bind: () async => false);

      final result = await backend.connect(device);

      expect(result.isErr, isTrue);
    });

    test('bind melempar mengembalikan PrinterErr', () async {
      final backend = PrinterBackendSunmi(
        bind: () async => throw Exception('bindService ditolak'),
      );

      expect((await backend.connect(device)).isErr, isTrue);
    });

    test('bind sukses dan langsung tersedia mengembalikan PrinterOk', () async {
      final backend = PrinterBackendSunmi(
        bind: () async => true,
        updateState: () async => 1,
      );

      final result = await backend.connect(device);

      expect(result.isOk, isTrue);
    });

    test('servis yang baru tersambung setelah beberapa detik tetap berhasil',
        () async {
      // Boot dingin: callback onServiceConnected datang terlambat. Dulu
      // connect() menyerah setelah 5 x 200 ms.
      var polls = 0;
      final backend = PrinterBackendSunmi(
        connectPollInterval: Duration.zero,
        bind: () async => true,
        updateState: () async => ++polls < 10 ? 505 : 1,
      );

      expect((await backend.connect(device)).isOk, isTrue);
      expect(polls, 10);
    });

    test('bind sukses tapi tidak pernah terdeteksi tetap gagal', () async {
      var polls = 0;
      final backend = PrinterBackendSunmi(
        connectPollInterval: Duration.zero,
        bind: () async => true,
        updateState: () async {
          polls++;
          return 505;
        },
      );

      final result = await backend.connect(device);

      expect(result.failureOrNull?.message, 'Printer bawaan tidak terdeteksi.');
      expect(polls, 15);
    });
  });

  group('checkStatus', () {
    test('kode 1 (normal) melaporkan semua kondisi baik', () async {
      final backend = PrinterBackendSunmi(updateState: () async => 1);

      final result = await backend.checkStatus();

      expect(result.isOk, isTrue);
      expect(result.valueOrNull?.hasKnownProblem, isFalse);
    });

    test('kode 4 (kertas habis)', () async {
      final backend = PrinterBackendSunmi(updateState: () async => 4);

      final result = await backend.checkStatus();

      expect(result.valueOrNull?.hasPaper, isFalse);
    });

    test('kode 505 (tidak terdeteksi) mengembalikan PrinterErr', () async {
      final backend = PrinterBackendSunmi(updateState: () async => 505);

      final result = await backend.checkStatus();

      expect(result.isErr, isTrue);
    });

    test('query status melempar setelah terhubung tetap Ok(unknown)', () async {
      var calls = 0;
      final backend = PrinterBackendSunmi(
        updateState: () async {
          // Panggilan pertama: isConnected(); kedua: query status.
          if (++calls == 1) return 1;
          throw Exception('RemoteException');
        },
      );

      final result = await backend.checkStatus();

      expect(result.isOk, isTrue);
      expect(result.valueOrNull?.hasKnownProblem, isFalse);
    });
  });

  group('printReceipt', () {
    PrinterBackendSunmi backendWith({
      required Future<int> Function() updateState,
      required SunmiPrintOutcome outcome,
      List<int>? feedLinesSeen,
    }) => PrinterBackendSunmi(
      updateState: updateState,
      printTransaction: (_, feedLines) async {
        feedLinesSeen?.add(feedLines);
        return outcome;
      },
    );

    test('outcome printed -> sukses tanpa perlu post-check', () async {
      var stateCalls = 0;
      final feedLines = <int>[];
      final backend = backendWith(
        updateState: () async {
          stateCalls++;
          return 1;
        },
        outcome: SunmiPrintOutcome.printed,
        feedLinesSeen: feedLines,
      );

      expect((await backend.printReceipt(receipt)).isOk, isTrue);
      // isConnected + pre-check saja.
      expect(stateCalls, 2);
      expect(feedLines, [PrinterBackendSunmi.feedLines]);
    });

    test('outcome failed -> galat dengan pesan status bila diketahui', () async {
      var call = 0;
      final backend = backendWith(
        // isConnected + pre-check normal; setelah transaksi gagal, kertas habis.
        updateState: () async => ++call <= 2 ? 1 : 4,
        outcome: SunmiPrintOutcome.failed,
      );

      final result = await backend.printReceipt(receipt);

      expect(result.failureOrNull?.message, 'Kertas printer habis.');
    });

    test('outcome failed tanpa penyebab diketahui -> pesan generik', () async {
      final backend = backendWith(
        updateState: () async => 1,
        outcome: SunmiPrintOutcome.failed,
      );

      final result = await backend.printReceipt(receipt);

      expect(
        result.failureOrNull?.message,
        'Printer gagal mencetak. Periksa kertas sebelum mencoba ulang.',
      );
    });

    test('outcome failed walau query status pasca-gagal melempar', () async {
      var call = 0;
      final backend = backendWith(
        updateState: () async {
          if (++call <= 2) return 1;
          throw Exception('RemoteException');
        },
        outcome: SunmiPrintOutcome.failed,
      );

      expect((await backend.printReceipt(receipt)).isErr, isTrue);
    });

    test('outcome unknown + status normal -> sukses (firmware tanpa callback)',
        () async {
      final backend = backendWith(
        updateState: () async => 1,
        outcome: SunmiPrintOutcome.unknown,
      );

      expect((await backend.printReceipt(receipt)).isOk, isTrue);
    });

    test('outcome unknown + post-check kertas habis -> galat', () async {
      var call = 0;
      final backend = backendWith(
        updateState: () async => ++call <= 2 ? 1 : 4,
        outcome: SunmiPrintOutcome.unknown,
      );

      final result = await backend.printReceipt(receipt);

      expect(result.failureOrNull?.message, 'Kertas printer habis.');
    });

    test('pre-check kertas habis (kode 4) tidak mengirim transaksi', () async {
      var sends = 0;
      final backend = PrinterBackendSunmi(
        updateState: () async => 4,
        printTransaction: (_, __) async {
          sends++;
          return SunmiPrintOutcome.printed;
        },
      );

      final result = await backend.printReceipt(receipt);

      expect(result.failureOrNull?.message, 'Kertas printer habis.');
      expect(sends, 0);
    });

    test('pre-check cover terbuka / overheat tidak mengirim transaksi', () async {
      for (final code in [6, 5]) {
        var sends = 0;
        final backend = PrinterBackendSunmi(
          updateState: () async => code,
          printTransaction: (_, __) async {
            sends++;
            return SunmiPrintOutcome.printed;
          },
        );

        expect((await backend.printReceipt(receipt)).isErr, isTrue);
        expect(sends, 0, reason: 'kode $code');
      }
    });

    test('transaksi native melempar dilaporkan sebagai galat', () async {
      final backend = PrinterBackendSunmi(
        updateState: () async => 1,
        printTransaction: (_, __) async => throw Exception('channel error'),
      );

      expect((await backend.printReceipt(receipt)).isErr, isTrue);
    });

    test('yang dikirim ke native adalah PNG hasil render', () async {
      List<int>? sent;
      final backend = PrinterBackendSunmi(
        updateState: () async => 1,
        printTransaction: (png, _) async {
          sent = png;
          return SunmiPrintOutcome.printed;
        },
      );

      await backend.printReceipt(receipt);

      expect(sent?.sublist(0, 8), [137, 80, 78, 71, 13, 10, 26, 10]);
    });

    test('menolak cetak bersamaan dan dapat mencoba ulang setelah gagal', () async {
      final pending = Completer<SunmiPrintOutcome>();
      var prints = 0;
      final backend = PrinterBackendSunmi(
        updateState: () async => 1,
        printTransaction: (_, __) {
          prints++;
          return prints == 1
              ? pending.future
              : Future.value(SunmiPrintOutcome.printed);
        },
      );

      final first = backend.printReceipt(receipt);
      expect((await backend.printReceipt(receipt)).isErr, isTrue);
      pending.complete(SunmiPrintOutcome.failed);
      expect((await first).isErr, isTrue);
      expect(prints, 1);
      expect((await backend.printReceipt(receipt)).isOk, isTrue);
      expect(prints, 2);
    });
  });

  test('displayName dan requiresPairing sesuai backend printer bawaan', () {
    final backend = PrinterBackendSunmi();

    expect(backend.displayName, 'Printer Bawaan Sunmi');
    expect(backend.requiresPairing, isFalse);
  });
}

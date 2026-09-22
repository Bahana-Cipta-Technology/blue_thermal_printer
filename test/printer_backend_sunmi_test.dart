import 'dart:async';

import 'package:blue_thermal_printer/printer_backend.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const receipt = Receipt(lines: []);
  const device = PrinterDevice(name: 'Printer Bawaan', macAddress: 'sunmi-builtin');

  group('isAvailable/discoverDevices', () {
    test('tersedia saat updateState bukan 505 (tidak terdeteksi)', () async {
      final backend = PrinterBackendSunmi(updateState: () async => 1);

      expect(await backend.isAvailable(), isTrue);
      expect(await backend.discoverDevices(), [device]);
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

    test('bind sukses dan langsung tersedia mengembalikan PrinterOk', () async {
      final backend = PrinterBackendSunmi(
        bind: () async => true,
        updateState: () async => 1,
      );

      final result = await backend.connect(device);

      expect(result.isOk, isTrue);
    });

    test('bind sukses tapi tidak pernah terdeteksi tetap gagal', () async {
      final backend = PrinterBackendSunmi(
        bind: () async => true,
        updateState: () async => 505,
      );

      final result = await backend.connect(device);

      expect(result.isErr, isTrue);
    });
  });

  group('checkStatus', () {
    test('kode 1 (normal) melaporkan semua kondisi baik', () async {
      final backend = PrinterBackendSunmi(updateState: () async => 1);

      final result = await backend.checkStatus();

      expect(result.isOk, isTrue);
      expect(result.valueOrNull?.hasKnownProblem, isFalse);
    });

    test('kode 3 (kertas habis)', () async {
      final backend = PrinterBackendSunmi(updateState: () async => 3);

      final result = await backend.checkStatus();

      expect(result.valueOrNull?.hasPaper, isFalse);
    });

    test('kode 6 (cover terbuka)', () async {
      final backend = PrinterBackendSunmi(updateState: () async => 6);

      final result = await backend.checkStatus();

      expect(result.valueOrNull?.coverClosed, isFalse);
    });

    test('kode 5/7 (overheat/cutter abnormal) melaporkan galat', () async {
      final overheat = PrinterBackendSunmi(updateState: () async => 5);
      final cutter = PrinterBackendSunmi(updateState: () async => 7);

      expect((await overheat.checkStatus()).valueOrNull?.hasError, isTrue);
      expect((await cutter.checkStatus()).valueOrNull?.hasError, isTrue);
    });

    test('kode 505 (tidak terdeteksi) mengembalikan PrinterErr', () async {
      final backend = PrinterBackendSunmi(updateState: () async => 505);

      final result = await backend.checkStatus();

      expect(result.isErr, isTrue);
    });

    test('kode lain yang tidak dikenal dianggap unknown, tetap Ok', () async {
      final backend = PrinterBackendSunmi(updateState: () async => 4);

      final result = await backend.checkStatus();

      expect(result.isOk, isTrue);
      expect(result.valueOrNull?.hasKnownProblem, isFalse);
    });
  });

  group('printReceipt', () {
    test('printer tidak terhubung tidak mengirim bitmap', () async {
      var prints = 0;
      final backend = PrinterBackendSunmi(
        updateState: () async => 505,
        doPrintBitmap: (_) async {
          prints++;
          return true;
        },
      );

      expect((await backend.printReceipt(receipt)).isErr, isTrue);
      expect(prints, 0);
    });

    test('pengiriman bitmap gagal dilaporkan sebagai galat', () async {
      final backend = PrinterBackendSunmi(
        updateState: () async => 1,
        doPrintBitmap: (_) async => false,
      );

      final result = await backend.printReceipt(receipt);

      expect(result.isErr, isTrue);
    });

    test('pengiriman sukses dan status normal dianggap sukses', () async {
      final backend = PrinterBackendSunmi(
        updateState: () async => 1,
        doPrintBitmap: (_) async => true,
      );

      final result = await backend.printReceipt(receipt);

      expect(result.isOk, isTrue);
    });

    test(
      'pengiriman sukses tapi status melaporkan kertas habis pasca-cetak tetap gagal',
      () async {
        var call = 0;
        final backend = PrinterBackendSunmi(
          // Pre-check (panggilan ke-1) bersih supaya benar-benar sampai
          // memanggil doPrintBitmap; baru pasca-cetak (panggilan ke-2)
          // melaporkan masalah.
          updateState: () async {
            call++;
            return call == 1 ? 1 : 3;
          },
          doPrintBitmap: (_) async => true,
        );

        final result = await backend.printReceipt(receipt);

        expect(result.isErr, isTrue);
      },
    );

    test(
      'pre-check menolak sebelum satu bitmap pun dikirim saat status sudah bermasalah',
      () async {
        var prints = 0;
        final backend = PrinterBackendSunmi(
          updateState: () async => 3,
          doPrintBitmap: (_) async {
            prints++;
            return true;
          },
        );

        final result = await backend.printReceipt(receipt);

        expect(result.isErr, isTrue);
        expect(result.failureOrNull?.message, 'Kertas printer habis.');
        expect(prints, 0);
      },
    );

    test(
      'enterBuffer/exitBuffer dipanggil mengapit doPrintBitmap saat sukses',
      () async {
        final calls = <String>[];
        final backend = PrinterBackendSunmi(
          updateState: () async => 1,
          doPrintBitmap: (_) async {
            calls.add('print');
            return true;
          },
          enterBuffer: (clean) async {
            calls.add('enter($clean)');
            return true;
          },
          exitBuffer: (commit) async {
            calls.add('exit($commit)');
            return true;
          },
        );

        final result = await backend.printReceipt(receipt);

        expect(result.isOk, isTrue);
        expect(calls, ['enter(true)', 'print', 'exit(true)']);
      },
    );

    test(
      'enterBuffer/exitBuffer gagal tidak pernah menggagalkan cetakan yang '
      'sebenarnya berhasil (API belum diverifikasi di semua vendor)',
      () async {
        final backend = PrinterBackendSunmi(
          updateState: () async => 1,
          doPrintBitmap: (_) async => true,
          enterBuffer: (_) async => throw Exception('belum didukung vendor ini'),
          exitBuffer: (_) async => throw Exception('belum didukung vendor ini'),
        );

        final result = await backend.printReceipt(receipt);

        expect(result.isOk, isTrue);
      },
    );

    test('menolak cetak bersamaan dan dapat mencoba ulang setelah gagal', () async {
      final pending = Completer<bool>();
      var prints = 0;
      final backend = PrinterBackendSunmi(
        updateState: () async => 1,
        doPrintBitmap: (_) {
          prints++;
          return pending.future;
        },
      );

      final first = backend.printReceipt(receipt);
      expect((await backend.printReceipt(receipt)).isErr, isTrue);
      pending.complete(false);
      expect((await first).isErr, isTrue);
      expect(prints, 1);
      await backend.printReceipt(receipt);
      expect(prints, 2);
    });
  });

  test('displayName dan requiresPairing sesuai backend printer bawaan', () {
    final backend = PrinterBackendSunmi();

    expect(backend.displayName, 'Printer Bawaan Sunmi');
    expect(backend.requiresPairing, isFalse);
  });
}

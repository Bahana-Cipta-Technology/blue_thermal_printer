import 'dart:async';

import 'package:blue_thermal_printer/printer_backend.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const receipt = Receipt(lines: []);
  const device = PrinterDevice(name: 'Printer', macAddress: '00:11:22:33:44:55');

  group('printReceipt', () {
    test('koneksi terputus tidak mengirim byte', () async {
      var writes = 0;
      final backend = PrinterBackendEscpos(
        connected: () async => false,
        write: (_) async {
          writes++;
          return true;
        },
        checkStatus: () async => PrinterStatus.unknown,
      );
      expect((await backend.printReceipt(receipt)).failureOrNull, isNotNull);
      expect(writes, 0);
    });

    test('menolak cetak bersamaan dan dapat mencoba ulang setelah gagal', () async {
      final pending = Completer<bool>();
      var writes = 0;
      final backend = PrinterBackendEscpos(
        connected: () async => true,
        encode: (_) async => [1],
        write: (_) {
          writes++;
          return pending.future;
        },
        checkStatus: () async => PrinterStatus.unknown,
      );
      final first = backend.printReceipt(receipt);
      expect((await backend.printReceipt(receipt)).failureOrNull, isNotNull);
      pending.complete(false);
      expect((await first).failureOrNull, isNotNull);
      expect(writes, 1);
      await backend.printReceipt(receipt);
      expect(writes, 2);
    });

    test(
      'penulisan sukses tapi printer melaporkan kertas habis pasca-tulis tetap gagal',
      () async {
        var call = 0;
        final backend = PrinterBackendEscpos(
          connected: () async => true,
          encode: (_) async => [1],
          write: (_) async => true,
          // Pre-check (panggilan ke-1) bersih supaya benar-benar sampai
          // menulis; baru pasca-tulis (panggilan ke-2) melaporkan masalah.
          checkStatus: () async {
            call++;
            return call == 1
                ? PrinterStatus.unknown
                : const PrinterStatus(hasPaper: false);
          },
        );

        final result = await backend.printReceipt(receipt);

        expect(result.isErr, isTrue);
      },
    );

    test('penulisan sukses dan status printer tidak diketahui tetap dianggap sukses', () async {
      var writes = 0;
      final backend = PrinterBackendEscpos(
        connected: () async => true,
        encode: (_) async => [1],
        write: (_) async {
          writes++;
          return true;
        },
        checkStatus: () async => PrinterStatus.unknown,
      );

      final result = await backend.printReceipt(receipt);

      expect(result.isOk, isTrue);
      expect(writes, 1);
    });

    test('penulisan sukses tapi printer melaporkan cover terbuka atau galat pasca-tulis tetap gagal', () async {
      var coverCall = 0;
      final coverOpen = PrinterBackendEscpos(
        connected: () async => true,
        encode: (_) async => [1],
        write: (_) async => true,
        checkStatus: () async {
          coverCall++;
          return coverCall == 1
              ? PrinterStatus.unknown
              : const PrinterStatus(coverClosed: false);
        },
      );
      var errorCall = 0;
      final error = PrinterBackendEscpos(
        connected: () async => true,
        encode: (_) async => [1],
        write: (_) async => true,
        checkStatus: () async {
          errorCall++;
          return errorCall == 1
              ? PrinterStatus.unknown
              : const PrinterStatus(hasError: true);
        },
      );

      expect((await coverOpen.printReceipt(receipt)).isErr, isTrue);
      expect((await error.printReceipt(receipt)).isErr, isTrue);
    });

    test(
      'pre-check menolak sebelum satu byte pun ditulis saat status sudah bermasalah',
      () async {
        var writes = 0;
        final backend = PrinterBackendEscpos(
          connected: () async => true,
          encode: (_) async => [1],
          write: (_) async {
            writes++;
            return true;
          },
          checkStatus: () async => const PrinterStatus(hasPaper: false),
        );

        final result = await backend.printReceipt(receipt);

        expect(result.isErr, isTrue);
        expect(result.failureOrNull?.message, 'Kertas printer habis.');
        expect(writes, 0);
      },
    );

    test(
      'kegagalan pasca-tulis memicu reset buffer (ESC @) tambahan',
      () async {
        final writes = <List<int>>[];
        var call = 0;
        final backend = PrinterBackendEscpos(
          connected: () async => true,
          encode: (_) async => [1, 2, 3],
          write: (bytes) async {
            writes.add(bytes);
            return true;
          },
          checkStatus: () async {
            call++;
            return call == 1
                ? PrinterStatus.unknown
                : const PrinterStatus(hasPaper: false);
          },
        );

        await backend.printReceipt(receipt);

        expect(writes, [
          [1, 2, 3], // data struk yang gagal tercetak
          [27, 64], // ESC @ pembersih buffer
        ]);
      },
    );
  });

  group('connect', () {
    test('izin ditolak mengembalikan PrinterErr dengan isPermissionDenied', () async {
      final backend = PrinterBackendEscpos(isPermissionGranted: () async => false);

      final result = await backend.connect(device);

      expect(result.isErr, isTrue);
      expect(result.failureOrNull?.isPermissionDenied, isTrue);
    });

    test('bluetooth nonaktif mengembalikan PrinterErr', () async {
      final backend = PrinterBackendEscpos(
        isPermissionGranted: () async => true,
        isBluetoothOn: () async => false,
      );

      final result = await backend.connect(device);

      expect(result.isErr, isTrue);
    });

    test('berhasil terhubung mengembalikan PrinterOk', () async {
      PrinterDevice? connectedTo;
      final backend = PrinterBackendEscpos(
        isPermissionGranted: () async => true,
        isBluetoothOn: () async => true,
        doConnect: (target) async {
          connectedTo = target;
          return true;
        },
      );

      final result = await backend.connect(device);

      expect(result.isOk, isTrue);
      expect(connectedTo, device);
    });
  });

  test('discoverDevices meneruskan daftar dari sumber terinjeksi', () async {
    final backend = PrinterBackendEscpos(discover: () async => const [device]);

    expect(await backend.discoverDevices(), [device]);
  });

  test('checkStatus gagal saat belum terhubung', () async {
    final backend = PrinterBackendEscpos(connected: () async => false);

    final result = await backend.checkStatus();

    expect(result.isErr, isTrue);
  });

  test('displayName dan requiresPairing sesuai backend Bluetooth', () {
    final backend = PrinterBackendEscpos();

    expect(backend.displayName, 'Bluetooth ESC/POS');
    expect(backend.requiresPairing, isTrue);
  });
}

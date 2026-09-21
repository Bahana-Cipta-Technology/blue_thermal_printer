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

    test('penulisan sukses tapi printer melaporkan kertas habis tetap gagal', () async {
      final backend = PrinterBackendEscpos(
        connected: () async => true,
        encode: (_) async => [1],
        write: (_) async => true,
        checkStatus: () async => const PrinterStatus(hasPaper: false),
      );

      final result = await backend.printReceipt(receipt);

      expect(result.isErr, isTrue);
    });

    test('penulisan sukses dan status printer tidak diketahui tetap dianggap sukses', () async {
      final backend = PrinterBackendEscpos(
        connected: () async => true,
        encode: (_) async => [1],
        write: (_) async => true,
        checkStatus: () async => PrinterStatus.unknown,
      );

      final result = await backend.printReceipt(receipt);

      expect(result.isOk, isTrue);
    });

    test('penulisan sukses tapi printer melaporkan cover terbuka atau galat tetap gagal', () async {
      final coverOpen = PrinterBackendEscpos(
        connected: () async => true,
        encode: (_) async => [1],
        write: (_) async => true,
        checkStatus: () async => const PrinterStatus(coverClosed: false),
      );
      final error = PrinterBackendEscpos(
        connected: () async => true,
        encode: (_) async => [1],
        write: (_) async => true,
        checkStatus: () async => const PrinterStatus(hasError: true),
      );

      expect((await coverOpen.printReceipt(receipt)).isErr, isTrue);
      expect((await error.printReceipt(receipt)).isErr, isTrue);
    });
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

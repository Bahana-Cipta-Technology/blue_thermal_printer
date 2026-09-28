import 'package:blue_thermal_printer/printer_backend.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/printer_backend_contract.dart';

/// Byte respons `DLE EOT 2`: 0x12 = normal, 0x32 = kertas habis (bit 5).
int? _statusByte(ContractStatus status) => switch (status) {
  ContractStatus.normal => 0x12,
  ContractStatus.unknown => null,
  ContractStatus.paperOut => 0x32,
};

void main() {
  const receipt = Receipt(lines: [ReceiptCenter('TES')]);
  const lanPrinter = PrinterDevice(name: 'Printer LAN', macAddress: '192.168.1.50:9100');

  runPrinterBackendContract('LAN', ({
    required bool connected,
    ContractStatus status = ContractStatus.normal,
    bool dependenciesThrow = false,
    Future<void> Function()? onSend,
    Duration printTimeout = const Duration(seconds: 30),
    Duration stuckAfter = const Duration(seconds: 30),
  }) {
    var sends = 0;
    var connects = 0;
    return ContractHarness(
      backend: PrinterBackendEscpos.withTransport(
        NetworkEscposTransport(
          openSettings: () async {
            if (dependenciesThrow) throw Exception('channel error');
          },
          invoke: (method, [args]) async {
            if (dependenciesThrow) throw Exception('channel error');
            switch (method) {
              case 'isAvailable':
                return true;
              case 'connect':
                connects++;
                return true;
              case 'isConnected':
                return connected;
              case 'writeBytes':
                sends++;
                await onSend?.call();
                return true;
              case 'queryStatus':
                return _statusByte(status);
            }
            return null;
          },
        ),
        encode: (_) async => [1],
        printTimeout: printTimeout,
        stuckAfter: stuckAfter,
      ),
      sends: () => sends,
      connectAttempts: () => connects,
      lastDevice: lanPrinter,
    );
  });

  group('parseNetworkAddress', () {
    test('IPv4 tanpa port memakai 9100', () {
      expect(parseNetworkAddress(' 192.168.1.50 '), const NetworkAddress('192.168.1.50', 9100));
    });

    test('IPv4 dan hostname dengan port', () {
      expect(parseNetworkAddress('10.0.0.7:9101')?.value, '10.0.0.7:9101');
      expect(parseNetworkAddress('printer-kasir.local:9100')?.host, 'printer-kasir.local');
    });

    test('input tidak valid ditolak', () {
      for (final input in [
        '',
        '   ',
        '192.168.1',
        '256.1.1.1',
        '192.168.1.50:0',
        '192.168.1.50:70000',
        '192.168.1.50:abc',
        'printer kasir',
        '-printer',
        '::1',
      ]) {
        expect(parseNetworkAddress(input), isNull, reason: input);
      }
    });
  });

  group('NetworkEscposTransport', () {
    test('connect mengirim host + port hasil parse', () async {
      final calls = <(String, Map<String, Object?>?)>[];
      final backend = PrinterBackendEscpos.withTransport(
        NetworkEscposTransport(
          invoke: (method, [args]) async {
            calls.add((method, args));
            return true;
          },
        ),
      );

      final result = await backend.connect(
        const PrinterDevice(name: 'x', macAddress: 'printer.local:9101'),
      );

      expect(result.isOk, isTrue);
      final connect = calls.singleWhere((call) => call.$1 == 'connect');
      expect(connect.$2, {'host': 'printer.local', 'port': 9101});
    });

    test('alamat tersimpan rusak -> pilih ulang, tanpa connect native', () async {
      var invoked = false;
      final backend = PrinterBackendEscpos.withTransport(
        NetworkEscposTransport(
          invoke: (method, [args]) async {
            if (method == 'connect') invoked = true;
            return true;
          },
        ),
      );

      final result = await backend.ensureConnected(
        lastDevice: const PrinterDevice(name: 'x', macAddress: 'bukan-alamat:'),
      );

      expect(result.failureOrNull?.requiresDeviceSelection, isTrue);
      expect(invoked, isFalse);
    });

    test('native gagal connect -> pesan LAN', () async {
      final backend = PrinterBackendEscpos.withTransport(
        NetworkEscposTransport(
          invoke: (method, [args]) async => method == 'isAvailable',
        ),
      );

      final result = await backend.connect(lanPrinter);

      expect(result.failureOrNull?.message, contains('printer LAN'));
    });

    test('ensureConnected tanpa alamat tersimpan meminta pilih printer', () async {
      final backend = PrinterBackendEscpos.withTransport(
        NetworkEscposTransport(invoke: (method, [args]) async => true),
      );

      final result = await backend.ensureConnected();

      expect(result.failureOrNull?.requiresDeviceSelection, isTrue);
    });

    test('displayName dan requiresPairing', () {
      final backend = PrinterBackendEscpos.withTransport(
        NetworkEscposTransport(invoke: (method, [args]) async => null),
      );
      expect(backend.displayName, 'Printer LAN (ESC/POS)');
      expect(backend.requiresPairing, isTrue);
    });

    test('kertas habis setelah kirim -> galat + reset ESC @', () async {
      final writes = <List<int>>[];
      var queries = 0;
      final backend = PrinterBackendEscpos.withTransport(
        NetworkEscposTransport(
          invoke: (method, [args]) async => switch (method) {
            'isAvailable' || 'isConnected' => true,
            'queryStatus' => queries++ == 0 ? 0x12 : 0x32,
            'writeBytes' => () {
              writes.add(args!['bytes'] as List<int>);
              return true;
            }(),
            _ => null,
          },
        ),
        encode: (_) async => [1, 2, 3],
      );

      final result = await backend.printReceipt(receipt);

      expect(result.failureOrNull?.message, 'Kertas printer habis.');
      expect(writes.last, [27, 64]);
    });
  });
}

import 'package:blue_thermal_printer/printer_backend.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/printer_backend_contract.dart';

void main() {
  const usbPrinterMap = {
    'name': 'POS-58 USB',
    'vendorId': 1155,
    'productId': 22304,
  };

  runPrinterBackendContract('USB', ({
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
        UsbEscposTransport(
          invoke: (method, [args]) async {
            if (dependenciesThrow) throw Exception('channel error');
            switch (method) {
              case 'isAvailable':
                return true;
              case 'devices':
                return [usbPrinterMap];
              case 'connect':
                connects++;
                return 'connected';
              case 'isConnected':
                return connected;
              case 'writeBytes':
                sends++;
                await onSend?.call();
                return true;
              case 'queryStatus':
                return switch (status) {
                  ContractStatus.normal => 0x12,
                  ContractStatus.unknown => null,
                  ContractStatus.paperOut => 0x32,
                };
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
    );
  });

  test('usbDeviceKey / parseUsbDeviceKey bolak-balik', () {
    expect(usbDeviceKey(1155, 22304), 'usb:1155:22304');
    expect(parseUsbDeviceKey('usb:1155:22304'), (1155, 22304));
    for (final bad in ['', 'usb:1:', 'bt:1:2', 'usb:a:2', 'usb:1:2:3']) {
      expect(parseUsbDeviceKey(bad), isNull, reason: bad);
    }
  });

  group('UsbEscposTransport', () {
    UsbEscposTransport transport(Object? Function(String, Map<String, Object?>?) native) =>
        UsbEscposTransport(invoke: (method, [args]) async => native(method, args));

    test('discover memetakan perangkat native dan membuang entri rusak', () async {
      final devices = await transport((method, args) => [
        usbPrinterMap,
        {'name': '  ', 'vendorId': 1, 'productId': 2},
        {'name': 'rusak'},
        'bukan map',
      ]).discover();

      expect(devices, const [
        PrinterDevice(name: 'POS-58 USB', macAddress: 'usb:1155:22304'),
        PrinterDevice(name: 'Printer USB', macAddress: 'usb:1:2'),
      ]);
    });

    test('connect mengirim vendorId + productId', () async {
      Map<String, Object?>? sent;
      final failure = await transport((method, args) {
        sent = args;
        return 'connected';
      }).connect(const PrinterDevice(name: 'x', macAddress: 'usb:1155:22304'));

      expect(failure, isNull);
      expect(sent, {'vendorId': 1155, 'productId': 22304});
    });

    test('izin ditolak -> isPermissionDenied', () async {
      final failure = await transport((method, args) => 'permission_denied').connect(
        const PrinterDevice(name: 'x', macAddress: 'usb:1:2'),
      );
      expect(failure?.isPermissionDenied, isTrue);
    });

    test('printer dicabut -> ensureConnected meminta pilih ulang', () async {
      final backend = PrinterBackendEscpos.withTransport(
        transport((method, args) => switch (method) {
          'isAvailable' => true,
          'devices' => const [],
          _ => null,
        }),
      );

      final result = await backend.ensureConnected(
        lastDevice: const PrinterDevice(name: 'x', macAddress: 'usb:1:2'),
      );

      expect(result.failureOrNull?.requiresDeviceSelection, isTrue);
      expect(result.failureOrNull?.message, contains('USB tidak tersambung'));
    });

    test('tanpa USB host -> tidak tersedia', () async {
      final backend = PrinterBackendEscpos.withTransport(
        transport((method, args) => method == 'isAvailable' ? false : null),
      );
      expect(await backend.isAvailable(), isFalse);
      final result = await backend.connect(
        const PrinterDevice(name: 'x', macAddress: 'usb:1:2'),
      );
      expect(result.failureOrNull?.message, contains('tidak mendukung printer USB'));
    });
  });
}

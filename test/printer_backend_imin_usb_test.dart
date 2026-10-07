import 'package:blue_thermal_printer/printer_backend.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/printer_backend_contract.dart';

void main() {
  // Printer USB internal iMin D1 (ALT althicoA726) dan perangkat USB lain yang
  // ikut terlihat di bus yang sama (adapter LAN USB di D1).
  const internalPrinter = {
    'name': 'althicoA726',
    'vendorId': 0x0519,
    'productId': 0x2013,
  };
  const otherUsbDevice = {
    'name': 'USB 10/100 LAN',
    'vendorId': 3034,
    'productId': 33106,
  };

  runPrinterBackendContract('IminUsb', ({
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
      backend: PrinterBackendIminUsb(
        invoke: (method, [args]) async {
          if (dependenciesThrow) throw Exception('channel error');
          switch (method) {
            case 'isAvailable':
              return true;
            case 'devices':
              return [otherUsbDevice, internalPrinter];
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
        encode: (_) async => [1],
        printTimeout: printTimeout,
        stuckAfter: stuckAfter,
      ),
      sends: () => sends,
      connectAttempts: () => connects,
    );
  });

  group('PrinterBackendIminUsb', () {
    PrinterBackendIminUsb backend(
      Object? Function(String method, Map<String, Object?>? args) native,
    ) => PrinterBackendIminUsb(
      invoke: (method, [args]) async => native(method, args),
    );

    test('discoverDevices hanya mengembalikan printer internal iMin', () async {
      final devices = await backend(
        (method, _) => method == 'devices'
            ? [otherUsbDevice, internalPrinter]
            : null,
      ).discoverDevices();

      expect(devices.map((d) => d.macAddress), ['usb:1305:8211']);
      expect(devices.single.name, 'Printer Bawaan iMin');
    });

    test('isAvailable mengikuti keberadaan printer internal', () async {
      expect(
        await backend((m, _) => m == 'devices' ? [internalPrinter] : null).isAvailable(),
        isTrue,
      );
      expect(
        await backend((m, _) => m == 'devices' ? [otherUsbDevice] : null).isAvailable(),
        isFalse,
      );
    });

    test('ensureConnected mengabaikan lastDevice dan menyambung printer internal',
        () async {
      final connected = <Object?>[];
      final b = backend((method, args) {
        switch (method) {
          case 'isAvailable':
            return true;
          case 'devices':
            return [internalPrinter];
          case 'connect':
            connected.add(args);
            return 'connected';
        }
        return null;
      });

      final result = await b.ensureConnected(
        lastDevice: const PrinterDevice(name: 'lama', macAddress: '00:11:22:33:44:55'),
      );

      expect(result.valueOrNull?.macAddress, 'usb:1305:8211');
      expect(connected, [
        {'vendorId': 0x0519, 'productId': 0x2013},
      ]);
    });

    test('tanpa printer internal: Err jelas, bukan permintaan pilih printer',
        () async {
      final result = await backend(
        (m, _) => m == 'devices' ? [otherUsbDevice] : (m == 'isAvailable' ? true : null),
      ).ensureConnected();

      final failure = result.failureOrNull!;
      expect(failure.message, PrinterBackendIminUsb.notFoundMessage);
      expect(failure.requiresDeviceSelection, isFalse);
    });

    test('izin USB ditolak diteruskan sebagai isPermissionDenied', () async {
      final result = await backend((method, _) => switch (method) {
        'isAvailable' => true,
        'devices' => [internalPrinter],
        'connect' => 'permission_denied',
        _ => null,
      }).ensureConnected();

      final failure = result.failureOrNull!;
      expect(failure.isPermissionDenied, isTrue);
      expect(failure.requiresDeviceSelection, isFalse);
    });

    test('channel melempar: Err, tidak bocor sebagai exception', () async {
      final result = await backend((_, __) => throw Exception('channel error'))
          .ensureConnected();

      expect(result.isErr, isTrue);
    });

    test('lebar kertas bisa diatur seperti ESC/POS lain', () async {
      final b = backend((_, __) => null);
      expect(b.supportsPaperWidthSetting, isTrue);
      b.setPaperWidth(PaperWidthSetting.mm80);
      expect((await b.capabilities()).paperWidthPx, paperWidth80Px);
    });

    test('printerFeature tidak menembus backend bawaan', () {
      final b = backend((_, __) => null);
      expect(printerFeature<TransportPowerControl>(b), isNull);
      expect(printerFeature<PrinterDeviceScanner>(b), isNull);
    });
  });
}

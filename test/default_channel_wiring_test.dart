import 'package:blue_thermal_printer/printer_backend.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Memverifikasi implementasi DEFAULT (tanpa injeksi) memanggil channel
/// native dengan nama method/argumen yang sama persis dengan sisi Java.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  group('Sunmi (blue_thermal_printer/sunmi)', () {
    const channel = MethodChannel('blue_thermal_printer/sunmi');
    late List<MethodCall> calls;

    void mock(Object? Function(MethodCall call) handler) {
      calls = [];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return handler(call);
      });
    }

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('printTransaction mengirim PNG + feedLines dan membaca outcome', () async {
      mock((call) => switch (call.method) {
        'updateState' => 1,
        'printTransaction' => 'printed',
        _ => null,
      });

      final result = await PrinterBackendSunmi().printReceipt(
        const Receipt(lines: [ReceiptCenter('TES')]),
      );

      expect(result.isOk, isTrue);
      final print = calls.singleWhere((c) => c.method == 'printTransaction');
      final args = print.arguments as Map;
      expect(args['bytes'], isA<Uint8List>());
      expect((args['bytes'] as Uint8List).sublist(0, 4), [137, 80, 78, 71]);
      expect(args['feedLines'], PrinterBackendSunmi.feedLines);
    });

    test('outcome failed dari native jadi PrinterErr', () async {
      mock((call) => switch (call.method) {
        'updateState' => 1,
        'printTransaction' => 'failed',
        _ => null,
      });

      final result = await PrinterBackendSunmi().printReceipt(
        const Receipt(lines: []),
      );

      expect(result.isErr, isTrue);
    });

    test('updateState null (channel tanpa jawaban) dianggap tidak terdeteksi',
        () async {
      mock((_) => null);

      expect(await PrinterBackendSunmi().isAvailable(), isFalse);
    });

    test('channel tidak terdaftar (mis. desktop) dianggap tidak tersedia',
        () async {
      // Tanpa mock handler sama sekali -> MissingPluginException.
      messenger.setMockMethodCallHandler(channel, null);

      expect(await PrinterBackendSunmi().isAvailable(), isFalse);
    });
  });

  group('ESC/POS (blue_thermal_printer/methods)', () {
    const channel = MethodChannel('blue_thermal_printer/methods');

    void mockStatusByte(int? byte) {
      messenger.setMockMethodCallHandler(channel, (call) async {
        return switch (call.method) {
          'isConnected' => true,
          'queryPrinterStatus' => byte,
          _ => null,
        };
      });
    }

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('byte DLE EOT sah didekode (0x32 = kertas habis)', () async {
      mockStatusByte(0x32);

      final status = (await PrinterBackendEscpos().checkStatus()).valueOrNull;

      expect(status?.hasPaper, isFalse);
    });

    test('byte XON 0x11 tidak dibaca sebagai status', () async {
      mockStatusByte(0x11);

      final status = (await PrinterBackendEscpos().checkStatus()).valueOrNull;

      expect(status?.hasKnownProblem, isFalse);
      expect(status?.hasPaper, isNull);
    });

    test('printer tanpa dukungan DLE EOT (null) -> unknown', () async {
      mockStatusByte(null);

      final status = (await PrinterBackendEscpos().checkStatus()).valueOrNull;

      expect(status?.hasPaper, isNull);
    });
  });

  group('Xcheng (blue_thermal_printer/xcheng)', () {
    const channel = MethodChannel('blue_thermal_printer/xcheng');

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('hasPaper + printBitmap memakai nama method/argumen native', () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return switch (call.method) {
          'hasPaper' => true,
          'printBitmap' => 'printed',
          _ => null,
        };
      });

      final result = await PrinterBackendXcheng().printReceipt(
        const Receipt(lines: [ReceiptCenter('TES')]),
      );

      expect(result.isOk, isTrue);
      final print = calls.singleWhere((c) => c.method == 'printBitmap');
      final args = print.arguments as Map;
      expect((args['bytes'] as Uint8List).sublist(0, 4), [137, 80, 78, 71]);
      expect(args['feedLines'], PrinterBackendXcheng.feedLines);
    });

    test('hasPaper false dari native memblokir tanpa printBitmap', () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return call.method == 'hasPaper' ? false : 'printed';
      });

      final result = await PrinterBackendXcheng().printReceipt(
        const Receipt(lines: []),
      );

      expect(result.failureOrNull?.message, 'Kertas printer habis.');
      expect(calls, isNot(contains('printBitmap')));
    });

    test('perangkat non-Xcheng (channel tanpa handler) tidak tersedia', () async {
      expect(await PrinterBackendXcheng().isAvailable(), isFalse);
    });
  });

  group('iMin (blue_thermal_printer/imin)', () {
    const channel = MethodChannel('blue_thermal_printer/imin');

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('status + paperType + printTransaction memakai nama method/argumen native',
        () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return switch (call.method) {
          'status' => 0,
          'paperType' => 80,
          'printTransaction' => 'printed',
          _ => null,
        };
      });

      final result = await PrinterBackendImin().printReceipt(
        const Receipt(lines: [ReceiptCenter('TES')]),
      );

      expect(result.isOk, isTrue);
      final print = calls.singleWhere((c) => c.method == 'printTransaction');
      final args = print.arguments as Map;
      expect((args['bytes'] as Uint8List).sublist(0, 4), [137, 80, 78, 71]);
      expect(args['feedDistance'], PrinterBackendImin.feedDistance);
      expect(args['cut'], isTrue);
    });

    test('status 7 dari native memblokir tanpa printTransaction', () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return call.method == 'status' ? 7 : null;
      });

      final result = await PrinterBackendImin().printReceipt(
        const Receipt(lines: []),
      );

      expect(result.failureOrNull?.message, 'Kertas printer habis.');
      expect(calls, isNot(contains('printTransaction')));
    });

    test('status null (channel tanpa jawaban) dianggap belum siap', () async {
      messenger.setMockMethodCallHandler(channel, (call) async => null);

      expect(await PrinterBackendImin().isAvailable(), isFalse);
    });

    test('perangkat non-iMin (channel tanpa handler) tidak tersedia', () async {
      expect(await PrinterBackendImin().isAvailable(), isFalse);
    });
  });

  group('LAN (blue_thermal_printer/escpos_net)', () {
    const channel = MethodChannel(NetworkEscposTransport.channelName);
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('connect/isConnected/queryStatus/writeBytes memakai nama method native',
        () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return switch (call.method) {
          'isAvailable' || 'connect' || 'isConnected' || 'writeBytes' => true,
          'queryStatus' => 0x12,
          _ => null,
        };
      });
      final backend = createPrinterBackend(PrinterVendor.lan);

      final connected = await backend.connect(
        const PrinterDevice(name: 'LAN', macAddress: '192.168.1.50'),
      );
      final printed = await backend.printReceipt(const Receipt(lines: []));

      expect(connected.isOk, isTrue);
      expect(printed.valueOrNull, PrintDelivery.unverified);
      final connect = calls.singleWhere((c) => c.method == 'connect');
      expect(connect.arguments, {'host': '192.168.1.50', 'port': 9100});
      final query = calls.firstWhere((c) => c.method == 'queryStatus');
      expect(query.arguments, {'type': 2});
      final write = calls.singleWhere((c) => c.method == 'writeBytes');
      expect((write.arguments as Map)['bytes'], isA<Uint8List>());
    });

    test('channel tanpa handler (mis. desktop) tidak tersedia', () async {
      expect(await createPrinterBackend(PrinterVendor.lan).isAvailable(), isFalse);
    });
  });

  group('USB (blue_thermal_printer/escpos_usb)', () {
    const channel = MethodChannel(UsbEscposTransport.channelName);
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('devices + connect memakai nama method/argumen native', () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return switch (call.method) {
          'isAvailable' => true,
          'devices' => [
            {'name': 'POS-58', 'vendorId': 1155, 'productId': 22304},
          ],
          'connect' => 'connected',
          _ => null,
        };
      });
      final backend = createPrinterBackend(PrinterVendor.usb);

      final devices = await backend.discoverDevices();
      final result = await backend.ensureConnected(lastDevice: devices.single);

      expect(devices.single.macAddress, 'usb:1155:22304');
      expect(result.valueOrNull, devices.single);
      final connect = calls.singleWhere((c) => c.method == 'connect');
      expect(connect.arguments, {'vendorId': 1155, 'productId': 22304});
    });

    test('channel tanpa handler (mis. desktop) tidak tersedia', () async {
      expect(await createPrinterBackend(PrinterVendor.usb).isAvailable(), isFalse);
    });
  });
}

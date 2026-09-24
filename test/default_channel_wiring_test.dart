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
}

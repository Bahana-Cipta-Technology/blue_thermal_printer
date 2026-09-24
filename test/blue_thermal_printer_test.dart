import 'package:blue_thermal_printer/blue_thermal_printer.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('blue_thermal_printer/methods');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      switch (methodCall.method) {
        case 'isOn':
          return true;
        case 'isPermissionBluetoothGranted':
          return true;
        case 'getBondedDevices':
          return [
            {'name': 'Printer A', 'address': '00:11:22:33:44:55'},
          ];
        case 'queryPrinterStatus':
          return 0x00;
        default:
          return null;
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('isOn returns the mocked bluetooth state', () async {
    expect(await BlueThermalPrinter.instance.isOn, isTrue);
  });

  test('isPermissionBluetoothGranted returns the mocked permission state',
      () async {
    expect(await BlueThermalPrinter.instance.isPermissionBluetoothGranted,
        isTrue);
  });

  test('getBondedDevices decodes the mocked device list', () async {
    final devices = await BlueThermalPrinter.instance.getBondedDevices();
    expect(devices, hasLength(1));
    expect(devices.first.name, 'Printer A');
    expect(devices.first.address, '00:11:22:33:44:55');
  });

  test('queryPrinterStatus invokes the channel with the status type', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      calls.add(methodCall);
      return 0x00;
    });

    final status = await BlueThermalPrinter.instance
        .queryPrinterStatus(BlueThermalPrinter.statusTypeOffline);

    expect(status, 0x00);
    expect(calls.single.method, 'queryPrinterStatus');
    expect(calls.single.arguments, {'type': BlueThermalPrinter.statusTypeOffline});
  });

  group('argumen channel API lama', () {
    late List<MethodCall> calls;

    setUp(() {
      calls = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
        calls.add(methodCall);
        return true;
      });
    });

    test('connect/isDeviceConnected mengirim peta perangkat', () async {
      final device = BluetoothDevice('Printer A', '00:11:22:33:44:55');

      expect(await BlueThermalPrinter.instance.connect(device), isTrue);
      await BlueThermalPrinter.instance.isDeviceConnected(device);

      expect(calls.map((c) => c.method), ['connect', 'isDeviceConnected']);
      expect(calls.first.arguments, {
        'name': 'Printer A',
        'address': '00:11:22:33:44:55',
        'connected': false,
      });
    });

    test('writeBytes mengirim Uint8List apa adanya', () async {
      final bytes = Uint8List.fromList([27, 64]);

      await BlueThermalPrinter.instance.writeBytes(bytes);

      expect(calls.single.method, 'writeBytes');
      expect(calls.single.arguments, {'message': bytes});
    });

    test('printCustom meneruskan ukuran, perataan, dan charset', () async {
      await BlueThermalPrinter.instance
          .printCustom('Halo', 1, 2, charset: 'windows-1252');

      expect(calls.single.arguments, {
        'message': 'Halo',
        'size': 1,
        'align': 2,
        'charset': 'windows-1252',
      });
    });

    test('printQRcode meneruskan dimensi dan perataan', () async {
      await BlueThermalPrinter.instance.printQRcode('PKW-1', 200, 200, 1);

      expect(calls.single.arguments, {
        'textToQR': 'PKW-1',
        'width': 200,
        'height': 200,
        'align': 1,
      });
    });

    test('disconnect/paperCut/printNewLine tanpa argumen', () async {
      await BlueThermalPrinter.instance.disconnect();
      await BlueThermalPrinter.instance.paperCut();
      await BlueThermalPrinter.instance.printNewLine();

      expect(calls.map((c) => c.method), ['disconnect', 'paperCut', 'printNewLine']);
      expect(calls.every((c) => c.arguments == null), isTrue);
    });
  });

  test('queryPrinterStatus meneruskan null saat printer tidak merespons', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async => null);

    expect(
      await BlueThermalPrinter.instance
          .queryPrinterStatus(BlueThermalPrinter.statusTypeOffline),
      isNull,
    );
  });

  test('BluetoothDevice setara berdasarkan alamat', () {
    expect(BluetoothDevice('A', '00:11'), BluetoothDevice('B', '00:11'));
    expect(BluetoothDevice.fromMap({'name': 'A', 'address': '00:11'}).name, 'A');
  });
}

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
}

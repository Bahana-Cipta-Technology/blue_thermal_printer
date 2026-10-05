import 'dart:async';

import 'package:blue_thermal_printer/printer_backend.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Channel native palsu: mencatat panggilan, menjawab lewat [handler], dan
/// mengirim event lewat [emit].
class _FakeChannel {
  _FakeChannel(this.handler);

  Object? Function(String method, Map<String, Object?>? arguments) handler;
  final calls = <String>[];
  final arguments = <String, Map<String, Object?>?>{};
  final _events = StreamController<Object?>.broadcast();

  Stream<Object?> get events => _events.stream;
  bool get hasListener => _events.hasListener;

  void emit(Map<String, Object?> event) => _events.add(event);

  Future<Object?> invoke(String method, [Map<String, Object?>? args]) async {
    calls.add(method);
    arguments[method] = args;
    return handler(method, args);
  }

  BluetoothControl control(
          {Duration pairTimeout = const Duration(seconds: 65)}) =>
      BluetoothControl(
        invoke: invoke,
        events: events,
        pairTimeout: pairTimeout,
        scanGrace: const Duration(milliseconds: 50),
        powerOnTimeout: const Duration(milliseconds: 100),
      );
}

Map<String, Object?> _item(
  String id,
  String kind,
  String status, {
  String resolution = 'none',
  List<String> permissions = const [],
  List<String> operations = const [
    'listPaired',
    'toggle',
    'scan',
    'pair',
    'connect'
  ],
}) =>
    {
      'id': id,
      'kind': kind,
      'status': status,
      'resolution': resolution,
      'permissions': permissions,
      'operations': operations,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PrerequisiteReport', () {
    final report = PrerequisiteReport.fromMap({
      'sdkInt': 30,
      'items': [
        _item('hardware', 'hardware', 'satisfied'),
        _item(
          'location',
          'permission',
          'missing',
          resolution: 'requestPermission',
          permissions: ['android.permission.ACCESS_FINE_LOCATION'],
          operations: ['scan'],
        ),
        _item(
          'adapter',
          'adapterEnabled',
          'missing',
          resolution: 'enableTransport',
          operations: ['listPaired', 'scan', 'pair', 'connect'],
        ),
        _item(
          'locationService',
          'locationService',
          'missing',
          resolution: 'openLocationSettings',
          operations: ['scan'],
        ),
      ],
    });

    test('memetakan map native', () {
      expect(report.sdkInt, 30);
      final location = report.items[1];
      expect(location.kind, PrerequisiteKind.permission);
      expect(location.resolution, PrerequisiteResolution.requestPermission);
      expect(location.permissions, ['android.permission.ACCESS_FINE_LOCATION']);
      expect(location.operations, {TransportOperation.scan});
    });

    test('missingFor hanya memuat prasyarat operasi itu, urut penyelesaian',
        () {
      expect(report.missingFor(TransportOperation.scan).map((p) => p.id), [
        'location',
        'adapter',
        'locationService',
      ]);
      expect(report.missingFor(TransportOperation.connect).map((p) => p.id),
          ['adapter']);
      expect(report.missingFor(TransportOperation.toggle), isEmpty);
    });

    test('nextStepFor = langkah pertama yang belum terpenuhi', () {
      expect(report.nextStepFor(TransportOperation.scan)?.id, 'location');
      expect(report.nextStepFor(TransportOperation.toggle), isNull);
      expect(report.isSatisfiedFor(TransportOperation.toggle), isTrue);
      expect(report.isSatisfiedFor(TransportOperation.connect), isFalse);
    });

    test('requiredFor menyertakan yang sudah terpenuhi (checklist)', () {
      expect(report.requiredFor(TransportOperation.connect).map((p) => p.id), [
        'hardware',
        'adapter',
      ]);
    });

    test('nilai tak dikenal tidak membuat parsing gagal', () {
      final parsed = PrerequisiteReport.fromMap({
        'items': [
          {
            'id': 'x',
            'kind': '???',
            'status': '???',
            'operations': ['scan', 'nope']
          },
          'bukan map',
        ],
      });
      expect(parsed.items.single.status, PrerequisiteStatus.missing);
      expect(parsed.items.single.operations, {TransportOperation.scan});
    });

    test('pesan izin ditolak permanen mengarah ke Setelan', () {
      const item = Prerequisite(
        id: 'nearbyDevices',
        kind: PrerequisiteKind.permission,
        status: PrerequisiteStatus.permanentlyDenied,
        resolution: PrerequisiteResolution.openAppSettings,
      );
      expect(item.message, contains('Setelan'));
      expect(item.label, 'Izin Perangkat sekitar');
    });
  });

  group('BluetoothControl prasyarat', () {
    test('channel tidak ada (desktop/test) = tidak ada Bluetooth', () async {
      final channel = _FakeChannel((_, __) => throw MissingPluginException());
      final report = await channel.control().checkPrerequisites();
      expect(report.isSatisfiedFor(TransportOperation.connect), isFalse);
      expect(report.nextStepFor(TransportOperation.scan)?.kind,
          PrerequisiteKind.hardware);
    });

    test('resolve izin meminta izin item itu dan memakai laporan balasan',
        () async {
      final channel = _FakeChannel(
        (method, _) => switch (method) {
          'requestPermissions' => {
              'items': [_item('hardware', 'hardware', 'satisfied')],
            },
          _ => null,
        },
      );
      final report = await channel.control().resolve(
            const Prerequisite(
              id: 'nearbyDevices',
              kind: PrerequisiteKind.permission,
              status: PrerequisiteStatus.missing,
              resolution: PrerequisiteResolution.requestPermission,
              permissions: ['a', 'b'],
            ),
          );
      expect(channel.arguments['requestPermissions'], {
        'permissions': ['a', 'b'],
      });
      expect(report.items.single.id, 'hardware');
      expect(channel.calls, isNot(contains('prerequisites')));
    });

    test('resolve Setelan membuka layar yang tepat lalu memeriksa ulang',
        () async {
      final channel = _FakeChannel((_, __) => {'items': <Object?>[]});
      final control = channel.control();
      await control.resolve(
        const Prerequisite(
          id: 'locationService',
          kind: PrerequisiteKind.locationService,
          status: PrerequisiteStatus.missing,
          resolution: PrerequisiteResolution.openLocationSettings,
        ),
      );
      await control.resolve(
        const Prerequisite(
          id: 'nearbyDevices',
          kind: PrerequisiteKind.permission,
          status: PrerequisiteStatus.permanentlyDenied,
          resolution: PrerequisiteResolution.openAppSettings,
        ),
      );
      expect(channel.calls, [
        'openLocationSettings',
        'prerequisites',
        'openAppSettings',
        'prerequisites',
      ]);
    });
  });

  group('BluetoothControl nyala/mati', () {
    test('powerState dipetakan; channel tidak ada = unsupported', () async {
      expect(await _FakeChannel((_, __) => 'turningOn').control().powerState(),
          TransportPowerState.turningOn);
      expect(
        await _FakeChannel((_, __) => throw MissingPluginException())
            .control()
            .powerState(),
        TransportPowerState.unsupported,
      );
    });

    test('watchPowerState hanya meneruskan event power', () async {
      final channel = _FakeChannel((_, __) => null);
      final states = <TransportPowerState>[];
      final sub = channel.control().watchPowerState().listen(states.add);
      channel
        ..emit({'type': 'power', 'state': 'turningOff'})
        ..emit({'type': 'found', 'address': 'AA'})
        ..emit({'type': 'power', 'state': 'off'});
      await pumpEventQueue();
      expect(states, [TransportPowerState.turningOff, TransportPowerState.off]);
      await sub.cancel();
    });

    test('setEnabled(true) changed menunggu radio benar-benar menyala',
        () async {
      final channel = _FakeChannel((_, __) => 'changed');
      final control = channel.control();
      var done = false;
      final pending = control.setEnabled(true).then((result) {
        done = true;
        return result;
      });
      await pumpEventQueue();
      expect(done, isFalse);
      channel.emit({'type': 'power', 'state': 'on'});
      final result = await pending;
      expect(result.valueOrNull, PowerToggleOutcome.changed);
      expect(channel.arguments['setEnabled'], {'enabled': true});
    });

    test('setEnabled tetap selesai bila radio tidak pernah melapor', () async {
      final channel = _FakeChannel((_, __) => 'changed');
      final result = await channel.control().setEnabled(true);
      expect(result.valueOrNull, PowerToggleOutcome.changed);
    });

    test('setEnabled(false) di Android 13+ membuka Setelan', () async {
      final result = await _FakeChannel((_, __) => 'openedSystemSettings')
          .control()
          .setEnabled(false);
      expect(result.valueOrNull, PowerToggleOutcome.openedSystemSettings);
    });

    test('izin belum ada = PrinterErr isPermissionDenied', () async {
      final result = await _FakeChannel(
        (_, __) => throw PlatformException(code: 'permission_denied'),
      ).control().setEnabled(true);
      expect(result.failureOrNull?.isPermissionDenied, isTrue);
    });
  });

  group('BluetoothControl pencarian', () {
    test('event native dipetakan dan stream ditutup ScanFinished', () async {
      final channel = _FakeChannel((_, __) => true);
      final events = <ScanEvent>[];
      final done = channel.control().scan().listen(events.add).asFuture<void>();
      await pumpEventQueue();
      expect(channel.arguments['startScan'], {'timeoutMillis': 12000});
      channel
        ..emit({'type': 'scanStarted'})
        ..emit({
          'type': 'found',
          'address': 'AA:BB',
          'name': 'RPP02N',
          'rssi': -60,
          'deviceClass': 0x0680,
          'bonded': false,
        })
        ..emit({'type': 'found', 'address': '', 'name': 'tanpa alamat'})
        ..emit({'type': 'scanFinished', 'reason': 'timedOut'});
      await done;

      expect(events[0], isA<ScanStarted>());
      final found = (events[1] as DeviceFound).printer;
      expect(found.device.macAddress, 'AA:BB');
      expect(found.rssi, -60);
      expect(found.isLikelyPrinter, isTrue);
      expect((events.last as ScanFinished).reason, ScanEndReason.timedOut);
      expect(events, hasLength(3));
    });

    test('single-flight: panggilan kedua mendapat pencarian yang sama',
        () async {
      final channel = _FakeChannel((_, __) => true);
      final control = channel.control();
      final first = control.scan().last;
      await pumpEventQueue();
      final second = control.scan().last;
      await pumpEventQueue();
      expect(control.isScanning, isTrue);
      expect(channel.calls.where((c) => c == 'startScan'), hasLength(1));
      channel.emit({'type': 'scanFinished', 'reason': 'completed'});
      expect((await first as ScanFinished).reason, ScanEndReason.completed);
      expect((await second as ScanFinished).reason, ScanEndReason.completed);
      expect(control.isScanning, isFalse);
    });

    test('galat native jadi ScanFinished(failed) dengan pesan', () async {
      final channel = _FakeChannel(
        (_, __) => throw PlatformException(code: 'location_off'),
      );
      final last = await channel.control().scan().last as ScanFinished;
      expect(last.reason, ScanEndReason.failed);
      expect(last.failure?.message, contains('Lokasi'));
    });

    test('ditolak selama struk dikirim, tanpa memanggil native', () async {
      final channel = _FakeChannel((_, __) => true);
      final control = channel.control()..bindPrintActivity(() => true);
      final last = await control.scan().last as ScanFinished;
      expect(last.reason, ScanEndReason.failed);
      expect(channel.calls, isNot(contains('startScan')));
    });

    test('stopScan menutup stream dengan alasan stopped', () async {
      final channel = _FakeChannel((_, __) => true);
      final control = channel.control();
      final last = control.scan().last;
      await pumpEventQueue();
      await control.stopScan();
      expect((await last as ScanFinished).reason, ScanEndReason.stopped);
      expect(channel.calls, contains('stopScan'));
    });

    test('pendengar terakhir berhenti = pencarian native dihentikan', () async {
      final channel = _FakeChannel((_, __) => true);
      final control = channel.control();
      final sub = control.scan().listen((_) {});
      await pumpEventQueue();
      await sub.cancel();
      await pumpEventQueue();
      expect(control.isScanning, isFalse);
      expect(channel.calls, contains('stopScan'));
      expect(channel.hasListener, isFalse);
    });

    test('native tidak pernah melapor selesai: Dart menutup sendiri', () async {
      final channel = _FakeChannel((_, __) => true);
      final last = await channel
          .control()
          .scan(timeout: const Duration(milliseconds: 10))
          .last as ScanFinished;
      expect(last.reason, ScanEndReason.timedOut);
      expect(channel.calls, contains('stopScan'));
    });
  });

  group('BluetoothControl pairing', () {
    const device = PrinterDevice(name: 'RPP02N', macAddress: 'AA:BB');

    test('bonded = PrinterOk berisi perangkat', () async {
      final channel = _FakeChannel((_, __) => 'bonded');
      final result = await channel.control().pair(device);
      expect(result.valueOrNull, device);
      expect(channel.arguments['pair'], {'address': 'AA:BB'});
    });

    test('ditolak / PIN salah dipetakan ke pesan', () async {
      final result = await _FakeChannel(
        (_, __) => throw PlatformException(code: 'pair_rejected'),
      ).control().pair(device);
      expect(result.failureOrNull?.message, contains('PIN'));
    });

    test('native tidak menjawab = batas waktu Dart', () async {
      final never = Completer<Object?>();
      final channel = _FakeChannel((_, __) => never.future);
      final result = await channel
          .control(pairTimeout: const Duration(milliseconds: 10))
          .pair(device);
      expect(result.failureOrNull?.message, contains('tidak selesai'));
    });
  });

  group('DiscoveredPrinter.isLikelyPrinter', () {
    DiscoveredPrinter printer(String name, int? cod) => DiscoveredPrinter(
          device: PrinterDevice(name: name, macAddress: 'AA'),
          deviceClass: cod,
        );

    test('Class of Device Imaging/Printer', () {
      expect(printer('Apa saja', 0x0680).isLikelyPrinter, isTrue);
      // Imaging tanpa bit printer (mis. kamera).
      expect(printer('Apa saja', 0x0620).isLikelyPrinter, isFalse);
    });

    test('class kosong/tak dikategorikan + nama khas printer', () {
      expect(printer('RPP02N', 0x1F00).isLikelyPrinter, isTrue);
      expect(printer('MTP-II', 0).isLikelyPrinter, isTrue);
      expect(printer('BlueTooth Printer', null).isLikelyPrinter, isTrue);
      expect(printer('Galaxy Buds', 0x1F00).isLikelyPrinter, isFalse);
    });

    test('nama printer pada class lain (mis. ponsel) tidak dihitung', () {
      expect(printer('POS Phone', 0x020C).isLikelyPrinter, isFalse);
    });
  });

  group('printerFeature', () {
    test('backend Bluetooth mengekspos ketiga kemampuan', () {
      final control = _FakeChannel((_, __) => null).control();
      final backend = PrinterBackendEscpos(bluetoothControl: control);
      expect(printerFeature<TransportPowerControl>(backend), same(control));
      expect(printerFeature<PrinterDeviceScanner>(backend), same(control));
      expect(printerFeature<TransportPrerequisites>(backend), same(control));
    });

    test('backend tanpa kemampuan itu = null', () {
      expect(
          printerFeature<PrinterDeviceScanner>(PrinterBackendSunmi()), isNull);
      expect(
        printerFeature<TransportPowerControl>(
          PrinterBackendEscpos.withTransport(NetworkEscposTransport()),
        ),
        isNull,
      );
    });

    test('menembus PrinterBackendFallback ke backend aktif', () {
      final control = _FakeChannel((_, __) => null).control();
      final backend = PrinterBackendFallback(
        primary: PrinterBackendEscpos(bluetoothControl: control),
        fallback: PrinterBackendEscpos(),
      );
      expect(printerFeature<PrinterDeviceScanner>(backend), same(control));
    });
  });

  group('integrasi PrinterBackendEscpos', () {
    const device = PrinterDevice(name: 'P', macAddress: 'AA');

    PrinterBackendEscpos backend(
      BluetoothControl control, {
      Future<void> Function()? onWrite,
      List<String>? log,
    }) =>
        PrinterBackendEscpos(
          bluetoothControl: control,
          isBluetoothOn: () async => true,
          isPermissionGranted: () async => true,
          discover: () async => const [device],
          doConnect: (_) async {
            log?.add('connect');
            return true;
          },
          connected: () async => true,
          encode: (_) async => [1],
          write: (_) async {
            await onWrite?.call();
            return true;
          },
          checkStatus: () async => PrinterStatus.unknown,
        );

    test('connect menghentikan pencarian yang sedang berjalan lebih dulu',
        () async {
      final log = <String>[];
      final channel = _FakeChannel((method, _) {
        if (method == 'stopScan') log.add('stopScan');
        return true;
      });
      final control = channel.control();
      final printer = backend(control, log: log);
      final scan = control.scan().last;
      await pumpEventQueue();

      await printer.connect(device);

      expect(log, ['stopScan', 'connect']);
      expect((await scan as ScanFinished).reason, ScanEndReason.stopped);
    });

    test('connect tanpa pencarian tidak memanggil stopScan', () async {
      final channel = _FakeChannel((_, __) => true);
      await backend(channel.control()).connect(device);
      expect(channel.calls, isNot(contains('stopScan')));
    });

    test('pencarian ditolak selama printReceipt berjalan', () async {
      final channel = _FakeChannel((_, __) => true);
      final control = channel.control();
      final release = Completer<void>();
      final printer = backend(control, onWrite: () => release.future);
      await printer.connect(device);
      final printing = printer.printReceipt(const Receipt(lines: []));
      await pumpEventQueue();

      final last = await control.scan().last as ScanFinished;
      expect(last.reason, ScanEndReason.failed);

      release.complete();
      await printing;
    });
  });
}

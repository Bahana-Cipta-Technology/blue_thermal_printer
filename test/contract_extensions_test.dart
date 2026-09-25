import 'package:blue_thermal_printer/printer_backend.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_backend.dart';
import 'support/printer_backend_contract.dart';

/// Perilaku spesifik vendor untuk perluasan kontrak (PrintDelivery,
/// capabilities, preview, ensureConnected) -- invariant lintas vendor ada di
/// `support/printer_backend_contract.dart`. Rancangan:
/// `doc/contract-extensions-design.md`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const receipt = Receipt(lines: [ReceiptCenter('TES')]);

  group('Sunmi', () {
    test('sunmiCapabilities: 80 mm hanya dipercaya dari paket asli', () {
      expect(
        sunmiCapabilities(const SunmiServiceInfo(paper: 0, genuine: true)),
        const PrinterCapabilities(
          paperWidthPx: 576,
          autoCut: false,
          reportsPaperOut: true,
          confirmsPrint: true,
        ),
      );
      expect(
        sunmiCapabilities(const SunmiServiceInfo(paper: 1, genuine: true))
            ?.paperWidthPx,
        384,
      );
      expect(
        sunmiCapabilities(const SunmiServiceInfo(genuine: true))?.paperWidthPx,
        384,
      );
      // Klon (servis Xcheng): lebar tidak dipercaya, status & konfirmasi tidak.
      expect(
        sunmiCapabilities(const SunmiServiceInfo(paper: 0, genuine: false)),
        const PrinterCapabilities(
          paperWidthPx: 384,
          autoCut: false,
          reportsPaperOut: false,
          confirmsPrint: false,
        ),
      );
      // Belum tersambung: tidak ada yang bisa disimpulkan.
      expect(sunmiCapabilities(const SunmiServiceInfo()), isNull);
    });

    test('callback transaksi yang pernah timeout mematikan confirmsPrint', () {
      final caps = sunmiCapabilities(
        const SunmiServiceInfo(genuine: true, transactionCallback: false),
      );

      expect(caps?.confirmsPrint, isFalse);
    });

    test('SunmiServiceInfo.fromMap', () {
      final info = SunmiServiceInfo.fromMap({
        'paper': 0,
        'genuine': true,
        'transactionCallback': null,
      });
      expect(info.paper, 0);
      expect(info.genuine, isTrue);
      expect(info.transactionCallback, isNull);
      expect(SunmiServiceInfo.fromMap(null).genuine, isNull);
    });

    PrinterBackendSunmi sunmi({
      required SunmiServiceInfo info,
      SunmiPrintOutcome outcome = SunmiPrintOutcome.printed,
      void Function(List<int> png)? onPrint,
    }) => PrinterBackendSunmi(
      updateState: () async => 1,
      serviceInfo: () async => info,
      printTransaction: (png, _) async {
        onPrint?.call(png);
        return outcome;
      },
    );

    test('Sunmi asli 80 mm mencetak 576 px dan terkonfirmasi', () async {
      List<int>? sent;
      final backend = sunmi(
        info: const SunmiServiceInfo(paper: 0, genuine: true),
        onPrint: (png) => sent = png,
      );

      final result = await backend.printReceipt(receipt);

      expect(result.valueOrNull, PrintDelivery.confirmed);
      expect(pngWidth(Uint8List.fromList(sent!)), 576);
    });

    test('printed dari klon tetap unverified', () async {
      final backend = sunmi(info: const SunmiServiceInfo(genuine: false));

      final result = await backend.printReceipt(receipt);

      expect(result.valueOrNull, PrintDelivery.unverified);
    });

    test('unknown -> unverified', () async {
      final backend = sunmi(
        info: const SunmiServiceInfo(genuine: true),
        outcome: SunmiPrintOutcome.unknown,
      );

      expect(
        (await backend.printReceipt(receipt)).valueOrNull,
        PrintDelivery.unverified,
      );
    });

    test('capabilities setelah putus memakai nilai terakhir yang diketahui',
        () async {
      var info = const SunmiServiceInfo(paper: 0, genuine: true);
      final backend = PrinterBackendSunmi(serviceInfo: () async => info);

      expect((await backend.capabilities()).paperWidthPx, 576);
      info = const SunmiServiceInfo();
      expect((await backend.capabilities()).paperWidthPx, 576);
      expect(pngWidth(await backend.preview(receipt)), 576);
    });

    test('sebelum pernah tersambung -> fallback58', () async {
      final backend = PrinterBackendSunmi(
        serviceInfo: () async => const SunmiServiceInfo(),
      );

      expect(await backend.capabilities(), PrinterCapabilities.fallback58);
    });

    test('channel default: serviceInfo dibaca dari native', () async {
      const channel = MethodChannel('blue_thermal_printer/sunmi');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        return call.method == 'serviceInfo'
            ? {'paper': 0, 'genuine': true, 'transactionCallback': true}
            : null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      final caps = await PrinterBackendSunmi().capabilities();

      expect(caps.paperWidthPx, 576);
      expect(caps.confirmsPrint, isTrue);
    });
  });

  group('Xcheng', () {
    PrinterBackendXcheng xcheng(XchengPrintOutcome outcome) =>
        PrinterBackendXcheng(
          hasPaper: () async => true,
          printBitmap: (_, __) async => outcome,
        );

    test('onComplete -> confirmed', () async {
      expect(
        (await xcheng(XchengPrintOutcome.printed).printReceipt(receipt))
            .valueOrNull,
        PrintDelivery.confirmed,
      );
    });

    test('tanpa callback + kertas ada -> unverified', () async {
      expect(
        (await xcheng(XchengPrintOutcome.unknown).printReceipt(receipt))
            .valueOrNull,
        PrintDelivery.unverified,
      );
    });

    test('capabilities tetap: 58 mm, sensor kertas, konfirmasi', () async {
      expect(
        await xcheng(XchengPrintOutcome.printed).capabilities(),
        PrinterBackendXcheng.capabilitiesValue,
      );
    });

    test('ensureConnected tidak bind ulang bila servis sudah siap', () async {
      var binds = 0;
      final backend = PrinterBackendXcheng(
        bind: () async {
          binds++;
          return true;
        },
        hasPaper: () async => true,
      );

      final result = await backend.ensureConnected();

      expect(result.valueOrNull, kXchengBuiltInDevice);
      expect(binds, 0);
    });
  });

  group('iMin', () {
    PrinterBackendImin imin({
      bool verified = false,
      int? paperType = 58,
      int status = 0,
    }) => PrinterBackendImin(
      status: () async => status,
      paperType: () async => paperType,
      printResultVerified: () async => verified,
      printTransaction: (_, __, ___) async => IminPrintOutcome.printed,
    );

    test('printed sebelum kode onPrintResult terverifikasi -> unverified',
        () async {
      expect(
        (await imin().printReceipt(receipt)).valueOrNull,
        PrintDelivery.unverified,
      );
    });

    test('printed setelah terverifikasi -> confirmed', () async {
      final backend = imin(verified: true);

      expect(
        (await backend.printReceipt(receipt)).valueOrNull,
        PrintDelivery.confirmed,
      );
      expect((await backend.capabilities()).confirmsPrint, isTrue);
    });

    test('capabilities mengikuti jenis kertas', () async {
      expect(
        await imin(paperType: 80).capabilities(),
        const PrinterCapabilities(
          paperWidthPx: 576,
          autoCut: true,
          reportsPaperOut: true,
          confirmsPrint: false,
        ),
      );
      expect((await imin(paperType: 58).capabilities()).autoCut, isFalse);
    });

    test('belum tersambung -> nilai terakhir / fallback58', () async {
      var status = 0;
      final backend = PrinterBackendImin(
        status: () async => status,
        paperType: () async => 80,
        printResultVerified: () async => false,
      );
      expect(
        await PrinterBackendImin(status: () async => -1).capabilities(),
        PrinterCapabilities.fallback58,
      );

      expect((await backend.capabilities()).paperWidthPx, 576);
      status = -1;
      expect((await backend.capabilities()).paperWidthPx, 576);
    });
  });

  group('ESC/POS', () {
    const printer = PrinterDevice(name: 'RPP', macAddress: '11:22:33:44:55:66');

    PrinterBackendEscpos escpos({
      bool permission = true,
      bool bluetoothOn = true,
      List<PrinterDevice> bonded = const [printer],
      PrinterStatus Function()? status,
      void Function()? onConnect,
    }) => PrinterBackendEscpos(
      isPermissionGranted: () async => permission,
      isBluetoothOn: () async => bluetoothOn,
      discover: () async => bonded,
      doConnect: (_) async {
        onConnect?.call();
        return true;
      },
      doDisconnect: () async {},
      connected: () async => true,
      encode: (_) async => [1],
      write: (_) async => true,
      checkStatus: () async => status?.call() ?? PrinterStatus.unknown,
    );

    group('ensureConnected', () {
      test('izin belum diberikan -> Err isPermissionDenied', () async {
        final result = await escpos(
          permission: false,
        ).ensureConnected(lastDevice: printer);

        expect(result.failureOrNull?.isPermissionDenied, isTrue);
      });

      test('Bluetooth mati -> Err tanpa minta pilih perangkat', () async {
        final result = await escpos(
          bluetoothOn: false,
        ).ensureConnected(lastDevice: printer);

        expect(result.failureOrNull?.message, 'Bluetooth belum aktif.');
        expect(result.failureOrNull?.requiresDeviceSelection, isFalse);
      });

      test('tanpa perangkat terakhir -> requiresDeviceSelection', () async {
        final result = await escpos().ensureConnected();

        expect(result.failureOrNull?.requiresDeviceSelection, isTrue);
      });

      test('perangkat terakhir tidak lagi terpasang -> requiresDeviceSelection',
          () async {
        final result = await escpos(
          bonded: const [],
        ).ensureConnected(lastDevice: printer);

        expect(result.failureOrNull?.requiresDeviceSelection, isTrue);
      });

      test('perangkat terpasang -> tersambung ke perangkat itu', () async {
        var connects = 0;
        final result = await escpos(
          onConnect: () => connects++,
        ).ensureConnected(lastDevice: printer);

        expect(result.valueOrNull, printer);
        expect(connects, 1);
      });

      test('menyambung ulang ke printer yang sama tidak melupakan bahwa '
          'printer tidak menjawab DLE EOT', () async {
        var queries = 0;
        final backend = escpos(
          status: () {
            queries++;
            return PrinterStatus.unknown;
          },
        );
        await backend.ensureConnected(lastDevice: printer);
        await backend.printReceipt(receipt); // 2 query tanpa jawaban
        expect((await backend.capabilities()).reportsPaperOut, isFalse);

        await backend.ensureConnected(lastDevice: printer);
        await backend.printReceipt(receipt);

        expect(queries, 2);
        expect((await backend.capabilities()).reportsPaperOut, isFalse);
      });
    });

    test('reportsPaperOut: null -> true setelah printer menjawab', () async {
      final backend = escpos(
        status: () => const PrinterStatus(
          hasPaper: true,
          coverClosed: true,
          hasError: false,
        ),
      );
      await backend.connect(printer);
      expect((await backend.capabilities()).reportsPaperOut, isNull);

      await backend.checkStatus();

      expect((await backend.capabilities()).reportsPaperOut, isTrue);
    });

    test('cetak ESC/POS selalu unverified', () async {
      final backend = escpos();
      await backend.connect(printer);

      expect(
        (await backend.printReceipt(receipt)).valueOrNull,
        PrintDelivery.unverified,
      );
      expect((await backend.capabilities()).confirmsPrint, isFalse);
    });

    test('preview memakai lebar renderer', () async {
      final backend = PrinterBackendEscpos(
        renderer: const ReceiptRenderer(width: 576),
      );

      expect(pngWidth(await backend.preview(receipt)), 576);
      expect((await backend.capabilities()).paperWidthPx, 576);
    });
  });

  group('Fallback', () {
    test('ensureConnected: primary gagal -> fallback, lalu fallback dipakai '
        'langsung tanpa mencoba primary lagi', () async {
      final primary = FakeBackend(name: 'Xcheng', connectResult: false);
      final fallback = FakeBackend(name: 'Sunmi');
      final backend = PrinterBackendFallback(
        primary: primary,
        fallback: fallback,
      );

      expect((await backend.ensureConnected()).isOk, isTrue);
      expect(backend.active, same(fallback));
      expect(primary.disconnects, 1);

      await backend.ensureConnected();

      expect(primary.ensures, 1);
      expect(fallback.ensures, 2);
    });

    test('capabilities & preview lewat backend aktif', () async {
      final backend = PrinterBackendFallback(
        primary: FakeBackend(name: 'Xcheng', connectResult: false),
        fallback: FakeBackend(name: 'Sunmi'),
      );
      await backend.ensureConnected();

      expect((await backend.capabilities()).confirmsPrint, isFalse);
      expect(String.fromCharCodes(await backend.preview(receipt)), 'Sunmi');
    });
  });

  test('PrintJobGate generik meneruskan nilai hasil', () async {
    final gate = PrintJobGate();

    final result = await gate.run(
      () async => const PrinterOk(PrintDelivery.confirmed),
    );

    expect(result.valueOrNull, PrintDelivery.confirmed);
  });
}

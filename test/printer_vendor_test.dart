import 'package:blue_thermal_printer/printer_backend.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_backend.dart';

void main() {
  test('innerSunmi membangun PrinterBackendSunmi', () {
    final backend = createPrinterBackend(PrinterVendor.innerSunmi);

    expect(backend, isA<PrinterBackendSunmi>());
    expect(backend.requiresPairing, isFalse);
  });

  test('bluetooth membangun PrinterBackendEscpos', () {
    final backend = createPrinterBackend(PrinterVendor.bluetooth);

    expect(backend, isA<PrinterBackendEscpos>());
    expect(backend.requiresPairing, isTrue);
  });

  test('innerXcheng membangun Xcheng dengan fallback Sunmi', () {
    final backend = createPrinterBackend(PrinterVendor.innerXcheng);

    expect(backend, isA<PrinterBackendFallback>());
    final fallback = backend as PrinterBackendFallback;
    expect(fallback.primary, isA<PrinterBackendXcheng>());
    expect(fallback.fallback, isA<PrinterBackendSunmi>());
    expect(fallback.active, same(fallback.primary));
    expect(backend.requiresPairing, isFalse);
  });

  test('innerImin membangun PrinterBackendImin', () {
    final backend = createPrinterBackend(PrinterVendor.innerImin);

    expect(backend, isA<PrinterBackendImin>());
    expect(backend.requiresPairing, isFalse);
  });

  test('lan dan usb membangun PrinterBackendEscpos dengan transportnya', () {
    final lan = createPrinterBackend(PrinterVendor.lan);
    final usb = createPrinterBackend(PrinterVendor.usb);

    expect(lan, isA<PrinterBackendEscpos>());
    expect(lan.displayName, 'Printer LAN (ESC/POS)');
    expect(lan.requiresPairing, isTrue);
    expect(usb, isA<PrinterBackendEscpos>());
    expect(usb.displayName, 'Printer USB (ESC/POS)');
    expect(usb.requiresPairing, isTrue);
  });

  group('PrinterTransport', () {
    test('setiap vendor tepat satu transport, konsisten dengan vendorsOf', () {
      for (final vendor in PrinterVendor.values) {
        final owners = PrinterTransport.values.where(
          (transport) => vendorsOf(transport).contains(vendor),
        );
        expect(owners, [vendor.transport], reason: vendor.name);
      }
    });

    test('printer bawaan mengikuti urutan deteksi', () {
      expect(vendorsOf(PrinterTransport.builtIn), [
        PrinterVendor.innerXcheng,
        PrinterVendor.innerImin,
        PrinterVendor.innerSunmi,
      ]);
      expect(vendorsOf(PrinterTransport.bluetooth), [PrinterVendor.bluetooth]);
    });

    test('backend bawaan tanpa pairing, transport lain butuh pairing', () {
      for (final vendor in PrinterVendor.values) {
        expect(
          createPrinterBackend(vendor).requiresPairing,
          vendor.transport != PrinterTransport.builtIn,
          reason: vendor.name,
        );
      }
    });
  });

  group('detectBuiltInPrinterVendor', () {
    FakeBackend fake(bool connects) => FakeBackend(connectResult: connects);

    test('Xcheng dicek lebih dulu (servis Xcheng juga menyediakan AIDL Sunmi)',
        () async {
      final probed = <PrinterVendor>[];
      final vendor = await detectBuiltInPrinterVendor(
        probe: (v) {
          probed.add(v);
          return fake(true);
        },
      );

      expect(vendor, PrinterVendor.innerXcheng);
      expect(probed, [PrinterVendor.innerXcheng]);
    });

    test('bukan Xcheng -> iMin dicek sebelum Sunmi', () async {
      final probed = <PrinterVendor>[];
      final vendor = await detectBuiltInPrinterVendor(
        probe: (v) {
          probed.add(v);
          return fake(v != PrinterVendor.innerXcheng);
        },
      );

      expect(vendor, PrinterVendor.innerImin);
      expect(probed, [PrinterVendor.innerXcheng, PrinterVendor.innerImin]);
    });

    test('bukan Xcheng/iMin -> Sunmi', () async {
      final probed = <PrinterVendor>[];
      final vendor = await detectBuiltInPrinterVendor(
        probe: (v) {
          probed.add(v);
          return fake(v == PrinterVendor.innerSunmi);
        },
      );

      expect(vendor, PrinterVendor.innerSunmi);
      expect(probed, [
        PrinterVendor.innerXcheng,
        PrinterVendor.innerImin,
        PrinterVendor.innerSunmi,
      ]);
    });

    test('tanpa printer bawaan -> null (pakai Bluetooth)', () async {
      expect(await detectBuiltInPrinterVendor(probe: (_) => fake(false)), isNull);
    });

    test('lan/usb bukan printer bawaan, tidak pernah di-probe', () async {
      final probed = <PrinterVendor>[];
      await detectBuiltInPrinterVendor(
        probe: (vendor) {
          probed.add(vendor);
          return fake(false);
        },
      );

      expect(probed, isNot(contains(PrinterVendor.lan)));
      expect(probed, isNot(contains(PrinterVendor.usb)));
    });

    test('probe yang melempar dianggap tidak tersedia dan tetap diputus',
        () async {
      final backends = <FakeBackend>[];
      final vendor = await detectBuiltInPrinterVendor(
        probe: (v) {
          final b = FakeBackend(
            connectResult: v == PrinterVendor.innerSunmi,
            connectThrows: v == PrinterVendor.innerXcheng,
          );
          backends.add(b);
          return b;
        },
      );

      expect(vendor, PrinterVendor.innerSunmi);
      expect(backends.every((b) => b.disconnects == 1), isTrue);
    });

    test('probe default: perangkat tanpa servis (channel tidak ada) -> null',
        () async {
      expect(await detectBuiltInPrinterVendor(), isNull);
    });
  });
}

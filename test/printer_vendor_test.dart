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

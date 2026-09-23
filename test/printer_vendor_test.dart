import 'package:blue_thermal_printer/printer_backend.dart';
import 'package:flutter_test/flutter_test.dart';

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
}

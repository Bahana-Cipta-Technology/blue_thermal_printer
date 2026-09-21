/// API umum lintas vendor untuk printer thermal: satu kontrak [PrinterBackend]
/// yang bisa diimplementasikan oleh backend ESC/POS generik (Bluetooth) atau
/// SDK vendor (mis. Sunmi), plus tipe data pendukungnya.
///
/// Berbeda dari `package:blue_thermal_printer/blue_thermal_printer.dart`
/// (API lama, khusus Bluetooth/`BlueThermalPrinter`, tetap dipertahankan apa
/// adanya untuk kompatibilitas mundur) -- import file ini untuk kontrak baru
/// yang jadi source of truth lintas backend/app konsumen.
library;

export 'src/printer_backend.dart';
export 'src/printer_backend_escpos.dart';
export 'src/printer_device.dart';
export 'src/printer_status.dart';
export 'src/receipt.dart';
export 'src/receipt_renderer.dart';
export 'src/result.dart';

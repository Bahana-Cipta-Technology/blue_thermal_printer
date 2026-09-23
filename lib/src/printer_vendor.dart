import 'printer_backend.dart';
import 'printer_backend_escpos.dart';
import 'printer_backend_sunmi.dart';

/// Vendor backend printer yang plugin ini dukung -- source of truth tunggal
/// dipakai semua app konsumen, supaya daftar vendor tidak didefinisikan
/// ulang (dan berisiko drift) di tiap app. Menambah dukungan vendor baru
/// (mis. Epson) cukup menambah satu nilai di sini plus satu implementasi
/// [PrinterBackend] baru dan satu case di [createPrinterBackend] --
/// `switch` di bawah dijaga exhaustive oleh compiler Dart, jadi tidak ada
/// tempat lupa di-update yang lolos diam-diam.
enum PrinterVendor { innerSunmi, bluetooth }

/// Bangun implementasi [PrinterBackend] konkret untuk [vendor].
PrinterBackend createPrinterBackend(PrinterVendor vendor) => switch (vendor) {
  PrinterVendor.innerSunmi => PrinterBackendSunmi(),
  PrinterVendor.bluetooth => PrinterBackendEscpos(),
};

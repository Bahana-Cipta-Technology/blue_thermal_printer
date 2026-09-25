import 'printer_backend.dart';
import 'printer_backend_escpos.dart';
import 'printer_backend_fallback.dart';
import 'printer_backend_imin.dart';
import 'printer_backend_sunmi.dart';
import 'printer_backend_xcheng.dart';

/// Vendor backend printer yang plugin ini dukung -- source of truth tunggal
/// dipakai semua app konsumen, supaya daftar vendor tidak didefinisikan
/// ulang (dan berisiko drift) di tiap app. Menambah dukungan vendor baru
/// (mis. Epson) cukup menambah satu nilai di sini plus satu implementasi
/// [PrinterBackend] baru dan satu case di [createPrinterBackend] --
/// `switch` di bawah dijaga exhaustive oleh compiler Dart, jadi tidak ada
/// tempat lupa di-update yang lolos diam-diam.
///
/// Nilai disimpan app konsumen berdasarkan `name`, jadi urutan di sini hanya
/// memengaruhi urutan tampil di UI.
enum PrinterVendor { innerSunmi, bluetooth, innerXcheng, innerImin }

/// Bangun implementasi [PrinterBackend] konkret untuk [vendor].
///
/// [PrinterVendor.innerXcheng] memakai antarmuka native Xcheng
/// ([PrinterBackendXcheng]) dan kembali ke AIDL kompatibel Sunmi yang juga
/// disediakan servis Xcheng bila antarmuka native itu tidak bisa terhubung
/// (lihat [PrinterBackendFallback]). [PrinterVendor.innerImin] untuk printer
/// bawaan iMin SDK 2.0 ([PrinterBackendImin]).
PrinterBackend createPrinterBackend(PrinterVendor vendor) => switch (vendor) {
  PrinterVendor.innerSunmi => PrinterBackendSunmi(),
  PrinterVendor.bluetooth => PrinterBackendEscpos(),
  PrinterVendor.innerXcheng => PrinterBackendFallback(
    primary: PrinterBackendXcheng(),
    fallback: PrinterBackendSunmi(),
  ),
  PrinterVendor.innerImin => PrinterBackendImin(),
};

/// Urutan pengecekan printer bawaan: yang paling spesifik dulu. Servis
/// Xcheng juga menyediakan AIDL kompatibel Sunmi, jadi Sunmi yang dicek
/// lebih dulu akan salah mengenali perangkat Xcheng sebagai Sunmi (dan
/// kehilangan sensor kertasnya). iMin juga dicek sebelum Sunmi dengan alasan
/// yang sama, berjaga-jaga bila servisnya ikut mengekspos AIDL Woyou.
const _builtInDetectionOrder = [
  PrinterVendor.innerXcheng,
  PrinterVendor.innerImin,
  PrinterVendor.innerSunmi,
];

/// Deteksi printer bawaan perangkat ini: vendor pertama (Xcheng, iMin, lalu
/// Sunmi) yang berhasil terhubung, atau `null` bila tidak ada printer bawaan
/// (pakai Bluetooth). Cukup dipanggil sekali (mis. saat boot) -- hardware tidak
/// berubah selama app hidup. Tiap probe diputus lagi setelah dicek.
///
/// Untuk Xcheng, probe memakai [PrinterBackendXcheng] langsung (tanpa
/// fallback), supaya perangkat Sunmi tidak ikut terdeteksi sebagai Xcheng.
/// [probe] bisa diganti untuk test.
Future<PrinterVendor?> detectBuiltInPrinterVendor({
  PrinterBackend Function(PrinterVendor vendor)? probe,
}) async {
  final build =
      probe ??
      (vendor) => switch (vendor) {
        PrinterVendor.innerXcheng => PrinterBackendXcheng(),
        _ => createPrinterBackend(vendor),
      };
  for (final vendor in _builtInDetectionOrder) {
    final backend = build(vendor);
    try {
      final devices = await backend.discoverDevices();
      if (devices.isEmpty) continue;
      final result = await backend.connect(devices.first);
      if (result.isOk) return vendor;
    } catch (_) {
      // Probe yang melempar = vendor ini tidak tersedia.
    } finally {
      await backend.disconnect();
    }
  }
  return null;
}

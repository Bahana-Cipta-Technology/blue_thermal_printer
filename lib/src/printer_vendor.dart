import 'printer_backend.dart';
import 'printer_backend_escpos.dart';
import 'printer_backend_escpos_network.dart';
import 'printer_backend_escpos_usb.dart';
import 'printer_backend_fallback.dart';
import 'printer_backend_imin.dart';
import 'printer_backend_imin_usb.dart';
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
enum PrinterVendor {
  innerSunmi,
  bluetooth,
  innerXcheng,
  innerImin,
  lan,
  usb,

  /// Printer USB internal perangkat iMin SDK 1.0 (mis. D1), lihat
  /// [PrinterBackendIminUsb].
  innerIminUsb,
}

/// Jalur fisik ke printer -- tingkat pertama yang dilihat pengguna saat
/// memilih printer ("printernya nempel di mesin / Bluetooth / jaringan /
/// kabel"), sebelum memilih vendor/perangkat spesifik.
enum PrinterTransport { builtIn, bluetooth, lan, usb }

/// Pengelompokan [PrinterVendor] per [PrinterTransport] -- dijaga exhaustive
/// oleh compiler, jadi vendor baru wajib menyebut transport-nya.
extension PrinterVendorTransport on PrinterVendor {
  PrinterTransport get transport => switch (this) {
    PrinterVendor.innerSunmi ||
    PrinterVendor.innerXcheng ||
    PrinterVendor.innerImin ||
    PrinterVendor.innerIminUsb => PrinterTransport.builtIn,
    PrinterVendor.bluetooth => PrinterTransport.bluetooth,
    PrinterVendor.lan => PrinterTransport.lan,
    PrinterVendor.usb => PrinterTransport.usb,
  };
}

/// Vendor milik [transport]. Untuk [PrinterTransport.builtIn] urutannya sama
/// dengan urutan deteksi printer bawaan (paling spesifik dulu).
List<PrinterVendor> vendorsOf(PrinterTransport transport) => switch (transport) {
  PrinterTransport.builtIn => _builtInDetectionOrder,
  _ => [
    for (final vendor in PrinterVendor.values)
      if (vendor.transport == transport) vendor,
  ],
};

/// Bangun implementasi [PrinterBackend] konkret untuk [vendor].
///
/// [PrinterVendor.innerXcheng] memakai antarmuka native Xcheng
/// ([PrinterBackendXcheng]) dan kembali ke AIDL kompatibel Sunmi yang juga
/// disediakan servis Xcheng bila antarmuka native itu tidak bisa terhubung
/// (lihat [PrinterBackendFallback]). [PrinterVendor.innerImin] untuk printer
/// bawaan iMin SDK 2.0 ([PrinterBackendImin]), [PrinterVendor.innerIminUsb]
/// untuk printer USB internal iMin SDK 1.0 ([PrinterBackendIminUsb]).
/// [PrinterVendor.lan] dan
/// [PrinterVendor.usb] memakai logika ESC/POS yang sama dengan Bluetooth di
/// atas [NetworkEscposTransport]/[UsbEscposTransport].
PrinterBackend createPrinterBackend(PrinterVendor vendor) => switch (vendor) {
  PrinterVendor.innerSunmi => PrinterBackendSunmi(),
  PrinterVendor.bluetooth => PrinterBackendEscpos(),
  PrinterVendor.innerXcheng => PrinterBackendFallback(
    primary: PrinterBackendXcheng(),
    fallback: PrinterBackendSunmi(),
  ),
  PrinterVendor.innerImin => PrinterBackendImin(),
  PrinterVendor.lan => PrinterBackendEscpos.withTransport(NetworkEscposTransport()),
  PrinterVendor.usb => PrinterBackendEscpos.withTransport(UsbEscposTransport()),
  PrinterVendor.innerIminUsb => PrinterBackendIminUsb(),
};

/// Urutan pengecekan printer bawaan: yang paling spesifik dulu. Servis
/// Xcheng juga menyediakan AIDL kompatibel Sunmi, jadi Sunmi yang dicek
/// lebih dulu akan salah mengenali perangkat Xcheng sebagai Sunmi (dan
/// kehilangan sensor kertasnya). iMin juga dicek sebelum Sunmi dengan alasan
/// yang sama, berjaga-jaga bila servisnya ikut mengekspos AIDL Woyou. iMin
/// SDK 1.0 (printer USB internal) dicek sesudah iMin SDK 2.0: perangkat SDK 2.0
/// memakai servisnya, perangkat SDK 1.0 tidak punya servis itu.
const _builtInDetectionOrder = [
  PrinterVendor.innerXcheng,
  PrinterVendor.innerImin,
  PrinterVendor.innerIminUsb,
  PrinterVendor.innerSunmi,
];

/// Vendor yang dideteksi cukup dari keberadaan perangkatnya
/// ([PrinterBackend.isAvailable]), tanpa `connect`. Menyambung printer USB
/// memunculkan dialog izin USB sistem, yang tidak boleh muncul hanya karena
/// app dibuka.
const _detectedWithoutConnect = {PrinterVendor.innerIminUsb};

/// Deteksi printer bawaan perangkat ini: vendor pertama (Xcheng, iMin, iMin
/// USB, lalu Sunmi) yang berhasil terhubung, atau `null` bila tidak ada printer bawaan
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
    if (_detectedWithoutConnect.contains(vendor)) {
      // Tanpa connect, jadi juga tanpa disconnect: channel USB native dipakai
      // bersama, dan disconnect di sini bisa memutus sambungan yang hidup.
      try {
        if (await backend.isAvailable()) return vendor;
      } catch (_) {
        // Probe yang melempar = vendor ini tidak tersedia.
      }
      continue;
    }
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

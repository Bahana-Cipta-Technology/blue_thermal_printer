import 'printer_backend.dart';
import 'printer_device.dart';
import 'printer_status.dart';
import 'receipt.dart';
import 'result.dart';

/// [PrinterBackend] yang memakai [primary], dan pindah ke [fallback] HANYA
/// bila [primary] gagal terhubung (mis. antarmuka native Xcheng tidak
/// menjawab di firmware lain -> AIDL kompatibel Sunmi).
///
/// Sengaja tidak ada fallback per cetakan: kalau [primary] menolak cetak
/// karena kertas habis lalu dicoba lagi lewat [fallback] yang buta kertas,
/// data justru menumpuk di buffer servis dan tercetak belakangan. Setelah
/// [connect], semua panggilan diteruskan ke backend yang aktif ([active]).
class PrinterBackendFallback implements PrinterBackend {
  PrinterBackendFallback({required this.primary, required this.fallback})
    : assert(
        primary.requiresPairing == fallback.requiresPairing,
        'primary dan fallback harus sama-sama butuh/tidak butuh pairing',
      ),
      _active = primary;

  final PrinterBackend primary;
  final PrinterBackend fallback;
  PrinterBackend _active;

  /// Backend yang sedang dipakai -- [primary] sampai [connect] ke [primary]
  /// gagal dan [fallback] berhasil.
  PrinterBackend get active => _active;

  @override
  String get displayName => _active.displayName;

  @override
  bool get requiresPairing => primary.requiresPairing;

  @override
  Future<bool> isAvailable() => _active.isAvailable();

  @override
  Future<List<PrinterDevice>> discoverDevices() => _active.discoverDevices();

  @override
  Future<PrinterResult<void>> connect(PrinterDevice device) async {
    final primaryResult = await primary.connect(device);
    if (primaryResult.isOk) {
      _active = primary;
      return primaryResult;
    }
    // Lepas bind yang mungkin setengah jadi sebelum mencoba jalur lain.
    await primary.disconnect();
    final fallbackResult = await fallback.connect(device);
    _active = fallbackResult.isOk ? fallback : primary;
    // Bila keduanya gagal, pesan fallback (lebih umum, mis. "Printer bawaan
    // tidak terdeteksi") lebih bermakna bagi pengguna daripada pesan
    // spesifik vendor primary.
    return fallbackResult;
  }

  @override
  Future<void> disconnect() async {
    await _active.disconnect();
    // Koneksi berikutnya mencoba primary lagi.
    _active = primary;
  }

  @override
  Future<bool> isConnected() => _active.isConnected();

  @override
  Future<PrinterResult<PrinterStatus>> checkStatus() => _active.checkStatus();

  @override
  Future<PrinterResult<void>> printReceipt(Receipt receipt) =>
      _active.printReceipt(receipt);

  @override
  Future<void> openSystemSettings() => _active.openSystemSettings();
}

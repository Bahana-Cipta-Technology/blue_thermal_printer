import 'printer_device.dart';
import 'result.dart';

/// Satu perangkat hasil pencarian.
class DiscoveredPrinter {
  const DiscoveredPrinter({
    required this.device,
    this.rssi,
    this.deviceClass,
    this.isBonded = false,
  });

  final PrinterDevice device;

  /// Kekuatan sinyal (dBm, makin mendekati 0 makin dekat), bila dilaporkan.
  final int? rssi;

  /// Class of Device Bluetooth (major + minor), bila dilaporkan.
  final int? deviceClass;

  /// Sudah dipasangkan di level OS.
  final bool isBonded;

  /// Perangkat tanpa nama -- UI boleh melipatnya.
  bool get hasName => device.name.trim().isNotEmpty;

  /// Kemungkinan besar printer: Class of Device "Imaging/Printer", atau class
  /// tidak dikategorikan dengan nama khas printer thermal. Hanya untuk
  /// pengurutan, bukan penyaring -- printer murah sering melaporkan class
  /// kosong dan nama apa saja.
  bool get isLikelyPrinter {
    final cod = deviceClass;
    if (cod != null &&
        cod & _majorMask == _majorImaging &&
        cod & _printerBit != 0) {
      return true;
    }
    // Class kosong/misc (0) juga umum di printer murah.
    final major = cod == null ? null : cod & _majorMask;
    final uncategorized =
        major == null || major == _majorUncategorized || major == _majorMisc;
    return uncategorized && _printerName.hasMatch(device.name);
  }

  static const _majorMask = 0x1F00;
  static const _majorImaging = 0x0600;
  static const _majorUncategorized = 0x1F00;
  static const _majorMisc = 0x0000;
  static const _printerBit = 0x80;
  static final _printerName = RegExp(
    r'print|pos|rpp|mtp|thermal|^pt-|^xp-|^mpt|^ppt|^bt-?58|^bt-?80',
    caseSensitive: false,
  );
}

/// Peristiwa dalam satu sesi pencarian.
sealed class ScanEvent {
  const ScanEvent();
}

final class ScanStarted extends ScanEvent {
  const ScanStarted();
}

/// Satu perangkat ditemukan. Perangkat yang sama bisa dilaporkan lebih dari
/// sekali (nama/RSSI diperbarui) -- UI menimpa berdasarkan alamat.
final class DeviceFound extends ScanEvent {
  const DeviceFound(this.printer);

  final DiscoveredPrinter printer;
}

/// Alasan pencarian berakhir.
enum ScanEndReason { completed, timedOut, stopped, adapterOff, failed }

/// Pencarian berakhir. Selalu jadi event terakhir stream.
final class ScanFinished extends ScanEvent {
  const ScanFinished(this.reason, {this.failure});

  final ScanEndReason reason;

  /// Penyebab bila [reason] == [ScanEndReason.failed].
  final PrinterFailure? failure;
}

/// Kemampuan opsional: mencari perangkat baru dan memasangkannya.
///
/// Didapat lewat `printerFeature<PrinterDeviceScanner>(backend)`.
/// `PrinterBackend.discoverDevices` tetap berarti "perangkat yang bisa
/// dipilih sekarang" (mis. sudah terpasang); pencarian di sini untuk
/// menemukan perangkat yang belum.
abstract interface class PrinterDeviceScanner {
  /// Waktu pencarian bawaan -- satu siklus inquiry Bluetooth Classic.
  static const defaultTimeout = Duration(seconds: 12);

  /// Mulai mencari. Single-flight: selama pencarian berjalan, panggilan
  /// berikutnya mendapat stream yang sama. Stream selalu diakhiri
  /// [ScanFinished]; prasyarat yang belum terpenuhi dilaporkan sebagai
  /// [ScanFinished] dengan [ScanEndReason.failed].
  Stream<ScanEvent> scan({Duration timeout = defaultTimeout});

  /// Pencarian dari [scan] sedang berjalan.
  bool get isScanning;

  /// Hentikan pencarian yang sedang berjalan (no-op bila tidak ada).
  Future<void> stopScan();

  /// Pasangkan [device] (dialog PIN ditampilkan sistem). Sukses bila sudah
  /// atau berhasil dipasangkan; gagal bila ditolak, PIN salah, atau tidak
  /// selesai dalam batas waktu.
  Future<PrinterResult<PrinterDevice>> pair(PrinterDevice device);
}

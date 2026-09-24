/// Status fisik printer dibaca dari respons ESC/POS `DLE EOT 2` (offline
/// status).
///
/// Setiap field `null` berarti printer tidak merespons query ini dalam batas
/// waktu -- BUKAN error, karena tidak semua printer clone SPP+ESC/POS
/// mengimplementasikan query real-time status. Jangan jadikan `null` alasan
/// memblokir pencetakan; hanya tampilkan sebagai peringatan bila diketahui
/// pasti (`false`/`true`).
class PrinterStatus {
  const PrinterStatus({this.hasPaper, this.coverClosed, this.hasError});

  /// `null` = tidak diketahui, `true` = kertas tersedia, `false` = kertas habis.
  final bool? hasPaper;

  /// `null` = tidak diketahui, `true` = tertutup, `false` = cover terbuka.
  final bool? coverClosed;

  /// `null` = tidak diketahui, `true` = printer melaporkan kondisi galat.
  final bool? hasError;

  /// Dipakai saat printer tidak merespons query status sama sekali.
  static const unknown = PrinterStatus();

  /// `true` hanya bila ada sinyal masalah yang diketahui pasti (bukan `null`).
  bool get hasKnownProblem =>
      hasPaper == false || coverClosed == false || hasError == true;

  /// Pesan yang menjelaskan masalah yang diketahui, atau `null` bila
  /// [hasKnownProblem] `false`. Satu sumber pesan dipakai bersama oleh
  /// semua backend (`PrinterBackendEscpos`/`PrinterBackendSunmi`) untuk
  /// pre-check maupun pengecekan pasca-cetak, supaya teksnya konsisten dan
  /// tidak diduplikasi tiap implementasi.
  String? get problemMessage {
    if (hasPaper == false) return 'Kertas printer habis.';
    if (coverClosed == false) return 'Penutup printer terbuka.';
    if (hasError == true) return 'Printer melaporkan galat.';
    return null;
  }

  /// Decode byte respons `DLE EOT 2` (offline status) sesuai spec ESC/POS:
  /// bit 2 = cover terbuka, bit 5 = berhenti karena kertas habis, bit 6 =
  /// galat terjadi.
  factory PrinterStatus.fromOfflineStatusByte(int byte) => PrinterStatus(
    hasPaper: (byte & 0x20) == 0,
    coverClosed: (byte & 0x04) == 0,
    hasError: (byte & 0x40) != 0,
  );

  /// Seperti [PrinterStatus.fromOfflineStatusByte], tapi mengembalikan
  /// [unknown] bila [byte] bukan respons `DLE EOT` yang sah. Semua respons
  /// `DLE EOT n` punya pola bit tetap (bit 0 = 0, bit 1 = 1, bit 4 = 1,
  /// bit 7 = 0) -- byte lain (mis. XON `0x11`/XOFF `0x13` dari flow control,
  /// atau sampah) jangan sampai dibaca sebagai status.
  static PrinterStatus tryFromOfflineStatusByte(int byte) =>
      isValidRealtimeStatusByte(byte)
      ? PrinterStatus.fromOfflineStatusByte(byte)
      : unknown;

  /// `true` bila [byte] cocok dengan pola bit tetap respons `DLE EOT n`.
  static bool isValidRealtimeStatusByte(int byte) =>
      byte >= 0 && byte <= 0xFF && (byte & 0x93) == 0x12;
}

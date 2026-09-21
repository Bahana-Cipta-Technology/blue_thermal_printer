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

  /// Decode byte respons `DLE EOT 2` (offline status) sesuai spec ESC/POS:
  /// bit 2 = cover terbuka, bit 5 = berhenti karena kertas habis, bit 6 =
  /// galat terjadi.
  factory PrinterStatus.fromOfflineStatusByte(int byte) => PrinterStatus(
    hasPaper: (byte & 0x20) == 0,
    coverClosed: (byte & 0x04) == 0,
    hasError: (byte & 0x40) != 0,
  );
}

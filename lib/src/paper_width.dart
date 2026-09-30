/// Lebar raster (piksel, 8 dot/mm) kertas 58 mm.
const paperWidth58Px = 384;

/// Lebar raster (piksel, 8 dot/mm) kertas 80 mm.
const paperWidth80Px = 576;

/// Lebar kertas pilihan pengguna untuk backend yang tidak bisa mengetahuinya
/// sendiri -- lihat [PrinterBackend.setPaperWidth].
///
/// ESC/POS tidak punya perintah universal untuk membaca lebar kertas:
/// sensor printer thermal hanya tahu ada/tidaknya kertas, dan lebar area
/// cetak adalah setelan printer (DIP/memory switch). `GS ( E` fn 6 (Epson)
/// hanya jalan di User Setting Mode yang me-reset printer saat keluar.
enum PaperWidthSetting {
  /// Ditebak backend (ESC/POS: autocutter terdeteksi → 80 mm, selain itu
  /// lebar renderer bawaan).
  auto,
  mm58,
  mm80,
}

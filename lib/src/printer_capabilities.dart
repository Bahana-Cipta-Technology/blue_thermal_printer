/// Hasil `printReceipt` yang sukses -- membedakan struk yang *pasti* tercetak
/// dari data yang sekadar terkirim tanpa bukti gagal.
enum PrintDelivery {
  /// Printer/servis melaporkan struk selesai tercetak (mis. `onComplete`
  /// Xcheng, `onPrintResult` Sunmi asli). Hanya mungkin bila
  /// [PrinterCapabilities.confirmsPrint] `true`.
  confirmed,

  /// Data terkirim dan tidak ada bukti gagal (pre-/post-check status bersih),
  /// tapi printer tidak mengonfirmasi struk keluar. UI sebaiknya meminta
  /// petugas memeriksa struk fisik, bukan mengklaim "tercetak".
  unverified,
}

/// Kemampuan backend printer yang sedang dipakai -- menjelaskan PERILAKU
/// backend (lebar raster yang akan dipakai, apakah backend memotong kertas),
/// bukan tebakan hardware. Dibaca tanpa menulis apa pun ke printer.
///
/// Field `bool?` bernilai `null` bila memang belum/tidak bisa diketahui
/// (mis. printer ESC/POS yang belum pernah ditanya status) -- jangan
/// diperlakukan sama dengan `false`.
class PrinterCapabilities {
  const PrinterCapabilities({
    required this.paperWidthPx,
    required this.autoCut,
    this.reportsPaperOut,
    this.confirmsPrint,
  });

  /// Default aman: kertas 58 mm (384 dot), tanpa pemotong, sisanya belum
  /// diketahui.
  static const fallback58 = PrinterCapabilities(paperWidthPx: 384, autoCut: false);

  /// Lebar raster (piksel, 8 dot/mm) yang DIPAKAI `printReceipt` dan
  /// `preview` saat ini: 384 = 58 mm, 576 = 80 mm.
  final int paperWidthPx;

  /// `true` bila backend memotong kertas otomatis setelah struk; `false`
  /// berarti petugas menyobek sendiri.
  final bool autoCut;

  /// Apakah deteksi kertas habis bisa dipercaya (pre-check memblokir cetak
  /// saat kertas habis). `null` = belum diketahui.
  final bool? reportsPaperOut;

  /// Apakah backend bisa menghasilkan [PrintDelivery.confirmed]. `null` =
  /// belum diketahui.
  final bool? confirmsPrint;

  @override
  bool operator ==(Object other) =>
      other is PrinterCapabilities &&
      other.paperWidthPx == paperWidthPx &&
      other.autoCut == autoCut &&
      other.reportsPaperOut == reportsPaperOut &&
      other.confirmsPrint == confirmsPrint;

  @override
  int get hashCode =>
      Object.hash(paperWidthPx, autoCut, reportsPaperOut, confirmsPrint);

  @override
  String toString() =>
      'PrinterCapabilities(paperWidthPx: $paperWidthPx, autoCut: $autoCut, '
      'reportsPaperOut: $reportsPaperOut, confirmsPrint: $confirmsPrint)';
}

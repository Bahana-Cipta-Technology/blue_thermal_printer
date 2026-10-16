package id.kakzaki.blue_thermal_printer.vendor.ciontek;

/**
 * Logika murni (tanpa Android framework, dites JUnit) untuk kode hasil servis printer Ciontek.
 * Sumber tabel: "CS30Pro-SDK instructions V1.0.1.pdf" §3 dan demo resmi {@code PrintActivity}.
 */
final class CiontekResultCodes {

  static final String OUTCOME_PRINTED = "printed";
  static final String OUTCOME_FAILED = "failed";
  static final String OUTCOME_UNKNOWN = "unknown";

  /** {@code Lib_PrnInit}/{@code Lib_PrnBmp}: buffer cetak servis penuh. */
  static final int PRN_BUFFER_OVERFLOW = -4008;

  /** Batas tinggi satu bitmap {@code Lib_PrnBmp} menurut dokumentasi resmi (lebar ≤ 384, tinggi ≤ 500). */
  static final int MAX_BITMAP_HEIGHT = 500;

  private CiontekResultCodes() {}

  /**
   * Terjemahkan kode {@code Lib_PrnStart} (sinkron, kembali setelah selesai mencetak).
   *
   * <p>Kode gagal yang terdokumentasi = {@code failed}: kertas habis (-1, -1014, -1015, -1021), suhu
   * tinggi (-2, -1022), tegangan rendah (-3), status error (-1023), batas jumlah cetak (-1007..-1012).
   * Timeout, gagal kirim/terima, balasan kacau (8/9), dan kode tak terdokumentasi = {@code unknown}:
   * struk mungkin sudah (sebagian) keluar, jadi hasilnya diverifikasi ulang lewat status, bukan
   * dilaporkan gagal pasti (petugas lalu mengulang dan struk tercetak dobel).
   */
  static String startOutcome(int code) {
    if (code == 0) return OUTCOME_PRINTED;
    switch (code) {
      case -1:
      case -1014:
      case -1015:
      case -1021:
      case -2:
      case -1022:
      case -3:
      case -1023:
        return OUTCOME_FAILED;
      default:
        if (code <= -1007 && code >= -1012) return OUTCOME_FAILED;
        return OUTCOME_UNKNOWN;
    }
  }

  /**
   * Pecah bitmap setinggi {@code height} menjadi strip setinggi maksimal {@code maxStrip}. Tiap
   * elemen = {top, tinggi}. Bitmap kosong (tinggi ≤ 0) = tanpa strip.
   */
  static int[][] strips(int height, int maxStrip) {
    if (maxStrip <= 0) throw new IllegalArgumentException("maxStrip must be positive");
    if (height <= 0) return new int[0][];
    int count = (height + maxStrip - 1) / maxStrip;
    int[][] result = new int[count][];
    for (int i = 0; i < count; i++) {
      int top = i * maxStrip;
      result[i] = new int[] {top, Math.min(maxStrip, height - top)};
    }
    return result;
  }
}

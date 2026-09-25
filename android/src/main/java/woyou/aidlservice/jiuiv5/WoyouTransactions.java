package woyou.aidlservice.jiuiv5;

/**
 * Membuka kode transaksi AIDL Woyou yang di-generate sebagai konstanta package-private di
 * {@code IWoyouService.Stub}, supaya {@code SunmiPrinterBridge} bisa memanggil method tertentu
 * lewat {@link android.os.IBinder#transact} dan MEMERIKSA hasil {@code transact}. Proxy hasil
 * generate mengabaikan hasil itu: di firmware yang belum punya method-nya, pemanggilan tetap
 * "berhasil" dan mengembalikan 0 -- untuk {@code getPrinterPaper()} artinya keliru terbaca 80 mm.
 *
 * Nilainya diambil dari stub hasil generate AIDL di folder ini, jadi selalu sinkron dengan
 * {@code IWoyouService.aidl}.
 */
public final class WoyouTransactions {
  private WoyouTransactions() {
  }

  public static final int GET_PRINTER_PAPER = IWoyouService.Stub.TRANSACTION_getPrinterPaper;
}

package id.kakzaki.blue_thermal_printer.vendor.imin;

import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.ServiceConnection;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.os.IBinder;
import android.os.RemoteException;
import android.util.Log;

import com.imin.printer.INeoPrinterService;
import com.imin.printer.IPrinterCallback;

import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

/**
 * Jembatan ke servis printer bawaan iMin SDK 2.0 ({@code com.imin.printerservice}) lewat stub
 * AIDL resmi {@code com.github.iminsoftware:IminPrinterLibrary} -- lihat
 * {@code doc/vendor-imin-design.md}.
 *
 * Setelah tersambung, servis mewajibkan handshake {@code initPrinter(packageName, callback)} yang
 * mengembalikan {@code fd}; semua method berikutnya menerima {@code fd} itu. Handshake dijalankan
 * di executor (bukan main thread) dan {@link #status()} mengembalikan {@link #STATUS_NOT_READY}
 * sampai {@code fd} tersedia, jadi polling {@code connect()} di Dart otomatis menunggunya.
 *
 * Cetak lewat mode transaksi (enterPrinterBuffer → bitmap → feed → cut →
 * exitPrinterBufferWithCallback). Menurut dokumen resmi §3.18, transaksi dibatalkan bila printer
 * bermasalah (kertas habis, overheat) -- tidak ditahan lalu tercetak menumpuk.
 */
public class IminPrinterBridge {

  private static final String TAG = "IminPrinterBridge";
  private static final String SERVICE_PACKAGE = "com.imin.printerservice";
  private static final String SERVICE_ACTION = "com.imin.printerservice.NeoPrinterService";
  private static final String SERVICE_CLASS =
      "com.imin.printerservice.core.ApiAdapterManager.NeoPrinterService";

  /** Kode resmi {@code getPrinterStatus()} untuk "belum tersambung ke servis" -- dipakai juga
   * sebagai sentinel selama servis/{@code fd} belum siap. Harus sinkron dengan sisi Dart. */
  public static final int STATUS_NOT_READY = -1;

  /** Nilai outcome transaksi yang dikirim ke Dart (lihat `IminPrintOutcome`). */
  public static final String OUTCOME_PRINTED = "printed";
  public static final String OUTCOME_FAILED = "failed";
  public static final String OUTCOME_UNKNOWN = "unknown";

  /** Kode {@code onPrintResult} yang berarti sukses. Dokumen resmi kontradiktif (pendahuluan §3.18:
   * 0 sukses; deskripsi per method termasuk §3.18.4: 1 sukses) -- nilai ini baru dipakai setelah
   * {@link #PRINT_RESULT_CODE_VERIFIED} diaktifkan dari hasil uji hardware. */
  static final int PRINT_RESULT_SUCCESS = 1;

  /** {@code false} = kode {@code onPrintResult} belum terverifikasi di hardware: setiap kode
   * dilaporkan {@link #OUTCOME_UNKNOWN} (dan di-log) supaya post-check status yang menentukan. */
  static final boolean PRINT_RESULT_CODE_VERIFIED = false;

  // Sama dengan Sunmi: struk parkir tercetak dalam hitungan detik; firmware yang tidak memanggil
  // callback transaksi jangan sampai menahan pemanggil jauh lebih lama dari ini.
  private static final long TRANSACTION_RESULT_TIMEOUT_MILLIS = 12_000;

  private final Context context;
  private final ExecutorService executor = Executors.newSingleThreadExecutor();
  private volatile INeoPrinterService service;
  private volatile int fd = STATUS_NOT_READY;

  /** {@code false} setelah callback transaksi pernah tidak datang sama sekali -- sisa sesi
   * langsung commit polos supaya jeda timeout tidak dibayar di tiap cetakan. */
  private volatile boolean transactionCallbackSupported = true;

  public IminPrinterBridge(Context context) {
    this.context = context;
  }

  private final ServiceConnection connection = new ServiceConnection() {
    @Override
    public void onServiceConnected(ComponentName name, IBinder binder) {
      INeoPrinterService connected = INeoPrinterService.Stub.asInterface(binder);
      service = connected;
      fd = STATUS_NOT_READY;
      executor.execute(() -> initPrinter(connected));
    }

    @Override
    public void onServiceDisconnected(ComponentName name) {
      // BIND_AUTO_CREATE menyambung ulang otomatis; handshake diulang di onServiceConnected.
      service = null;
      fd = STATUS_NOT_READY;
    }

    @Override
    public void onBindingDied(ComponentName name) {
      Log.w(TAG, "Binding servis printer iMin mati, bind ulang");
      unbindPrinterService();
      bindPrinterService();
    }

    @Override
    public void onNullBinding(ComponentName name) {
      Log.w(TAG, "Servis printer iMin menolak binding (onBind mengembalikan null)");
      service = null;
      fd = STATUS_NOT_READY;
    }
  };

  private void initPrinter(INeoPrinterService connected) {
    try {
      int result = connected.initPrinter(context.getPackageName(), new LoggingCallback("initPrinter"));
      if (service != connected) return; // Servis sudah berganti selama handshake.
      if (result < 0) {
        Log.w(TAG, "initPrinter iMin gagal, fd=" + result);
        return;
      }
      fd = result;
      Log.i(TAG, "Printer iMin siap, fd=" + result + ", servis v" + connected.getServiceVersion(result));
    } catch (RemoteException | RuntimeException error) {
      Log.w(TAG, "Handshake initPrinter iMin gagal", error);
    }
  }

  /** Mulai bind. `true` = permintaan diterima sistem (tersambungnya async). `false` di perangkat
   * tanpa servis iMin SDK 2.0. */
  public boolean bindPrinterService() {
    try {
      Intent intent = new Intent(SERVICE_ACTION);
      intent.setComponent(new ComponentName(SERVICE_PACKAGE, SERVICE_CLASS));
      return context.bindService(intent, connection, Context.BIND_AUTO_CREATE);
    } catch (Exception error) {
      Log.w(TAG, "Gagal memulai bind ke servis printer iMin", error);
      return false;
    }
  }

  public void unbindPrinterService() {
    try {
      context.unbindService(connection);
    } catch (IllegalArgumentException error) {
      // Belum pernah/tidak lagi terbind -- aman diabaikan.
    } finally {
      service = null;
      fd = STATUS_NOT_READY;
    }
  }

  /** Kode {@code getPrinterStatus()}, atau {@link #STATUS_NOT_READY} bila servis/{@code fd} belum
   * siap atau panggilan gagal. Kode di luar tabel resmi (-1/0/3/4/7) di-log. */
  public int status() {
    INeoPrinterService current = service;
    int currentFd = fd;
    if (current == null || currentFd < 0) return STATUS_NOT_READY;
    try {
      int code = current.getPrinterStatus(currentFd);
      if (code != -1 && code != 0 && code != 3 && code != 4 && code != 7) {
        Log.i(TAG, "Kode status iMin di luar tabel resmi: " + code);
      }
      return code;
    } catch (RemoteException | RuntimeException error) {
      Log.w(TAG, "Query status printer iMin gagal", error);
      return STATUS_NOT_READY;
    }
  }

  /** Lebar kertas terpasang (58/80), atau {@code null} bila tidak diketahui. */
  public Integer paperType() {
    INeoPrinterService current = service;
    int currentFd = fd;
    if (current == null || currentFd < 0) return null;
    try {
      return current.getPrinterPaperType(currentFd);
    } catch (RemoteException | RuntimeException error) {
      Log.w(TAG, "Query jenis kertas iMin gagal", error);
      return null;
    }
  }

  public interface TransactionCallback {
    void onOutcome(String outcome);
  }

  /** Cetak satu gambar (bytes PNG) sebagai satu transaksi, lalu feed {@code feedDistance} dan
   * potong kertas bila {@code cut}. Dijalankan di thread background; {@code callback} dipanggil
   * tepat sekali dengan salah satu {@code OUTCOME_*}. */
  public void printTransaction(byte[] encodedImage, int feedDistance, boolean cut,
      TransactionCallback callback) {
    executor.execute(() -> callback.onOutcome(runTransaction(encodedImage, feedDistance, cut)));
  }

  private String runTransaction(byte[] encodedImage, int feedDistance, boolean cut) {
    INeoPrinterService current = service;
    int currentFd = fd;
    if (current == null || currentFd < 0) return OUTCOME_FAILED;
    Bitmap bitmap = BitmapFactory.decodeByteArray(encodedImage, 0, encodedImage.length);
    if (bitmap == null) return OUTCOME_FAILED;

    try {
      // clean=true membuang sisa antrean transaksi sebelumnya yang tidak sempat di-exit.
      current.enterPrinterBuffer(currentFd, true);
      current.printBitmap(currentFd, bitmap, null);
      if (feedDistance > 0) current.printAndFeedPaper(currentFd, feedDistance);
      if (cut) current.partialCut(currentFd);
    } catch (RemoteException | RuntimeException error) {
      Log.w(TAG, "Gagal mengisi buffer transaksi printer iMin", error);
      commitQuietly(current, currentFd);
      return OUTCOME_UNKNOWN;
    }

    if (!transactionCallbackSupported) {
      commitQuietly(current, currentFd);
      return OUTCOME_UNKNOWN;
    }

    final ArrayBlockingQueue<String> mailbox = new ArrayBlockingQueue<>(1);
    try {
      current.exitPrinterBufferWithCallback(currentFd, true, new LoggingCallback("transaksi") {
        @Override
        public void onRaiseException(int code, String msg) {
          super.onRaiseException(code, msg);
          mailbox.offer(OUTCOME_FAILED);
        }

        @Override
        public void onPrintResult(int code, String msg) {
          super.onPrintResult(code, msg);
          mailbox.offer(outcomeFor(code));
        }
      });
    } catch (RemoteException | RuntimeException error) {
      Log.w(TAG, "exitPrinterBufferWithCallback iMin gagal, commit tanpa callback", error);
      commitQuietly(current, currentFd);
      return OUTCOME_UNKNOWN;
    }

    String outcome;
    try {
      outcome = mailbox.poll(TRANSACTION_RESULT_TIMEOUT_MILLIS, TimeUnit.MILLISECONDS);
    } catch (InterruptedException error) {
      Thread.currentThread().interrupt();
      outcome = null;
    }
    if (outcome == null) {
      Log.w(TAG, "onPrintResult iMin tidak datang dalam " + TRANSACTION_RESULT_TIMEOUT_MILLIS
          + "ms -- callback transaksi tidak ditunggu lagi di sesi ini");
      transactionCallbackSupported = false;
      // Isi buffer yang belum di-commit dicetak; no-op bila transaksi sebenarnya sudah selesai.
      commitQuietly(current, currentFd);
      return OUTCOME_UNKNOWN;
    }
    return outcome;
  }

  static String outcomeFor(int printResultCode) {
    if (!PRINT_RESULT_CODE_VERIFIED) return OUTCOME_UNKNOWN;
    return printResultCode == PRINT_RESULT_SUCCESS ? OUTCOME_PRINTED : OUTCOME_FAILED;
  }

  private void commitQuietly(INeoPrinterService current, int currentFd) {
    try {
      current.exitPrinterBuffer(currentFd, true);
    } catch (RemoteException | RuntimeException error) {
      Log.w(TAG, "Gagal keluar mode buffer printer iMin", error);
    }
  }

  public void dispose() {
    unbindPrinterService();
    executor.shutdown();
  }

  /** Callback yang hanya me-log -- dasar untuk callback handshake dan transaksi. */
  private static class LoggingCallback extends IPrinterCallback.Stub {
    private final String label;

    LoggingCallback(String label) {
      this.label = label;
    }

    @Override
    public void onRunResult(boolean isSuccess) {
      // Hanya menandakan API diterima, bukan hasil cetak.
    }

    @Override
    public void onReturnString(String result) {
      // Tidak relevan untuk handshake/transaksi.
    }

    @Override
    public void onRaiseException(int code, String msg) {
      Log.w(TAG, "iMin " + label + " melaporkan galat " + code + ": " + msg);
    }

    @Override
    public void onPrintResult(int code, String msg) {
      // Dicatat apa adanya -- bahan verifikasi arti kode (lihat PRINT_RESULT_CODE_VERIFIED).
      Log.i(TAG, "iMin " + label + " onPrintResult code=" + code + " msg=" + msg);
    }
  }
}

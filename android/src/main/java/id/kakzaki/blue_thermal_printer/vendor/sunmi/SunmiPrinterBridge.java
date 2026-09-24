package id.kakzaki.blue_thermal_printer.vendor.sunmi;

import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.ServiceConnection;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.os.IBinder;
import android.os.RemoteException;
import android.util.Log;

import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

import woyou.aidlservice.jiuiv5.ICallback;
import woyou.aidlservice.jiuiv5.IWoyouService;

/**
 * Jembatan ke servis printer bawaan Sunmi ("Woyou") lewat AIDL.
 *
 * Struktur bind/unbind diadaptasi dari {@code SunmiPrinterMethod.java} milik paket pub.dev
 * {@code sunmi_printer_plus} (https://github.com/brasizza/sunmi_printer, BSD-3-Clause -- lihat
 * LICENSE-sunmi_printer_plus di folder ini), diringkas hanya untuk method yang dipakai kontrak
 * {@code PrinterBackend}: bind/unbind, query status ({@link #updatePrinterState()}), dan cetak
 * satu struk sebagai transaksi buffer ({@link #printTransaction(byte[], int, TransactionCallback)}).
 *
 * Cetak sengaja lewat mode transaksi, bukan {@code printBitmap} polos: menurut doc
 * {@link ICallback#onRunResult(boolean)}, callback itu hanya menandakan panggilan API diterima,
 * bukan hasil kerja printer -- hasil sungguhan (kertas habis di tengah cetak, dst.) hanya datang
 * lewat {@link ICallback#onPrintResult(int, String)} milik
 * {@code exitPrinterBufferWithCallback}.
 */
public class SunmiPrinterBridge {

  private static final String TAG = "SunmiPrinterBridge";
  private static final String SERVICE_PACKAGE = "woyou.aidlservice.jiuiv5";
  private static final String SERVICE_ACTION = "woyou.aidlservice.jiuiv5.IWoyouService";

  /** Kode `updatePrinterState()` yang dipakai sebagai sentinel "servis belum
   * tersambung" -- sama seperti kode asli Sunmi untuk "printer tidak
   * terdeteksi", supaya pemanggil tidak perlu tahu ada dua sumber kode. */
  public static final int STATE_NOT_DETECTED = 505;

  /** Nilai outcome transaksi yang dikirim ke Dart (lihat `SunmiPrintOutcome`). */
  public static final String OUTCOME_PRINTED = "printed";
  public static final String OUTCOME_FAILED = "failed";
  public static final String OUTCOME_UNKNOWN = "unknown";

  // Batas tunggu onPrintResult. Struk parkir tercetak dalam hitungan detik; firmware yang tidak
  // mendukung exitPrinterBufferWithCallback (Sunmi: T1mini < v2.4.1, sebagian klon) tidak pernah
  // memanggil callback sama sekali, jadi jangan menahan pemanggil jauh lebih lama dari ini.
  private static final long TRANSACTION_RESULT_TIMEOUT_MILLIS = 12_000;

  private final Context context;
  private final ExecutorService executor = Executors.newSingleThreadExecutor();
  private volatile IWoyouService woyouService;

  /** {@code null} = belum diketahui; {@code false} = jangan tunggu callback transaksi, langsung
   * commit polos. Diset {@code false} sejak awal bila AIDL Woyou disediakan servis klon (bukan
   * paket Sunmi asli -- mis. {@code com.xcheng.printerservice}, yang terbukti tidak pernah
   * memanggil callback transaksi), atau setelah callback pernah tidak datang sama sekali, supaya
   * jeda timeout tidak dibayar di tiap cetakan. */
  private volatile Boolean transactionCallbackSupported;

  public SunmiPrinterBridge(Context context) {
    this.context = context;
  }

  private final ServiceConnection connection = new ServiceConnection() {
    @Override
    public void onServiceConnected(ComponentName name, IBinder binder) {
      woyouService = IWoyouService.Stub.asInterface(binder);
      boolean genuineSunmi = SERVICE_PACKAGE.equals(name.getPackageName());
      if (!genuineSunmi) {
        Log.i(TAG, "AIDL Woyou disediakan " + name.getPackageName()
            + " (bukan Sunmi asli) -- callback transaksi tidak ditunggu");
      }
      transactionCallbackSupported = genuineSunmi ? null : Boolean.FALSE;
    }

    @Override
    public void onServiceDisconnected(ComponentName name) {
      // BIND_AUTO_CREATE menyambung ulang otomatis saat servis hidup lagi.
      woyouService = null;
    }

    @Override
    public void onBindingDied(ComponentName name) {
      // Binding ini tidak akan pernah tersambung lagi dengan sendirinya (mis. paket servis
      // di-update) -- wajib unbind lalu bind ulang.
      Log.w(TAG, "Binding servis printer Sunmi mati, bind ulang");
      unbindPrinterService();
      bindPrinterService();
    }

    @Override
    public void onNullBinding(ComponentName name) {
      Log.w(TAG, "Servis printer Sunmi menolak binding (onBind mengembalikan null)");
      woyouService = null;
    }
  };

  /** Mulai bind ke servis Sunmi. Mengembalikan `true` bila permintaan bind
   * diterima sistem (BUKAN berarti sudah tersambung -- itu proses async,
   * lihat {@link #updatePrinterState()} untuk konfirmasi). */
  public boolean bindPrinterService() {
    try {
      Intent intent = new Intent();
      intent.setPackage(SERVICE_PACKAGE);
      intent.setAction(SERVICE_ACTION);
      return context.bindService(intent, connection, Context.BIND_AUTO_CREATE);
    } catch (Exception error) {
      Log.w(TAG, "Gagal memulai bind ke servis printer Sunmi", error);
      return false;
    }
  }

  public void unbindPrinterService() {
    try {
      context.unbindService(connection);
    } catch (IllegalArgumentException error) {
      // Belum pernah/tidak lagi terbind -- aman diabaikan.
    } finally {
      woyouService = null;
    }
  }

  /** Query status fisik printer. Mengembalikan {@link #STATE_NOT_DETECTED}
   * bila servis belum tersambung atau panggilan AIDL gagal. */
  public int updatePrinterState() {
    IWoyouService service = woyouService;
    if (service == null) return STATE_NOT_DETECTED;
    try {
      return service.updatePrinterState();
    } catch (RemoteException error) {
      Log.w(TAG, "Query status printer Sunmi gagal", error);
      return STATE_NOT_DETECTED;
    }
  }

  public interface TransactionCallback {
    void onOutcome(String outcome);
  }

  /** Cetak satu gambar penuh (bytes gambar biasa, mis. PNG -- didekode lewat
   * {@link BitmapFactory}, bukan raw pixel) sebagai satu transaksi buffer, lalu feed
   * {@code feedLines} baris. Dijalankan di thread background; {@code callback} dipanggil
   * tepat sekali dengan salah satu {@code OUTCOME_*}. */
  public void printTransaction(byte[] encodedImage, int feedLines, TransactionCallback callback) {
    executor.execute(() -> callback.onOutcome(runTransaction(encodedImage, feedLines)));
  }

  private String runTransaction(byte[] encodedImage, int feedLines) {
    IWoyouService service = woyouService;
    if (service == null) return OUTCOME_FAILED;
    Bitmap bitmap = BitmapFactory.decodeByteArray(encodedImage, 0, encodedImage.length);
    if (bitmap == null) return OUTCOME_FAILED;

    try {
      // clean=true membuang sisa buffer dari transaksi sebelumnya yang tidak sempat di-exit.
      service.enterPrinterBuffer(true);
      service.printBitmap(bitmap, null);
      service.lineWrap(feedLines, null);
    } catch (RemoteException | RuntimeException error) {
      Log.w(TAG, "Gagal mengisi buffer transaksi printer Sunmi", error);
      commitQuietly(service);
      return OUTCOME_UNKNOWN;
    }

    if (Boolean.FALSE.equals(transactionCallbackSupported)) {
      commitQuietly(service);
      return OUTCOME_UNKNOWN;
    }

    final ArrayBlockingQueue<String> mailbox = new ArrayBlockingQueue<>(1);
    try {
      service.exitPrinterBufferWithCallback(true, new ICallback.Stub() {
        @Override
        public void onRunResult(boolean isSuccess) {
          // Hanya menandakan API diterima, bukan hasil cetak -- tunggu onPrintResult.
        }

        @Override
        public void onReturnString(String result) {
          // Tidak relevan untuk transaksi cetak.
        }

        @Override
        public void onRaiseException(int code, String msg) {
          Log.w(TAG, "Transaksi Sunmi melaporkan galat " + code + ": " + msg);
          mailbox.offer(OUTCOME_FAILED);
        }

        @Override
        public void onPrintResult(int code, String msg) {
          // Doc ICallback: 0 sukses, 1 gagal.
          if (code != 0) Log.w(TAG, "Transaksi Sunmi gagal " + code + ": " + msg);
          mailbox.offer(code == 0 ? OUTCOME_PRINTED : OUTCOME_FAILED);
        }
      });
    } catch (RemoteException | RuntimeException error) {
      Log.w(TAG, "exitPrinterBufferWithCallback gagal, commit tanpa callback", error);
      commitQuietly(service);
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
      Log.w(TAG, "onPrintResult tidak datang dalam " + TRANSACTION_RESULT_TIMEOUT_MILLIS
          + "ms -- anggap firmware tidak mendukung callback transaksi");
      transactionCallbackSupported = false;
      // Firmware yang diam-diam mengabaikan exitPrinterBufferWithCallback masih memegang isi
      // buffer; commit polos mencetaknya (no-op bila transaksi sebenarnya sudah selesai).
      commitQuietly(service);
      return OUTCOME_UNKNOWN;
    }
    transactionCallbackSupported = true;
    return outcome;
  }

  private void commitQuietly(IWoyouService service) {
    try {
      service.exitPrinterBuffer(true);
    } catch (RemoteException | RuntimeException error) {
      Log.w(TAG, "Gagal keluar mode buffer printer Sunmi", error);
    }
  }

  public void dispose() {
    unbindPrinterService();
    executor.shutdown();
  }
}

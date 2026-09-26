package id.kakzaki.blue_thermal_printer.vendor.xcheng;

import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.ServiceConnection;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.os.Binder;
import android.os.IBinder;
import android.os.Parcel;
import android.os.RemoteException;
import android.os.SystemClock;
import android.util.Log;

import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

/**
 * Jembatan ke antarmuka native servis printer bawaan Xcheng ({@code com.xcheng.printerservice},
 * AIDL {@code com.xcheng.printerservice.IPrinterService}) -- ALTERNATIF opsional untuk perangkat
 * Xcheng, bukan default. Servis yang sama juga mengekspos AIDL kompatibel Sunmi (dipakai
 * {@code SunmiPrinterBridge}), tapi di hardware Xcheng O1 (servis v1.1.12) jalur Sunmi itu
 * terbukti tidak pernah melaporkan kertas habis ({@code updatePrinterState()} selalu 1) dan tidak
 * pernah memanggil callback hasil cetak. Antarmuka native ini punya keduanya:
 * {@code printerPaper()} membaca sensor kertas, dan callback {@code onComplete()} dari
 * {@code printBitmap} hanya datang saat struk benar-benar tercetak.
 *
 * Xcheng tidak menerbitkan SDK/jar; integrasi resminya adalah file AIDL yang didistribusikan OEM
 * perangkat. Alih-alih menyalin AIDL-nya, bridge ini memanggil {@link IBinder#transact} langsung
 * dengan kode transaksi yang TERVERIFIKASI sama di dua sumber independen (bytecode servis di
 * perangkat O1 dan AIDL OEM Positivo L300): hanya kode 1-17 yang dipakai, karena setelah itu
 * urutan method berbeda antar varian firmware. Kalau urutan berubah di firmware lain, panggilan
 * gagal/mengembalikan nilai tak terduga dan backend jatuh ke "tidak diketahui", bukan crash.
 */
public class XchengPrinterBridge {

  private static final String TAG = "XchengPrinterBridge";
  private static final String SERVICE_PACKAGE = "com.xcheng.printerservice";
  private static final String SERVICE_ACTION = "com.xcheng.printerservice.IPrinterService";
  private static final String SERVICE_DESCRIPTOR = "com.xcheng.printerservice.IPrinterService";
  private static final String CALLBACK_DESCRIPTOR = "com.xcheng.printerservice.IPrinterCallback";

  // Kode transaksi IPrinterService (FIRST_CALL_TRANSACTION + urutan deklarasi).
  static final int TX_PRINT_WRAP_PAPER = 6;
  static final int TX_PRINT_BITMAP = 10;
  static final int TX_PRINTER_PAPER = 17;

  // Kode transaksi IPrinterCallback yang sama di semua varian yang diketahui. Kode 3 berbeda
  // antar firmware (onStart vs onRealLength) dan kode 2 (onLength) tidak dibutuhkan -- diabaikan.
  static final int CB_ON_EXCEPTION = 1;
  static final int CB_ON_COMPLETE = 4;

  public static final String OUTCOME_PRINTED = "printed";
  public static final String OUTCOME_FAILED = "failed";
  public static final String OUTCOME_UNKNOWN = "unknown";

  // onComplete datang ~60 ms setelah struk pendek tercetak; struk panjang butuh beberapa detik.
  // Tanpa kertas callback tidak pernah datang sama sekali -- lalu sensor kertas yang menentukan.
  private static final long PRINT_RESULT_TIMEOUT_MILLIS = 10_000;

  // Selama menunggu callback, sensor kertas dicek tiap interval ini. Kertas habis = callback
  // dipastikan tidak akan datang, jadi penantian dihentikan lebih awal tanpa menunggu timeout
  // penuh. Kertas ada / sensor tidak menjawab = tetap menunggu seperti biasa, supaya struk
  // panjang tetap mendapat konfirmasi onComplete.
  private static final long PAPER_POLL_INTERVAL_MILLIS = 500;

  private final Context context;
  private final ExecutorService executor = Executors.newSingleThreadExecutor();
  private volatile IBinder service;

  public XchengPrinterBridge(Context context) {
    this.context = context;
  }

  private final ServiceConnection connection = new ServiceConnection() {
    @Override
    public void onServiceConnected(ComponentName name, IBinder binder) {
      service = binder;
    }

    @Override
    public void onServiceDisconnected(ComponentName name) {
      service = null;
    }

    @Override
    public void onBindingDied(ComponentName name) {
      Log.w(TAG, "Binding servis printer Xcheng mati, bind ulang");
      unbindPrinterService();
      bindPrinterService();
    }

    @Override
    public void onNullBinding(ComponentName name) {
      service = null;
    }
  };

  /** Mulai bind. `true` = permintaan diterima sistem (tersambungnya async). `false` di perangkat
   * tanpa servis Xcheng. */
  public boolean bindPrinterService() {
    try {
      Intent intent = new Intent(SERVICE_ACTION);
      intent.setPackage(SERVICE_PACKAGE);
      return context.bindService(intent, connection, Context.BIND_AUTO_CREATE);
    } catch (Exception error) {
      Log.w(TAG, "Gagal memulai bind ke servis printer Xcheng", error);
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
    }
  }

  /** Sensor kertas: {@code true}/{@code false}, atau {@code null} bila servis belum tersambung
   * atau panggilan gagal (mis. firmware dengan urutan method berbeda). */
  public Boolean hasPaper() {
    IBinder binder = service;
    if (binder == null) return null;
    Parcel data = Parcel.obtain();
    Parcel reply = Parcel.obtain();
    try {
      data.writeInterfaceToken(SERVICE_DESCRIPTOR);
      data.writeStrongBinder(null);
      if (!binder.transact(TX_PRINTER_PAPER, data, reply, 0)) return null;
      reply.readException();
      return reply.readInt() != 0;
    } catch (RemoteException | RuntimeException error) {
      Log.w(TAG, "Query sensor kertas Xcheng gagal", error);
      return null;
    } finally {
      data.recycle();
      reply.recycle();
    }
  }

  public interface OutcomeCallback {
    void onOutcome(String outcome);
  }

  /** Cetak satu gambar (bytes PNG) lalu feed {@code feedLines} baris, di thread background.
   * {@code callback} dipanggil tepat sekali. */
  public void printBitmap(byte[] encodedImage, int feedLines, OutcomeCallback callback) {
    executor.execute(() -> callback.onOutcome(runPrint(encodedImage, feedLines)));
  }

  private String runPrint(byte[] encodedImage, int feedLines) {
    IBinder binder = service;
    if (binder == null) return OUTCOME_FAILED;
    Bitmap bitmap = BitmapFactory.decodeByteArray(encodedImage, 0, encodedImage.length);
    if (bitmap == null) return OUTCOME_FAILED;

    final ArrayBlockingQueue<String> mailbox = new ArrayBlockingQueue<>(1);
    Binder printCallback = new Binder() {
      @Override
      protected boolean onTransact(int code, Parcel data, Parcel reply, int flags)
          throws RemoteException {
        if (code == INTERFACE_TRANSACTION) {
          if (reply != null) reply.writeString(CALLBACK_DESCRIPTOR);
          return true;
        }
        if (code == CB_ON_COMPLETE) {
          mailbox.offer(OUTCOME_PRINTED);
          return true;
        }
        if (code == CB_ON_EXCEPTION) {
          data.enforceInterface(CALLBACK_DESCRIPTOR);
          int errorCode = data.readInt();
          String message = data.readString();
          Log.w(TAG, "Xcheng printBitmap melaporkan galat " + errorCode + ": " + message);
          mailbox.offer(OUTCOME_FAILED);
          return true;
        }
        // onLength / onStart / onRealLength: progres saja, tidak menentukan hasil.
        return code >= FIRST_CALL_TRANSACTION && code <= LAST_CALL_TRANSACTION;
      }
    };

    Parcel data = Parcel.obtain();
    Parcel reply = Parcel.obtain();
    try {
      data.writeInterfaceToken(SERVICE_DESCRIPTOR);
      data.writeInt(1); // bitmap != null
      bitmap.writeToParcel(data, 0);
      data.writeStrongBinder(printCallback);
      binder.transact(TX_PRINT_BITMAP, data, reply, 0);
      reply.readException();
    } catch (RemoteException | RuntimeException error) {
      Log.w(TAG, "Xcheng printBitmap gagal dikirim", error);
      return OUTCOME_UNKNOWN;
    } finally {
      data.recycle();
      reply.recycle();
    }

    String outcome = awaitOutcome(mailbox);
    if (outcome == null) return OUTCOME_UNKNOWN;
    if (OUTCOME_PRINTED.equals(outcome) && feedLines > 0) {
      feedQuietly(binder, feedLines);
    }
    return outcome;
  }

  /** Tunggu callback hasil cetak hingga {@link #PRINT_RESULT_TIMEOUT_MILLIS}; {@code null} bila
   * tidak ada callback atau sensor melaporkan kertas habis lebih dulu (pemanggil Dart lalu
   * membaca sensor lagi dan melaporkan "kertas habis"). */
  private String awaitOutcome(ArrayBlockingQueue<String> mailbox) {
    long deadline = SystemClock.elapsedRealtime() + PRINT_RESULT_TIMEOUT_MILLIS;
    try {
      while (true) {
        long remaining = deadline - SystemClock.elapsedRealtime();
        if (remaining <= 0) return null;
        String outcome = mailbox.poll(
            Math.min(remaining, PAPER_POLL_INTERVAL_MILLIS), TimeUnit.MILLISECONDS);
        if (outcome != null) return outcome;
        if (Boolean.FALSE.equals(hasPaper())) {
          // Callback yang datang tepat bersamaan tetap diutamakan.
          outcome = mailbox.poll();
          if (outcome == null) Log.i(TAG, "Kertas habis saat menunggu hasil cetak");
          return outcome;
        }
      }
    } catch (InterruptedException error) {
      Thread.currentThread().interrupt();
      return null;
    }
  }

  private void feedQuietly(IBinder binder, int lines) {
    Parcel data = Parcel.obtain();
    Parcel reply = Parcel.obtain();
    try {
      data.writeInterfaceToken(SERVICE_DESCRIPTOR);
      data.writeInt(lines);
      data.writeStrongBinder(null);
      binder.transact(TX_PRINT_WRAP_PAPER, data, reply, 0);
      reply.readException();
    } catch (RemoteException | RuntimeException error) {
      Log.w(TAG, "Feed kertas Xcheng gagal", error);
    } finally {
      data.recycle();
      reply.recycle();
    }
  }

  public void dispose() {
    unbindPrinterService();
    executor.shutdown();
  }
}

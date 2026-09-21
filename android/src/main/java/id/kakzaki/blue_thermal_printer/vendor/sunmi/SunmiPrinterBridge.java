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

import woyou.aidlservice.jiuiv5.ICallback;
import woyou.aidlservice.jiuiv5.IWoyouService;

/**
 * Jembatan ke servis printer bawaan Sunmi ("Woyou") lewat AIDL.
 *
 * Struktur bind/unbind dan sebagian besar method di sini diadaptasi dari
 * {@code SunmiPrinterMethod.java} milik paket pub.dev {@code sunmi_printer_plus}
 * (https://github.com/brasizza/sunmi_printer, BSD-3-Clause -- lihat
 * LICENSE-sunmi_printer_plus di folder ini), diringkas hanya untuk method yang
 * dipakai kontrak {@code PrinterBackend}: bind/unbind, query status
 * ({@link #updatePrinterState()}), dan cetak satu bitmap penuh
 * ({@link #printBitmap(byte[], Callback)}).
 *
 * Beda dari upstream: {@link ICallback} di sini diimplementasikan sungguhan
 * (bukan stub kosong) -- {@code onRunResult}/{@code onRaiseException}
 * menyelesaikan hasil lewat {@link ArrayBlockingQueue} satu slot, dengan
 * timeout fallback (pola sama seperti mailbox status ESC/POS di
 * {@code BlueThermalPrinterPlugin.ConnectedThread}), supaya panggilan AIDL
 * yang callback-nya tidak pernah dipanggil oleh firmware tertentu tidak
 * menggantung selamanya.
 */
public class SunmiPrinterBridge {

  private static final String TAG = "SunmiPrinterBridge";
  private static final String SERVICE_PACKAGE = "woyou.aidlservice.jiuiv5";
  private static final String SERVICE_ACTION = "woyou.aidlservice.jiuiv5.IWoyouService";

  /** Kode `updatePrinterState()` yang dipakai sebagai sentinel "servis belum
   * tersambung" -- sama seperti kode asli Sunmi untuk "printer tidak
   * terdeteksi", supaya pemanggil tidak perlu tahu ada dua sumber kode. */
  public static final int STATE_NOT_DETECTED = 505;

  // Cukup untuk satu panggilan AIDL lokal (bukan jaringan) merespons, tapi
  // tidak menahan pemanggil lama-lama kalau firmware tidak pernah memanggil
  // ICallback sama sekali.
  private static final long PRINT_CALLBACK_TIMEOUT_MILLIS = 3_000;

  private final Context context;
  private final ExecutorService executor = Executors.newSingleThreadExecutor();
  private IWoyouService woyouService;

  public SunmiPrinterBridge(Context context) {
    this.context = context;
  }

  private final ServiceConnection connection = new ServiceConnection() {
    @Override
    public void onServiceConnected(ComponentName name, IBinder binder) {
      woyouService = IWoyouService.Stub.asInterface(binder);
    }

    @Override
    public void onServiceDisconnected(ComponentName name) {
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
    if (woyouService == null) return STATE_NOT_DETECTED;
    try {
      return woyouService.updatePrinterState();
    } catch (RemoteException error) {
      Log.w(TAG, "Query status printer Sunmi gagal", error);
      return STATE_NOT_DETECTED;
    }
  }

  public interface Callback {
    void onResult(boolean success);
  }

  /** Cetak satu gambar penuh (bytes gambar biasa, mis. PNG -- didekode lewat
   * {@link BitmapFactory}, bukan raw pixel). */
  public void printBitmap(byte[] encodedImage, Callback callback) {
    if (woyouService == null) {
      callback.onResult(false);
      return;
    }
    final Bitmap bitmap = BitmapFactory.decodeByteArray(encodedImage, 0, encodedImage.length);
    if (bitmap == null) {
      callback.onResult(false);
      return;
    }

    final ArrayBlockingQueue<Boolean> mailbox = new ArrayBlockingQueue<>(1);
    try {
      woyouService.printBitmap(bitmap, new ICallback.Stub() {
        @Override
        public void onRunResult(boolean isSuccess) {
          mailbox.offer(isSuccess);
        }

        @Override
        public void onReturnString(String result) {
          // Tidak relevan untuk printBitmap.
        }

        @Override
        public void onRaiseException(int code, String msg) {
          Log.w(TAG, "Sunmi printBitmap melaporkan galat " + code + ": " + msg);
          mailbox.offer(false);
        }

        @Override
        public void onPrintResult(int code, String msg) {
          // Hanya relevan untuk alur transaksi buffer (commitPrinterBufferWithCallback),
          // tidak dipakai printBitmap polos -- sengaja diabaikan.
        }
      });
    } catch (RemoteException error) {
      callback.onResult(false);
      return;
    }

    executor.execute(() -> {
      Boolean result;
      try {
        result = mailbox.poll(PRINT_CALLBACK_TIMEOUT_MILLIS, java.util.concurrent.TimeUnit.MILLISECONDS);
      } catch (InterruptedException error) {
        Thread.currentThread().interrupt();
        result = null;
      }
      // Timeout (result == null) berarti firmware tidak memanggil ICallback
      // sama sekali -- optimis anggap panggilan AIDL-nya sendiri berhasil
      // terkirim (sama seperti upstream), karena kondisi fisik sungguhan
      // tetap diverifikasi ulang lewat updatePrinterState() setelah ini oleh
      // pemanggil (lihat PrinterBackendSunmi.printReceipt).
      callback.onResult(result == null || result);
    });
  }

  public void dispose() {
    unbindPrinterService();
    executor.shutdown();
  }
}

package id.kakzaki.blue_thermal_printer.vendor.ciontek;

import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Rect;
import android.os.IBinder;
import android.os.RemoteException;
import android.util.Log;

import com.ciontek.ciontekposservice.ICiontekPosService;

import java.lang.reflect.Method;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.locks.ReentrantLock;

/**
 * Jembatan ke printer bawaan perangkat Ciontek (CS30 dan sejenisnya) lewat AIDL resmi
 * {@code com.ciontek.ciontekposservice.ICiontekPosService} (system service {@code "posmanager"}, file
 * AIDL disalin dari SDK resmi CS30Pro v1.0.2). Servis meneruskan perintah ke modul printer internal;
 * bukan Bluetooth/USB.
 *
 * <p>Sengaja tidak memakai {@code PosApiHelper} resmi: singleton, menelan {@link RemoteException}
 * menjadi -5555, dan ikut mengekspos API sensitif (install ROM, tulis SN, daftar putih aplikasi).
 * Cara mengambil servisnya sama dengan {@code PosApiHelper}: refleksi
 * {@code ServiceManager.getService("posmanager")}.
 *
 * <p>Satu pekerjaan cetak = {@code Lib_PrnInit} → {@code Lib_PrnBmp} per strip → {@code Lib_PrnStep}
 * → {@code Lib_PrnStart}. {@code Lib_PrnStart} sinkron dan kembali setelah selesai mencetak, jadi
 * kodenya adalah hasil cetak. Query status dan cetak berbagi {@link #hardwareLock}: query yang datang
 * selama mencetak menjawab {@code null} (tidak diketahui) alih-alih menyela modul printer -- panduan
 * resmi melarang proses cetak diganggu.
 */
public class CiontekPrinterBridge {

  private static final String TAG = "CiontekPrinterBridge";
  private static final String SERVICE_NAME = "posmanager";
  private static final String SERVICE_DESCRIPTOR = "com.ciontek.ciontekposservice.ICiontekPosService";

  /** Lebar maksimum bitmap {@code Lib_PrnBmp} (dokumentasi resmi): 384 dot = 58 mm. */
  static final int MAX_BITMAP_WIDTH = 384;

  /** Tinggi strip per {@code Lib_PrnBmp}, di bawah batas resmi 500 px. */
  static final int STRIP_HEIGHT_PX = 480;

  private final ExecutorService printExecutor = Executors.newSingleThreadExecutor();
  private final ReentrantLock hardwareLock = new ReentrantLock();
  private final Object bindLock = new Object();

  // Ditulis di bawah bindLock, dibaca tanpa lock (isReady dipanggil dari main thread dan tidak
  // boleh menunggu bind yang sedang melakukan IPC).
  private volatile ICiontekPosService service;
  private volatile IBinder binder;

  private final IBinder.DeathRecipient deathRecipient = () -> {
    Log.w(TAG, "Servis posmanager mati");
    synchronized (bindLock) {
      service = null;
      binder = null;
    }
  };

  /**
   * Ambil servis {@code posmanager}. {@code true} bila servis ada DAN descriptor-nya cocok dengan
   * AIDL Ciontek (perangkat lain dengan nama servis sama tidak salah terdeteksi). Melakukan IPC --
   * jangan dipanggil dari main thread.
   */
  public boolean bind() {
    synchronized (bindLock) {
      if (service != null && binder != null && binder.isBinderAlive()) return true;
      try {
        Class<?> serviceManager = Class.forName("android.os.ServiceManager");
        Method getService = serviceManager.getMethod("getService", String.class);
        IBinder candidate = (IBinder) getService.invoke(null, SERVICE_NAME);
        if (candidate == null) return false;
        if (!SERVICE_DESCRIPTOR.equals(candidate.getInterfaceDescriptor())) {
          Log.w(TAG, "Servis posmanager bukan antarmuka Ciontek: " + candidate.getInterfaceDescriptor());
          return false;
        }
        candidate.linkToDeath(deathRecipient, 0);
        binder = candidate;
        service = ICiontekPosService.Stub.asInterface(candidate);
        return true;
      } catch (Exception error) {
        // Perangkat non-Ciontek, refleksi ditolak (hidden API), atau servis mati saat diperiksa.
        Log.i(TAG, "Servis printer Ciontek tidak tersedia: " + error);
        return false;
      }
    }
  }

  public void unbind() {
    synchronized (bindLock) {
      if (binder != null) {
        try {
          binder.unlinkToDeath(deathRecipient, 0);
        } catch (RuntimeException ignored) {
          // Sudah tidak tertaut (servis mati) -- aman diabaikan.
        }
      }
      binder = null;
      service = null;
    }
  }

  /** Servis terambil dan proses servisnya masih hidup. Tanpa IPC. */
  public boolean isReady() {
    IBinder current = binder;
    return service != null && current != null && current.isBinderAlive();
  }

  /**
   * Kode {@code Lib_PrnCheckStatus} (0 normal, -1 kertas habis, -2 suhu tinggi, -3 tegangan rendah),
   * atau {@code null} bila servis belum terambil, panggilan gagal, atau printer sedang mencetak.
   */
  public Integer status() {
    ICiontekPosService current = service;
    if (current == null) return null;
    if (!hardwareLock.tryLock()) return null;
    try {
      return current.Lib_PrnCheckStatus();
    } catch (RemoteException | RuntimeException error) {
      Log.w(TAG, "Query status printer Ciontek gagal", error);
      return null;
    } finally {
      hardwareLock.unlock();
    }
  }

  public interface OutcomeCallback {
    void onOutcome(String outcome);
  }

  /**
   * Cetak satu gambar (bytes PNG, lebar ≤ {@link #MAX_BITMAP_WIDTH}) lalu feed {@code feedPixels} dot,
   * di thread background. {@code callback} dipanggil tepat sekali.
   */
  public void printBitmap(byte[] encodedImage, int feedPixels, OutcomeCallback callback) {
    printExecutor.execute(() -> {
      String outcome;
      hardwareLock.lock();
      try {
        outcome = runPrint(encodedImage, feedPixels);
      } catch (RuntimeException error) {
        Log.w(TAG, "Cetak Ciontek gagal tak terduga", error);
        outcome = CiontekResultCodes.OUTCOME_UNKNOWN;
      } finally {
        hardwareLock.unlock();
      }
      callback.onOutcome(outcome);
    });
  }

  private String runPrint(byte[] encodedImage, int feedPixels) {
    ICiontekPosService current = service;
    if (current == null) return CiontekResultCodes.OUTCOME_FAILED;
    Bitmap source = BitmapFactory.decodeByteArray(encodedImage, 0, encodedImage.length);
    if (source == null) return CiontekResultCodes.OUTCOME_FAILED;
    try {
      if (source.getWidth() > MAX_BITMAP_WIDTH) {
        Log.w(TAG, "Bitmap " + source.getWidth() + " px melebihi lebar printer " + MAX_BITMAP_WIDTH);
        return CiontekResultCodes.OUTCOME_FAILED;
      }
      int ret = current.Lib_PrnInit();
      if (ret != 0) {
        Log.w(TAG, "Lib_PrnInit gagal, kode " + ret);
        return CiontekResultCodes.OUTCOME_FAILED;
      }
      for (int[] strip : CiontekResultCodes.strips(source.getHeight(), STRIP_HEIGHT_PX)) {
        ret = sendStrip(current, source, strip[0], strip[1]);
        if (ret == CiontekResultCodes.PRN_BUFFER_OVERFLOW) {
          // Buffer servis penuh: cetak isi buffer sejauh ini, lalu lanjutkan sisa struk. Kertas
          // tidak di-feed di antaranya, jadi struk tetap menyambung.
          Log.i(TAG, "Buffer printer penuh, cetak bertahap");
          ret = current.Lib_PrnStart();
          if (ret != 0) {
            Log.w(TAG, "Lib_PrnStart (bertahap) kode " + ret);
            return CiontekResultCodes.startOutcome(ret);
          }
          ret = current.Lib_PrnInit();
          if (ret == 0) ret = sendStrip(current, source, strip[0], strip[1]);
        }
        if (ret != 0) {
          Log.w(TAG, "Lib_PrnBmp gagal, kode " + ret);
          return CiontekResultCodes.OUTCOME_FAILED;
        }
      }
      if (feedPixels > 0) {
        int feed = current.Lib_PrnStep(feedPixels);
        if (feed != 0) Log.w(TAG, "Lib_PrnStep kode " + feed);
      }
      ret = current.Lib_PrnStart();
      if (ret != 0) Log.w(TAG, "Lib_PrnStart kode " + ret);
      return CiontekResultCodes.startOutcome(ret);
    } catch (RemoteException error) {
      Log.w(TAG, "Servis printer Ciontek tidak menjawab saat mencetak", error);
      return CiontekResultCodes.OUTCOME_UNKNOWN;
    } finally {
      source.recycle();
    }
  }

  /** Kirim satu strip, dikomposit ke latar putih (piksel transparan jangan tercetak hitam). */
  private static int sendStrip(ICiontekPosService current, Bitmap source, int top, int height)
      throws RemoteException {
    Bitmap strip = Bitmap.createBitmap(source.getWidth(), height, Bitmap.Config.ARGB_8888);
    try {
      Canvas canvas = new Canvas(strip);
      canvas.drawColor(Color.WHITE);
      canvas.drawBitmap(source, new Rect(0, top, source.getWidth(), top + height),
          new Rect(0, 0, source.getWidth(), height), null);
      return current.Lib_PrnBmp(strip);
    } finally {
      strip.recycle();
    }
  }

  public void dispose() {
    unbind();
    printExecutor.shutdown();
  }
}

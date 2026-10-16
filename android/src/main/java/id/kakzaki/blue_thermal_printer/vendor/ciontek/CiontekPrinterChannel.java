package id.kakzaki.blue_thermal_printer.vendor.ciontek;

import android.os.Handler;
import android.os.Looper;

import androidx.annotation.NonNull;

import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.RejectedExecutionException;

import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.MethodChannel.MethodCallHandler;
import io.flutter.plugin.common.MethodChannel.Result;

/**
 * Method channel terisolasi untuk printer bawaan Ciontek ("blue_thermal_printer/ciontek"),
 * terpisah dari channel ESC/POS dan vendor lain.
 */
public class CiontekPrinterChannel implements MethodCallHandler {

  private static final String CHANNEL_NAME = "blue_thermal_printer/ciontek";

  private final CiontekPrinterBridge bridge = new CiontekPrinterBridge();
  private final MethodChannel channel;
  private final Handler mainHandler = new Handler(Looper.getMainLooper());
  private final ExecutorService queryExecutor = Executors.newSingleThreadExecutor();

  public CiontekPrinterChannel(BinaryMessenger messenger) {
    channel = new MethodChannel(messenger, CHANNEL_NAME);
    channel.setMethodCallHandler(this);
  }

  @Override
  public void onMethodCall(@NonNull MethodCall call, @NonNull Result result) {
    switch (call.method) {
      case "bind":
        // Berbeda dari vendor berbasis bindService: mengambil servis + memeriksa descriptor-nya
        // adalah IPC sinkron, jadi ikut dijalankan di luar main thread.
        runQuery(result, bridge::bind);
        break;

      case "unbind":
        bridge.unbind();
        result.success(null);
        break;

      case "isReady":
        result.success(bridge.isReady());
        break;

      case "status":
        runQuery(result, bridge::status);
        break;

      case "printBitmap":
        byte[] bytes = call.argument("bytes");
        Integer feedPixels = call.argument("feedPixels");
        if (bytes == null) {
          result.error("invalid_argument", "argument 'bytes' not found", null);
          break;
        }
        bridge.printBitmap(bytes, feedPixels == null ? 0 : feedPixels,
            outcome -> mainHandler.post(() -> result.success(outcome)));
        break;

      default:
        result.notImplemented();
    }
  }

  public void dispose() {
    channel.setMethodCallHandler(null);
    queryExecutor.shutdown();
    bridge.dispose();
  }

  /** Panggilan yang melakukan binder IPC sinkron. */
  private interface Query {
    Object run();
  }

  /** Jalankan {@code query} di {@link #queryExecutor}, lalu kirim hasilnya lewat main thread (syarat
   * {@link Result}). Dart di Android berjalan di main thread (merged platform/UI thread), jadi IPC
   * langsung di {@link #onMethodCall} ikut membekukan UI. Executor ini terpisah dari executor cetak
   * bridge, yang tertahan selama {@code Lib_PrnStart} mencetak. */
  private void runQuery(Result result, Query query) {
    try {
      queryExecutor.execute(() -> {
        Object value = query.run();
        mainHandler.post(() -> result.success(value));
      });
    } catch (RejectedExecutionException error) {
      // Channel sudah di-dispose.
      result.error("disposed", "printer channel disposed", null);
    }
  }
}

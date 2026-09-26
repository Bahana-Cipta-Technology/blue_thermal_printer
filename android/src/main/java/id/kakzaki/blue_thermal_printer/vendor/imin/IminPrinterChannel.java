package id.kakzaki.blue_thermal_printer.vendor.imin;

import android.content.Context;
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
 * Method channel terisolasi untuk backend printer bawaan iMin ("blue_thermal_printer/imin"),
 * terpisah dari channel ESC/POS, Sunmi, dan Xcheng.
 */
public class IminPrinterChannel implements MethodCallHandler {

  private static final String CHANNEL_NAME = "blue_thermal_printer/imin";

  private final IminPrinterBridge bridge;
  private final MethodChannel channel;
  private final Handler mainHandler = new Handler(Looper.getMainLooper());
  private final ExecutorService queryExecutor = Executors.newSingleThreadExecutor();

  public IminPrinterChannel(Context context, BinaryMessenger messenger) {
    bridge = new IminPrinterBridge(context.getApplicationContext());
    channel = new MethodChannel(messenger, CHANNEL_NAME);
    channel.setMethodCallHandler(this);
  }

  @Override
  public void onMethodCall(@NonNull MethodCall call, @NonNull Result result) {
    switch (call.method) {
      case "bind":
        result.success(bridge.bindPrinterService());
        break;

      case "unbind":
        bridge.unbindPrinterService();
        result.success(null);
        break;

      case "status":
        runQuery(result, bridge::status);
        break;

      case "paperType":
        runQuery(result, bridge::paperType);
        break;

      case "printResultVerified":
        result.success(IminPrinterBridge.PRINT_RESULT_CODE_VERIFIED);
        break;

      case "printTransaction":
        byte[] bytes = call.argument("bytes");
        Integer feedDistance = call.argument("feedDistance");
        Boolean cut = call.argument("cut");
        if (bytes == null) {
          result.error("invalid_argument", "argument 'bytes' not found", null);
          break;
        }
        bridge.printTransaction(bytes, feedDistance == null ? 0 : feedDistance,
            Boolean.TRUE.equals(cut),
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

  /** Query status yang memanggil binder IPC sinkron. */
  private interface Query {
    Object run();
  }

  /** Jalankan {@code query} di {@link #queryExecutor}, lalu kirim hasilnya lewat main thread (syarat
   * {@link Result}). Sejak Flutter 3.29, Dart di Android berjalan di main thread yang sama
   * (merged platform/UI thread), jadi binder transact langsung di {@link #onMethodCall} ikut
   * membekukan UI selama servis printer lambat menjawab (mis. sibuk menahan data saat kertas
   * habis). Executor ini terpisah dari executor cetak di bridge, karena executor cetak bisa
   * tertahan belasan detik menunggu callback hasil cetak. */
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

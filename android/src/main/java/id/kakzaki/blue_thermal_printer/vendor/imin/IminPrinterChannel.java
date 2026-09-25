package id.kakzaki.blue_thermal_printer.vendor.imin;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;

import androidx.annotation.NonNull;

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
        result.success(bridge.status());
        break;

      case "paperType":
        result.success(bridge.paperType());
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
    bridge.dispose();
  }
}

package id.kakzaki.blue_thermal_printer.vendor.sunmi;

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
 * Method channel terisolasi untuk backend printer bawaan Sunmi, terpisah dari
 * channel ESC/POS ("blue_thermal_printer/methods") yang sudah ada di
 * {@link id.kakzaki.blue_thermal_printer.BlueThermalPrinterPlugin} -- supaya
 * kode dua vendor tidak saling campur dan bisa dites/dimatikan terpisah.
 */
public class SunmiPrinterChannel implements MethodCallHandler {

  private static final String CHANNEL_NAME = "blue_thermal_printer/sunmi";

  private final SunmiPrinterBridge bridge;
  private final MethodChannel channel;
  private final Handler mainHandler = new Handler(Looper.getMainLooper());

  public SunmiPrinterChannel(Context context, BinaryMessenger messenger) {
    bridge = new SunmiPrinterBridge(context.getApplicationContext());
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

      case "updateState":
        result.success(bridge.updatePrinterState());
        break;

      case "printBitmap":
        byte[] bytes = call.argument("bytes");
        if (bytes == null) {
          result.error("invalid_argument", "argument 'bytes' not found", null);
          break;
        }
        bridge.printBitmap(bytes, success -> mainHandler.post(() -> result.success(success)));
        break;

      case "enterBuffer":
        Boolean clean = call.argument("clean");
        result.success(bridge.enterPrinterBuffer(Boolean.TRUE.equals(clean)));
        break;

      case "exitBuffer":
        Boolean commit = call.argument("commit");
        result.success(bridge.exitPrinterBuffer(Boolean.TRUE.equals(commit)));
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

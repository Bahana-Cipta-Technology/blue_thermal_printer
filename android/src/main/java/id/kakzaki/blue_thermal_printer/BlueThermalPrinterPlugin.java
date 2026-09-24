package id.kakzaki.blue_thermal_printer;

import android.Manifest;
import android.app.Activity;
import android.app.Application;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothManager;
import android.bluetooth.BluetoothSocket;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.PackageManager;

import androidx.annotation.NonNull;
import androidx.core.app.ActivityCompat;
import androidx.core.content.ContextCompat;

import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.os.Build;
import android.util.Log;
import android.os.AsyncTask;
import android.os.Handler;
import android.os.Looper;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.PrintWriter;
import java.io.StringWriter;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.EventChannel.StreamHandler;
import io.flutter.plugin.common.EventChannel.EventSink;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.MethodChannel.MethodCallHandler;
import io.flutter.plugin.common.MethodChannel.Result;
import io.flutter.plugin.common.PluginRegistry.RequestPermissionsResultListener;

import com.google.zxing.BarcodeFormat;
import com.google.zxing.MultiFormatWriter;
import com.google.zxing.common.BitMatrix;
import com.journeyapps.barcodescanner.BarcodeEncoder;

import id.kakzaki.blue_thermal_printer.vendor.sunmi.SunmiPrinterChannel;
import id.kakzaki.blue_thermal_printer.vendor.xcheng.XchengPrinterChannel;

public class BlueThermalPrinterPlugin implements FlutterPlugin, ActivityAware, MethodCallHandler, RequestPermissionsResultListener {

  private static final String TAG = "BThermalPrinterPlugin";
  private static final String NAMESPACE = "blue_thermal_printer";
  private static final int REQUEST_COARSE_LOCATION_PERMISSIONS = 1451;
  private static final UUID MY_UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB");
  // Batas waktu tunggu socket.connect() sebelum dianggap gagal -- cukup untuk radio BT merespons
  // tapi tidak bikin user menunggu terlalu lama kalau device tidak terjangkau.
  private static final int CONNECT_TIMEOUT_MILLIS = 12_000;
  // Batas waktu tunggu satu byte respons query status real-time ESC/POS (DLE EOT n) --
  // cukup untuk printer yang mendukungnya merespons, tapi tidak menahan pemanggil lama-lama
  // kalau printer (mis. clone murah) sama sekali tidak mengimplementasikan query ini.
  private static final long STATUS_QUERY_TIMEOUT_MILLIS = 1_500;
  // Koneksi aktif (satu per proses, sengaja static seperti sebelumnya). Dibersihkan sendiri oleh
  // ConnectedThread.run() begitu socket mati -- tidak lagi bergantung pada BroadcastReceiver
  // state, yang hanya terdaftar kalau ada yang listen onStateChanged().
  private static final AtomicReference<ConnectedThread> connectedThreadRef = new AtomicReference<>();
  // Mencegah dua percobaan connect paralel membuka dua socket (yang satu bocor).
  private static final AtomicBoolean connecting = new AtomicBoolean(false);
  // Semua operasi tulis ke printer dijalankan serial di sini, bukan di platform thread: raster
  // struk puluhan KB lewat SPP bisa memblokir berdetik-detik (risiko ANR).
  private static final ExecutorService writeExecutor = Executors.newSingleThreadExecutor();

  private BluetoothAdapter mBluetoothAdapter;

  private Result pendingResult;

  private final Handler mainHandler = new Handler(Looper.getMainLooper());
  private volatile EventSink readSink;
  private volatile EventSink statusSink;

  private FlutterPluginBinding pluginBinding;
  private ActivityPluginBinding activityBinding;
  private final Object initializationLock = new Object();
  private Context context;
  private MethodChannel channel;

  private EventChannel stateChannel;
  private BluetoothManager mBluetoothManager;

  private Activity activity;

  // Vendor Sunmi (printer bawaan, lewat AIDL) -- terisolasi di package
  // `vendor.sunmi`, channel method sendiri ("blue_thermal_printer/sunmi"),
  // sama sekali tidak menyentuh switch/logic ESC/POS di atas. Tidak butuh
  // Activity (bind AIDL cukup lewat Application context), jadi disiapkan di
  // sini, bukan di setup()/detach() yang terikat siklus hidup Activity.
  private SunmiPrinterChannel sunmiPrinterChannel;
  // Vendor Xcheng (antarmuka native servis printer bawaan Xcheng) -- alternatif opsional untuk
  // perangkat Xcheng, terisolasi di `vendor.xcheng`, channel "blue_thermal_printer/xcheng".
  private XchengPrinterChannel xchengPrinterChannel;

  public BlueThermalPrinterPlugin() {
  }

  @Override
  public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
    pluginBinding = binding;
    sunmiPrinterChannel = new SunmiPrinterChannel(binding.getApplicationContext(), binding.getBinaryMessenger());
    xchengPrinterChannel = new XchengPrinterChannel(binding.getApplicationContext(), binding.getBinaryMessenger());
  }

  @Override
  public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
    pluginBinding = null;
    sunmiPrinterChannel.dispose();
    sunmiPrinterChannel = null;
    xchengPrinterChannel.dispose();
    xchengPrinterChannel = null;
  }

  @Override
  public void onAttachedToActivity(@NonNull ActivityPluginBinding binding) {
    activityBinding = binding;
    setup(
            pluginBinding.getBinaryMessenger(),
            (Application) pluginBinding.getApplicationContext(),
            activityBinding.getActivity(),
            activityBinding);
  }

  @Override
  public void onDetachedFromActivityForConfigChanges() {
    onDetachedFromActivity();
  }

  @Override
  public void onReattachedToActivityForConfigChanges(@NonNull ActivityPluginBinding binding) {
    onAttachedToActivity(binding);
  }

  @Override
  public void onDetachedFromActivity() {
    detach();
  }

  private void setup(
          final BinaryMessenger messenger,
          final Application application,
          final Activity activity,
          final ActivityPluginBinding activityBinding) {
    synchronized (initializationLock) {
      Log.i(TAG, "setup");
      this.activity = activity;
      this.context = application;
      channel = new MethodChannel(messenger, NAMESPACE + "/methods");
      channel.setMethodCallHandler(this);
      stateChannel = new EventChannel(messenger, NAMESPACE + "/state");
      stateChannel.setStreamHandler(stateStreamHandler);
      EventChannel readChannel = new EventChannel(messenger, NAMESPACE + "/read");
      readChannel.setStreamHandler(readResultsHandler);
      mBluetoothManager = (BluetoothManager) application.getSystemService(Context.BLUETOOTH_SERVICE);
      mBluetoothAdapter = mBluetoothManager.getAdapter();
      activityBinding.addRequestPermissionsResultListener(this);
    }
  }


  private void detach() {
    Log.i(TAG, "detach");
    context = null;
    activityBinding.removeRequestPermissionsResultListener(this);
    activityBinding = null;
    channel.setMethodCallHandler(null);
    channel = null;
    stateChannel.setStreamHandler(null);
    stateChannel = null;
    mBluetoothAdapter = null;
    mBluetoothManager = null;
  }

  // MethodChannel.Result wrapper that responds on the platform thread.
  private static class MethodResultWrapper implements Result {
    private final Result methodResult;
    private final Handler handler;

    MethodResultWrapper(Result result) {
      methodResult = result;
      handler = new Handler(Looper.getMainLooper());
    }

    @Override
    public void success(final Object result) {
      handler.post(() -> methodResult.success(result));
    }

    @Override
    public void error(@NonNull final String errorCode, final String errorMessage, final Object errorDetails) {
      handler.post(() -> methodResult.error(errorCode, errorMessage, errorDetails));
    }

    @Override
    public void notImplemented() {
      handler.post(methodResult::notImplemented);
    }
  }

  @Override
  public void onMethodCall(@NonNull MethodCall call, @NonNull Result rawResult) {
    Result result = new MethodResultWrapper(rawResult);

    if (mBluetoothAdapter == null && !"isAvailable".equals(call.method)) {
      result.error("bluetooth_unavailable", "the device does not have bluetooth", null);
      return;
    }

    final Map<String, Object> arguments = call.arguments();
    switch (call.method) {

      case "state":
        state(result);
        break;

      case "isAvailable":
        result.success(mBluetoothAdapter != null);
        break;

      case "isOn":
        try {
          result.success(mBluetoothAdapter.isEnabled());
        } catch (Exception ex) {
          result.error("Error", ex.getMessage(), exceptionToString(ex));
        }
        break;

      case "isConnected":
        result.success(activeConnection() != null);
        break;

      case "isDeviceConnected":
        if (arguments.containsKey("address")) {
          String address = (String) arguments.get("address");
          isDeviceConnected(result, address);
        } else {
          result.error("invalid_argument", "argument 'address' not found", null);
        }
        break;

      case "openSettings":
        ContextCompat.startActivity(context, new Intent(android.provider.Settings.ACTION_BLUETOOTH_SETTINGS),
                null);
        result.success(true);
        break;

      case "isPermissionBluetoothGranted":
        result.success(hasRequiredBluetoothPermissions());
        break;

      case "getBondedDevices":
        try {

          if(Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {

            if (!hasRequiredBluetoothPermissions()) {

              ActivityCompat.requestPermissions(activity,new String[]{
                      Manifest.permission.BLUETOOTH_SCAN,
                      Manifest.permission.BLUETOOTH_CONNECT,
                      Manifest.permission.ACCESS_FINE_LOCATION,
              }, REQUEST_COARSE_LOCATION_PERMISSIONS);

              pendingResult = result;
              break;
            }
          } else {
            if (!hasRequiredBluetoothPermissions()) {

              ActivityCompat.requestPermissions(activity,
                      new String[] { Manifest.permission.ACCESS_COARSE_LOCATION,Manifest.permission.ACCESS_FINE_LOCATION }, REQUEST_COARSE_LOCATION_PERMISSIONS);

              pendingResult = result;
              break;
            }
          }
          getBondedDevices(result);

        } catch (Exception ex) {
          result.error("Error", ex.getMessage(), exceptionToString(ex));
        }

        break;

      case "connect":
        if (arguments.containsKey("address")) {
          String address = (String) arguments.get("address");
          connect(result, address);
        } else {
          result.error("invalid_argument", "argument 'address' not found", null);
        }
        break;

      case "disconnect":
        disconnect(result);
        break;

      case "write":
        if (arguments.containsKey("message")) {
          String message = (String) arguments.get("message");
          writeExecutor.execute(() -> write(result, message));
        } else {
          result.error("invalid_argument", "argument 'message' not found", null);
        }
        break;

      case "writeBytes":
        if (arguments.containsKey("message")) {
          byte[] message = (byte[]) arguments.get("message");
          writeExecutor.execute(() -> writeBytes(result, message));
        } else {
          result.error("invalid_argument", "argument 'message' not found", null);
        }
        break;

      case "queryPrinterStatus":
        if (arguments.containsKey("type")) {
          int statusType = (int) arguments.get("type");
          queryPrinterStatus(result, statusType);
        } else {
          result.error("invalid_argument", "argument 'type' not found", null);
        }
        break;

      case "printCustom":
        if (arguments.containsKey("message")) {
          String message = (String) arguments.get("message");
          int size = (int) arguments.get("size");
          int align = (int) arguments.get("align");
          String charset = (String) arguments.get("charset");
          writeExecutor.execute(() -> printCustom(result, message, size, align, charset));
        } else {
          result.error("invalid_argument", "argument 'message' not found", null);
        }
        break;

      case "printNewLine":
        writeExecutor.execute(() -> printNewLine(result));
        break;

      case "paperCut":
        writeExecutor.execute(() -> paperCut(result));
        break;

      case "drawerPin2":
        writeExecutor.execute(() -> drawerPin2(result));
        break;

      case "drawerPin5":
        writeExecutor.execute(() -> drawerPin5(result));
        break;

      case "printImage":
        if (arguments.containsKey("pathImage")) {
          String pathImage = (String) arguments.get("pathImage");
          writeExecutor.execute(() -> printImage(result, pathImage));
        } else {
          result.error("invalid_argument", "argument 'pathImage' not found", null);
        }
        break;

        case "printImageBytes":
        if (arguments.containsKey("bytes")) {
          byte[] bytes = (byte[]) arguments.get("bytes");
          writeExecutor.execute(() -> printImageBytes(result, bytes));
        } else {
          result.error("invalid_argument", "argument 'bytes' not found", null);
        }
        break;

      case "printQRcode":
        if (arguments.containsKey("textToQR")) {
          String textToQR = (String) arguments.get("textToQR");
          int width = (int) arguments.get("width");
          int height = (int) arguments.get("height");
          int align = (int) arguments.get("align");
          writeExecutor.execute(() -> printQRcode(result, textToQR, width, height, align));
        } else {
          result.error("invalid_argument", "argument 'textToQR' not found", null);
        }
        break;
      case "printLeftRight":
        if (arguments.containsKey("string1")) {
          String string1 = (String) arguments.get("string1");
          String string2 = (String) arguments.get("string2");
          int size = (int) arguments.get("size");
          String charset = (String) arguments.get("charset");
          String format = (String) arguments.get("format");
          writeExecutor.execute(() -> printLeftRight(result, string1, string2, size, charset,format));
        } else {
          result.error("invalid_argument", "argument 'message' not found", null);
        }
        break;
      case "print3Column":
        if (arguments.containsKey("string1")) {
          String string1 = (String) arguments.get("string1");
          String string2 = (String) arguments.get("string2");
          String string3 = (String) arguments.get("string3");
          int size = (int) arguments.get("size");
          String charset = (String) arguments.get("charset");
          String format = (String) arguments.get("format");
          writeExecutor.execute(() -> print3Column(result, string1, string2,string3, size, charset,format));
        } else {
          result.error("invalid_argument", "argument 'message' not found", null);
        }
        break;
      case "print4Column":
        if (arguments.containsKey("string1")) {
          String string1 = (String) arguments.get("string1");
          String string2 = (String) arguments.get("string2");
          String string3 = (String) arguments.get("string3");
          String string4 = (String) arguments.get("string4");
          int size = (int) arguments.get("size");
          String charset = (String) arguments.get("charset");
          String format = (String) arguments.get("format");
          writeExecutor.execute(() -> print4Column(result, string1, string2,string3,string4, size, charset,format));
        } else {
          result.error("invalid_argument", "argument 'message' not found", null);
        }
        break;
      default:
        result.notImplemented();
        break;
    }
  }

  /**
   * @param requestCode  requestCode
   * @param permissions  permissions
   * @param grantResults grantResults
   * @return boolean
   */
  @Override
  public boolean onRequestPermissionsResult(int requestCode, @NonNull String[] permissions, @NonNull int[] grantResults) {

    if (requestCode == REQUEST_COARSE_LOCATION_PERMISSIONS) {
      boolean allGranted = grantResults.length > 0;
      for (int grantResult : grantResults) {
        if (grantResult != PackageManager.PERMISSION_GRANTED) {
          allGranted = false;
          break;
        }
      }
      if (allGranted) {
        getBondedDevices(pendingResult);
      } else {
        pendingResult.error("no_permissions", "this plugin requires location permissions for scanning", null);
      }
      pendingResult = null;
      return true;
    }
    return false;
  }

  /**
   * @return boolean apakah izin Bluetooth yang dibutuhkan sudah diberikan,
   * tanpa memicu dialog permintaan izin.
   */
  private boolean hasRequiredBluetoothPermissions() {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
      return ContextCompat.checkSelfPermission(activity, Manifest.permission.BLUETOOTH_SCAN)
              == PackageManager.PERMISSION_GRANTED
          && ContextCompat.checkSelfPermission(activity, Manifest.permission.BLUETOOTH_CONNECT)
              == PackageManager.PERMISSION_GRANTED
          && ContextCompat.checkSelfPermission(activity, Manifest.permission.ACCESS_FINE_LOCATION)
              == PackageManager.PERMISSION_GRANTED;
    }
    return ContextCompat.checkSelfPermission(activity, Manifest.permission.ACCESS_COARSE_LOCATION)
            == PackageManager.PERMISSION_GRANTED
        && ContextCompat.checkSelfPermission(activity, Manifest.permission.ACCESS_FINE_LOCATION)
            == PackageManager.PERMISSION_GRANTED;
  }

  private void state(Result result) {
    try {
      switch (mBluetoothAdapter.getState()) {
        case BluetoothAdapter.STATE_OFF:
          result.success(BluetoothAdapter.STATE_OFF);
          break;
        case BluetoothAdapter.STATE_ON:
          result.success(BluetoothAdapter.STATE_ON);
          break;
        case BluetoothAdapter.STATE_TURNING_OFF:
          result.success(BluetoothAdapter.STATE_TURNING_OFF);
          break;
        case BluetoothAdapter.STATE_TURNING_ON:
          result.success(BluetoothAdapter.STATE_TURNING_ON);
          break;
        default:
          result.success(0);
          break;
      }
    } catch (SecurityException e) {
      result.error("invalid_argument", "Argument 'address' not found", null);
    }
  }

  /**
   * @param result result
   */
  private void getBondedDevices(Result result) {

    List<Map<String, Object>> list = new ArrayList<>();

    for (BluetoothDevice device : mBluetoothAdapter.getBondedDevices()) {
      Map<String, Object> ret = new HashMap<>();
      ret.put("address", device.getAddress());
      ret.put("name", device.getName());
      ret.put("type", device.getType());
      list.add(ret);
    }

    result.success(list);
  }


  /**
   * @param result  result
   * @param address address
   */
  private void isDeviceConnected(Result result, String address) {

    AsyncTask.execute(() -> {
      try {
        BluetoothDevice device = mBluetoothAdapter.getRemoteDevice(address);

        if (device == null) {
          result.error("connect_error", "device not found", null);
          return;
        }

        ConnectedThread thread = activeConnection();
        result.success(thread != null && thread.address.equalsIgnoreCase(address));
      } catch (Exception ex) {
        Log.e(TAG, ex.getMessage(), ex);
        result.error("connect_error", ex.getMessage(), exceptionToString(ex));
      }
    });
  }

  private String exceptionToString(Exception ex) {
    StringWriter sw = new StringWriter();
    PrintWriter pw = new PrintWriter(sw);
    ex.printStackTrace(pw);
    return sw.toString();
  }

  /**
   * @param result  result
   * @param address address
   */
  private void connect(Result result, String address) {

    ConnectedThread existing = activeConnection();
    if (existing != null) {
      // Idempoten untuk printer yang sama: pemanggil yang tidak tahu koneksinya masih hidup
      // (mis. auto-connect setelah app kembali ke foreground) tidak perlu disconnect dulu.
      if (existing.address.equalsIgnoreCase(address)) {
        result.success(true);
      } else {
        result.error("connect_error", "already connected", null);
      }
      return;
    }
    if (!connecting.compareAndSet(false, true)) {
      result.error("connect_in_progress", "a connection attempt is already in progress", null);
      return;
    }
    AsyncTask.execute(() -> {
      try {
        BluetoothDevice device = mBluetoothAdapter.getRemoteDevice(address);

        if (device == null) {
          result.error("connect_error", "device not found", null);
          return;
        }

        BluetoothSocket socket = device.createRfcommSocketToServiceRecord(MY_UUID);

        if (socket == null) {
          result.error("connect_error", "socket connection not established", null);
          return;
        }

        // Cancel bt discovery, even though we didn't start it
        mBluetoothAdapter.cancelDiscovery();

        connectWithTimeoutAndFallback(result, device, socket);
      } catch (Exception ex) {
        Log.e(TAG, ex.getMessage(), ex);
        result.error("connect_error", ex.getMessage(), exceptionToString(ex));
      } finally {
        connecting.set(false);
      }
    });
  }

  /**
   * Koneksi aktif yang masih benar-benar bisa dipakai, atau {@code null}. Koneksi yang sudah mati
   * (thread baca berhenti, socket tertutup) dibersihkan di sini juga, supaya status "terhubung"
   * tidak pernah basi.
   */
  private static ConnectedThread activeConnection() {
    ConnectedThread thread = connectedThreadRef.get();
    if (thread != null && !thread.isUsable()) {
      if (connectedThreadRef.compareAndSet(thread, null)) {
        thread.cancel();
      }
      return null;
    }
    return thread;
  }

  /** Putus koneksi aktif bila {@code address} cocok (atau {@code null} = koneksi apa pun). */
  private static void dropConnection(String address) {
    ConnectedThread thread = connectedThreadRef.get();
    if (thread == null) return;
    if (address != null && !thread.address.equalsIgnoreCase(address)) return;
    if (connectedThreadRef.compareAndSet(thread, null)) {
      thread.cancel();
    }
  }

  private void startConnection(BluetoothSocket socket, String address) {
    ConnectedThread thread = new ConnectedThread(socket, address);
    // start() dulu baru dipublikasikan: activeConnection() menganggap thread yang belum hidup
    // sebagai koneksi mati.
    thread.start();
    connectedThreadRef.set(thread);
  }

  /**
   * Menyambungkan ke {@code socket} dengan batas waktu {@link #CONNECT_TIMEOUT_MILLIS}. Kalau
   * percobaan standar gagal (bukan timeout), coba sekali lagi lewat reflection fallback di
   * {@link #attemptFallbackConnect} sebelum benar-benar menyerah.
   */
  private void connectWithTimeoutAndFallback(Result result, BluetoothDevice device, BluetoothSocket socket) {
    ExecutorService connectExecutor = Executors.newSingleThreadExecutor();
    try {
      Future<Void> connectFuture = connectExecutor.submit(() -> {
        socket.connect();
        return null;
      });
      connectFuture.get(CONNECT_TIMEOUT_MILLIS, TimeUnit.MILLISECONDS);
      startConnection(socket, device.getAddress());
      result.success(true);
    } catch (TimeoutException te) {
      closeSocketQuietly(socket);
      result.error("connect_timeout",
              "connecting to the printer timed out after " + CONNECT_TIMEOUT_MILLIS + "ms", null);
    } catch (ExecutionException ee) {
      Log.w(TAG, "standard RFCOMM connect failed, retrying with reflection fallback on channel 1", ee.getCause());
      attemptFallbackConnect(result, device, socket, ee);
    } catch (InterruptedException ie) {
      Thread.currentThread().interrupt();
      closeSocketQuietly(socket);
      result.error("connect_error", "connection attempt was interrupted", null);
    } finally {
      connectExecutor.shutdownNow();
    }
  }

  /**
   * Workaround dikenal luas di ekosistem Android BT Classic: sejumlah kombinasi device/printer
   * gagal di socket RFCOMM secure standar ("read failed, socket might closed") tapi berhasil
   * lewat channel 1 yang cuma bisa diakses lewat reflection karena {@code createRfcommSocket(int)}
   * bukan bagian dari API publik {@link BluetoothDevice}.
   */
  private void attemptFallbackConnect(Result result, BluetoothDevice device, BluetoothSocket failedSocket,
      ExecutionException originalError) {
    closeSocketQuietly(failedSocket);
    try {
      BluetoothSocket fallbackSocket = createFallbackRfcommSocket(device);
      mBluetoothAdapter.cancelDiscovery();
      fallbackSocket.connect();
      startConnection(fallbackSocket, device.getAddress());
      Log.i(TAG, "connected via reflection fallback (createRfcommSocket channel 1)");
      result.success(true);
    } catch (Exception fallbackEx) {
      Log.e(TAG, "reflection fallback connect also failed", fallbackEx);
      Throwable cause = originalError.getCause();
      String message = cause != null ? cause.getMessage() : originalError.getMessage();
      result.error("connect_error", message, exceptionToString(originalError));
    }
  }

  private BluetoothSocket createFallbackRfcommSocket(BluetoothDevice device) throws Exception {
    Method method = device.getClass().getMethod("createRfcommSocket", int.class);
    return (BluetoothSocket) method.invoke(device, 1);
  }

  private void closeSocketQuietly(BluetoothSocket socket) {
    try {
      socket.close();
    } catch (IOException e) {
      Log.e(TAG, "failed to close socket after a failed connection attempt", e);
    }
  }

  /**
   * @param result result
   */
  private void disconnect(Result result) {

    ConnectedThread thread = connectedThreadRef.getAndSet(null);
    if (thread == null) {
      result.error("disconnection_error", "not connected", null);
      return;
    }
    AsyncTask.execute(() -> {
      try {
        thread.cancel();
        result.success(true);
      } catch (Exception ex) {
        Log.e(TAG, ex.getMessage(), ex);
        result.error("disconnection_error", ex.getMessage(), exceptionToString(ex));
      }
    });
  }

  /**
   * Menulis byte ke socket printer yang sedang tersambung dan meneruskan kegagalan tulis fisik
   * (mis. printer diputus di tengah pengiriman) sebagai {@code result.error(...)} alih-alih diam-
   * diam melapor sukses.
   *
   * @return true kalau berhasil ditulis; false kalau gagal (result sudah diisi error).
   */
  private boolean writeOrFail(ConnectedThread thread, Result result, byte[] bytes) {
    if (thread.write(bytes)) {
      return true;
    }
    result.error("write_error", "failed to write bytes to the printer socket", null);
    return false;
  }

  /**
   * @return byte code ESC/POS untuk ukuran teks (lihat {@link PrinterCommands}), atau null kalau
   * argumen ukurannya di luar rentang yang didukung.
   */
  private byte[] textSizeCode(int size) {
    switch (size) {
      case 0:
        return PrinterCommands.TEXT_SIZE_NORMAL;
      case 1:
        return PrinterCommands.TEXT_SIZE_BOLD;
      case 2:
        return PrinterCommands.TEXT_SIZE_BOLD_MEDIUM;
      case 3:
        return PrinterCommands.TEXT_SIZE_BOLD_LARGE;
      case 4:
        return PrinterCommands.TEXT_SIZE_STRONG;
      case 5:
        return PrinterCommands.TEXT_SIZE_EXTRA_STRONG;
      default:
        return null;
    }
  }

  private byte[] alignCode(int align) {
    switch (align) {
      case 0:
        return PrinterCommands.ESC_ALIGN_LEFT;
      case 1:
        return PrinterCommands.ESC_ALIGN_CENTER;
      case 2:
        return PrinterCommands.ESC_ALIGN_RIGHT;
      default:
        return null;
    }
  }

  /**
   * @param result  result
   * @param message message
   */
  private void write(Result result, String message) {
    final ConnectedThread thread = activeConnection();
    if (thread == null) {
      result.error("write_error", "not connected", null);
      return;
    }

    if (writeOrFail(thread, result, message.getBytes())) {
      result.success(true);
    }
  }

  private void writeBytes(Result result, byte[] message) {
    final ConnectedThread thread = activeConnection();
    if (thread == null) {
      result.error("write_error", "not connected", null);
      return;
    }

    if (writeOrFail(thread, result, message)) {
      result.success(true);
    }
  }

  /**
   * Kirim query status real-time ESC/POS (DLE EOT n, lihat {@link PrinterCommands}) dan
   * tunggu satu byte respons lewat {@link ConnectedThread#awaitStatusResponse(long)}.
   * {@code null} berarti printer tidak merespons dalam {@link #STATUS_QUERY_TIMEOUT_MILLIS}
   * -- dianggap "tidak diketahui", bukan galat, karena tidak semua printer clone ESC/POS
   * mengimplementasikan query ini.
   */
  private void queryPrinterStatus(Result result, int statusType) {
    final ConnectedThread thread = activeConnection();
    if (thread == null) {
      result.error("write_error", "not connected", null);
      return;
    }
    byte[] command = statusQueryCommand(statusType);
    if (command == null) {
      result.error("invalid_argument", "unsupported status type: " + statusType, null);
      return;
    }
    AsyncTask.execute(() -> {
      thread.armStatusRequest();
      if (!thread.write(command)) {
        result.error("write_error", "failed to write status query to the printer socket", null);
        return;
      }
      Integer response = thread.awaitStatusResponse(STATUS_QUERY_TIMEOUT_MILLIS);
      if (response == null) {
        Log.w(TAG, "queryPrinterStatus(type=" + statusType + "): no response within "
            + STATUS_QUERY_TIMEOUT_MILLIS + "ms -- printer may not support DLE EOT status queries");
      } else {
        Log.i(TAG, "queryPrinterStatus(type=" + statusType + "): response byte = 0x"
            + Integer.toHexString(response));
      }
      result.success(response);
    });
  }

  private byte[] statusQueryCommand(int statusType) {
    switch (statusType) {
      case 1:
        return PrinterCommands.TRANSMIT_DLE_PRINTER_STATUS;
      case 2:
        return PrinterCommands.TRANSMIT_DLE_OFFLINE_PRINTER_STATUS;
      case 3:
        return PrinterCommands.TRANSMIT_DLE_ERROR_STATUS;
      case 4:
        return PrinterCommands.TRANSMIT_DLE_ROLL_PAPER_SENSOR_STATUS;
      default:
        return null;
    }
  }

  private void printCustom(Result result, String message, int size, int align, String charset) {
    final ConnectedThread thread = activeConnection();
    if (thread == null) {
      result.error("write_error", "not connected", null);
      return;
    }

    try {
      byte[] sizeCode = textSizeCode(size);
      if (sizeCode != null && !writeOrFail(thread, result, sizeCode)) {
        return;
      }

      byte[] alignCode = alignCode(align);
      if (alignCode != null && !writeOrFail(thread, result, alignCode)) {
        return;
      }

      byte[] messageBytes = charset != null ? message.getBytes(charset) : message.getBytes();
      if (!writeOrFail(thread, result, messageBytes)) {
        return;
      }
      if (writeOrFail(thread, result, PrinterCommands.FEED_LINE)) {
        result.success(true);
      }
    } catch (Exception ex) {
      Log.e(TAG, ex.getMessage(), ex);
      result.error("write_error", ex.getMessage(), exceptionToString(ex));
    }
  }

  private void printLeftRight(Result result, String msg1, String msg2, int size ,String charset,String format) {
    final ConnectedThread thread = activeConnection();
    if (thread == null) {
      result.error("write_error", "not connected", null);
      return;
    }
    try {
      byte[] sizeCode = textSizeCode(size);
      if (sizeCode != null && !writeOrFail(thread, result, sizeCode)) {
        return;
      }
      if (!writeOrFail(thread, result, PrinterCommands.ESC_ALIGN_CENTER)) {
        return;
      }
      String line = String.format("%-15s %15s %n", msg1, msg2);
      if(format != null) {
        line = String.format(format, msg1, msg2);
      }
      byte[] lineBytes = charset != null ? line.getBytes(charset) : line.getBytes();
      if (writeOrFail(thread, result, lineBytes)) {
        result.success(true);
      }
    } catch (Exception ex) {
      Log.e(TAG, ex.getMessage(), ex);
      result.error("write_error", ex.getMessage(), exceptionToString(ex));
    }

  }

  private void print3Column(Result result, String msg1, String msg2, String msg3, int size ,String charset, String format) {
    final ConnectedThread thread = activeConnection();
    if (thread == null) {
      result.error("write_error", "not connected", null);
      return;
    }
    try {
      byte[] sizeCode = textSizeCode(size);
      if (sizeCode != null && !writeOrFail(thread, result, sizeCode)) {
        return;
      }
      if (!writeOrFail(thread, result, PrinterCommands.ESC_ALIGN_CENTER)) {
        return;
      }
      String line = String.format("%-10s %10s %10s %n", msg1, msg2  , msg3);
      if(format != null) {
        line = String.format(format, msg1, msg2, msg3);
      }
      byte[] lineBytes = charset != null ? line.getBytes(charset) : line.getBytes();
      if (writeOrFail(thread, result, lineBytes)) {
        result.success(true);
      }
    } catch (Exception ex) {
      Log.e(TAG, ex.getMessage(), ex);
      result.error("write_error", ex.getMessage(), exceptionToString(ex));
    }

  }

  private void print4Column(Result result, String msg1, String msg2,String msg3,String msg4, int size, String charset, String format) {
    final ConnectedThread thread = activeConnection();
    if (thread == null) {
      result.error("write_error", "not connected", null);
      return;
    }
    try {
      byte[] sizeCode = textSizeCode(size);
      if (sizeCode != null && !writeOrFail(thread, result, sizeCode)) {
        return;
      }
      if (!writeOrFail(thread, result, PrinterCommands.ESC_ALIGN_CENTER)) {
        return;
      }
      String line = String.format("%-8s %7s %7s %7s %n", msg1, msg2,msg3,msg4);
      if(format != null) {
        line = String.format(format, msg1, msg2,msg3,msg4);
      }
      byte[] lineBytes = charset != null ? line.getBytes(charset) : line.getBytes();
      if (writeOrFail(thread, result, lineBytes)) {
        result.success(true);
      }
    } catch (Exception ex) {
      Log.e(TAG, ex.getMessage(), ex);
      result.error("write_error", ex.getMessage(), exceptionToString(ex));
    }

  }

  private void printNewLine(Result result) {
    final ConnectedThread thread = activeConnection();
    if (thread == null) {
      result.error("write_error", "not connected", null);
      return;
    }
    if (writeOrFail(thread, result, PrinterCommands.FEED_LINE)) {
      result.success(true);
    }
  }

  private void paperCut(Result result) {
    final ConnectedThread thread = activeConnection();
    if (thread == null) {
      result.error("write_error", "not connected", null);
      return;
    }
    if (writeOrFail(thread, result, PrinterCommands.FEED_PAPER_AND_CUT)) {
      result.success(true);
    }
  }

  private void drawerPin2(Result result) {
    final ConnectedThread thread = activeConnection();
    if (thread == null) {
      result.error("write_error", "not connected", null);
      return;
    }
    if (writeOrFail(thread, result, PrinterCommands.ESC_DRAWER_PIN2)) {
      result.success(true);
    }
  }

  private void drawerPin5(Result result) {
    final ConnectedThread thread = activeConnection();
    if (thread == null) {
      result.error("write_error", "not connected", null);
      return;
    }
    if (writeOrFail(thread, result, PrinterCommands.ESC_DRAWER_PIN5)) {
      result.success(true);
    }
  }

  private void printImage(Result result, String pathImage) {
    final ConnectedThread thread = activeConnection();
    if (thread == null) {
      result.error("write_error", "not connected", null);
      return;
    }
    try {
      Bitmap bmp = BitmapFactory.decodeFile(pathImage);
      if (bmp == null) {
        Log.e(TAG, "the image file does not exist: " + pathImage);
        result.error("image_error", "the image file does not exist", null);
        return;
      }
      byte[] command = Utils.decodeBitmap(bmp);
      if (command == null) {
        result.error("image_error", "image dimensions exceed the printer's supported raster size", null);
        return;
      }
      if (!writeOrFail(thread, result, PrinterCommands.ESC_ALIGN_CENTER)) {
        return;
      }
      if (writeOrFail(thread, result, command)) {
        result.success(true);
      }
    } catch (Exception ex) {
      Log.e(TAG, ex.getMessage(), ex);
      result.error("write_error", ex.getMessage(), exceptionToString(ex));
    }
  }

  private void printImageBytes(Result result, byte[] bytes) {
    final ConnectedThread thread = activeConnection();
    if (thread == null) {
      result.error("write_error", "not connected", null);
      return;
    }
    try {
      Bitmap bmp = BitmapFactory.decodeByteArray(bytes, 0, bytes.length);
      if (bmp == null) {
        Log.e(TAG, "the image bytes could not be decoded");
        result.error("image_error", "the image bytes could not be decoded", null);
        return;
      }
      byte[] command = Utils.decodeBitmap(bmp);
      if (command == null) {
        result.error("image_error", "image dimensions exceed the printer's supported raster size", null);
        return;
      }
      if (!writeOrFail(thread, result, PrinterCommands.ESC_ALIGN_CENTER)) {
        return;
      }
      if (writeOrFail(thread, result, command)) {
        result.success(true);
      }
    } catch (Exception ex) {
      Log.e(TAG, ex.getMessage(), ex);
      result.error("write_error", ex.getMessage(), exceptionToString(ex));
    }
  }

  private void printQRcode(Result result, String textToQR, int width, int height, int align) {
    final ConnectedThread thread = activeConnection();
    if (thread == null) {
      result.error("write_error", "not connected", null);
      return;
    }
    try {
      byte[] alignCode = alignCode(align);
      if (alignCode != null && !writeOrFail(thread, result, alignCode)) {
        return;
      }

      MultiFormatWriter multiFormatWriter = new MultiFormatWriter();
      BitMatrix bitMatrix = multiFormatWriter.encode(textToQR, BarcodeFormat.QR_CODE, width, height);
      BarcodeEncoder barcodeEncoder = new BarcodeEncoder();
      Bitmap bmp = barcodeEncoder.createBitmap(bitMatrix);
      if (bmp == null) {
        Log.e(TAG, "the QR bitmap could not be generated");
        result.error("image_error", "the QR bitmap could not be generated", null);
        return;
      }
      byte[] command = Utils.decodeBitmap(bmp);
      if (command == null) {
        result.error("image_error", "image dimensions exceed the printer's supported raster size", null);
        return;
      }
      if (writeOrFail(thread, result, command)) {
        result.success(true);
      }
    } catch (Exception ex) {
      Log.e(TAG, ex.getMessage(), ex);
      result.error("write_error", ex.getMessage(), exceptionToString(ex));
    }
  }

  private class ConnectedThread extends Thread {
    final String address;
    private final BluetoothSocket mmSocket;
    private final InputStream inputStream;
    private final OutputStream outputStream;
    private volatile boolean closed = false;

    // Mailbox satu slot dipakai queryPrinterStatus() untuk menangkap byte respons DLE EOT
    // tanpa membuka thread pembaca kedua di atas InputStream yang sama -- run() di bawah ini
    // tetap satu-satunya pembaca socket, ia cuma dialihkan sementara ke mailbox alih-alih
    // readSink saat sebuah query sedang ditunggu.
    private final ArrayBlockingQueue<Byte> statusResponseMailbox = new ArrayBlockingQueue<>(1);
    private volatile boolean awaitingStatusResponse = false;

    ConnectedThread(BluetoothSocket socket, String address) {
      this.address = address;
      mmSocket = socket;
      InputStream tmpIn = null;
      OutputStream tmpOut = null;

      try {
        tmpIn = socket.getInputStream();
        tmpOut = socket.getOutputStream();
      } catch (IOException e) {
        Log.e(TAG, "failed to open printer socket streams", e);
      }
      inputStream = tmpIn;
      outputStream = tmpOut;
    }

    /** Masih bisa dipakai menulis: thread baca hidup dan socket belum ditutup. */
    boolean isUsable() {
      return !closed && isAlive() && outputStream != null && mmSocket.isConnected();
    }

    public void run() {
      byte[] buffer = new byte[1024];
      try {
        while (!closed) {
          int bytes = inputStream.read(buffer);
          if (bytes < 0) break;
          if (bytes == 0) continue;
          if (awaitingStatusResponse) {
            // Cari byte status yang sah di seluruh potongan data -- byte lain (XON/XOFF, sisa
            // respons lama) tidak boleh menggantikan respons query yang sedang ditunggu.
            int index = EscPosStatus.indexOfRealtimeStatus(buffer, bytes);
            if (index >= 0) {
              awaitingStatusResponse = false;
              statusResponseMailbox.offer(buffer[index]);
              emitRead(buffer, 0, index);
              emitRead(buffer, index + 1, bytes - index - 1);
              continue;
            }
          }
          emitRead(buffer, 0, bytes);
        }
      } catch (Exception e) {
        // IOException = socket putus/ditutup; exception lain (mis. stream gagal dibuka) juga
        // mengakhiri koneksi ini -- apa pun penyebabnya, jangan biarkan koneksi basi tercatat.
        if (!closed) {
          Log.w(TAG, "printer socket read loop ended", e);
        }
      } finally {
        connectedThreadRef.compareAndSet(this, null);
        cancel();
      }
    }

    /**
     * Teruskan byte yang tidak diminta ke onRead() -- lewat platform thread (syarat EventSink)
     * dan dibuang begitu saja kalau tidak ada listener. Dulu readSink dipanggil langsung dari
     * thread ini, sehingga NullPointerException saat tidak ada listener mematikan thread baca
     * (dan semua query status sesudahnya) selamanya.
     */
    private void emitRead(byte[] buffer, int offset, int length) {
      if (length <= 0 || readSink == null) return;
      final String data = new String(buffer, offset, length);
      mainHandler.post(() -> {
        EventSink sink = readSink;
        if (sink != null) {
          sink.success(data);
        }
      });
    }

    /** Bersihkan mailbox lalu tandai byte status sah berikutnya sebagai respons query. */
    void armStatusRequest() {
      statusResponseMailbox.clear();
      awaitingStatusResponse = true;
    }

    /**
     * Tunggu byte respons query status hingga {@code timeoutMillis}, dikembalikan sebagai
     * {@code int} tak-bertanda (0-255). {@code null} kalau timeout atau terinterupsi. Selalu
     * mematikan {@link #awaitingStatusResponse} di akhir supaya {@link #run()} kembali
     * meneruskan byte apa pun ke {@code readSink} seperti biasa.
     */
    Integer awaitStatusResponse(long timeoutMillis) {
      try {
        Byte response = statusResponseMailbox.poll(timeoutMillis, TimeUnit.MILLISECONDS);
        return response == null ? null : (response & 0xFF);
      } catch (InterruptedException e) {
        Thread.currentThread().interrupt();
        return null;
      } finally {
        awaitingStatusResponse = false;
      }
    }

    public synchronized boolean write(byte[] bytes) {
      if (closed || outputStream == null) {
        return false;
      }
      try {
        outputStream.write(bytes);
        return true;
      } catch (IOException e) {
        Log.e(TAG, "failed to write bytes to the printer socket", e);
        return false;
      }
    }

    /** Tutup socket. Idempoten -- dipanggil dari disconnect() maupun akhir run(). */
    public void cancel() {
      closed = true;
      try {
        if (outputStream != null) outputStream.close();
      } catch (IOException e) {
        Log.w(TAG, "failed to close printer output stream", e);
      }
      try {
        if (inputStream != null) inputStream.close();
      } catch (IOException e) {
        Log.w(TAG, "failed to close printer input stream", e);
      }
      try {
        mmSocket.close();
      } catch (IOException e) {
        Log.e(TAG, "failed to close printer socket cleanly", e);
      }
    }
  }

  private final StreamHandler stateStreamHandler = new StreamHandler() {

    private final BroadcastReceiver mReceiver = new BroadcastReceiver() {
      @Override
      public void onReceive(Context context, Intent intent) {
        final String action = intent.getAction();

        Log.d(TAG, action);

        EventSink sink = statusSink;

        if (BluetoothAdapter.ACTION_STATE_CHANGED.equals(action)) {
          int state = intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, -1);
          if (state != BluetoothAdapter.STATE_ON && state != BluetoothAdapter.STATE_TURNING_ON) {
            dropConnection(null);
          }
          if (sink != null) sink.success(state);
        } else if (BluetoothDevice.ACTION_ACL_CONNECTED.equals(action)) {
          if (sink != null) sink.success(1);
        } else if (BluetoothDevice.ACTION_ACL_DISCONNECT_REQUESTED.equals(action)) {
          dropConnection(deviceAddress(intent));
          if (sink != null) sink.success(2);
        } else if (BluetoothDevice.ACTION_ACL_DISCONNECTED.equals(action)) {
          // Hanya koneksi ke perangkat yang terputus itu -- dulu ACL disconnect perangkat BT
          // mana pun (mis. headset) ikut "memutus" printer tanpa menutup socket-nya.
          dropConnection(deviceAddress(intent));
          if (sink != null) sink.success(0);
        }
      }

      @SuppressWarnings("deprecation")
      private String deviceAddress(Intent intent) {
        BluetoothDevice device = intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE);
        // Tanpa info perangkat, jangan asal memutus koneksi printer.
        return device != null ? device.getAddress() : "";
      }
    };

    @Override
    public void onListen(Object o, EventSink eventSink) {
      statusSink = eventSink;
      context.registerReceiver(mReceiver, new IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED));

      context.registerReceiver(mReceiver, new IntentFilter(BluetoothDevice.ACTION_ACL_CONNECTED));

      context.registerReceiver(mReceiver, new IntentFilter(BluetoothDevice.ACTION_ACL_DISCONNECT_REQUESTED));

      context.registerReceiver(mReceiver, new IntentFilter(BluetoothDevice.ACTION_ACL_DISCONNECTED));

    }

    @Override
    public void onCancel(Object o) {
      statusSink = null;
      context.unregisterReceiver(mReceiver);
    }
  };

  private final StreamHandler readResultsHandler = new StreamHandler() {
    @Override
    public void onListen(Object o, EventSink eventSink) {
      readSink = eventSink;
    }

    @Override
    public void onCancel(Object o) {
      readSink = null;
    }
  };
}

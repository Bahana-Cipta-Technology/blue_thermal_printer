package id.kakzaki.blue_thermal_printer.transport.usb;

import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.PackageManager;
import android.hardware.usb.UsbConstants;
import android.hardware.usb.UsbDevice;
import android.hardware.usb.UsbDeviceConnection;
import android.hardware.usb.UsbEndpoint;
import android.hardware.usb.UsbInterface;
import android.hardware.usb.UsbManager;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;

import androidx.annotation.NonNull;
import androidx.core.content.ContextCompat;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.atomic.AtomicReference;

import id.kakzaki.blue_thermal_printer.EscPosPrinterId;
import id.kakzaki.blue_thermal_printer.EscPosStatus;
import id.kakzaki.blue_thermal_printer.transport.TransportSupport;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.MethodChannel.MethodCallHandler;
import io.flutter.plugin.common.MethodChannel.Result;

/**
 * Transport ESC/POS lewat USB host (bulk transfer) -- channel "blue_thermal_printer/escpos_usb",
 * terpisah dari channel Bluetooth lama dan channel vendor.
 *
 * <p>Perangkat diidentifikasi dengan {@code vendorId}/{@code productId} (stabil saat kabel
 * dicabut-colok, beda dengan nama node {@code /dev/bus/usb/...}). Izin akses per perangkat diminta
 * lewat dialog sistem saat {@code connect}; hasilnya {@code "connected"}, {@code "permission_denied"},
 * {@code "not_found"}, atau {@code "failed"}.
 *
 * <p>Model thread sama dengan transport LAN: IO serial di {@link #ioExecutor}, {@code disconnect}
 * di {@link #controlExecutor} supaya bisa melepas {@code bulkTransfer} yang macet.
 */
public class UsbPrinterChannel implements MethodCallHandler {

  public static final String CHANNEL_NAME = "blue_thermal_printer/escpos_usb";

  private static final String TAG = "UsbPrinterChannel";
  private static final int WRITE_TIMEOUT_MILLIS = 5_000;
  private static final int DRAIN_TIMEOUT_MILLIS = 10;

  private final Context context;
  private final UsbManager usbManager;
  private final String permissionAction;
  private final MethodChannel channel;
  private final Handler mainHandler = new Handler(Looper.getMainLooper());
  private final ExecutorService ioExecutor = Executors.newSingleThreadExecutor();
  private final ExecutorService controlExecutor = Executors.newSingleThreadExecutor();
  private final AtomicReference<Connection> connectionRef = new AtomicReference<>();

  /** Permintaan izin yang sedang menunggu jawaban dialog sistem (paling banyak satu). */
  private PendingPermission pendingPermission;
  private BroadcastReceiver permissionReceiver;

  public UsbPrinterChannel(Context context, BinaryMessenger messenger) {
    this.context = context.getApplicationContext();
    this.usbManager = (UsbManager) this.context.getSystemService(Context.USB_SERVICE);
    this.permissionAction = this.context.getPackageName() + ".ESCPOS_USB_PERMISSION";
    channel = new MethodChannel(messenger, CHANNEL_NAME);
    channel.setMethodCallHandler(this);
  }

  @Override
  public void onMethodCall(@NonNull MethodCall call, @NonNull Result result) {
    switch (call.method) {
      case "isAvailable":
        result.success(usbManager != null
            && context.getPackageManager().hasSystemFeature(PackageManager.FEATURE_USB_HOST));
        break;

      case "devices":
        result.success(listPrinters());
        break;

      case "connect": {
        Integer vendorId = call.argument("vendorId");
        Integer productId = call.argument("productId");
        if (vendorId == null || productId == null) {
          result.error("invalid_argument", "arguments 'vendorId' and 'productId' are required", null);
          break;
        }
        connect(vendorId, productId, result);
        break;
      }

      case "disconnect":
        run(controlExecutor, result, () -> {
          closeConnection(connectionRef.getAndSet(null));
          return null;
        });
        break;

      case "isConnected":
        result.success(activeConnection() != null);
        break;

      case "writeBytes": {
        byte[] bytes = call.argument("bytes");
        if (bytes == null) {
          result.error("invalid_argument", "argument 'bytes' not found", null);
          break;
        }
        run(ioExecutor, result, () -> write(bytes));
        break;
      }

      case "queryStatus": {
        Integer type = call.argument("type");
        byte[] command = type == null ? null : TransportSupport.statusQueryCommand(type);
        if (command == null) {
          result.error("invalid_argument", "unsupported status type: " + type, null);
          break;
        }
        run(ioExecutor, result, () -> querySingleByte(command, false));
        break;
      }

      case "queryPrinterId": {
        Integer type = call.argument("type");
        byte[] command = type == null ? null : EscPosPrinterId.queryCommand(type);
        if (command == null) {
          result.error("invalid_argument", "unsupported printer id type: " + type, null);
          break;
        }
        run(ioExecutor, result, () -> querySingleByte(command, true));
        break;
      }

      default:
        result.notImplemented();
    }
  }

  public void dispose() {
    channel.setMethodCallHandler(null);
    finishPermissionRequest(null);
    closeConnection(connectionRef.getAndSet(null));
    ioExecutor.shutdownNow();
    controlExecutor.shutdownNow();
  }

  // ---------------------------------------------------------------------------------------------
  // Discovery
  // ---------------------------------------------------------------------------------------------

  private List<Map<String, Object>> listPrinters() {
    List<Map<String, Object>> printers = new ArrayList<>();
    if (usbManager == null) return printers;
    for (UsbDevice device : usbManager.getDeviceList().values()) {
      if (findPrinterInterface(device) == null) continue;
      Map<String, Object> entry = new HashMap<>();
      entry.put("name", productName(device));
      entry.put("vendorId", device.getVendorId());
      entry.put("productId", device.getProductId());
      printers.add(entry);
    }
    return printers;
  }

  private static String productName(UsbDevice device) {
    try {
      return device.getProductName();
    } catch (SecurityException ignored) {
      // Beberapa ROM mensyaratkan izin untuk membaca descriptor string.
      return null;
    }
  }

  private UsbDevice findDevice(int vendorId, int productId) {
    if (usbManager == null) return null;
    for (UsbDevice device : usbManager.getDeviceList().values()) {
      if (device.getVendorId() == vendorId && device.getProductId() == productId
          && findPrinterInterface(device) != null) {
        return device;
      }
    }
    return null;
  }

  /** Interface dengan endpoint bulk OUT berprioritas terbaik (lihat
   * {@link TransportSupport#usbInterfacePriority}), atau {@code null}. */
  private static UsbInterface findPrinterInterface(UsbDevice device) {
    UsbInterface best = null;
    int bestPriority = Integer.MAX_VALUE;
    for (int i = 0; i < device.getInterfaceCount(); i++) {
      UsbInterface candidate = device.getInterface(i);
      int priority = TransportSupport.usbInterfacePriority(candidate.getInterfaceClass());
      if (priority < 0 || priority >= bestPriority) continue;
      if (findBulkEndpoint(candidate, UsbConstants.USB_DIR_OUT) == null) continue;
      best = candidate;
      bestPriority = priority;
    }
    return best;
  }

  private static UsbEndpoint findBulkEndpoint(UsbInterface usbInterface, int direction) {
    for (int i = 0; i < usbInterface.getEndpointCount(); i++) {
      UsbEndpoint endpoint = usbInterface.getEndpoint(i);
      if (endpoint.getType() == UsbConstants.USB_ENDPOINT_XFER_BULK
          && endpoint.getDirection() == direction) {
        return endpoint;
      }
    }
    return null;
  }

  // ---------------------------------------------------------------------------------------------
  // Connect + izin
  // ---------------------------------------------------------------------------------------------

  private void connect(int vendorId, int productId, Result result) {
    Connection existing = activeConnection();
    if (existing != null && existing.device.getVendorId() == vendorId
        && existing.device.getProductId() == productId) {
      result.success("connected");
      return;
    }
    UsbDevice device = findDevice(vendorId, productId);
    if (device == null) {
      result.success("not_found");
      return;
    }
    if (usbManager.hasPermission(device)) {
      run(ioExecutor, result, () -> open(device));
      return;
    }
    requestPermission(device, result);
  }

  private void requestPermission(UsbDevice device, Result result) {
    if (pendingPermission != null) {
      result.error("connect_in_progress", "USB permission request already pending", null);
      return;
    }
    pendingPermission = new PendingPermission(device, result);
    permissionReceiver = new BroadcastReceiver() {
      @Override
      public void onReceive(Context receiverContext, Intent intent) {
        if (!permissionAction.equals(intent.getAction())) return;
        boolean granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false);
        finishPermissionRequest(granted);
      }
    };
    ContextCompat.registerReceiver(context, permissionReceiver,
        new IntentFilter(permissionAction), ContextCompat.RECEIVER_NOT_EXPORTED);
    // Intent eksplisit (setPackage) + FLAG_MUTABLE: sistem menambah extra hasil izin ke intent ini,
    // dan Android 14+ menolak PendingIntent mutable yang implisit.
    Intent intent = new Intent(permissionAction).setPackage(context.getPackageName());
    int flags = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S ? PendingIntent.FLAG_MUTABLE : 0;
    PendingIntent permissionIntent = PendingIntent.getBroadcast(context, 0, intent, flags);
    usbManager.requestPermission(device, permissionIntent);
  }

  /** Selesaikan permintaan izin yang tertunda. {@code granted == null} = dibatalkan (dispose). */
  private void finishPermissionRequest(Boolean granted) {
    PendingPermission pending = pendingPermission;
    pendingPermission = null;
    if (permissionReceiver != null) {
      try {
        context.unregisterReceiver(permissionReceiver);
      } catch (IllegalArgumentException ignored) {
        // Belum/tidak lagi terdaftar.
      }
      permissionReceiver = null;
    }
    if (pending == null) return;
    if (Boolean.TRUE.equals(granted)) {
      run(ioExecutor, pending.result, () -> open(pending.device));
    } else {
      pending.result.success("permission_denied");
    }
  }

  private String open(UsbDevice device) {
    UsbInterface usbInterface = findPrinterInterface(device);
    if (usbInterface == null) return "not_found";
    UsbDeviceConnection connection = usbManager.openDevice(device);
    if (connection == null) return "failed";
    if (!connection.claimInterface(usbInterface, true)) {
      connection.close();
      return "failed";
    }
    closeConnection(connectionRef.getAndSet(new Connection(device, connection, usbInterface,
        findBulkEndpoint(usbInterface, UsbConstants.USB_DIR_OUT),
        findBulkEndpoint(usbInterface, UsbConstants.USB_DIR_IN))));
    return "connected";
  }

  // ---------------------------------------------------------------------------------------------
  // IO (selalu di ioExecutor)
  // ---------------------------------------------------------------------------------------------

  private boolean write(byte[] bytes) {
    Connection connection = activeConnection();
    if (connection == null) return false;
    if (!connection.writeAll(bytes)) {
      Log.w(TAG, "bulk write failed");
      connectionRef.compareAndSet(connection, null);
      closeConnection(connection);
      return false;
    }
    return true;
  }

  /** Byte respons sah -- {@code GS I} bila {@code printerId}, selain itu {@code DLE EOT} --
   * atau {@code null} bila printer tidak menjawab (atau tidak punya endpoint IN sama sekali). */
  private Integer querySingleByte(byte[] command, boolean printerId) {
    Connection connection = activeConnection();
    if (connection == null || connection.in == null) return null;
    byte[] buffer = new byte[64];
    // Buang sisa respons lama supaya yang dibaca adalah jawaban query ini.
    while (connection.connection.bulkTransfer(connection.in, buffer, buffer.length,
        DRAIN_TIMEOUT_MILLIS) > 0) {
      // lanjut menguras
    }
    if (!connection.writeAll(command)) return null;
    long deadline = System.currentTimeMillis() + TransportSupport.STATUS_QUERY_TIMEOUT_MILLIS;
    while (System.currentTimeMillis() < deadline) {
      int remaining = (int) Math.max(1, deadline - System.currentTimeMillis());
      int count = connection.connection.bulkTransfer(connection.in, buffer, buffer.length, remaining);
      if (count <= 0) continue;
      int index = printerId
          ? EscPosPrinterId.indexOfIdResponse(buffer, count)
          : EscPosStatus.indexOfRealtimeStatus(buffer, count);
      if (index >= 0) return buffer[index] & 0xFF;
    }
    Log.w(TAG, (printerId ? "queryPrinterId" : "queryStatus")
        + ": no response -- printer may not support it");
    return null;
  }

  // ---------------------------------------------------------------------------------------------
  // Koneksi
  // ---------------------------------------------------------------------------------------------

  /** Koneksi yang masih hidup (perangkat masih tercolok), sekaligus membuang yang sudah mati. */
  private Connection activeConnection() {
    Connection connection = connectionRef.get();
    if (connection == null) return null;
    if (!connection.closed && usbManager != null
        && usbManager.getDeviceList().containsKey(connection.device.getDeviceName())) {
      return connection;
    }
    connectionRef.compareAndSet(connection, null);
    closeConnection(connection);
    return null;
  }

  private static void closeConnection(Connection connection) {
    if (connection == null) return;
    connection.closed = true;
    try {
      connection.connection.releaseInterface(connection.usbInterface);
    } catch (RuntimeException ignored) {
      // Perangkat sudah dicabut.
    }
    connection.connection.close();
  }

  private static final class Connection {
    final UsbDevice device;
    final UsbDeviceConnection connection;
    final UsbInterface usbInterface;
    final UsbEndpoint out;
    final UsbEndpoint in;
    volatile boolean closed = false;

    Connection(UsbDevice device, UsbDeviceConnection connection, UsbInterface usbInterface,
        UsbEndpoint out, UsbEndpoint in) {
      this.device = device;
      this.connection = connection;
      this.usbInterface = usbInterface;
      this.out = out;
      this.in = in;
    }

    /** Tulis semua byte per potongan {@link TransportSupport#USB_CHUNK_BYTES}. */
    boolean writeAll(byte[] bytes) {
      int offset = 0;
      while (offset < bytes.length) {
        int length = Math.min(TransportSupport.USB_CHUNK_BYTES, bytes.length - offset);
        int written = connection.bulkTransfer(out, bytes, offset, length, WRITE_TIMEOUT_MILLIS);
        if (written <= 0) return false;
        offset += written;
      }
      return true;
    }
  }

  private static final class PendingPermission {
    final UsbDevice device;
    final Result result;

    PendingPermission(UsbDevice device, Result result) {
      this.device = device;
      this.result = result;
    }
  }

  // ---------------------------------------------------------------------------------------------
  // Utilitas channel
  // ---------------------------------------------------------------------------------------------

  private interface Task {
    Object run() throws Exception;
  }

  /** Jalankan {@code task} di {@code executor}, lalu kirim hasilnya lewat main thread (syarat
   * {@link Result}) -- {@code bulkTransfer} memblokir dan tidak boleh di main thread. */
  private void run(ExecutorService executor, Result result, Task task) {
    try {
      executor.execute(() -> {
        Object value;
        try {
          value = task.run();
        } catch (Exception error) {
          Log.w(TAG, "task failed", error);
          mainHandler.post(() -> result.error("io_error", String.valueOf(error.getMessage()), null));
          return;
        }
        mainHandler.post(() -> result.success(value));
      });
    } catch (RejectedExecutionException error) {
      result.error("disposed", "printer channel disposed", null);
    }
  }
}

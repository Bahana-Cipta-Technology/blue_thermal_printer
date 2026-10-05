package id.kakzaki.blue_thermal_printer.transport.bluetooth;

import android.app.Activity;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothClass;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothManager;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.location.LocationManager;
import android.net.Uri;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.util.Log;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.core.app.ActivityCompat;
import androidx.core.content.ContextCompat;
import androidx.core.location.LocationManagerCompat;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import id.kakzaki.blue_thermal_printer.transport.bluetooth.BluetoothRequirementPolicy.PermissionState;
import id.kakzaki.blue_thermal_printer.transport.bluetooth.BluetoothRequirementPolicy.Requirement;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.MethodChannel.MethodCallHandler;
import io.flutter.plugin.common.MethodChannel.Result;
import io.flutter.plugin.common.PluginRegistry.ActivityResultListener;
import io.flutter.plugin.common.PluginRegistry.RequestPermissionsResultListener;

/**
 * Kontrol adapter Bluetooth: prasyarat, nyala/mati, pencarian (discovery), dan pairing -- channel
 * "blue_thermal_printer/bluetooth" + event "blue_thermal_printer/bluetooth/events". Terpisah dari
 * channel ESC/POS lama ({@code BlueThermalPrinterPlugin}), yang tetap memegang koneksi SPP.
 *
 * <p>Semua operasi di sini cepat (tidak memblokir), jadi dijalankan langsung di main thread;
 * hasilnya datang lewat broadcast sistem. Satu permintaan per jenis (izin, dialog nyalakan,
 * pairing) boleh tertunda sekaligus -- permintaan kedua ditolak {@code request_in_progress}
 * alih-alih menimpa {@link Result} yang pertama.
 */
public class BluetoothControlChannel
    implements MethodCallHandler, EventChannel.StreamHandler, RequestPermissionsResultListener,
        ActivityResultListener {

  public static final String CHANNEL_NAME = "blue_thermal_printer/bluetooth";
  public static final String EVENTS_CHANNEL_NAME = "blue_thermal_printer/bluetooth/events";

  private static final String TAG = "BluetoothControl";
  private static final int REQUEST_PERMISSIONS = 1452;
  private static final int REQUEST_ENABLE = 1453;
  private static final long DEFAULT_SCAN_TIMEOUT_MILLIS = 12_000;
  private static final long PAIR_TIMEOUT_MILLIS = 60_000;
  /** Menyimpan izin yang pernah ditolak permanen (lihat {@link #permissionState}). */
  private static final String PREFS_NAME = "blue_thermal_printer.bluetooth_permissions";

  private final Context context;
  private final MethodChannel channel;
  private final EventChannel eventChannel;
  private final Handler mainHandler = new Handler(Looper.getMainLooper());
  private final SharedPreferences prefs;
  @Nullable private final BluetoothAdapter adapter;

  @Nullable private ActivityPluginBinding activityBinding;
  @Nullable private EventChannel.EventSink eventSink;

  @Nullable private Result pendingPermissionResult;
  @Nullable private Result pendingEnableResult;
  @Nullable private Result pendingPairResult;
  @Nullable private String pendingPairAddress;

  private boolean scanning;
  /** Alasan berhentinya pencarian yang dipicu app sendiri; {@code null} = selesai alami. */
  @Nullable private String scanStopReason;
  private final Runnable scanTimeout = () -> stopDiscovery("timedOut");
  private final Runnable pairTimeout = () -> finishPair(false, "pair_timeout",
      "pairing did not complete in time");

  private boolean receiverRegistered;

  public BluetoothControlChannel(Context context, BinaryMessenger messenger) {
    this.context = context.getApplicationContext();
    BluetoothManager manager =
        (BluetoothManager) this.context.getSystemService(Context.BLUETOOTH_SERVICE);
    adapter = manager == null ? null : manager.getAdapter();
    prefs = this.context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE);
    channel = new MethodChannel(messenger, CHANNEL_NAME);
    channel.setMethodCallHandler(this);
    eventChannel = new EventChannel(messenger, EVENTS_CHANNEL_NAME);
    eventChannel.setStreamHandler(this);
  }

  public void attachActivity(@NonNull ActivityPluginBinding binding) {
    activityBinding = binding;
    binding.addRequestPermissionsResultListener(this);
    binding.addActivityResultListener(this);
  }

  public void detachActivity() {
    ActivityPluginBinding binding = activityBinding;
    if (binding == null) return;
    binding.removeRequestPermissionsResultListener(this);
    binding.removeActivityResultListener(this);
    activityBinding = null;
    // Dialog yang hasilnya tidak akan pernah datang -- jangan biarkan Dart menunggu selamanya.
    if (pendingPermissionResult != null) {
      pendingPermissionResult.success(prerequisites());
      pendingPermissionResult = null;
    }
    if (pendingEnableResult != null) {
      pendingEnableResult.error("no_activity", "activity detached before the dialog returned", null);
      pendingEnableResult = null;
    }
  }

  public void dispose() {
    detachActivity();
    if (scanning) stopDiscovery("stopped");
    finishPair(false, "disposed", "plugin detached");
    channel.setMethodCallHandler(null);
    eventChannel.setStreamHandler(null);
    eventSink = null;
    updateReceiver();
  }

  @Nullable
  private Activity activity() {
    return activityBinding == null ? null : activityBinding.getActivity();
  }

  // ---------------------------------------------------------------------------------------------
  // Method channel
  // ---------------------------------------------------------------------------------------------

  @Override
  public void onMethodCall(@NonNull MethodCall call, @NonNull Result result) {
    try {
      switch (call.method) {
        case "prerequisites":
          result.success(prerequisites());
          break;
        case "requestPermissions":
          requestPermissions(call.argument("permissions"), result);
          break;
        case "powerState":
          result.success(powerStateName(adapter == null ? -1 : adapter.getState()));
          break;
        case "setEnabled": {
          Boolean enabled = call.argument("enabled");
          if (enabled == null) {
            result.error("invalid_argument", "argument 'enabled' not found", null);
            break;
          }
          setEnabled(enabled, result);
          break;
        }
        case "startScan": {
          Number timeout = call.argument("timeoutMillis");
          startScan(timeout == null ? DEFAULT_SCAN_TIMEOUT_MILLIS : timeout.longValue(), result);
          break;
        }
        case "stopScan":
          if (scanning) stopDiscovery("stopped");
          result.success(null);
          break;
        case "pair": {
          String address = call.argument("address");
          if (address == null) {
            result.error("invalid_argument", "argument 'address' not found", null);
            break;
          }
          pair(address, result);
          break;
        }
        case "openBluetoothSettings":
          result.success(startSettings(new Intent(Settings.ACTION_BLUETOOTH_SETTINGS)));
          break;
        case "openLocationSettings":
          result.success(startSettings(new Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS)));
          break;
        case "openAppSettings":
          result.success(startSettings(new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
              Uri.fromParts("package", context.getPackageName(), null))));
          break;
        default:
          result.notImplemented();
      }
    } catch (SecurityException ex) {
      result.error("permission_denied", ex.getMessage(), null);
    } catch (Exception ex) {
      Log.e(TAG, "onMethodCall " + call.method, ex);
      result.error("error", ex.getMessage(), null);
    }
  }

  // ---------------------------------------------------------------------------------------------
  // Prasyarat & izin
  // ---------------------------------------------------------------------------------------------

  private Map<String, Object> prerequisites() {
    int sdk = Build.VERSION.SDK_INT;
    Map<String, PermissionState> permissions = new HashMap<>();
    for (String permission : BluetoothRequirementPolicy.runtimePermissions(sdk)) {
      permissions.put(permission, permissionState(permission));
    }
    boolean locationEnabled = !BluetoothRequirementPolicy.requiresLocationService(sdk)
        || isLocationEnabled();
    BluetoothRequirementPolicy.Snapshot snapshot = new BluetoothRequirementPolicy.Snapshot(sdk,
        adapter != null && hasBluetoothFeature(), isAdapterOn(), activity() != null,
        locationEnabled, permissions);

    List<Map<String, Object>> items = new ArrayList<>();
    for (Requirement requirement : BluetoothRequirementPolicy.evaluate(snapshot)) {
      Map<String, Object> item = new HashMap<>();
      item.put("id", requirement.id);
      item.put("kind", requirement.kind);
      item.put("status", requirement.status);
      item.put("resolution", requirement.resolution);
      item.put("permissions", requirement.permissions);
      item.put("operations", requirement.operations);
      items.add(item);
    }
    Map<String, Object> report = new HashMap<>();
    report.put("sdkInt", sdk);
    report.put("items", items);
    return report;
  }

  private boolean hasBluetoothFeature() {
    return context.getPackageManager().hasSystemFeature(PackageManager.FEATURE_BLUETOOTH);
  }

  private boolean isAdapterOn() {
    try {
      return adapter != null && adapter.isEnabled();
    } catch (SecurityException ex) {
      return false;
    }
  }

  private boolean isLocationEnabled() {
    LocationManager manager = (LocationManager) context.getSystemService(Context.LOCATION_SERVICE);
    return manager != null && LocationManagerCompat.isLocationEnabled(manager);
  }

  /**
   * Status satu izin. Android tidak menyediakan API "ditolak permanen", jadi dipakai pola umum:
   * setelah dialog ditolak dan {@code shouldShowRequestPermissionRationale} tetap {@code false},
   * izin dicatat permanen di {@link #prefs} sampai diberikan lewat Setelan. Konsekuensinya, dialog
   * yang ditutup tanpa memilih juga bisa tercatat permanen -- UI tetap menawarkan "Buka Setelan
   * Aplikasi", yang selalu bisa menyelesaikannya.
   */
  private PermissionState permissionState(String permission) {
    if (ContextCompat.checkSelfPermission(context, permission)
        == PackageManager.PERMISSION_GRANTED) {
      if (prefs.contains(permission)) prefs.edit().remove(permission).apply();
      return PermissionState.GRANTED;
    }
    return prefs.getBoolean(permission, false)
        ? PermissionState.PERMANENTLY_DENIED
        : PermissionState.DENIED;
  }

  private void requestPermissions(@Nullable List<String> requested, Result result) {
    Activity activity = activity();
    if (activity == null) {
      result.error("no_activity", "permission dialogs need a foreground activity", null);
      return;
    }
    if (pendingPermissionResult != null) {
      result.error("request_in_progress", "a permission request is already pending", null);
      return;
    }
    List<String> missing = new ArrayList<>();
    List<String> candidates = requested != null
        ? requested
        : BluetoothRequirementPolicy.runtimePermissions(Build.VERSION.SDK_INT);
    for (String permission : candidates) {
      if (ContextCompat.checkSelfPermission(context, permission)
          != PackageManager.PERMISSION_GRANTED) {
        missing.add(permission);
      }
    }
    if (missing.isEmpty()) {
      result.success(prerequisites());
      return;
    }
    pendingPermissionResult = result;
    ActivityCompat.requestPermissions(activity, missing.toArray(new String[0]),
        REQUEST_PERMISSIONS);
  }

  @Override
  public boolean onRequestPermissionsResult(int requestCode, @NonNull String[] permissions,
      @NonNull int[] grantResults) {
    if (requestCode != REQUEST_PERMISSIONS) return false;
    Activity activity = activity();
    SharedPreferences.Editor editor = prefs.edit();
    for (int i = 0; i < permissions.length && i < grantResults.length; i++) {
      boolean denied = grantResults[i] != PackageManager.PERMISSION_GRANTED;
      boolean permanent = denied && activity != null
          && !ActivityCompat.shouldShowRequestPermissionRationale(activity, permissions[i]);
      if (permanent) {
        editor.putBoolean(permissions[i], true);
      } else {
        editor.remove(permissions[i]);
      }
    }
    editor.apply();
    Result result = pendingPermissionResult;
    pendingPermissionResult = null;
    if (result != null) result.success(prerequisites());
    return true;
  }

  // ---------------------------------------------------------------------------------------------
  // Nyala / mati
  // ---------------------------------------------------------------------------------------------

  @SuppressWarnings("deprecation") // enable()/disable(): tetap dicoba untuk app sistem/device owner.
  private void setEnabled(boolean enabled, Result result) {
    if (adapter == null) {
      result.error("unsupported", "the device does not have bluetooth", null);
      return;
    }
    if (isAdapterOn() == enabled) {
      result.success("alreadyInState");
      return;
    }
    if (!hasConnectPermission()) {
      result.error("permission_denied", "BLUETOOTH_CONNECT not granted", null);
      return;
    }
    if (!enabled) {
      // API 33+: disable() selalu false untuk app biasa -- arahkan pengguna ke Setelan.
      if (adapter.disable()) {
        result.success("changed");
      } else {
        startSettings(new Intent(Settings.ACTION_BLUETOOTH_SETTINGS));
        result.success("openedSystemSettings");
      }
      return;
    }
    if (adapter.enable()) {
      result.success("changed");
      return;
    }
    Activity activity = activity();
    if (activity == null) {
      result.error("no_activity", "the enable dialog needs a foreground activity", null);
      return;
    }
    if (pendingEnableResult != null) {
      result.error("request_in_progress", "an enable request is already pending", null);
      return;
    }
    pendingEnableResult = result;
    activity.startActivityForResult(new Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE),
        REQUEST_ENABLE);
  }

  @Override
  public boolean onActivityResult(int requestCode, int resultCode, @Nullable Intent data) {
    if (requestCode != REQUEST_ENABLE) return false;
    Result result = pendingEnableResult;
    pendingEnableResult = null;
    if (result != null) {
      result.success(resultCode == Activity.RESULT_OK ? "changed" : "declinedByUser");
    }
    return true;
  }

  private boolean hasConnectPermission() {
    for (String permission : BluetoothRequirementPolicy.connectPermissions(Build.VERSION.SDK_INT)) {
      if (ContextCompat.checkSelfPermission(context, permission)
          != PackageManager.PERMISSION_GRANTED) {
        return false;
      }
    }
    return true;
  }

  private static String powerStateName(int state) {
    switch (state) {
      case BluetoothAdapter.STATE_ON:
        return "on";
      case BluetoothAdapter.STATE_TURNING_ON:
        return "turningOn";
      case BluetoothAdapter.STATE_TURNING_OFF:
        return "turningOff";
      case -1:
        return "unsupported";
      default:
        // STATE_OFF dan state BLE-only: Bluetooth Classic tidak bisa dipakai.
        return "off";
    }
  }

  // ---------------------------------------------------------------------------------------------
  // Pencarian
  // ---------------------------------------------------------------------------------------------

  private void startScan(long timeoutMillis, Result result) {
    if (adapter == null) {
      result.error("unsupported", "the device does not have bluetooth", null);
      return;
    }
    for (String permission : BluetoothRequirementPolicy.scanPermissions(Build.VERSION.SDK_INT)) {
      if (ContextCompat.checkSelfPermission(context, permission)
          != PackageManager.PERMISSION_GRANTED) {
        result.error("permission_denied", permission + " not granted", null);
        return;
      }
    }
    if (!isAdapterOn()) {
      result.error("adapter_off", "bluetooth is off", null);
      return;
    }
    if (BluetoothRequirementPolicy.requiresLocationService(Build.VERSION.SDK_INT)
        && !isLocationEnabled()) {
      result.error("location_off", "location services are off", null);
      return;
    }
    if (scanning) {
      result.success(true);
      return;
    }
    scanning = true;
    scanStopReason = null;
    updateReceiver();
    if (adapter.isDiscovering()) {
      // Pencarian yang sudah berjalan (mis. dari Setelan) dipakai apa adanya -- membatalkannya
      // akan memicu ACTION_DISCOVERY_FINISHED yang langsung menutup pencarian kita.
      Map<String, Object> event = new HashMap<>();
      event.put("type", "scanStarted");
      emit(event);
    } else if (!adapter.startDiscovery()) {
      scanning = false;
      updateReceiver();
      result.error("scan_failed", "startDiscovery returned false", null);
      return;
    }
    mainHandler.postDelayed(scanTimeout, timeoutMillis);
    result.success(true);
  }

  private void stopDiscovery(String reason) {
    if (!scanning) return;
    scanStopReason = reason;
    mainHandler.removeCallbacks(scanTimeout);
    try {
      if (adapter != null && adapter.isDiscovering()) {
        adapter.cancelDiscovery();
        // ACTION_DISCOVERY_FINISHED yang menyusul menutup pencarian dengan alasan ini.
        return;
      }
    } catch (SecurityException ex) {
      Log.w(TAG, "cancelDiscovery", ex);
    }
    finishScan(reason);
  }

  private void finishScan(String reason) {
    if (!scanning) return;
    scanning = false;
    scanStopReason = null;
    mainHandler.removeCallbacks(scanTimeout);
    Map<String, Object> event = new HashMap<>();
    event.put("type", "scanFinished");
    event.put("reason", reason);
    emit(event);
    updateReceiver();
  }

  @SuppressWarnings("deprecation")
  private void onDeviceFound(Intent intent) {
    BluetoothDevice device = intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE);
    if (device == null) return;
    int type;
    String name;
    int bondState;
    try {
      type = device.getType();
      name = device.getName();
      bondState = device.getBondState();
    } catch (SecurityException ex) {
      return;
    }
    // SPP butuh Bluetooth Classic; perangkat BLE-only tidak bisa jadi printer ESC/POS di sini.
    if (type == BluetoothDevice.DEVICE_TYPE_LE) return;
    if (name == null) name = intent.getStringExtra(BluetoothDevice.EXTRA_NAME);
    BluetoothClass bluetoothClass = intent.getParcelableExtra(BluetoothDevice.EXTRA_CLASS);
    short rssi = intent.getShortExtra(BluetoothDevice.EXTRA_RSSI, Short.MIN_VALUE);

    Map<String, Object> event = new HashMap<>();
    event.put("type", "found");
    event.put("address", device.getAddress());
    event.put("name", name);
    event.put("rssi", rssi == Short.MIN_VALUE ? null : (int) rssi);
    event.put("deviceClass", bluetoothClass == null ? null : bluetoothClass.getDeviceClass());
    event.put("bonded", bondState == BluetoothDevice.BOND_BONDED);
    emit(event);
  }

  // ---------------------------------------------------------------------------------------------
  // Pairing
  // ---------------------------------------------------------------------------------------------

  private void pair(String address, Result result) {
    if (adapter == null) {
      result.error("unsupported", "the device does not have bluetooth", null);
      return;
    }
    if (!hasConnectPermission()) {
      result.error("permission_denied", "BLUETOOTH_CONNECT not granted", null);
      return;
    }
    if (!isAdapterOn()) {
      result.error("adapter_off", "bluetooth is off", null);
      return;
    }
    if (pendingPairResult != null) {
      result.error("request_in_progress", "a pairing request is already pending", null);
      return;
    }
    BluetoothDevice device = adapter.getRemoteDevice(address);
    if (device.getBondState() == BluetoothDevice.BOND_BONDED) {
      result.success("bonded");
      return;
    }
    // Discovery memperlambat (dan di sebagian chipset menggagalkan) pairing.
    if (scanning) stopDiscovery("stopped");
    pendingPairResult = result;
    pendingPairAddress = address;
    updateReceiver();
    if (!device.createBond()) {
      finishPair(false, "pair_failed", "createBond returned false");
      return;
    }
    mainHandler.postDelayed(pairTimeout, PAIR_TIMEOUT_MILLIS);
  }

  private void onBondStateChanged(Intent intent) {
    BluetoothDevice device = intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE);
    if (device == null) return;
    int state = intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, BluetoothDevice.ERROR);
    int previous = intent.getIntExtra(BluetoothDevice.EXTRA_PREVIOUS_BOND_STATE,
        BluetoothDevice.ERROR);

    Map<String, Object> event = new HashMap<>();
    event.put("type", "bond");
    event.put("address", device.getAddress());
    event.put("state", state == BluetoothDevice.BOND_BONDED ? "bonded"
        : state == BluetoothDevice.BOND_BONDING ? "bonding" : "none");
    emit(event);

    if (pendingPairAddress == null || !pendingPairAddress.equalsIgnoreCase(device.getAddress())) {
      return;
    }
    if (state == BluetoothDevice.BOND_BONDED) {
      finishPair(true, null, null);
    } else if (state == BluetoothDevice.BOND_NONE && previous == BluetoothDevice.BOND_BONDING) {
      // PIN salah, dibatalkan pengguna, atau printer menolak.
      finishPair(false, "pair_rejected", "pairing was rejected or cancelled");
    }
  }

  private void finishPair(boolean bonded, @Nullable String errorCode,
      @Nullable String errorMessage) {
    mainHandler.removeCallbacks(pairTimeout);
    Result result = pendingPairResult;
    pendingPairResult = null;
    pendingPairAddress = null;
    if (result != null) {
      if (bonded) {
        result.success("bonded");
      } else {
        result.error(errorCode, errorMessage, null);
      }
    }
    updateReceiver();
  }

  // ---------------------------------------------------------------------------------------------
  // Event & broadcast
  // ---------------------------------------------------------------------------------------------

  @Override
  public void onListen(Object arguments, EventChannel.EventSink events) {
    eventSink = events;
    updateReceiver();
  }

  @Override
  public void onCancel(Object arguments) {
    eventSink = null;
    // Tanpa pendengar hasil pencarian tidak sampai ke siapa pun.
    if (scanning) stopDiscovery("stopped");
    updateReceiver();
  }

  private void emit(Map<String, Object> event) {
    EventChannel.EventSink sink = eventSink;
    if (sink != null) sink.success(event);
  }

  private final BroadcastReceiver receiver = new BroadcastReceiver() {
    @Override
    public void onReceive(Context context, Intent intent) {
      String action = intent.getAction();
      if (action == null) return;
      switch (action) {
        case BluetoothAdapter.ACTION_STATE_CHANGED: {
          int state = intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR);
          Map<String, Object> event = new HashMap<>();
          event.put("type", "power");
          event.put("state", powerStateName(state));
          emit(event);
          if (state != BluetoothAdapter.STATE_ON) {
            finishScan("adapterOff");
            if (state == BluetoothAdapter.STATE_TURNING_OFF || state == BluetoothAdapter.STATE_OFF) {
              finishPair(false, "adapter_off", "bluetooth turned off");
            }
          }
          break;
        }
        case BluetoothAdapter.ACTION_DISCOVERY_STARTED:
          if (scanning) {
            Map<String, Object> event = new HashMap<>();
            event.put("type", "scanStarted");
            emit(event);
          }
          break;
        case BluetoothAdapter.ACTION_DISCOVERY_FINISHED:
          finishScan(scanStopReason != null ? scanStopReason : "completed");
          break;
        case BluetoothDevice.ACTION_FOUND:
          if (scanning) onDeviceFound(intent);
          break;
        case BluetoothDevice.ACTION_BOND_STATE_CHANGED:
          onBondStateChanged(intent);
          break;
        default:
          break;
      }
    }
  };

  /** Receiver hanya terdaftar selama ada yang membutuhkannya (pendengar, pencarian, pairing). */
  private void updateReceiver() {
    boolean needed = eventSink != null || scanning || pendingPairResult != null;
    if (needed && !receiverRegistered) {
      IntentFilter filter = new IntentFilter();
      filter.addAction(BluetoothAdapter.ACTION_STATE_CHANGED);
      filter.addAction(BluetoothAdapter.ACTION_DISCOVERY_STARTED);
      filter.addAction(BluetoothAdapter.ACTION_DISCOVERY_FINISHED);
      filter.addAction(BluetoothDevice.ACTION_FOUND);
      filter.addAction(BluetoothDevice.ACTION_BOND_STATE_CHANGED);
      // Broadcast sistem tetap sampai ke receiver NOT_EXPORTED.
      ContextCompat.registerReceiver(context, receiver, filter,
          ContextCompat.RECEIVER_NOT_EXPORTED);
      receiverRegistered = true;
    } else if (!needed && receiverRegistered) {
      try {
        context.unregisterReceiver(receiver);
      } catch (IllegalArgumentException ignored) {
        // Sudah tidak terdaftar.
      }
      receiverRegistered = false;
    }
  }

  private boolean startSettings(Intent intent) {
    try {
      intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
      context.startActivity(intent);
      return true;
    } catch (Exception ex) {
      Log.w(TAG, "cannot open settings " + intent.getAction(), ex);
      return false;
    }
  }
}

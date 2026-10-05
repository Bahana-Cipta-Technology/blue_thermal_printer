package id.kakzaki.blue_thermal_printer.transport.bluetooth;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * Aturan prasyarat Bluetooth per operasi per versi Android -- sumber kebenaran tunggal untuk
 * {@link BluetoothControlChannel} dan pengecekan izin API lama. Java murni (tanpa Android
 * framework) supaya dites JUnit; tabel lengkapnya ada di {@code doc/bluetooth-control-design.md}.
 *
 * <p>Ringkasan izin runtime:
 * <ul>
 *   <li>API 31+: "Perangkat sekitar" ({@code BLUETOOTH_SCAN} + {@code BLUETOOTH_CONNECT}) untuk
 *       semua operasi. {@code BLUETOOTH_SCAN} dideklarasikan {@code neverForLocation}, jadi tanpa
 *       lokasi.</li>
 *   <li>API 23–30: hanya pencarian yang butuh izin runtime ({@code ACCESS_FINE_LOCATION}, yang
 *       sudah mencakup lokasi kasar). API 29–30 juga butuh layanan Lokasi menyala.</li>
 * </ul>
 */
public final class BluetoothRequirementPolicy {

  private BluetoothRequirementPolicy() {}

  public static final String PERMISSION_SCAN = "android.permission.BLUETOOTH_SCAN";
  public static final String PERMISSION_CONNECT = "android.permission.BLUETOOTH_CONNECT";
  public static final String PERMISSION_FINE_LOCATION = "android.permission.ACCESS_FINE_LOCATION";

  static final int SDK_M = 23;
  static final int SDK_Q = 29;
  static final int SDK_S = 31;
  static final int SDK_TIRAMISU = 33;

  public static final String OP_LIST_PAIRED = "listPaired";
  public static final String OP_TOGGLE = "toggle";
  public static final String OP_SCAN = "scan";
  public static final String OP_PAIR = "pair";
  public static final String OP_CONNECT = "connect";

  static final List<String> ALL_OPERATIONS = Collections.unmodifiableList(
      Arrays.asList(OP_LIST_PAIRED, OP_TOGGLE, OP_SCAN, OP_PAIR, OP_CONNECT));

  public static final String KIND_HARDWARE = "hardware";
  public static final String KIND_ACTIVITY = "activity";
  public static final String KIND_PERMISSION = "permission";
  public static final String KIND_ADAPTER = "adapterEnabled";
  public static final String KIND_LOCATION_SERVICE = "locationService";

  public static final String STATUS_SATISFIED = "satisfied";
  public static final String STATUS_MISSING = "missing";
  public static final String STATUS_PERMANENTLY_DENIED = "permanentlyDenied";

  public static final String RESOLUTION_NONE = "none";
  public static final String RESOLUTION_REQUEST_PERMISSION = "requestPermission";
  public static final String RESOLUTION_ENABLE_TRANSPORT = "enableTransport";
  public static final String RESOLUTION_OPEN_APP_SETTINGS = "openAppSettings";
  public static final String RESOLUTION_OPEN_LOCATION_SETTINGS = "openLocationSettings";

  /** Status satu izin runtime. */
  public enum PermissionState { GRANTED, DENIED, PERMANENTLY_DENIED }

  /** Izin runtime untuk daftar perangkat terpasang, nyala/mati, pairing, dan koneksi. */
  public static List<String> connectPermissions(int sdkInt) {
    return sdkInt >= SDK_S
        ? Arrays.asList(PERMISSION_SCAN, PERMISSION_CONNECT)
        : Collections.<String>emptyList();
  }

  /** Izin runtime untuk pencarian (discovery). */
  public static List<String> scanPermissions(int sdkInt) {
    if (sdkInt >= SDK_S) return Arrays.asList(PERMISSION_SCAN, PERMISSION_CONNECT);
    if (sdkInt >= SDK_M) return Collections.singletonList(PERMISSION_FINE_LOCATION);
    return Collections.emptyList();
  }

  /** Semua izin runtime yang mungkin dibutuhkan di [sdkInt]. */
  public static List<String> runtimePermissions(int sdkInt) {
    Set<String> all = new LinkedHashSet<>(connectPermissions(sdkInt));
    all.addAll(scanPermissions(sdkInt));
    return new ArrayList<>(all);
  }

  /** Pencarian di API 29–30 tidak menghasilkan apa pun selama layanan Lokasi mati. */
  public static boolean requiresLocationService(int sdkInt) {
    return sdkInt >= SDK_Q && sdkInt < SDK_S;
  }

  /** Kondisi perangkat saat ini, dikumpulkan oleh channel. */
  public static final class Snapshot {
    final int sdkInt;
    final boolean hasAdapter;
    final boolean adapterOn;
    final boolean activityAttached;
    final boolean locationEnabled;
    final Map<String, PermissionState> permissions;

    public Snapshot(int sdkInt, boolean hasAdapter, boolean adapterOn, boolean activityAttached,
        boolean locationEnabled, Map<String, PermissionState> permissions) {
      this.sdkInt = sdkInt;
      this.hasAdapter = hasAdapter;
      this.adapterOn = adapterOn;
      this.activityAttached = activityAttached;
      this.locationEnabled = locationEnabled;
      this.permissions = permissions;
    }

    PermissionState permission(String name) {
      PermissionState state = permissions.get(name);
      return state == null ? PermissionState.DENIED : state;
    }
  }

  /** Satu prasyarat beserta operasi yang membutuhkannya. */
  public static final class Requirement {
    public final String id;
    public final String kind;
    public final String status;
    public final String resolution;
    public final List<String> permissions;
    public final List<String> operations;

    Requirement(String id, String kind, String status, String resolution,
        List<String> permissions, List<String> operations) {
      this.id = id;
      this.kind = kind;
      this.status = status;
      this.resolution = resolution;
      this.permissions = permissions;
      this.operations = operations;
    }

    public boolean isSatisfied() {
      return STATUS_SATISFIED.equals(status);
    }
  }

  /**
   * Semua prasyarat yang berlaku di [snapshot], berurutan sesuai urutan penyelesaiannya:
   * hardware → activity → izin → adapter → layanan Lokasi. Prasyarat yang tidak berlaku di versi
   * Android ini tidak dimasukkan; yang sudah terpenuhi tetap dimasukkan (untuk checklist UI).
   */
  public static List<Requirement> evaluate(Snapshot snapshot) {
    List<Requirement> result = new ArrayList<>();
    if (!snapshot.hasAdapter) {
      result.add(new Requirement("hardware", KIND_HARDWARE, STATUS_MISSING, RESOLUTION_NONE,
          Collections.<String>emptyList(), ALL_OPERATIONS));
      return result;
    }
    result.add(new Requirement("hardware", KIND_HARDWARE, STATUS_SATISFIED, RESOLUTION_NONE,
        Collections.<String>emptyList(), ALL_OPERATIONS));

    Requirement permission = permissionRequirement(snapshot);

    // Dialog izin dan dialog nyalakan Bluetooth (API 33+) hanya bisa ditampilkan dari Activity.
    if (!snapshot.activityAttached) {
      Set<String> needsActivity = new LinkedHashSet<>();
      if (permission != null && RESOLUTION_REQUEST_PERMISSION.equals(permission.resolution)) {
        needsActivity.addAll(permission.operations);
      }
      if (snapshot.sdkInt >= SDK_TIRAMISU && !snapshot.adapterOn) needsActivity.add(OP_TOGGLE);
      if (!needsActivity.isEmpty()) {
        result.add(new Requirement("activity", KIND_ACTIVITY, STATUS_MISSING, RESOLUTION_NONE,
            Collections.<String>emptyList(), new ArrayList<>(needsActivity)));
      }
    }

    if (permission != null) result.add(permission);

    result.add(new Requirement("adapter", KIND_ADAPTER,
        snapshot.adapterOn ? STATUS_SATISFIED : STATUS_MISSING,
        snapshot.adapterOn ? RESOLUTION_NONE : RESOLUTION_ENABLE_TRANSPORT,
        Collections.<String>emptyList(),
        Arrays.asList(OP_LIST_PAIRED, OP_SCAN, OP_PAIR, OP_CONNECT)));

    if (requiresLocationService(snapshot.sdkInt)) {
      result.add(new Requirement("locationService", KIND_LOCATION_SERVICE,
          snapshot.locationEnabled ? STATUS_SATISFIED : STATUS_MISSING,
          snapshot.locationEnabled ? RESOLUTION_NONE : RESOLUTION_OPEN_LOCATION_SETTINGS,
          Collections.<String>emptyList(), Collections.singletonList(OP_SCAN)));
    }
    return result;
  }

  /**
   * Satu item per dialog izin yang dilihat pengguna: "Perangkat sekitar" di API 31+ (SCAN dan
   * CONNECT satu grup, satu dialog), atau lokasi di API 23–30. `null` bila tidak ada izin runtime.
   */
  private static Requirement permissionRequirement(Snapshot snapshot) {
    final String id;
    final List<String> permissions;
    final List<String> operations;
    if (snapshot.sdkInt >= SDK_S) {
      id = "nearbyDevices";
      permissions = connectPermissions(snapshot.sdkInt);
      operations = ALL_OPERATIONS;
    } else if (snapshot.sdkInt >= SDK_M) {
      id = "location";
      permissions = scanPermissions(snapshot.sdkInt);
      operations = Collections.singletonList(OP_SCAN);
    } else {
      return null;
    }

    boolean allGranted = true;
    boolean anyPermanent = false;
    for (String name : permissions) {
      PermissionState state = snapshot.permission(name);
      if (state != PermissionState.GRANTED) allGranted = false;
      if (state == PermissionState.PERMANENTLY_DENIED) anyPermanent = true;
    }
    final String status;
    final String resolution;
    if (allGranted) {
      status = STATUS_SATISFIED;
      resolution = RESOLUTION_NONE;
    } else if (anyPermanent) {
      status = STATUS_PERMANENTLY_DENIED;
      resolution = RESOLUTION_OPEN_APP_SETTINGS;
    } else {
      status = STATUS_MISSING;
      resolution = RESOLUTION_REQUEST_PERMISSION;
    }
    return new Requirement(id, KIND_PERMISSION, status, resolution, permissions, operations);
  }
}

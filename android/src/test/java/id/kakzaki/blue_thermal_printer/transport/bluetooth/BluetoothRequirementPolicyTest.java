package id.kakzaki.blue_thermal_printer.transport.bluetooth;

import static id.kakzaki.blue_thermal_printer.transport.bluetooth.BluetoothRequirementPolicy.PERMISSION_CONNECT;
import static id.kakzaki.blue_thermal_printer.transport.bluetooth.BluetoothRequirementPolicy.PERMISSION_FINE_LOCATION;
import static id.kakzaki.blue_thermal_printer.transport.bluetooth.BluetoothRequirementPolicy.PERMISSION_SCAN;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import id.kakzaki.blue_thermal_printer.transport.bluetooth.BluetoothRequirementPolicy.PermissionState;
import id.kakzaki.blue_thermal_printer.transport.bluetooth.BluetoothRequirementPolicy.Requirement;
import id.kakzaki.blue_thermal_printer.transport.bluetooth.BluetoothRequirementPolicy.Snapshot;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import org.junit.Test;

public class BluetoothRequirementPolicyTest {

  private static Map<String, PermissionState> permissions(Object... pairs) {
    Map<String, PermissionState> map = new HashMap<>();
    for (int i = 0; i < pairs.length; i += 2) {
      map.put((String) pairs[i], (PermissionState) pairs[i + 1]);
    }
    return map;
  }

  private static Requirement find(List<Requirement> list, String id) {
    for (Requirement requirement : list) {
      if (requirement.id.equals(id)) return requirement;
    }
    return null;
  }

  private static List<String> ids(List<Requirement> list) {
    String[] ids = new String[list.size()];
    for (int i = 0; i < ids.length; i++) ids[i] = list.get(i).id;
    return Arrays.asList(ids);
  }

  @Test
  public void runtimePermissionsPerSdk() {
    assertEquals(Collections.emptyList(), BluetoothRequirementPolicy.connectPermissions(28));
    assertEquals(Collections.emptyList(), BluetoothRequirementPolicy.connectPermissions(30));
    assertEquals(Arrays.asList(PERMISSION_SCAN, PERMISSION_CONNECT),
        BluetoothRequirementPolicy.connectPermissions(31));
    assertEquals(Collections.singletonList(PERMISSION_FINE_LOCATION),
        BluetoothRequirementPolicy.scanPermissions(28));
    assertEquals(Collections.singletonList(PERMISSION_FINE_LOCATION),
        BluetoothRequirementPolicy.scanPermissions(30));
    assertEquals(Arrays.asList(PERMISSION_SCAN, PERMISSION_CONNECT),
        BluetoothRequirementPolicy.scanPermissions(33));
    assertEquals(Collections.emptyList(), BluetoothRequirementPolicy.scanPermissions(22));
  }

  @Test
  public void noAdapterReportsOnlyHardware() {
    List<Requirement> list = BluetoothRequirementPolicy.evaluate(
        new Snapshot(33, false, false, true, true, permissions()));
    assertEquals(Collections.singletonList("hardware"), ids(list));
    assertEquals(BluetoothRequirementPolicy.STATUS_MISSING, list.get(0).status);
    assertEquals(BluetoothRequirementPolicy.ALL_OPERATIONS, list.get(0).operations);
  }

  @Test
  public void api28NeedsFineLocationOnlyForScan() {
    List<Requirement> list = BluetoothRequirementPolicy.evaluate(new Snapshot(28, true, true, true,
        false, permissions(PERMISSION_FINE_LOCATION, PermissionState.DENIED)));
    assertEquals(Arrays.asList("hardware", "location", "adapter"), ids(list));
    Requirement location = find(list, "location");
    assertEquals(Collections.singletonList(BluetoothRequirementPolicy.OP_SCAN), location.operations);
    assertEquals(BluetoothRequirementPolicy.RESOLUTION_REQUEST_PERMISSION, location.resolution);
    // Lokasi mati tidak relevan di API 28.
    assertNull(find(list, "locationService"));
  }

  @Test
  public void api30AlsoNeedsLocationService() {
    List<Requirement> list = BluetoothRequirementPolicy.evaluate(new Snapshot(30, true, true, true,
        false, permissions(PERMISSION_FINE_LOCATION, PermissionState.GRANTED)));
    assertEquals(Arrays.asList("hardware", "location", "adapter", "locationService"), ids(list));
    assertTrue(find(list, "location").isSatisfied());
    Requirement service = find(list, "locationService");
    assertEquals(BluetoothRequirementPolicy.STATUS_MISSING, service.status);
    assertEquals(BluetoothRequirementPolicy.RESOLUTION_OPEN_LOCATION_SETTINGS, service.resolution);
  }

  @Test
  public void api31UsesNearbyDevicesForEveryOperationWithoutLocation() {
    List<Requirement> list = BluetoothRequirementPolicy.evaluate(new Snapshot(31, true, false, true,
        false, permissions(PERMISSION_SCAN, PermissionState.GRANTED,
            PERMISSION_CONNECT, PermissionState.DENIED)));
    assertEquals(Arrays.asList("hardware", "nearbyDevices", "adapter"), ids(list));
    Requirement nearby = find(list, "nearbyDevices");
    assertEquals(BluetoothRequirementPolicy.ALL_OPERATIONS, nearby.operations);
    assertEquals(BluetoothRequirementPolicy.STATUS_MISSING, nearby.status);
    assertEquals(BluetoothRequirementPolicy.RESOLUTION_ENABLE_TRANSPORT,
        find(list, "adapter").resolution);
  }

  @Test
  public void permanentDenialPointsToAppSettings() {
    List<Requirement> list = BluetoothRequirementPolicy.evaluate(new Snapshot(33, true, true, true,
        false, permissions(PERMISSION_SCAN, PermissionState.PERMANENTLY_DENIED,
            PERMISSION_CONNECT, PermissionState.DENIED)));
    Requirement nearby = find(list, "nearbyDevices");
    assertEquals(BluetoothRequirementPolicy.STATUS_PERMANENTLY_DENIED, nearby.status);
    assertEquals(BluetoothRequirementPolicy.RESOLUTION_OPEN_APP_SETTINGS, nearby.resolution);
  }

  @Test
  public void missingActivityBlocksPermissionDialogAndEnableDialog() {
    List<Requirement> list = BluetoothRequirementPolicy.evaluate(new Snapshot(33, true, false,
        false, false, permissions(PERMISSION_SCAN, PermissionState.DENIED,
            PERMISSION_CONNECT, PermissionState.DENIED)));
    assertEquals(Arrays.asList("hardware", "activity", "nearbyDevices", "adapter"), ids(list));
    assertEquals(BluetoothRequirementPolicy.ALL_OPERATIONS, find(list, "activity").operations);
  }

  @Test
  public void missingActivityIsIrrelevantWhenNothingNeedsADialog() {
    List<Requirement> list = BluetoothRequirementPolicy.evaluate(new Snapshot(33, true, true,
        false, false, permissions(PERMISSION_SCAN, PermissionState.GRANTED,
            PERMISSION_CONNECT, PermissionState.GRANTED)));
    assertNull(find(list, "activity"));
  }

  @Test
  public void missingActivityOnApi28OnlyBlocksScan() {
    List<Requirement> list = BluetoothRequirementPolicy.evaluate(new Snapshot(28, true, false,
        false, false, permissions(PERMISSION_FINE_LOCATION, PermissionState.DENIED)));
    // Di API 28 enable() langsung, tanpa dialog -- toggle tidak butuh Activity.
    assertEquals(Collections.singletonList(BluetoothRequirementPolicy.OP_SCAN),
        find(list, "activity").operations);
  }
}

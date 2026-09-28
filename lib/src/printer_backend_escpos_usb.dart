import 'escpos_transport.dart';
import 'printer_device.dart';
import 'result.dart';

/// Kunci perangkat USB yang stabil saat kabel dicabut-colok:
/// `usb:<vendorId>:<productId>` (nama node `/dev/bus/usb/...` berubah tiap
/// dicolok ulang, nomor seri butuh izin untuk dibaca).
String usbDeviceKey(int vendorId, int productId) => 'usb:$vendorId:$productId';

/// Kebalikan [usbDeviceKey]: `(vendorId, productId)` atau `null`.
(int, int)? parseUsbDeviceKey(String key) {
  final parts = key.split(':');
  if (parts.length != 3 || parts[0] != 'usb') return null;
  final vendorId = int.tryParse(parts[1]);
  final productId = int.tryParse(parts[2]);
  if (vendorId == null || productId == null) return null;
  return (vendorId, productId);
}

/// Transport ESC/POS lewat USB host (bulk transfer) -- native
/// `transport/usb/UsbPrinterChannel.java`, channel
/// `blue_thermal_printer/escpos_usb`.
///
/// Izin akses per perangkat diminta sistem saat [connect] pertama (dialog
/// Android); penolakan dilaporkan sebagai [PrinterFailure.isPermissionDenied].
class UsbEscposTransport extends ChannelEscposTransport {
  UsbEscposTransport({super.invoke}) : super(channelName);

  static const channelName = 'blue_thermal_printer/escpos_usb';

  @override
  String get displayName => 'Printer USB (ESC/POS)';

  /// Perangkat mendukung mode USB host.
  @override
  Future<bool> isEnabled() async => await invoke('isAvailable') == true;

  /// Izin per perangkat diminta saat connect, bukan di tingkat transport.
  @override
  Future<bool> isPermissionGranted() async => true;

  @override
  Future<List<PrinterDevice>> discover() async {
    final raw = await invoke('devices');
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map &&
            item['vendorId'] is int &&
            item['productId'] is int)
          PrinterDevice(
            name: (item['name'] as String?)?.trim().isNotEmpty == true
                ? (item['name'] as String).trim()
                : 'Printer USB',
            macAddress: usbDeviceKey(
              item['vendorId'] as int,
              item['productId'] as int,
            ),
          ),
    ];
  }

  /// Hanya printer yang masih tercolok yang disambung ulang otomatis.
  @override
  bool get requiresDiscoveredDevice => true;

  @override
  Future<PrinterFailure?> connect(PrinterDevice device) async {
    final ids = parseUsbDeviceKey(device.macAddress);
    if (ids == null) {
      return const PrinterFailure(
        'Printer USB tidak dikenali. Pilih printer lagi.',
        requiresDeviceSelection: true,
      );
    }
    final outcome = await invoke('connect', {
      'vendorId': ids.$1,
      'productId': ids.$2,
    });
    return switch (outcome) {
      'connected' => null,
      'permission_denied' => const PrinterFailure(
        'Izin akses printer USB ditolak. Pilih printer lagi lalu izinkan.',
        isPermissionDenied: true,
      ),
      'not_found' => PrinterFailure(deviceGoneMessage, requiresDeviceSelection: true),
      _ => const PrinterFailure('Gagal terhubung ke printer USB.'),
    };
  }

  @override
  Future<void> openSettings() async {
    // Tidak ada setelan sistem untuk USB host.
  }

  @override
  String get disabledMessage => 'Perangkat ini tidak mendukung printer USB.';

  @override
  String get permissionDeniedMessage => 'Izin akses printer USB ditolak.';

  @override
  String get deviceGoneMessage =>
      'Printer USB tidak tersambung. Colokkan kabel lalu pilih printer lagi.';
}

import 'dart:typed_data';

import 'escpos_transport.dart';
import 'paper_width.dart';
import 'printer_backend.dart';
import 'printer_backend_escpos.dart';
import 'printer_backend_escpos_usb.dart';
import 'printer_capabilities.dart';
import 'printer_device.dart';
import 'printer_status.dart';
import 'receipt.dart';
import 'receipt_renderer.dart';
import 'result.dart';

/// Pasangan `(vendorId, productId)` printer USB internal perangkat iMin SDK 1.0
/// yang sudah terverifikasi di hardware.
///
/// - `(0x0519, 0x2013)`: iMin D1 (Android 11), printer "ALT althicoA726", kelas
///   USB Printer dua arah. Diuji 7 Okt 2026 (`doc/hardware-test-2026-10.md`).
///
/// Model lain cukup ditambahkan di sini setelah ID-nya dibaca dari
/// `adb shell dumpsys usb` dan dicetak lewat app uji `example/`.
const Set<(int, int)> kIminUsbPrinterIds = {(0x0519, 0x2013)};

/// Transport USB yang hanya melihat printer internal iMin ([kIminUsbPrinterIds]).
class IminUsbEscposTransport extends UsbEscposTransport {
  IminUsbEscposTransport({super.invoke, Set<(int, int)>? printerIds})
    : _printerIds = printerIds ?? kIminUsbPrinterIds;

  final Set<(int, int)> _printerIds;

  @override
  String get displayName => 'Printer Bawaan iMin (USB)';

  @override
  Future<List<PrinterDevice>> discover() async => [
    for (final device in await super.discover())
      if (_isInternal(device))
        PrinterDevice(name: 'Printer Bawaan iMin', macAddress: device.macAddress),
  ];

  bool _isInternal(PrinterDevice device) {
    final ids = parseUsbDeviceKey(device.macAddress);
    return ids != null && _printerIds.contains(ids);
  }

  @override
  String get deviceGoneMessage => PrinterBackendIminUsb.notFoundMessage;
}

/// Printer bawaan perangkat iMin SDK 1.0 (mis. D1): printer USB internal yang
/// diakses langsung, sama seperti pustaka resmi iMin SDK 1.0 (`IminPrintUtils`).
///
/// Perangkat ini TIDAK punya servis iMin SDK 2.0 (`com.imin.printerservice`),
/// jadi [PrinterBackendImin] tidak bisa dipakai. Printer Bluetooth virtual
/// "BluetoothPrinter" (00:11:22:33:44:55) di perangkat yang sama menerima data
/// tetapi gagal meneruskannya ke printer (`UsbDriver: Length -1`), sehingga
/// jalur itu juga tidak dipakai.
///
/// Semua logika ESC/POS (pre/post-check `DLE EOT`, [PrintJobGate], auto cut,
/// lebar kertas, renderer) didelegasikan ke [PrinterBackendEscpos]; kelas ini
/// hanya menghilangkan pemilihan perangkat: tidak ada pairing dan
/// `ensureConnected` selalu menyambung ke printer internal.
///
/// Sambungan pertama per boot memunculkan dialog izin USB sistem. Dialog itu
/// sengaja tidak dipicu dari [detectBuiltInPrinterVendor] (lihat di sana).
class PrinterBackendIminUsb implements PrinterBackend {
  PrinterBackendIminUsb({
    EscposChannelInvoke? invoke,
    Set<(int, int)>? printerIds,
    ReceiptRenderer renderer = const ReceiptRenderer(),
    Future<List<int>> Function(Receipt)? encode,
    Duration printTimeout = const Duration(seconds: 30),
    Duration stuckAfter = const Duration(seconds: 30),
  }) : _inner = PrinterBackendEscpos.withTransport(
         IminUsbEscposTransport(invoke: invoke, printerIds: printerIds),
         renderer: renderer,
         encode: encode,
         printTimeout: printTimeout,
         stuckAfter: stuckAfter,
       );

  static const notFoundMessage =
      'Printer bawaan iMin tidak ditemukan di perangkat ini.';

  final PrinterBackendEscpos _inner;

  @override
  String get displayName => 'Printer Bawaan iMin (USB)';

  @override
  bool get requiresPairing => false;

  /// true bila printer internal terlihat di bus USB (belum tentu tersambung).
  @override
  Future<bool> isAvailable() async => (await discoverDevices()).isNotEmpty;

  @override
  Future<List<PrinterDevice>> discoverDevices() => _inner.discoverDevices();

  @override
  Future<PrinterResult<void>> connect(PrinterDevice device) =>
      _inner.connect(device);

  @override
  Future<void> disconnect() => _inner.disconnect();

  @override
  Future<bool> isConnected() => _inner.isConnected();

  @override
  Future<PrinterResult<PrinterStatus>> checkStatus() => _inner.checkStatus();

  /// [lastDevice] diabaikan: hanya ada satu printer internal.
  @override
  Future<PrinterResult<PrinterDevice>> ensureConnected({
    PrinterDevice? lastDevice,
  }) async {
    final List<PrinterDevice> devices;
    try {
      devices = await discoverDevices();
    } catch (_) {
      return const PrinterErr(PrinterFailure(notFoundMessage));
    }
    if (devices.isEmpty) {
      return const PrinterErr(PrinterFailure(notFoundMessage));
    }
    final result = await _inner.ensureConnected(lastDevice: devices.first);
    return switch (result) {
      PrinterOk() => result,
      // Tidak ada perangkat yang bisa dipilih ulang pengguna untuk printer
      // bawaan, jadi tanda "pilih printer lagi" tidak diteruskan.
      PrinterErr(:final failure) => PrinterErr(
        PrinterFailure(
          failure.message,
          isPermissionDenied: failure.isPermissionDenied,
        ),
      ),
    };
  }

  @override
  Future<PrinterCapabilities> capabilities() => _inner.capabilities();

  @override
  bool get supportsPaperWidthSetting => _inner.supportsPaperWidthSetting;

  @override
  void setPaperWidth(PaperWidthSetting setting) => _inner.setPaperWidth(setting);

  @override
  Future<Uint8List> preview(Receipt receipt) => _inner.preview(receipt);

  @override
  Future<PrinterResult<PrintDelivery>> printReceipt(Receipt receipt) =>
      _inner.printReceipt(receipt);

  @override
  Future<void> openSystemSettings() => _inner.openSystemSettings();
}

import 'dart:async';
import 'dart:developer' as developer;
import 'dart:typed_data';

import 'package:app_settings/app_settings.dart';

import '../blue_thermal_printer.dart';
import 'printer_backend.dart';
import 'printer_device.dart';
import 'printer_status.dart';
import 'receipt.dart';
import 'receipt_renderer.dart';
import 'result.dart';

/// Implementasi [PrinterBackend] memakai Bluetooth Classic generik (profil
/// SPP + perintah ESC/POS), lewat [BlueThermalPrinter] yang sudah ada di
/// package ini sendiri.
///
/// Pengiriman tunggal (busy-lock); timeout tidak membatalkan pekerjaan
/// native yang tertunda. Setiap pemanggilan dibungkus try/catch dan
/// diperlakukan sebagai "tidak tersedia" di platform yang tidak didukung
/// plugin (mis. Linux desktop), sama seperti pola `DeviceCameraService` di
/// app konsumen.
class PrinterBackendEscpos implements PrinterBackend {
  PrinterBackendEscpos({
    ReceiptRenderer renderer = const ReceiptRenderer(),
    Future<bool> Function()? isBluetoothOn,
    Future<bool> Function()? isPermissionGranted,
    Future<List<PrinterDevice>> Function()? discover,
    Future<bool> Function(PrinterDevice)? doConnect,
    Future<void> Function()? doDisconnect,
    Future<bool> Function()? connected,
    Future<bool> Function(List<int>)? write,
    Future<List<int>> Function(Receipt)? encode,
    Future<PrinterStatus> Function()? checkStatus,
    Future<void> Function()? openSettings,
  }) : _isBluetoothOn =
           isBluetoothOn ??
           (() async => await BlueThermalPrinter.instance.isOn ?? false),
       _isPermissionGranted =
           isPermissionGranted ??
           (() async =>
               await BlueThermalPrinter.instance.isPermissionBluetoothGranted ??
               false),
       _discover =
           discover ??
           (() async {
             final paired = await BlueThermalPrinter.instance
                 .getBondedDevices();
             return paired
                 .map(
                   (device) => PrinterDevice(
                     name: device.name ?? '',
                     macAddress: device.address ?? '',
                   ),
                 )
                 .toList();
           }),
       _doConnect =
           doConnect ??
           ((device) async {
             final connected = await BlueThermalPrinter.instance.connect(
               BluetoothDevice(device.name, device.macAddress),
             );
             return connected == true;
           }),
       _doDisconnect =
           doDisconnect ?? (() => BlueThermalPrinter.instance.disconnect()),
       _connected =
           connected ??
           (() async => await BlueThermalPrinter.instance.isConnected ?? false),
       _write =
           write ??
           ((bytes) async =>
               await BlueThermalPrinter.instance.writeBytes(
                 Uint8List.fromList(bytes),
               ) ??
               false),
       _encode = encode ?? renderer.encode,
       _checkStatus =
           checkStatus ??
           (() async {
             try {
               final raw = await BlueThermalPrinter.instance
                   .queryPrinterStatus(BlueThermalPrinter.statusTypeOffline);
               if (raw == null) return PrinterStatus.unknown;
               return PrinterStatus.fromOfflineStatusByte(raw);
             } catch (_) {
               return PrinterStatus.unknown;
             }
           }),
       _openSettings =
           openSettings ??
           (() => AppSettings.openAppSettings(type: AppSettingsType.bluetooth));

  final Future<bool> Function() _isBluetoothOn;
  final Future<bool> Function() _isPermissionGranted;
  final Future<List<PrinterDevice>> Function() _discover;
  final Future<bool> Function(PrinterDevice) _doConnect;
  final Future<void> Function() _doDisconnect;
  final Future<bool> Function() _connected;
  final Future<bool> Function(List<int>) _write;
  final Future<List<int>> Function(Receipt) _encode;
  final Future<PrinterStatus> Function() _checkStatus;
  final Future<void> Function() _openSettings;

  bool _busy = false;

  @override
  String get displayName => 'Bluetooth ESC/POS';

  @override
  bool get requiresPairing => true;

  @override
  Future<bool> isAvailable() async {
    try {
      return await _isBluetoothOn();
    } catch (error) {
      _warn('Status Bluetooth tidak dapat diperiksa', error);
      return false;
    }
  }

  @override
  Future<List<PrinterDevice>> discoverDevices() async {
    try {
      return await _discover();
    } catch (error) {
      _warn('Daftar perangkat berpasangan gagal dibaca', error);
      return const <PrinterDevice>[];
    }
  }

  @override
  Future<PrinterResult<void>> connect(PrinterDevice device) async {
    try {
      if (!await _isPermissionGranted()) {
        return const PrinterErr(
          PrinterFailure(
            'Izin Bluetooth ditolak. Berikan izin lewat Setelan.',
            isPermissionDenied: true,
          ),
        );
      }
      if (!await _isBluetoothOn()) {
        return const PrinterErr(PrinterFailure('Bluetooth belum aktif.'));
      }
      if (!await _doConnect(device)) {
        return const PrinterErr(
          PrinterFailure('Gagal terhubung ke printer.'),
        );
      }
      return const PrinterOk(null);
    } catch (error) {
      _warn('Koneksi printer gagal', error);
      return const PrinterErr(PrinterFailure('Gagal terhubung ke printer.'));
    }
  }

  @override
  Future<void> disconnect() async {
    try {
      await _doDisconnect();
    } catch (error) {
      _warn('Memutuskan koneksi printer gagal', error);
    }
  }

  @override
  Future<bool> isConnected() async {
    try {
      return await _connected();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<PrinterResult<PrinterStatus>> checkStatus() async {
    if (!await isConnected()) {
      return const PrinterErr(PrinterFailure('Printer belum terhubung.'));
    }
    try {
      return PrinterOk(await _checkStatus());
    } catch (error) {
      _warn('Query status printer gagal', error);
      return const PrinterOk(PrinterStatus.unknown);
    }
  }

  @override
  Future<PrinterResult<void>> printReceipt(Receipt receipt) async {
    if (_busy) {
      return const PrinterErr(
        PrinterFailure('Printer masih memproses pengiriman sebelumnya.'),
      );
    }
    _busy = true;
    final operation = _send(receipt);
    // Kunci tetap dipegang hingga pekerjaan sebenarnya selesai, termasuk
    // setelah timeout di bawah.
    unawaited(
      operation.then((_) {
        _busy = false;
      }),
    );
    return operation.timeout(
      const Duration(seconds: 30),
      onTimeout: () => const PrinterErr(
        PrinterFailure(
          'Pengiriman melewati batas waktu. Periksa kertas sebelum mencoba ulang.',
        ),
      ),
    );
  }

  Future<PrinterResult<void>> _send(Receipt receipt) async {
    try {
      if (!await _connected()) {
        return const PrinterErr(
          PrinterFailure('Printer belum terhubung. Buka Koneksi Printer.'),
        );
      }
      // Cek status LEBIH DULU, sebelum satu byte pun terkirim -- untuk
      // skenario paling umum (kertas sudah habis sebelum operator mencoba
      // cetak), ini mencegah data ikut nyangkut di buffer printer sama
      // sekali. Status `unknown` (banyak printer clone tidak mendukung
      // `DLE EOT`) sengaja TIDAK memblokir -- `hasKnownProblem` sudah
      // dirancang begitu.
      final preStatus = await _checkStatus();
      if (preStatus.hasKnownProblem) {
        return PrinterErr(PrinterFailure(preStatus.problemMessage!));
      }
      final bytes = await _encode(receipt);
      if (!await _write(bytes)) {
        return const PrinterErr(
          PrinterFailure(
            'Pengiriman gagal. Periksa kertas sebelum mencoba ulang.',
          ),
        );
      }
      // Penulisan ke socket Bluetooth sukses selama koneksi masih hidup,
      // tanpa peduli printer sungguhan punya kertas/cover tertutup/dalam
      // kondisi error -- query status sekali lagi di sini supaya "byte
      // terkirim" tidak keliru dilaporkan sebagai "berhasil dicetak".
      final status = await _checkStatus();
      if (status.hasKnownProblem) {
        // Bersihkan buffer printer dari data yang baru saja gagal tercetak
        // sekarang juga -- best-effort, jangan sampai gagal di sini malah
        // menutupi pesan galat yang sebenarnya. Kalau operator tidak pernah
        // mencoba lagi, sisa data tidak menumpuk menunggu percobaan
        // berikutnya yang mungkin tidak pernah terjadi.
        try {
          await _write(const [27, 64]); // ESC @ (Initialize Printer)
        } catch (_) {
          // Diabaikan -- ini cuma kebersihan, bukan penentu hasil.
        }
        return PrinterErr(PrinterFailure(status.problemMessage!));
      }
      return const PrinterOk(null);
    } catch (_) {
      return const PrinterErr(
        PrinterFailure(
          'Tidak dapat mengirim struk. Periksa koneksi dan kertas sebelum mencoba ulang.',
        ),
      );
    }
  }

  @override
  Future<void> openSystemSettings() async {
    try {
      await _openSettings();
    } catch (error) {
      _warn('Gagal membuka Setelan Bluetooth', error);
    }
  }

  void _warn(String message, Object error) =>
      developer.log(message, name: 'PrinterBackendEscpos', error: error);
}

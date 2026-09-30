import 'package:flutter/services.dart';

import 'printer_device.dart';
import 'printer_status.dart';
import 'result.dart';

/// Jalur byte ke printer ESC/POS (Bluetooth, LAN, USB) di bawah
/// `PrinterBackendEscpos`.
///
/// Transport hanya memindahkan byte dan menjawab pertanyaan soal koneksinya
/// sendiri. Semua logika ESC/POS -- pre-/post-check status `DLE EOT`, reset
/// `ESC @`, busy-lock, pelacakan printer yang tidak menjawab status -- ada
/// di `PrinterBackendEscpos` SEKALI untuk semua transport. Setiap method
/// boleh melempar; backend yang menangkapnya.
abstract class EscposTransport {
  const EscposTransport();

  /// Nama tampilan backend dengan transport ini, mis. "Bluetooth ESC/POS".
  String get displayName;

  /// Transport aktif/tersedia (radio Bluetooth menyala, USB host ada, ...).
  Future<bool> isEnabled();

  /// Izin tingkat transport sudah diberikan, tanpa memicu dialog izin.
  Future<bool> isPermissionGranted();

  /// Perangkat yang bisa dipilih pengguna.
  Future<List<PrinterDevice>> discover();

  /// `true` bila perangkat tersimpan hanya boleh disambung ulang selama
  /// masih muncul di [discover] (mis. masih dipasangkan / masih tercolok).
  bool get requiresDiscoveredDevice;

  /// Buka koneksi ke [device]. `null` = berhasil; selain itu kegagalan yang
  /// dilaporkan apa adanya ke pemanggil.
  Future<PrinterFailure?> connect(PrinterDevice device);

  Future<void> disconnect();

  /// Koneksi masih hidup (tanpa menulis ke printer bila transport bisa
  /// mengetahuinya sendiri).
  Future<bool> isConnected();

  /// Tulis [bytes] ke printer. `false` = penulisan fisik gagal.
  Future<bool> write(List<int> bytes);

  /// Status offline printer (`DLE EOT 2`). Printer yang tidak menjawab →
  /// [PrinterStatus.unknown] (semua field `null`), bukan galat.
  Future<PrinterStatus> queryStatus();

  /// Byte Type ID dari `GS I 2`, atau `null` bila printer tidak menjawab
  /// (atau transport tidak mendukung query ini). Default `null`, supaya
  /// transport yang belum mengimplementasikannya tidak pernah memicu cut.
  Future<int?> queryPrinterTypeId() async => null;

  /// Byte status galat `DLE EOT 3`, atau `null` bila printer tidak menjawab.
  Future<int?> queryErrorStatus() async => null;

  /// Buka setelan sistem yang relevan untuk transport ini (boleh no-op).
  Future<void> openSettings();

  /// Pesan saat [isEnabled] `false`.
  String get disabledMessage;

  /// Pesan saat [isPermissionGranted] `false`.
  String get permissionDeniedMessage;

  /// Pesan saat perangkat tersimpan tidak lagi muncul di [discover].
  String get deviceGoneMessage =>
      'Printer terakhir tidak lagi tersedia. Pilih printer lagi.';
}

/// Tipe query `DLE EOT n` untuk status offline (kertas/cover/error) -- sama
/// dengan `BlueThermalPrinter.statusTypeOffline`.
const escposOfflineStatusType = 2;

/// Tipe query `DLE EOT n` untuk penyebab galat (bit 3 = galat autocutter).
const escposErrorStatusType = 3;

/// `n` pada `GS I n` untuk Type ID.
const escposPrinterTypeIdType = 2;

/// Type ID `GS I 2` bit 1: autocutter terpasang.
bool escposTypeIdHasAutoCutter(int typeId) => typeId & 0x02 != 0;

/// Status `DLE EOT 3` bit 3: galat autocutter.
bool escposErrorStatusHasCutterError(int errorStatus) =>
    errorStatus & 0x08 != 0;

/// `GS V 66 0`: feed sampai posisi pisau lalu partial cut. Printer sendiri
/// yang tahu jarak kepala cetak ke pisau, jadi baris terakhir tidak
/// terpotong.
const escposFeedAndPartialCut = <int>[0x1D, 0x56, 66, 0];

/// Terjemahkan byte respons `DLE EOT 2` mentah (atau `null` = tidak ada
/// jawaban) jadi [PrinterStatus].
PrinterStatus escposOfflineStatus(int? raw) =>
    raw == null ? PrinterStatus.unknown : PrinterStatus.tryFromOfflineStatusByte(raw);

/// Pemanggil method channel native, bisa diganti di test.
typedef EscposChannelInvoke =
    Future<Object?> Function(String method, [Map<String, Object?>? arguments]);

/// Dasar transport ESC/POS yang native-nya berupa satu method channel dengan
/// kosakata bersama: `disconnect`, `isConnected`, `writeBytes{bytes}`,
/// `queryStatus{type}` (byte respons `DLE EOT` atau `null`).
abstract class ChannelEscposTransport extends EscposTransport {
  ChannelEscposTransport(String channelName, {EscposChannelInvoke? invoke})
    : invoke = invoke ?? _channelInvoker(MethodChannel(channelName));

  /// Pemanggil channel native transport ini.
  final EscposChannelInvoke invoke;

  static EscposChannelInvoke _channelInvoker(MethodChannel channel) =>
      (method, [arguments]) => channel.invokeMethod<Object?>(method, arguments);

  @override
  Future<void> disconnect() => invoke('disconnect');

  @override
  Future<bool> isConnected() async => await invoke('isConnected') == true;

  @override
  Future<bool> write(List<int> bytes) async =>
      await invoke('writeBytes', {'bytes': Uint8List.fromList(bytes)}) == true;

  @override
  Future<PrinterStatus> queryStatus() async {
    try {
      final raw = await invoke('queryStatus', {'type': escposOfflineStatusType});
      return escposOfflineStatus(raw is int ? raw : null);
    } catch (_) {
      return PrinterStatus.unknown;
    }
  }

  @override
  Future<int?> queryPrinterTypeId() =>
      _queryByte('queryPrinterId', escposPrinterTypeIdType);

  @override
  Future<int?> queryErrorStatus() =>
      _queryByte('queryStatus', escposErrorStatusType);

  Future<int?> _queryByte(String method, int type) async {
    try {
      final raw = await invoke(method, {'type': type});
      return raw is int ? raw : null;
    } catch (_) {
      return null;
    }
  }
}

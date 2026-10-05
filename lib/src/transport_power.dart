import 'result.dart';

/// Status daya transport (mis. radio Bluetooth).
enum TransportPowerState {
  /// Perangkat tidak punya transport ini.
  unsupported,
  off,
  turningOn,
  on,
  turningOff,
}

/// Hasil permintaan [TransportPowerControl.setEnabled].
enum PowerToggleOutcome {
  /// Sistem menerima permintaan; perubahan status menyusul lewat
  /// [TransportPowerControl.watchPowerState].
  changed,

  /// Transport sudah dalam status yang diminta.
  alreadyInState,

  /// Pengguna menolak dialog sistem (nyalakan Bluetooth di Android 13+).
  declinedByUser,

  /// Android tidak mengizinkan app mengubahnya (matikan Bluetooth di
  /// Android 13+) -- Setelan sistem dibuka supaya pengguna mengubahnya sendiri.
  openedSystemSettings,
}

/// Kemampuan opsional: menyalakan/mematikan transport dari dalam app.
///
/// Didapat lewat `printerFeature<TransportPowerControl>(backend)`; backend
/// tanpa transport yang bisa dinyalakan (printer bawaan, LAN) mengembalikan
/// `null`.
abstract interface class TransportPowerControl {
  /// Status saat ini. Tidak pernah melempar.
  Future<TransportPowerState> powerState();

  /// Perubahan status sejak didengarkan (tanpa nilai awal -- pakai
  /// [powerState] untuk itu).
  Stream<TransportPowerState> watchPowerState();

  /// Minta transport menyala/mati. Bisa memunculkan dialog sistem atau
  /// membuka Setelan (lihat [PowerToggleOutcome]); [PrinterErr] bila izin
  /// belum ada ([PrinterFailure.isPermissionDenied]) atau tidak didukung.
  Future<PrinterResult<PowerToggleOutcome>> setEnabled(bool enabled);
}

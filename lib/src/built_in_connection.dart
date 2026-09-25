import 'printer_backend.dart';
import 'printer_device.dart';
import 'result.dart';

/// Menjalankan satu pekerjaan async sekaligus: panggilan bersamaan berbagi
/// hasil pekerjaan yang sedang berjalan alih-alih memulai percobaan native
/// baru.
class SingleFlight<T> {
  Future<T>? _pending;

  Future<T> run(Future<T> Function() task) {
    final pending = _pending;
    if (pending != null) return pending;
    final attempt = task();
    _pending = attempt;
    return attempt.whenComplete(() {
      if (identical(_pending, attempt)) _pending = null;
    });
  }
}

/// Implementasi bersama `ensureConnected` untuk printer bawaan (Sunmi,
/// Xcheng, iMin): servis yang sudah siap langsung dianggap terhubung,
/// selain itu [PrinterBackend.connect] ke satu-satunya [device].
///
/// Sengaja memeriksa [PrinterBackend.isAvailable] (query ke servis, bukan
/// tulis ke printer) sebelum connect, dan tidak pernah menggerbang
/// [PrinterBackend.discoverDevices] di `isAvailable` -- printer bawaan baru
/// "available" SETELAH bind, jadi menggerbangnya membuat printer tidak
/// pernah tersambung (deadlock yang dulu harus dipahami tiap app konsumen).
Future<PrinterResult<PrinterDevice>> ensureBuiltInConnected(
  PrinterBackend backend,
  PrinterDevice device,
) async {
  try {
    if (await backend.isAvailable()) return PrinterOk(device);
    return (await backend.connect(device)).map((_) => device);
  } catch (_) {
    return const PrinterErr(
      PrinterFailure('Gagal terhubung ke printer bawaan.'),
    );
  }
}

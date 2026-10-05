import 'printer_backend.dart';
import 'printer_backend_escpos.dart';
import 'printer_backend_fallback.dart';

/// Kemampuan opsional [T] milik [backend] (mis. `TransportPowerControl`,
/// `PrinterDeviceScanner`, `TransportPrerequisites`), atau `null` bila
/// backend/transport-nya tidak punya kemampuan itu.
///
/// Satu-satunya tempat yang tahu cara menembus komposisi backend:
/// [PrinterBackendEscpos] meneruskan ke transport-nya, dan
/// [PrinterBackendFallback] ke backend yang sedang aktif. App konsumen tidak
/// perlu (dan tidak boleh) melakukan cast sendiri.
T? printerFeature<T extends Object>(PrinterBackend backend) {
  if (backend is T) return backend as T;
  return switch (backend) {
    PrinterBackendEscpos() => backend.feature<T>(),
    PrinterBackendFallback() => printerFeature<T>(backend.active),
    _ => null,
  };
}

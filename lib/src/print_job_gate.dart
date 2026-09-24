import 'dart:async';

import 'result.dart';

/// Kunci pengiriman tunggal (busy-lock) + batas waktu untuk satu pekerjaan
/// cetak, dipakai bersama oleh semua implementasi `PrinterBackend` supaya
/// semantiknya identik lintas vendor dan tidak diduplikasi di tiap backend.
///
/// Semantik:
/// - Selama satu pekerjaan berjalan, pekerjaan berikutnya langsung ditolak
///   dengan [PrinterErr] ([busyMessage]).
/// - Pemanggil menerima [PrinterErr] ([timeoutMessage]) setelah [timeout],
///   tapi kunci TETAP dipegang sampai pekerjaan native yang sebenarnya
///   selesai -- timeout di Dart tidak membatalkan pekerjaan native, jadi
///   melepas kunci lebih awal berisiko mengirim dua struk bertumpuk.
/// - Bila pekerjaan itu masih belum selesai [stuckAfter] setelah timeout,
///   [onStuck] dipanggil (mis. menutup socket supaya write native yang
///   macet terlepas) dan kunci dilepas paksa -- tanpa ini backend bisa
///   terkunci "masih memproses" selamanya sampai app di-restart.
class PrintJobGate {
  PrintJobGate({
    this.timeout = const Duration(seconds: 30),
    this.stuckAfter = const Duration(seconds: 30),
    this.onStuck,
  });

  static const busyMessage = 'Printer masih memproses pengiriman sebelumnya.';
  static const timeoutMessage =
      'Pengiriman melewati batas waktu. Periksa kertas sebelum mencoba ulang.';

  final Duration timeout;
  final Duration stuckAfter;
  final FutureOr<void> Function()? onStuck;

  /// Penanda pekerjaan yang sedang memegang kunci; `null` berarti bebas.
  /// Berupa objek (bukan `bool`) supaya pekerjaan lama yang akhirnya selesai
  /// setelah kunci dilepas paksa tidak ikut melepas kunci pekerjaan baru.
  Object? _holder;

  bool get isBusy => _holder != null;

  Future<PrinterResult<void>> run(Future<PrinterResult<void>> Function() job) {
    if (_holder != null) {
      return Future.value(const PrinterErr(PrinterFailure(busyMessage)));
    }
    final holder = Object();
    _holder = holder;
    void release() {
      if (identical(_holder, holder)) _holder = null;
    }

    // Dibungkus `async` supaya tipe runtime-nya selalu
    // Future<PrinterResult<void>> -- Future.sync(job) meneruskan Future milik
    // job apa adanya (mis. Future<Never> dari job yang langsung melempar),
    // dan `timeout(onTimeout:)` di bawah menolak callback bertipe lain.
    Future<PrinterResult<void>> guarded() async => await job();
    final operation = guarded();
    unawaited(operation.then((_) => release(), onError: (_) => release()));
    return operation.timeout(
      timeout,
      onTimeout: () {
        unawaited(_watchStuck(operation, holder));
        return const PrinterErr(PrinterFailure(timeoutMessage));
      },
    );
  }

  Future<void> _watchStuck(Future<void> operation, Object holder) async {
    try {
      await operation.timeout(stuckAfter);
    } on TimeoutException {
      if (!identical(_holder, holder)) return;
      try {
        await onStuck?.call();
      } catch (_) {
        // Pembersihan best-effort -- kunci tetap dilepas di bawah.
      }
      if (identical(_holder, holder)) _holder = null;
    } catch (_) {
      // Pekerjaan selesai dengan galat -- kunci sudah dilepas di [run].
    }
  }
}

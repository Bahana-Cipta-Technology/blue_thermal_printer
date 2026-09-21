/// Kegagalan operasi printer.
///
/// Sengaja berupa satu class sederhana, bukan hierarki `sealed` seperti
/// `Failure` milik app konsumen tertentu -- plugin ini dipakai lintas app,
/// jadi tidak boleh tahu apa pun soal taksonomi galat spesifik satu app.
/// App konsumen bebas memetakan [PrinterFailure] ke tipe galat miliknya
/// sendiri di titik pemanggilan (mis. jadi `DeviceFailure`).
class PrinterFailure {
  const PrinterFailure(this.message, {this.isPermissionDenied = false});

  final String message;

  /// `true` bila kegagalan ini spesifik karena izin sistem ditolak (mis.
  /// izin Bluetooth) -- UI app bisa menampilkan ajakan buka Setelan alih-alih
  /// pesan galat generik.
  final bool isPermissionDenied;

  @override
  String toString() => 'PrinterFailure($message)';
}

/// Hasil operasi printer yang bisa gagal.
///
/// Independen dari tipe `Result`/`Failure` milik app manapun yang
/// mengonsumsi plugin ini -- lihat [PrinterFailure]. Nama diberi awalan
/// `Printer` supaya tidak bentrok saat diimpor bersamaan dengan `Result`
/// milik app di titik pemetaan boundary.
sealed class PrinterResult<T> {
  const PrinterResult();

  const factory PrinterResult.ok(T value) = PrinterOk<T>;
  const factory PrinterResult.err(PrinterFailure failure) = PrinterErr<T>;

  bool get isOk => this is PrinterOk<T>;
  bool get isErr => this is PrinterErr<T>;

  /// Nilai bila sukses, `null` bila gagal.
  T? get valueOrNull => switch (this) {
    PrinterOk<T>(:final value) => value,
    PrinterErr<T>() => null,
  };

  /// Kegagalan bila gagal, `null` bila sukses.
  PrinterFailure? get failureOrNull => switch (this) {
    PrinterOk<T>() => null,
    PrinterErr<T>(:final failure) => failure,
  };

  /// Ubah nilai sukses tanpa menyentuh cabang gagal.
  PrinterResult<R> map<R>(R Function(T value) transform) => switch (this) {
    PrinterOk<T>(:final value) => PrinterOk<R>(transform(value)),
    PrinterErr<T>(:final failure) => PrinterErr<R>(failure),
  };

  /// Runtuhkan kedua cabang menjadi satu nilai.
  R fold<R>({
    required R Function(T value) onOk,
    required R Function(PrinterFailure failure) onErr,
  }) => switch (this) {
    PrinterOk<T>(:final value) => onOk(value),
    PrinterErr<T>(:final failure) => onErr(failure),
  };
}

final class PrinterOk<T> extends PrinterResult<T> {
  const PrinterOk(this.value);

  final T value;

  @override
  String toString() => 'PrinterOk($value)';
}

final class PrinterErr<T> extends PrinterResult<T> {
  const PrinterErr(this.failure);

  final PrinterFailure failure;

  @override
  String toString() => 'PrinterErr($failure)';
}

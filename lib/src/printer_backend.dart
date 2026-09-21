import 'printer_device.dart';
import 'printer_status.dart';
import 'receipt.dart';
import 'result.dart';

/// Kontrak tunggal yang menyatukan pemasangan/koneksi perangkat *dan*
/// pengiriman data cetak untuk satu vendor/transport printer.
///
/// Digabung sengaja jadi satu interface (bukan dipisah "koneksi" vs "cetak")
/// supaya backend tanpa konsep pemasangan (mis. printer bawaan seperti
/// Sunmi) tidak dipaksa mengimplementasikan method yang secara semantik
/// tidak berlaku untuknya lewat jawaban stub yang menyesatkan -- lihat
/// [requiresPairing]. Tiap vendor (ESC/POS generik lewat Bluetooth, SDK
/// Sunmi, dst.) mengimplementasikan satu class ini, dengan kode native
/// masing-masing tetap terisolasi per vendor.
abstract interface class PrinterBackend {
  /// Nama tampilan singkat backend ini, mis. "Bluetooth ESC/POS" atau
  /// "Printer Bawaan Sunmi" -- dipakai UI, bukan identitas teknis/kunci.
  String get displayName;

  /// Apakah backend ini mengharuskan pengguna memilih/memasangkan satu
  /// perangkat sebelum bisa mencetak. `false` berarti backend otomatis
  /// terhubung ke satu-satunya printer yang tersedia (mis. printer bawaan) --
  /// UI boleh menyembunyikan afordansi pemasangan/pemilihan perangkat bila
  /// ini `false`.
  bool get requiresPairing;

  /// Apakah transport yang mendasari backend ini aktif/tersedia sama sekali
  /// (mis. radio Bluetooth menyala, atau servis printer bawaan terdeteksi
  /// ada) -- belum tentu berarti sudah terhubung ke sebuah perangkat.
  Future<bool> isAvailable();

  /// Daftar perangkat yang bisa dipilih. Backend dengan [requiresPairing]
  /// `false` mengembalikan paling banyak satu entri sintetis.
  Future<List<PrinterDevice>> discoverDevices();

  /// Hubungkan ke satu perangkat. Mengembalikan kegagalan bila transport
  /// nonaktif, izin ditolak, atau perangkat menolak koneksi.
  Future<PrinterResult<void>> connect(PrinterDevice device);

  /// Putuskan koneksi perangkat yang sedang aktif, bila ada. No-op pada
  /// backend dengan [requiresPairing] `false`.
  Future<void> disconnect();

  /// Apakah sedang terhubung ke sebuah perangkat dan siap dipakai mencetak.
  ///
  /// Implementasi boleh melakukan operasi tulis sungguhan ke printer untuk
  /// memverifikasi koneksi (bukan sekadar baca status) -- jangan panggil ini
  /// dari alur refresh/status pasif (mis. saat menu tampil), hanya tepat
  /// sebelum benar-benar mengirim data cetak.
  Future<bool> isConnected();

  /// Query status fisik printer (kertas/cover/error), bila didukung
  /// hardware/protokolnya. Sama seperti [isConnected], implementasi boleh
  /// menulis byte permintaan ke printer fisik -- jangan panggil dari alur
  /// refresh/status pasif, hanya tepat sebelum mencetak. [PrinterErr] hanya
  /// untuk precondition yang gagal (tidak terhubung); printer yang tidak
  /// merespons/tidak mendukung query ini tetap mengembalikan [PrinterOk]
  /// berisi [PrinterStatus.unknown].
  Future<PrinterResult<PrinterStatus>> checkStatus();

  /// Cetak struk. Mengembalikan kegagalan bila printer menolak atau belum
  /// terhubung.
  Future<PrinterResult<void>> printReceipt(Receipt receipt);

  /// Buka layar pengaturan sistem yang relevan untuk transport ini (mis.
  /// Setelan Bluetooth). No-op pada backend tanpa pengaturan sistem yang
  /// relevan (mis. printer bawaan).
  Future<void> openSystemSettings();
}

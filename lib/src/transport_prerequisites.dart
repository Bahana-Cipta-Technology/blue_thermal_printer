/// Operasi transport yang punya prasyarat sendiri.
enum TransportOperation { listPaired, toggle, scan, pair, connect }

/// Jenis prasyarat, berurutan sesuai urutan penyelesaiannya.
enum PrerequisiteKind {
  hardware,
  activity,
  permission,
  adapterEnabled,
  locationService
}

enum PrerequisiteStatus { satisfied, missing, permanentlyDenied }

/// Cara menyelesaikan satu prasyarat -- dijalankan oleh
/// [TransportPrerequisites.resolve].
enum PrerequisiteResolution {
  /// Tidak bisa diselesaikan dari app (mis. tidak ada hardware).
  none,
  requestPermission,
  enableTransport,
  openAppSettings,
  openLocationSettings,
}

/// Satu prasyarat beserta operasi yang membutuhkannya.
class Prerequisite {
  const Prerequisite({
    required this.id,
    required this.kind,
    required this.status,
    required this.resolution,
    this.permissions = const <String>[],
    this.operations = const <TransportOperation>{},
  });

  /// Identitas stabil, mis. `nearbyDevices`, `location`, `adapter`.
  final String id;
  final PrerequisiteKind kind;
  final PrerequisiteStatus status;
  final PrerequisiteResolution resolution;

  /// Nama izin Android yang tercakup (untuk [PrerequisiteKind.permission]).
  final List<String> permissions;

  final Set<TransportOperation> operations;

  bool get isSatisfied => status == PrerequisiteStatus.satisfied;

  /// Label pendek untuk checklist UI.
  String get label => switch (id) {
        'hardware' => 'Bluetooth tersedia',
        'activity' => 'Aplikasi terbuka',
        'nearbyDevices' => 'Izin Perangkat sekitar',
        'location' => 'Izin lokasi',
        'adapter' => 'Bluetooth aktif',
        'locationService' => 'Lokasi aktif',
        _ => id,
      };

  /// Penjelasan siap tampil saat belum terpenuhi.
  String get message => switch ((id, status)) {
        ('hardware', _) => 'Perangkat ini tidak memiliki Bluetooth.',
        ('activity', _) => 'Buka aplikasi untuk melanjutkan.',
        ('nearbyDevices', PrerequisiteStatus.permanentlyDenied) =>
          'Izin Perangkat sekitar ditolak. Aktifkan lewat Setelan aplikasi.',
        ('nearbyDevices', _) =>
          'Izinkan akses Perangkat sekitar untuk mencari dan menyambung printer.',
        ('location', PrerequisiteStatus.permanentlyDenied) =>
          'Izin lokasi ditolak. Aktifkan lewat Setelan aplikasi.',
        ('location', _) =>
          'Android versi ini mewajibkan izin lokasi untuk mencari printer Bluetooth.',
        ('adapter', _) => 'Bluetooth belum aktif.',
        ('locationService', _) =>
          'Aktifkan Lokasi agar pencarian printer Bluetooth berfungsi.',
        _ => 'Prasyarat "$id" belum terpenuhi.',
      };

  factory Prerequisite.fromMap(Map<Object?, Object?> map) => Prerequisite(
        id: map['id'] as String? ?? '',
        kind: _byName(
            PrerequisiteKind.values, map['kind'], PrerequisiteKind.hardware),
        status: _byName(PrerequisiteStatus.values, map['status'],
            PrerequisiteStatus.missing),
        resolution: _byName(
          PrerequisiteResolution.values,
          map['resolution'],
          PrerequisiteResolution.none,
        ),
        permissions: [
          for (final permission in map['permissions'] as List? ?? const [])
            if (permission is String) permission,
        ],
        operations: {
          for (final operation in map['operations'] as List? ?? const [])
            for (final value in TransportOperation.values)
              if (value.name == operation) value,
        },
      );

  static T _byName<T extends Enum>(List<T> values, Object? name, T fallback) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    return fallback;
  }
}

/// Semua prasyarat transport pada satu titik waktu.
class PrerequisiteReport {
  const PrerequisiteReport({required this.items, this.sdkInt});

  /// Laporan untuk platform tanpa transport ini (mis. desktop, test).
  static const unsupported = PrerequisiteReport(
    items: [
      Prerequisite(
        id: 'hardware',
        kind: PrerequisiteKind.hardware,
        status: PrerequisiteStatus.missing,
        resolution: PrerequisiteResolution.none,
        operations: {...TransportOperation.values},
      ),
    ],
  );

  final List<Prerequisite> items;

  /// Versi API Android, bila dilaporkan.
  final int? sdkInt;

  factory PrerequisiteReport.fromMap(Map<Object?, Object?> map) =>
      PrerequisiteReport(
        sdkInt: map['sdkInt'] as int?,
        items: [
          for (final item in map['items'] as List? ?? const [])
            if (item is Map) Prerequisite.fromMap(item),
        ],
      );

  /// Semua prasyarat yang berlaku untuk [operation] (terpenuhi atau belum),
  /// berurutan sesuai [PrerequisiteKind] -- untuk checklist UI.
  List<Prerequisite> requiredFor(TransportOperation operation) => [
        for (final item in items)
          if (item.operations.contains(operation)) item,
      ]..sort((a, b) => a.kind.index.compareTo(b.kind.index));

  /// Prasyarat [operation] yang belum terpenuhi, sesuai urutan penyelesaian.
  List<Prerequisite> missingFor(TransportOperation operation) => [
        for (final item in requiredFor(operation))
          if (!item.isSatisfied) item,
      ];

  bool isSatisfiedFor(TransportOperation operation) =>
      missingFor(operation).isEmpty;

  /// Satu langkah berikutnya yang perlu diselesaikan untuk [operation], atau
  /// `null` bila sudah siap. UI cukup menampilkan satu ajakan untuk ini.
  Prerequisite? nextStepFor(TransportOperation operation) {
    final missing = missingFor(operation);
    return missing.isEmpty ? null : missing.first;
  }
}

/// Kemampuan opsional: memeriksa dan menyelesaikan prasyarat transport.
///
/// Didapat lewat `printerFeature<TransportPrerequisites>(backend)`.
abstract interface class TransportPrerequisites {
  /// Periksa semua prasyarat TANPA memunculkan dialog apa pun.
  Future<PrerequisiteReport> checkPrerequisites();

  /// Jalankan [Prerequisite.resolution] milik [item] -- paling banyak satu
  /// dialog sistem atau satu layar Setelan -- lalu kembalikan laporan
  /// terbaru. Setelan dibuka di luar app, jadi laporan sesudahnya bisa masih
  /// sama; periksa ulang saat app kembali ke depan.
  Future<PrerequisiteReport> resolve(Prerequisite item);
}

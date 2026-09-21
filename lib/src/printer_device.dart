/// Satu perangkat printer yang bisa dipilih untuk mencetak.
///
/// Untuk backend yang butuh pemasangan (mis. Bluetooth), ini merepresentasikan
/// perangkat yang sudah dipasangkan di level OS. Untuk backend tanpa
/// pemasangan (mis. printer bawaan), berupa satu entri sintetis yang mewakili
/// satu-satunya printer yang tersedia -- lihat `PrinterBackend.requiresPairing`.
class PrinterDevice {
  const PrinterDevice({required this.name, required this.macAddress});

  final String name;

  /// Identitas unik perangkat. Untuk backend Bluetooth ini alamat MAC
  /// sungguhan; untuk backend tanpa pemasangan boleh berupa id sintetis yang
  /// tetap (mis. `'built-in'`).
  final String macAddress;

  @override
  bool operator ==(Object other) =>
      other is PrinterDevice && other.macAddress == macAddress;

  @override
  int get hashCode => macAddress.hashCode;
}

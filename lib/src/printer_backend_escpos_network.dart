import 'package:app_settings/app_settings.dart';

import 'escpos_transport.dart';
import 'printer_device.dart';
import 'result.dart';

/// Port RAW/JetDirect standar printer ESC/POS jaringan.
const kEscposNetworkDefaultPort = 9100;

/// Alamat printer LAN hasil [parseNetworkAddress].
class NetworkAddress {
  const NetworkAddress(this.host, this.port);

  final String host;
  final int port;

  /// Bentuk kanonik `host:port` -- disimpan sebagai
  /// [PrinterDevice.macAddress] (field itu = alamat transport).
  String get value => '$host:$port';

  @override
  bool operator ==(Object other) =>
      other is NetworkAddress && other.host == host && other.port == port;

  @override
  int get hashCode => Object.hash(host, port);

  @override
  String toString() => value;
}

final _ipv4 = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$');
final _hostname = RegExp(
  r'^(?=.{1,253}$)[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?'
  r'(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$',
);

/// Validasi input alamat printer LAN: `host` atau `host:port` (host = IPv4
/// atau hostname; port default [kEscposNetworkDefaultPort]). `null` bila
/// tidak valid. IPv6 sengaja belum didukung.
NetworkAddress? parseNetworkAddress(String input) {
  final text = input.trim();
  if (text.isEmpty) return null;
  final separator = text.lastIndexOf(':');
  final host = separator < 0 ? text : text.substring(0, separator);
  var port = kEscposNetworkDefaultPort;
  if (separator >= 0) {
    final parsed = int.tryParse(text.substring(separator + 1));
    if (parsed == null || parsed < 1 || parsed > 65535) return null;
    port = parsed;
  }
  final ipv4 = _ipv4.firstMatch(host);
  if (ipv4 != null) {
    for (var group = 1; group <= 4; group++) {
      if (int.parse(ipv4.group(group)!) > 255) return null;
    }
    return NetworkAddress(host, port);
  }
  // Semua-angka-dan-titik tapi bukan IPv4 sah (mis. "192.168.1") = salah
  // ketik, bukan hostname.
  if (RegExp(r'^[\d.]+$').hasMatch(host)) return null;
  if (!_hostname.hasMatch(host)) return null;
  return NetworkAddress(host, port);
}

/// Transport ESC/POS lewat TCP (port RAW, default 9100) -- native
/// `transport/net/NetPrinterChannel.java`, channel
/// `blue_thermal_printer/escpos_net`.
///
/// Tidak ada discovery: alamat dimasukkan pengguna dan disimpan app sebagai
/// [PrinterDevice.macAddress] berbentuk `host:port`.
class NetworkEscposTransport extends ChannelEscposTransport {
  NetworkEscposTransport({super.invoke, Future<void> Function()? openSettings})
    : _openSettings =
          openSettings ??
          (() => AppSettings.openAppSettings(type: AppSettingsType.wifi)),
      super(channelName);

  static const channelName = 'blue_thermal_printer/escpos_net';

  final Future<void> Function() _openSettings;

  @override
  String get displayName => 'Printer LAN (ESC/POS)';

  /// Native transport LAN terpasang (channel menjawab). Konektivitas
  /// jaringan sendiri baru terbukti saat connect -- jaringan yang mati
  /// dilaporkan sebagai kegagalan connect, bukan transport "nonaktif".
  @override
  Future<bool> isEnabled() async => await invoke('isAvailable') == true;

  /// `INTERNET` adalah izin normal (diberikan saat instal).
  @override
  Future<bool> isPermissionGranted() async => true;

  @override
  Future<List<PrinterDevice>> discover() async => const [];

  /// Alamat tersimpan langsung disambung ulang (tidak ada daftar pembanding).
  @override
  bool get requiresDiscoveredDevice => false;

  @override
  Future<PrinterFailure?> connect(PrinterDevice device) async {
    final address = parseNetworkAddress(device.macAddress);
    if (address == null) {
      return const PrinterFailure(
        'Alamat printer LAN tidak valid. Masukkan IP printer lagi.',
        requiresDeviceSelection: true,
      );
    }
    final connected = await invoke('connect', {
      'host': address.host,
      'port': address.port,
    });
    return connected == true
        ? null
        : const PrinterFailure(
            'Gagal terhubung ke printer LAN. Periksa alamat IP dan jaringan.',
          );
  }

  @override
  Future<void> openSettings() => _openSettings();

  @override
  String get disabledMessage => 'Jaringan tidak tersedia.';

  @override
  String get permissionDeniedMessage => 'Izin jaringan ditolak.';
}

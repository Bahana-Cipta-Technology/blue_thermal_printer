import 'package:blue_thermal_printer/printer_backend.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_backend.dart';

void main() {
  const device = PrinterDevice(name: 'Printer Bawaan', macAddress: 'x');
  const receipt = Receipt(lines: []);

  late FakeBackend primary;
  late FakeBackend fallback;
  late PrinterBackendFallback backend;

  void build({required bool primaryConnects, required bool fallbackConnects}) {
    primary = FakeBackend(name: 'Xcheng', connectResult: primaryConnects);
    fallback = FakeBackend(name: 'Sunmi', connectResult: fallbackConnects);
    backend = PrinterBackendFallback(primary: primary, fallback: fallback);
  }

  test('primary berhasil -> fallback tidak disentuh', () async {
    build(primaryConnects: true, fallbackConnects: true);

    expect((await backend.connect(device)).isOk, isTrue);
    expect(backend.active, same(primary));
    expect(backend.displayName, 'Xcheng');
    expect(fallback.connects, 0);
  });

  test('primary gagal -> diputus lalu pindah ke fallback', () async {
    build(primaryConnects: false, fallbackConnects: true);

    expect((await backend.connect(device)).isOk, isTrue);
    expect(primary.disconnects, 1);
    expect(backend.active, same(fallback));
    expect(backend.displayName, 'Sunmi');
  });

  test('keduanya gagal -> pesan fallback, active kembali ke primary', () async {
    build(primaryConnects: false, fallbackConnects: false);

    final result = await backend.connect(device);

    expect(result.failureOrNull?.message, 'Sunmi tidak terdeteksi.');
    expect(backend.active, same(primary));
  });

  test('setelah connect, cetak & status hanya lewat backend aktif', () async {
    build(primaryConnects: false, fallbackConnects: true);
    await backend.connect(device);

    await backend.printReceipt(receipt);
    await backend.checkStatus();

    expect(fallback.prints, 1);
    expect(fallback.statusChecks, 1);
    expect(primary.prints, 0);
  });

  test('cetak yang ditolak primary TIDAK dicoba ulang lewat fallback '
      '(mencegah penumpukan buffer)', () async {
    build(primaryConnects: true, fallbackConnects: true);
    await backend.connect(device);

    final result = await backend.printReceipt(receipt);

    expect(result.failureOrNull?.message, 'Xcheng: Kertas printer habis.');
    expect(fallback.prints, 0);
  });

  test('disconnect memutus backend aktif lalu kembali ke primary', () async {
    build(primaryConnects: false, fallbackConnects: true);
    await backend.connect(device);

    await backend.disconnect();

    expect(fallback.disconnects, 1);
    expect(backend.active, same(primary));
  });

  test('primary pulih: connect berikutnya kembali memakai primary', () async {
    build(primaryConnects: false, fallbackConnects: true);
    await backend.connect(device);
    await backend.disconnect();

    primary.connectResult = true;
    await backend.connect(device);

    expect(backend.active, same(primary));
  });

  test('sebelum connect, panggilan diteruskan ke primary', () async {
    build(primaryConnects: true, fallbackConnects: true);

    expect(backend.active, same(primary));
    expect((await backend.discoverDevices()).single.name, 'Xcheng');
    expect(backend.requiresPairing, isFalse);
  });
}

import 'dart:ui' as ui;

import 'package:blue_thermal_printer/printer_backend.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pisahkan keluaran [ReceiptRenderer.encode] jadi header pita `GS v 0`.
List<({int bytesPerRow, int rows})> bands(List<int> bytes) {
  final result = <({int bytesPerRow, int rows})>[];
  var offset = 2; // lewati ESC @
  while (offset < bytes.length - 3) {
    expect(bytes.sublist(offset, offset + 4), [29, 118, 48, 0]);
    final bytesPerRow = bytes[offset + 4] | (bytes[offset + 5] << 8);
    final rows = bytes[offset + 6] | (bytes[offset + 7] << 8);
    result.add((bytesPerRow: bytesPerRow, rows: rows));
    offset += 8 + bytesPerRow * rows;
  }
  expect(offset, bytes.length - 3, reason: 'sisa byte harus ESC d 2');
  return result;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const receipt = Receipt(
    lines: [
      ReceiptCenter('PARKWAYS', emphasized: true),
      ReceiptDivider(),
      ReceiptRow('Plat', 'B 1234 XY'),
      ReceiptBlank(),
      ReceiptQr('PKW-260912-0001'),
    ],
  );

  test('encode diawali ESC @ dan diakhiri feed ESC d 2', () async {
    final bytes = await const ReceiptRenderer().encode(receipt);

    expect(bytes.sublist(0, 2), [27, 64]);
    expect(bytes.sublist(bytes.length - 3), [27, 100, 2]);
  });

  test('raster dipecah jadi pita <=128 baris dengan lebar width/8', () async {
    final bytes = await const ReceiptRenderer().encode(receipt);
    final parsed = bands(bytes);

    expect(parsed, isNotEmpty);
    for (final band in parsed) {
      expect(band.bytesPerRow, 384 ~/ 8);
      expect(band.rows, inInclusiveRange(1, 128));
    }
    // Struk dengan QR pasti lebih tinggi dari satu pita.
    expect(parsed.length, greaterThan(1));
  });

  test('total baris raster sama dengan tinggi gambar render', () async {
    const renderer = ReceiptRenderer();
    final image = await renderer.render(receipt);
    final height = image.height;
    image.dispose();

    final parsed = bands(await renderer.encode(receipt));

    expect(parsed.fold<int>(0, (sum, b) => sum + b.rows), height);
  });

  test('kertas 80 mm (576 px) didukung', () async {
    final parsed = bands(await const ReceiptRenderer(width: 576).encode(receipt));

    expect(parsed.first.bytesPerRow, 72);
  });

  test('lebar bukan kelipatan 8 ditolak alih-alih menghasilkan raster rusak',
      () async {
    await expectLater(
      const ReceiptRenderer(width: 380).encode(receipt),
      throwsArgumentError,
    );
    await expectLater(
      const ReceiptRenderer(width: 0).preview(receipt),
      throwsArgumentError,
    );
  });

  test('QR menghasilkan piksel hitam pada raster', () async {
    const qrOnly = Receipt(lines: [ReceiptQr('PKW-260912-0001')]);
    final bytes = await const ReceiptRenderer().encode(qrOnly);

    // Abaikan header; cukup pastikan ada data raster yang tidak putih.
    expect(bytes.skip(10).any((b) => b != 0), isTrue);
  });

  test('struk kosong tetap menghasilkan raster valid', () async {
    final parsed = bands(await const ReceiptRenderer().encode(const Receipt(lines: [])));

    expect(parsed.single.rows, greaterThan(0));
  });

  test('preview menghasilkan PNG selebar width', () async {
    final png = await const ReceiptRenderer().preview(receipt);

    expect(png.sublist(0, 8), [137, 80, 78, 71, 13, 10, 26, 10]);
    final codec = await ui.instantiateImageCodec(png);
    final frame = await codec.getNextFrame();
    expect(frame.image.width, 384);
    frame.image.dispose();
  });
}

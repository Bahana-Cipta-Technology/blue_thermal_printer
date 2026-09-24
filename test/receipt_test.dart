import 'package:blue_thermal_printer/printer_backend.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Receipt.toPlainText', () {
    test('teks tengah diberi padding kiri sesuai lebar', () {
      const receipt = Receipt(lines: [ReceiptCenter('ABCD')], width: 10);
      expect(receipt.toPlainText(), '   ABCD\n');
    });

    test('teks tengah lebih panjang dari lebar tidak diberi padding', () {
      const receipt = Receipt(lines: [ReceiptCenter('ABCDEFGHIJKL')], width: 10);
      expect(receipt.toPlainText(), 'ABCDEFGHIJKL\n');
    });

    test('baris label/nilai rata kiri-kanan', () {
      const receipt = Receipt(lines: [ReceiptRow('Plat', 'B 1234 XY')], width: 20);
      final line = receipt.toPlainText().trimRight();
      expect(line.length, 20);
      expect(line, startsWith('Plat'));
      expect(line, endsWith('B 1234 XY'));
    });

    test('baris yang tidak muat dipisah satu spasi', () {
      const receipt = Receipt(lines: [ReceiptRow('Label', 'NilaiPanjang')], width: 10);
      expect(receipt.toPlainText(), 'Label NilaiPanjang\n');
    });

    test('pemisah, QR, dan baris kosong', () {
      const receipt = Receipt(
        lines: [ReceiptDivider(), ReceiptQr('PKW-260912-0001'), ReceiptBlank()],
        width: 5,
      );
      expect(receipt.toPlainText(), '-----\nPKW-260912-0001\n\n');
    });

    test('default lebar 32 kolom (kertas 58 mm) dan jenis customer', () {
      const receipt = Receipt(lines: [ReceiptDivider()]);
      expect(receipt.width, 32);
      expect(receipt.kind, ReceiptKind.customer);
      expect(receipt.toPlainText(), '${'-' * 32}\n');
    });
  });
}

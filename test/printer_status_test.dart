import 'package:blue_thermal_printer/printer_backend.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PrinterStatus.fromOfflineStatusByte (DLE EOT 2)', () {
    test('0x12 = printer normal', () {
      final status = PrinterStatus.fromOfflineStatusByte(0x12);
      expect(status.hasPaper, isTrue);
      expect(status.coverClosed, isTrue);
      expect(status.hasError, isFalse);
      expect(status.hasKnownProblem, isFalse);
    });

    test('bit 2 = cover terbuka', () {
      expect(PrinterStatus.fromOfflineStatusByte(0x16).coverClosed, isFalse);
    });

    test('bit 5 = berhenti karena kertas habis', () {
      expect(PrinterStatus.fromOfflineStatusByte(0x32).hasPaper, isFalse);
    });

    test('bit 6 = galat', () {
      expect(PrinterStatus.fromOfflineStatusByte(0x52).hasError, isTrue);
    });
  });

  group('PrinterStatus.tryFromOfflineStatusByte', () {
    test('byte sah didekode seperti biasa', () {
      expect(PrinterStatus.tryFromOfflineStatusByte(0x32).hasPaper, isFalse);
    });

    test('XON/XOFF/sampah tidak dibaca sebagai status', () {
      for (final byte in [0x11, 0x13, 0x00, 0xFF, 0x92, 256, -1]) {
        final status = PrinterStatus.tryFromOfflineStatusByte(byte);
        expect(status.hasPaper, isNull, reason: 'byte $byte');
        expect(status.hasKnownProblem, isFalse, reason: 'byte $byte');
      }
    });

    test('0xFF (semua bit menyala) tidak memblokir cetak lagi', () {
      // Dulu 0xFF didekode jadi kertas habis + cover terbuka + galat.
      expect(PrinterStatus.fromOfflineStatusByte(0xFF).hasKnownProblem, isTrue);
      expect(PrinterStatus.tryFromOfflineStatusByte(0xFF).hasKnownProblem, isFalse);
    });
  });

  group('problemMessage', () {
    test('null saat tidak ada masalah yang diketahui', () {
      expect(PrinterStatus.unknown.problemMessage, isNull);
      expect(
        const PrinterStatus(hasPaper: true, coverClosed: true, hasError: false)
            .problemMessage,
        isNull,
      );
    });

    test('prioritas: kertas > cover > galat', () {
      expect(
        const PrinterStatus(hasPaper: false, coverClosed: false, hasError: true)
            .problemMessage,
        'Kertas printer habis.',
      );
      expect(
        const PrinterStatus(coverClosed: false, hasError: true).problemMessage,
        'Penutup printer terbuka.',
      );
      expect(
        const PrinterStatus(hasError: true).problemMessage,
        'Printer melaporkan galat.',
      );
    });

    test('field null tidak pernah dianggap masalah', () {
      expect(const PrinterStatus(hasPaper: true).hasKnownProblem, isFalse);
      expect(const PrinterStatus(hasError: false).hasKnownProblem, isFalse);
    });
  });
}

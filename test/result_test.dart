import 'package:blue_thermal_printer/printer_backend.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PrinterResult', () {
    const ok = PrinterResult<int>.ok(2);
    const err = PrinterResult<int>.err(PrinterFailure('gagal'));

    test('isOk/isErr', () {
      expect(ok.isOk, isTrue);
      expect(ok.isErr, isFalse);
      expect(err.isOk, isFalse);
      expect(err.isErr, isTrue);
    });

    test('valueOrNull/failureOrNull', () {
      expect(ok.valueOrNull, 2);
      expect(ok.failureOrNull, isNull);
      expect(err.valueOrNull, isNull);
      expect(err.failureOrNull?.message, 'gagal');
    });

    test('map hanya mengubah cabang sukses', () {
      expect(ok.map((v) => v * 10).valueOrNull, 20);
      final mapped = err.map((v) => v * 10);
      expect(mapped.failureOrNull?.message, 'gagal');
    });

    test('fold meruntuhkan kedua cabang', () {
      String describe(PrinterResult<int> r) =>
          r.fold(onOk: (v) => 'ok $v', onErr: (f) => 'err ${f.message}');
      expect(describe(ok), 'ok 2');
      expect(describe(err), 'err gagal');
    });

    test('PrinterFailure default bukan penolakan izin', () {
      expect(const PrinterFailure('x').isPermissionDenied, isFalse);
      expect(
        const PrinterFailure('x', isPermissionDenied: true).isPermissionDenied,
        isTrue,
      );
    });
  });

  group('PrinterDevice', () {
    test('kesetaraan hanya berdasarkan alamat', () {
      const a = PrinterDevice(name: 'Printer A', macAddress: '00:11');
      const renamed = PrinterDevice(name: 'Nama Baru', macAddress: '00:11');
      const other = PrinterDevice(name: 'Printer A', macAddress: '00:22');

      expect(a, renamed);
      expect(a.hashCode, renamed.hashCode);
      expect(a, isNot(other));
      expect({a, renamed, other}, hasLength(2));
    });
  });
}

import 'dart:async';

import 'package:blue_thermal_printer/printer_backend.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<PrinterResult<void>> ok() async => const PrinterOk(null);

  test('meneruskan hasil pekerjaan dan melepas kunci', () async {
    final gate = PrintJobGate();

    expect((await gate.run(ok)).isOk, isTrue);
    expect(gate.isBusy, isFalse);
  });

  test('pekerjaan yang melempar tetap melepas kunci', () async {
    final gate = PrintJobGate();

    await expectLater(
      gate.run(() async => throw StateError('bug')),
      throwsStateError,
    );
    expect(gate.isBusy, isFalse);
  });

  test('menolak pekerjaan kedua selama yang pertama berjalan', () async {
    final gate = PrintJobGate();
    final pending = Completer<PrinterResult<void>>();

    final first = gate.run(() => pending.future);
    final second = await gate.run(ok);

    expect(second.failureOrNull?.message, PrintJobGate.busyMessage);
    pending.complete(const PrinterOk(null));
    expect((await first).isOk, isTrue);
  });

  test('pekerjaan lama yang selesai setelah kunci dilepas paksa tidak '
      'melepas kunci pekerjaan baru', () async {
    var cleanups = 0;
    final gate = PrintJobGate(
      timeout: const Duration(milliseconds: 5),
      stuckAfter: const Duration(milliseconds: 5),
      onStuck: () => cleanups++,
    );
    final stuck = Completer<PrinterResult<void>>();
    await gate.run(() => stuck.future);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(cleanups, 1);
    expect(gate.isBusy, isFalse);

    final current = Completer<PrinterResult<void>>();
    final next = gate.run(() => current.future);
    stuck.complete(const PrinterOk(null)); // pekerjaan lama akhirnya selesai
    await pumpEventQueue();

    expect(gate.isBusy, isTrue);
    current.complete(const PrinterOk(null));
    await next;
    expect(gate.isBusy, isFalse);
  });

  test('onStuck yang melempar tetap melepas kunci', () async {
    final gate = PrintJobGate(
      timeout: const Duration(milliseconds: 5),
      stuckAfter: const Duration(milliseconds: 5),
      onStuck: () => throw Exception('disconnect gagal'),
    );

    await gate.run(() => Completer<PrinterResult<void>>().future);
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(gate.isBusy, isFalse);
  });

  test('pekerjaan yang selesai sebelum hard-timeout tidak memanggil onStuck',
      () async {
    var cleanups = 0;
    final gate = PrintJobGate(
      timeout: const Duration(milliseconds: 5),
      stuckAfter: const Duration(milliseconds: 200),
      onStuck: () => cleanups++,
    );
    final pending = Completer<PrinterResult<void>>();

    final result = await gate.run(() => pending.future);
    expect(result.failureOrNull?.message, PrintJobGate.timeoutMessage);
    pending.complete(const PrinterOk(null));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(cleanups, 0);
    expect(gate.isBusy, isFalse);
  });
}

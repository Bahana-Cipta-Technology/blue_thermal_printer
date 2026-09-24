import 'dart:async';

import 'package:blue_thermal_printer/printer_backend.dart';
import 'package:flutter_test/flutter_test.dart';

/// Kondisi fisik printer yang disimulasikan fake tiap backend.
enum ContractStatus { normal, unknown, paperOut }

/// Satu backend yang sudah dirangkai dengan fake, plus pengamat efek
/// sampingnya -- dibangun oleh factory milik tiap vendor.
class ContractHarness {
  ContractHarness({required this.backend, required this.sends});

  final PrinterBackend backend;

  /// Berapa kali data cetak benar-benar dikirim ke native.
  final int Function() sends;
}

typedef ContractHarnessFactory =
    ContractHarness Function({
      required bool connected,
      ContractStatus status,
      bool dependenciesThrow,
      Future<void> Function()? onSend,
      Duration printTimeout,
      Duration stuckAfter,
    });

/// Invariant kontrak [PrinterBackend] yang WAJIB dipenuhi semua vendor.
/// Vendor baru (mis. iMin) cukup memanggil fungsi ini dengan factory-nya.
///
/// [supportsUnknownStatus] `false` untuk backend yang tidak punya keadaan
/// "terhubung tapi status tidak diketahui" -- mis. Xcheng, di mana sensor
/// kertas yang tidak menjawab justru berarti servis tidak tersedia.
void runPrinterBackendContract(
  String name,
  ContractHarnessFactory build, {
  bool supportsUnknownStatus = true,
}) {
  const receipt = Receipt(lines: [ReceiptCenter('TES')]);

  group('kontrak PrinterBackend: $name', () {
    test('cetak saat tidak terhubung gagal tanpa mengirim data', () async {
      final harness = build(connected: false);

      final result = await harness.backend.printReceipt(receipt);

      expect(result.isErr, isTrue);
      expect(harness.sends(), 0);
    });

    test('masalah pada pre-check menolak tanpa mengirim data', () async {
      final harness = build(connected: true, status: ContractStatus.paperOut);

      final result = await harness.backend.printReceipt(receipt);

      expect(result.failureOrNull?.message, 'Kertas printer habis.');
      expect(harness.sends(), 0);
    });

    test('status tidak diketahui tidak memblokir cetak', skip: !supportsUnknownStatus, () async {
      final harness = build(connected: true, status: ContractStatus.unknown);

      final result = await harness.backend.printReceipt(receipt);

      expect(result.isOk, isTrue);
      expect(harness.sends(), 1);
    });

    test('status normal mencetak dengan sukses', () async {
      final harness = build(connected: true);

      expect((await harness.backend.printReceipt(receipt)).isOk, isTrue);
    });

    test('cetak bersamaan ditolak, lalu bisa mencetak lagi', () async {
      final gate = Completer<void>();
      final harness = build(connected: true, onSend: () => gate.future);

      final first = harness.backend.printReceipt(receipt);
      final second = await harness.backend.printReceipt(receipt);
      expect(second.failureOrNull?.message, PrintJobGate.busyMessage);

      gate.complete();
      await first;
      await harness.backend.printReceipt(receipt);
      expect(harness.sends(), 2);
    });

    test('checkStatus saat tidak terhubung mengembalikan PrinterErr', () async {
      final harness = build(connected: false);

      expect((await harness.backend.checkStatus()).isErr, isTrue);
    });

    test('checkStatus saat terhubung melaporkan kondisi fisik', () async {
      final harness = build(connected: true, status: ContractStatus.paperOut);

      final status = (await harness.backend.checkStatus()).valueOrNull;

      expect(status?.hasPaper, isFalse);
    });

    test('dependency yang melempar tidak pernah bocor keluar kontrak', () async {
      final harness = build(connected: true, dependenciesThrow: true);
      final backend = harness.backend;

      expect(await backend.isAvailable(), isFalse);
      expect(await backend.isConnected(), isFalse);
      await backend.discoverDevices();
      expect(
        (await backend.connect(
          const PrinterDevice(name: 'X', macAddress: 'x'),
        )).isErr,
        isTrue,
      );
      await backend.disconnect();
      await backend.openSystemSettings();
      expect((await backend.checkStatus()).isErr, isTrue);
      expect((await backend.printReceipt(receipt)).isErr, isTrue);
    });

    test('timeout mengembalikan galat tapi kunci ditahan sampai native selesai',
        () async {
      final gate = Completer<void>();
      final harness = build(
        connected: true,
        onSend: () => gate.future,
        printTimeout: const Duration(milliseconds: 20),
        stuckAfter: const Duration(seconds: 30),
      );

      final first = await harness.backend.printReceipt(receipt);
      expect(first.failureOrNull?.message, PrintJobGate.timeoutMessage);
      expect(
        (await harness.backend.printReceipt(receipt)).failureOrNull?.message,
        PrintJobGate.busyMessage,
      );

      gate.complete();
      await pumpEventQueue();
      expect((await harness.backend.printReceipt(receipt)).isOk, isTrue);
    });

    test('pekerjaan yang macet melepas kunci setelah batas hard-timeout',
        () async {
      final harness = build(
        connected: true,
        onSend: () => Completer<void>().future, // tidak pernah selesai
        printTimeout: const Duration(milliseconds: 10),
        stuckAfter: const Duration(milliseconds: 10),
      );

      await harness.backend.printReceipt(receipt);
      await Future<void>.delayed(const Duration(milliseconds: 60));

      final next = harness.backend.printReceipt(receipt);
      // Tidak lagi ditolak dengan "masih memproses".
      expect(
        (await next.timeout(const Duration(seconds: 1))).failureOrNull?.message,
        isNot(PrintJobGate.busyMessage),
      );
      expect(harness.sends(), 2);
    });
  });
}

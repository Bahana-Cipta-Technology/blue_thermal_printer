import 'dart:async';

import 'package:blue_thermal_printer/printer_backend.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_test/flutter_test.dart';

import 'support/printer_backend_contract.dart';

void main() {
  const receipt = Receipt(lines: []);
  const device = PrinterDevice(name: 'Printer', macAddress: '00:11:22:33:44:55');

  runPrinterBackendContract('ESC/POS', ({
    required bool connected,
    ContractStatus status = ContractStatus.normal,
    bool dependenciesThrow = false,
    Future<void> Function()? onSend,
    Duration printTimeout = const Duration(seconds: 30),
    Duration stuckAfter = const Duration(seconds: 30),
  }) {
    var sends = 0;
    var connects = 0;
    Never fail() => throw Exception('channel error');
    final printerStatus = switch (status) {
      ContractStatus.normal => const PrinterStatus(
        hasPaper: true,
        coverClosed: true,
        hasError: false,
      ),
      ContractStatus.unknown => PrinterStatus.unknown,
      ContractStatus.paperOut => const PrinterStatus(hasPaper: false),
    };
    return ContractHarness(
      backend: PrinterBackendEscpos(
        printTimeout: printTimeout,
        stuckAfter: stuckAfter,
        isBluetoothOn: () async => dependenciesThrow ? fail() : true,
        isPermissionGranted: () async => dependenciesThrow ? fail() : true,
        discover: () async => dependenciesThrow ? fail() : const [device],
        doConnect: (_) async {
          if (dependenciesThrow) fail();
          connects++;
          return true;
        },
        doDisconnect: () async => dependenciesThrow ? fail() : null,
        connected: () async => dependenciesThrow ? fail() : connected,
        encode: (_) async => [1],
        write: (_) async {
          if (dependenciesThrow) fail();
          sends++;
          await onSend?.call();
          return true;
        },
        checkStatus: () async => dependenciesThrow ? fail() : printerStatus,
        openSettings: () async => dependenciesThrow ? fail() : null,
      ),
      sends: () => sends,
      connectAttempts: () => connects,
    );
  });

  group('printReceipt', () {
    test('koneksi terputus tidak mengirim byte', () async {
      var writes = 0;
      final backend = PrinterBackendEscpos(
        connected: () async => false,
        write: (_) async {
          writes++;
          return true;
        },
        checkStatus: () async => PrinterStatus.unknown,
      );
      expect((await backend.printReceipt(receipt)).failureOrNull, isNotNull);
      expect(writes, 0);
    });

    test('menolak cetak bersamaan dan dapat mencoba ulang setelah gagal', () async {
      final pending = Completer<bool>();
      var writes = 0;
      final backend = PrinterBackendEscpos(
        connected: () async => true,
        encode: (_) async => [1],
        write: (_) {
          writes++;
          return pending.future;
        },
        checkStatus: () async => PrinterStatus.unknown,
      );
      final first = backend.printReceipt(receipt);
      expect((await backend.printReceipt(receipt)).failureOrNull, isNotNull);
      pending.complete(false);
      expect((await first).failureOrNull, isNotNull);
      expect(writes, 1);
      await backend.printReceipt(receipt);
      expect(writes, 2);
    });

    test(
      'penulisan sukses tapi printer melaporkan kertas habis pasca-tulis tetap gagal',
      () async {
        var call = 0;
        final backend = PrinterBackendEscpos(
          connected: () async => true,
          encode: (_) async => [1],
          write: (_) async => true,
          // Pre-check (panggilan ke-1) bersih supaya benar-benar sampai
          // menulis; baru pasca-tulis (panggilan ke-2) melaporkan masalah.
          checkStatus: () async {
            call++;
            return call == 1
                ? PrinterStatus.unknown
                : const PrinterStatus(hasPaper: false);
          },
        );

        final result = await backend.printReceipt(receipt);

        expect(result.isErr, isTrue);
      },
    );

    test('penulisan sukses dan status printer tidak diketahui tetap dianggap sukses', () async {
      var writes = 0;
      final backend = PrinterBackendEscpos(
        connected: () async => true,
        encode: (_) async => [1],
        write: (_) async {
          writes++;
          return true;
        },
        checkStatus: () async => PrinterStatus.unknown,
      );

      final result = await backend.printReceipt(receipt);

      expect(result.isOk, isTrue);
      expect(writes, 1);
    });

    test('penulisan sukses tapi printer melaporkan cover terbuka atau galat pasca-tulis tetap gagal', () async {
      var coverCall = 0;
      final coverOpen = PrinterBackendEscpos(
        connected: () async => true,
        encode: (_) async => [1],
        write: (_) async => true,
        checkStatus: () async {
          coverCall++;
          return coverCall == 1
              ? PrinterStatus.unknown
              : const PrinterStatus(coverClosed: false);
        },
      );
      var errorCall = 0;
      final error = PrinterBackendEscpos(
        connected: () async => true,
        encode: (_) async => [1],
        write: (_) async => true,
        checkStatus: () async {
          errorCall++;
          return errorCall == 1
              ? PrinterStatus.unknown
              : const PrinterStatus(hasError: true);
        },
      );

      expect((await coverOpen.printReceipt(receipt)).isErr, isTrue);
      expect((await error.printReceipt(receipt)).isErr, isTrue);
    });

    test(
      'pre-check menolak sebelum satu byte pun ditulis saat status sudah bermasalah',
      () async {
        var writes = 0;
        final backend = PrinterBackendEscpos(
          connected: () async => true,
          encode: (_) async => [1],
          write: (_) async {
            writes++;
            return true;
          },
          checkStatus: () async => const PrinterStatus(hasPaper: false),
        );

        final result = await backend.printReceipt(receipt);

        expect(result.isErr, isTrue);
        expect(result.failureOrNull?.message, 'Kertas printer habis.');
        expect(writes, 0);
      },
    );

    test(
      'kegagalan pasca-tulis memicu reset buffer (ESC @) tambahan',
      () async {
        final writes = <List<int>>[];
        var call = 0;
        final backend = PrinterBackendEscpos(
          connected: () async => true,
          encode: (_) async => [1, 2, 3],
          write: (bytes) async {
            writes.add(bytes);
            return true;
          },
          checkStatus: () async {
            call++;
            return call == 1
                ? PrinterStatus.unknown
                : const PrinterStatus(hasPaper: false);
          },
        );

        await backend.printReceipt(receipt);

        expect(writes, [
          [1, 2, 3], // data struk yang gagal tercetak
          [27, 64], // ESC @ pembersih buffer
        ]);
      },
    );

    test('reset ESC @ yang gagal tetap melaporkan penyebab aslinya', () async {
      var call = 0;
      var writes = 0;
      final backend = PrinterBackendEscpos(
        connected: () async => true,
        encode: (_) async => [1],
        write: (_) async {
          if (++writes == 2) throw Exception('socket tertutup');
          return true;
        },
        checkStatus: () async => ++call == 1
            ? PrinterStatus.unknown
            : const PrinterStatus(coverClosed: false),
      );

      final result = await backend.printReceipt(receipt);

      expect(result.failureOrNull?.message, 'Penutup printer terbuka.');
    });

    test('write mengembalikan false dilaporkan sebagai pengiriman gagal', () async {
      final backend = PrinterBackendEscpos(
        connected: () async => true,
        encode: (_) async => [1],
        write: (_) async => false,
        checkStatus: () async => PrinterStatus.unknown,
      );

      final result = await backend.printReceipt(receipt);

      expect(
        result.failureOrNull?.message,
        'Pengiriman gagal. Periksa kertas sebelum mencoba ulang.',
      );
    });

    test('encode atau write melempar dilaporkan sebagai galat', () async {
      final encodeFails = PrinterBackendEscpos(
        connected: () async => true,
        encode: (_) async => throw ArgumentError('lebar tidak valid'),
        checkStatus: () async => PrinterStatus.unknown,
      );
      final writeFails = PrinterBackendEscpos(
        connected: () async => true,
        encode: (_) async => [1],
        write: (_) async => throw Exception('write_error'),
        checkStatus: () async => PrinterStatus.unknown,
      );

      expect((await encodeFails.printReceipt(receipt)).isErr, isTrue);
      expect((await writeFails.printReceipt(receipt)).isErr, isTrue);
    });

    test('pekerjaan macet memutus koneksi supaya write native terlepas',
        () async {
      var disconnects = 0;
      final backend = PrinterBackendEscpos(
        printTimeout: const Duration(milliseconds: 10),
        stuckAfter: const Duration(milliseconds: 10),
        connected: () async => true,
        encode: (_) async => [1],
        write: (_) => Completer<bool>().future, // socket macet
        checkStatus: () async => PrinterStatus.unknown,
        doDisconnect: () async => disconnects++,
      );

      await backend.printReceipt(receipt);
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(disconnects, 1);
    });
  });

  group('connect', () {
    test('izin ditolak mengembalikan PrinterErr dengan isPermissionDenied', () async {
      final backend = PrinterBackendEscpos(isPermissionGranted: () async => false);

      final result = await backend.connect(device);

      expect(result.isErr, isTrue);
      expect(result.failureOrNull?.isPermissionDenied, isTrue);
    });

    test('bluetooth nonaktif mengembalikan PrinterErr', () async {
      final backend = PrinterBackendEscpos(
        isPermissionGranted: () async => true,
        isBluetoothOn: () async => false,
      );

      final result = await backend.connect(device);

      expect(result.isErr, isTrue);
    });

    test('berhasil terhubung mengembalikan PrinterOk', () async {
      PrinterDevice? connectedTo;
      final backend = PrinterBackendEscpos(
        isPermissionGranted: () async => true,
        isBluetoothOn: () async => true,
        doConnect: (target) async {
          connectedTo = target;
          return true;
        },
      );

      final result = await backend.connect(device);

      expect(result.isOk, isTrue);
      expect(connectedTo, device);
    });

    test('perangkat menolak koneksi mengembalikan PrinterErr', () async {
      final backend = PrinterBackendEscpos(
        isPermissionGranted: () async => true,
        isBluetoothOn: () async => true,
        doConnect: (_) async => false,
      );

      final result = await backend.connect(device);

      expect(result.failureOrNull?.message, 'Gagal terhubung ke printer.');
      expect(result.failureOrNull?.isPermissionDenied, isFalse);
    });

    test('native melempar (mis. connect_timeout) mengembalikan PrinterErr',
        () async {
      final backend = PrinterBackendEscpos(
        isPermissionGranted: () async => true,
        isBluetoothOn: () async => true,
        doConnect: (_) async => throw Exception('connect_timeout'),
      );

      expect((await backend.connect(device)).isErr, isTrue);
    });

    test('connect bersamaan berbagi satu percobaan native', () async {
      final pending = Completer<bool>();
      var attempts = 0;
      final backend = PrinterBackendEscpos(
        isPermissionGranted: () async => true,
        isBluetoothOn: () async => true,
        doConnect: (_) {
          attempts++;
          return pending.future;
        },
      );

      // Mis. auto-connect saat app dibuka + tap pengguna di lembar koneksi.
      final first = backend.connect(device);
      final second = backend.connect(device);
      pending.complete(true);

      expect((await first).isOk, isTrue);
      expect((await second).isOk, isTrue);
      expect(attempts, 1);
    });

    test('setelah percobaan selesai, connect berikutnya mencoba ulang', () async {
      var attempts = 0;
      final backend = PrinterBackendEscpos(
        isPermissionGranted: () async => true,
        isBluetoothOn: () async => true,
        doConnect: (_) async => ++attempts > 1,
      );

      expect((await backend.connect(device)).isErr, isTrue);
      expect((await backend.connect(device)).isOk, isTrue);
      expect(attempts, 2);
    });
  });

  group('printer yang tidak mendukung DLE EOT', () {
    const answered = PrinterStatus(hasPaper: true, coverClosed: true, hasError: false);

    PrinterBackendEscpos backendWith(Future<PrinterStatus> Function() checkStatus) =>
        PrinterBackendEscpos(
          isPermissionGranted: () async => true,
          isBluetoothOn: () async => true,
          doConnect: (_) async => true,
          connected: () async => true,
          encode: (_) async => [1],
          write: (_) async => true,
          checkStatus: checkStatus,
        );

    test('berhenti query setelah 2 query beruntun tanpa jawaban', () async {
      var queries = 0;
      final backend = backendWith(() async {
        queries++;
        return PrinterStatus.unknown;
      });

      await backend.printReceipt(receipt); // pre + post = 2 query tanpa jawaban
      expect(queries, 2);
      await backend.printReceipt(receipt);
      await backend.printReceipt(receipt);
      expect((await backend.checkStatus()).valueOrNull?.hasPaper, isNull);

      expect(queries, 2);
    });

    test('printer yang pernah menjawab tidak pernah dianggap tidak mendukung',
        () async {
      var queries = 0;
      final backend = backendWith(() async {
        queries++;
        // Menjawab sekali, lalu sesekali tidak menjawab (mis. sibuk).
        return queries == 1 ? answered : PrinterStatus.unknown;
      });

      for (var i = 0; i < 3; i++) {
        await backend.printReceipt(receipt);
      }

      expect(queries, 6);
    });

    test('koneksi baru mengulang deteksi (printer lain mungkin mendukung)',
        () async {
      var queries = 0;
      final backend = backendWith(() async {
        queries++;
        return PrinterStatus.unknown;
      });

      await backend.printReceipt(receipt);
      await backend.printReceipt(receipt);
      expect(queries, 2);

      await backend.connect(device);
      await backend.printReceipt(receipt);
      expect(queries, 4);
    });

    test('status bermasalah tetap memblokir sebelum deteksi selesai', () async {
      final backend = backendWith(() async => const PrinterStatus(hasPaper: false));

      final result = await backend.printReceipt(receipt);

      expect(result.failureOrNull?.message, 'Kertas printer habis.');
    });
  });

  group('autocutter (GS I 2)', () {
    const answered = PrinterStatus(
      hasPaper: true,
      coverClosed: true,
      hasError: false,
    );
    const cut = [0x1D, 0x56, 66, 0];

    bool endsWithCut(List<int> bytes) =>
        bytes.length >= 4 && listEquals(bytes.sublist(bytes.length - 4), cut);

    ({
      PrinterBackendEscpos backend,
      List<List<int>> writes,
      int Function() probes,
    }) harness({
      Future<int?> Function()? typeId,
      Future<PrinterStatus> Function()? checkStatus,
      Future<int?> Function()? errorStatus,
    }) {
      final writes = <List<int>>[];
      var probes = 0;
      final backend = PrinterBackendEscpos(
        isPermissionGranted: () async => true,
        isBluetoothOn: () async => true,
        doConnect: (_) async => true,
        connected: () async => true,
        encode: (_) async => [1, 2, 3],
        write: (bytes) async {
          writes.add(bytes);
          return true;
        },
        checkStatus: checkStatus ?? () async => answered,
        queryTypeId: () async {
          probes++;
          return typeId == null ? null : await typeId();
        },
        queryErrorStatus: errorStatus,
      );
      return (backend: backend, writes: writes, probes: () => probes);
    }

    test(
      'cutter terdeteksi: struk diakhiri GS V 66 0 dan autoCut true',
      () async {
        final h = harness(typeId: () async => 0x02);

        await h.backend.printReceipt(receipt);

        expect(endsWithCut(h.writes.single), isTrue);
        expect(h.writes.single.sublist(0, 3), [1, 2, 3]);
        expect((await h.backend.capabilities()).autoCut, isTrue);
      },
    );

    test('tanpa cutter (bit 1 mati) tidak memotong', () async {
      final h = harness(typeId: () async => 0x01);

      await h.backend.printReceipt(receipt);

      expect(h.writes.single, [1, 2, 3]);
      expect((await h.backend.capabilities()).autoCut, isFalse);
    });

    test('printer tidak menjawab GS I (null) tidak memotong', () async {
      final h = harness(typeId: () async => null);

      await h.backend.printReceipt(receipt);

      expect(h.writes.single, [1, 2, 3]);
      expect((await h.backend.capabilities()).autoCut, isFalse);
    });

    test('query yang melempar diperlakukan tidak diketahui', () async {
      final h = harness(typeId: () async => throw Exception('channel error'));

      final result = await h.backend.printReceipt(receipt);

      expect(result.isOk, isTrue);
      expect(h.writes.single, [1, 2, 3]);
    });

    test('belum terhubung: autoCut false tanpa query ke printer', () async {
      final h = harness(typeId: () async => 0x02);

      expect((await h.backend.capabilities()).autoCut, isFalse);
      expect(h.probes(), 0);
    });

    test('deteksi sekali per koneksi, diulang untuk printer lain', () async {
      final h = harness(typeId: () async => 0x02);

      await h.backend.connect(device);
      await h.backend.printReceipt(receipt);
      await h.backend.printReceipt(receipt);
      await h.backend.connect(device); // printer sama (ensureConnected)
      await h.backend.printReceipt(receipt);
      expect(h.probes(), 1);

      await h.backend.connect(
        const PrinterDevice(name: 'Lain', macAddress: 'AA:BB:CC:DD:EE:FF'),
      );
      await h.backend.printReceipt(receipt);
      expect(h.probes(), 2);

      await h.backend.disconnect();
      await h.backend.connect(device);
      await h.backend.printReceipt(receipt);
      expect(h.probes(), 3);
    });

    test('printer yang tidak menjawab DLE EOT tidak ditanya GS I', () async {
      final h = harness(
        typeId: () async => 0x02,
        checkStatus: () async => PrinterStatus.unknown,
      );

      await h.backend.printReceipt(receipt);
      await h.backend.printReceipt(receipt);

      expect(h.probes(), 0);
      expect(h.writes.every((bytes) => !endsWithCut(bytes)), isTrue);
    });

    test('deteksi menunggu sampai printer menjawab DLE EOT', () async {
      var queries = 0;
      final h = harness(
        typeId: () async => 0x02,
        checkStatus: () async =>
            ++queries == 1 ? PrinterStatus.unknown : answered,
      );

      await h.backend.printReceipt(receipt); // pre tidak dijawab
      expect(h.probes(), 0);
      await h.backend.printReceipt(receipt);

      expect(h.probes(), 1);
      expect(endsWithCut(h.writes.last), isTrue);
    });

    test('status bermasalah memblokir tanpa deteksi dan tanpa kirim', () async {
      final h = harness(
        typeId: () async => 0x02,
        checkStatus: () async => const PrinterStatus(
          hasPaper: false,
          coverClosed: true,
          hasError: false,
        ),
      );

      expect((await h.backend.printReceipt(receipt)).isErr, isTrue);
      expect(h.probes(), 0);
      expect(h.writes, isEmpty);
    });

    group('circuit breaker', () {
      const failed = PrinterStatus(
        hasPaper: true,
        coverClosed: true,
        hasError: true,
      );

      test(
        'galat autocutter di post-check mematikan cut sampai koneksi baru',
        () async {
          var queries = 0;
          var errorQueries = 0;
          final h = harness(
            typeId: () async => 0x02,
            // pre OK, post galat, lalu normal lagi.
            checkStatus: () async => ++queries == 2 ? failed : answered,
            errorStatus: () async {
              errorQueries++;
              return 0x1A; // DLE EOT 3: bit 3 galat autocutter
            },
          );

          expect((await h.backend.printReceipt(receipt)).isErr, isTrue);
          expect(errorQueries, 1);
          expect((await h.backend.capabilities()).autoCut, isFalse);

          await h.backend.printReceipt(receipt);
          expect(endsWithCut(h.writes.last), isFalse);

          await h.backend.disconnect();
          await h.backend.connect(device);
          await h.backend.printReceipt(receipt);
          expect(endsWithCut(h.writes.last), isTrue);
        },
      );

      test(
        'galat autocutter yang baru terlihat di pre-check juga mematikan cut',
        () async {
          var queries = 0;
          final h = harness(
            typeId: () async => 0x02,
            // cetak 1: pre+post OK; cetak 2: pre galat; cetak 3: OK.
            checkStatus: () async => ++queries == 3 ? failed : answered,
            errorStatus: () async => 0x1A,
          );

          await h.backend.printReceipt(receipt);
          expect(endsWithCut(h.writes.single), isTrue);
          expect((await h.backend.printReceipt(receipt)).isErr, isTrue);
          await h.backend.printReceipt(receipt);

          expect(h.writes, hasLength(2));
          expect(endsWithCut(h.writes.last), isFalse);
        },
      );

      test('galat lain (bit 3 mati) tidak mematikan cut', () async {
        var queries = 0;
        final h = harness(
          typeId: () async => 0x02,
          checkStatus: () async => ++queries == 2 ? failed : answered,
          errorStatus: () async => 0x32, // galat tak terpulihkan, bukan cutter
        );

        await h.backend.printReceipt(receipt);
        await h.backend.printReceipt(receipt);

        expect(endsWithCut(h.writes.last), isTrue);
      });

      test('galat saat cut tidak dipakai tidak menanyakan DLE EOT 3', () async {
        var errorQueries = 0;
        final h = harness(
          typeId: () async => 0x00,
          checkStatus: () async => failed,
          errorStatus: () async {
            errorQueries++;
            return 0x1A;
          },
        );

        await h.backend.printReceipt(receipt);

        expect(errorQueries, 0);
      });
    });
  });

  group('lebar kertas', () {
    const answered = PrinterStatus(
      hasPaper: true,
      coverClosed: true,
      hasError: false,
    );
    const lines = Receipt(lines: [ReceiptCenter('PARKWAYS')]);

    /// Byte per baris raster dari header `GS v 0` pertama: 48 = 384 px,
    /// 72 = 576 px.
    int bytesPerRow(List<int> bytes) {
      final i = List.generate(bytes.length - 3, (i) => i).firstWhere(
        (i) => bytes[i] == 29 && bytes[i + 1] == 118 && bytes[i + 2] == 48,
      );
      return bytes[i + 4];
    }

    ({PrinterBackendEscpos backend, List<List<int>> writes}) harness({
      int? typeId,
      Future<PrinterStatus> Function()? checkStatus,
      Future<int?> Function()? errorStatus,
    }) {
      final writes = <List<int>>[];
      final backend = PrinterBackendEscpos(
        isPermissionGranted: () async => true,
        isBluetoothOn: () async => true,
        doConnect: (_) async => true,
        connected: () async => true,
        write: (bytes) async {
          writes.add(bytes);
          return true;
        },
        checkStatus: checkStatus ?? () async => answered,
        queryTypeId: () async => typeId,
        queryErrorStatus: errorStatus,
      );
      return (backend: backend, writes: writes);
    }

    test('otomatis + autocutter: cetakan pertama langsung 80 mm', () async {
      final h = harness(typeId: 0x02);
      expect((await h.backend.capabilities()).paperWidthPx, 384);

      await h.backend.printReceipt(lines);

      expect(bytesPerRow(h.writes.single), 72);
      expect((await h.backend.capabilities()).paperWidthPx, 576);
      expect(pngWidth(await h.backend.preview(lines)), 576);
    });

    test('otomatis tanpa autocutter atau tidak menjawab tetap 58 mm', () async {
      for (final typeId in [0x00, null]) {
        final h = harness(typeId: typeId);

        await h.backend.printReceipt(lines);

        expect(bytesPerRow(h.writes.single), 48);
        expect((await h.backend.capabilities()).paperWidthPx, 384);
      }
    });

    test('80 mm manual tanpa autocutter', () async {
      final h = harness(typeId: 0x00)
        ..backend.setPaperWidth(PaperWidthSetting.mm80);

      await h.backend.printReceipt(lines);

      expect(bytesPerRow(h.writes.single), 72);
      expect(pngWidth(await h.backend.preview(lines)), 576);
    });

    test('58 mm manual pada printer ber-pemotong tetap memotong', () async {
      final h = harness(typeId: 0x02)
        ..backend.setPaperWidth(PaperWidthSetting.mm58);

      await h.backend.printReceipt(lines);

      final bytes = h.writes.single;
      expect(bytesPerRow(bytes), 48);
      expect(bytes.sublist(bytes.length - 4), [0x1D, 0x56, 66, 0]);
    });

    test('circuit breaker cutter tidak mengubah lebar', () async {
      var queries = 0;
      final h = harness(
        typeId: 0x02,
        checkStatus: () async => ++queries == 2
            ? const PrinterStatus(
                hasPaper: true,
                coverClosed: true,
                hasError: true,
              )
            : answered,
        errorStatus: () async => 0x1A,
      );

      await h.backend.printReceipt(lines); // post-check galat cutter
      await h.backend.printReceipt(lines);

      expect((await h.backend.capabilities()).autoCut, isFalse);
      expect(bytesPerRow(h.writes.last), 72);
    });

    test(
      'printer lain: otomatis kembali 58 mm sampai terdeteksi ulang',
      () async {
        final h = harness(typeId: 0x02);
        await h.backend.connect(device);
        await h.backend.printReceipt(lines);
        expect((await h.backend.capabilities()).paperWidthPx, 576);

        await h.backend.connect(
          const PrinterDevice(name: 'Lain', macAddress: 'AA:BB:CC:DD:EE:FF'),
        );

        expect((await h.backend.capabilities()).paperWidthPx, 384);
      },
    );
  });

  group('checkStatus default (native DLE EOT)', () {
    test('status yang terbaca diteruskan apa adanya', () async {
      final backend = PrinterBackendEscpos(
        connected: () async => true,
        checkStatus: () async => const PrinterStatus(hasError: true),
      );

      final result = await backend.checkStatus();

      expect(result.valueOrNull?.hasError, isTrue);
    });

    test('query status melempar tetap Ok(unknown)', () async {
      final backend = PrinterBackendEscpos(
        connected: () async => true,
        checkStatus: () async => throw Exception('write_error'),
      );

      final result = await backend.checkStatus();

      expect(result.isOk, isTrue);
      expect(result.valueOrNull?.hasKnownProblem, isFalse);
    });
  });

  test('discoverDevices meneruskan daftar dari sumber terinjeksi', () async {
    final backend = PrinterBackendEscpos(discover: () async => const [device]);

    expect(await backend.discoverDevices(), [device]);
  });

  test('checkStatus gagal saat belum terhubung', () async {
    final backend = PrinterBackendEscpos(connected: () async => false);

    final result = await backend.checkStatus();

    expect(result.isErr, isTrue);
  });

  test('displayName dan requiresPairing sesuai backend Bluetooth', () {
    final backend = PrinterBackendEscpos();

    expect(backend.displayName, 'Bluetooth ESC/POS');
    expect(backend.requiresPairing, isTrue);
  });
}

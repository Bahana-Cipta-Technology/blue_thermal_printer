// App uji hardware untuk kontrak PrinterBackend.
//
// Tiap fungsi kontrak punya satu atau lebih kasus uji. Hasil tampil di layar dan
// dicetak ke logcat dengan awalan `HARNESS|` supaya bisa dibaca dari adb:
//
//   HARNESS|<grup>|<id>|<PASS/FAIL/SKIP/INFO>|<ms>ms|<catatan>
//
// Kasus yang mencetak ke kertas ditandai [TestCase.prints]; yang mengubah
// keadaan Bluetooth perangkat ditandai [TestCase.disruptive].

import 'dart:async';

import 'package:blue_thermal_printer/blue_thermal_printer.dart' as legacy;
import 'package:blue_thermal_printer/printer_backend.dart';

enum Verdict { pass, fail, skip, info }

/// Dilempar kasus uji untuk menandai kegagalan dengan pesan jelas.
class Fail implements Exception {
  Fail(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Dilempar bila kasus uji tidak relevan di perangkat/konfigurasi ini.
class Skip implements Exception {
  Skip(this.message);
  final String message;
}

/// Hasil informatif (nilai yang dicatat, bukan dinilai lulus/gagal).
class Info implements Exception {
  Info(this.message);
  final String message;
}

class Outcome {
  Outcome(this.verdict, this.note, this.elapsed);
  final Verdict verdict;
  final String note;
  final Duration elapsed;
}

/// Konfigurasi dan keadaan bersama seluruh kasus uji.
class Ctx {
  /// MAC printer Bluetooth yang diuji; kosong = pilih otomatis dari perangkat
  /// ter-pairing yang namanya mengandung "printer".
  String btAddress = '';

  /// Alamat server TCP palsu di PC. Boleh `host` atau `host:portDasar`; kasus
  /// LAN memakai portDasar + 0..4 (default 9100..9104).
  String lanHost = '';

  String get lanHostOnly {
    final int i = lanHost.lastIndexOf(':');
    return i < 0 ? lanHost : lanHost.substring(0, i);
  }

  int get lanBasePort {
    final int i = lanHost.lastIndexOf(':');
    return i < 0 ? 9100 : int.tryParse(lanHost.substring(i + 1)) ?? 9100;
  }

  final Map<PrinterVendor, PrinterBackend> _backends =
      <PrinterVendor, PrinterBackend>{};

  PrinterBackend backend(PrinterVendor vendor) =>
      _backends.putIfAbsent(vendor, () => createPrinterBackend(vendor));

  PrinterBackend get bt => backend(PrinterVendor.bluetooth);

  /// Printer USB internal iMin D1 (ALT althicoA726).
  PrinterBackend get usb => backend(PrinterVendor.usb);

  static const PrinterDevice internalUsb =
      PrinterDevice(name: 'Printer USB internal', macAddress: 'usb:1305:8211');

  /// Printer LAN sungguhan: host dari kolom LAN (port default 9100).
  PrinterBackend get realLan => backend(PrinterVendor.lan);

  PrinterDevice get realLanDevice {
    if (lanHost.isEmpty) throw Skip('isi alamat printer LAN di kolom LAN');
    return PrinterDevice(
      name: 'LAN nyata',
      macAddress: lanHostOnly.isEmpty
          ? lanHost
          : '$lanHostOnly:${lanHost.contains(':') ? lanBasePort : 9100}',
    );
  }

  PrinterDevice? target;

  /// Printer Bluetooth yang diuji. Gagal bila tidak ada yang ter-pairing.
  Future<PrinterDevice> requireTarget() async {
    final PrinterDevice? cached = target;
    if (cached != null) return cached;
    final List<PrinterDevice> devices = await bt.discoverDevices();
    for (final PrinterDevice device in devices) {
      final bool match = btAddress.isNotEmpty
          ? device.macAddress.toLowerCase() == btAddress.toLowerCase()
          : device.name.toLowerCase().contains('printer');
      if (match) return target = device;
    }
    throw Fail(
      'Tidak ada printer Bluetooth ter-pairing yang cocok. '
      'Ter-pairing: ${devices.map((d) => '${d.name}/${d.macAddress}').join(', ')}',
    );
  }
}

typedef Body = Future<String?> Function(Ctx c);

class TestCase {
  const TestCase(
    this.group,
    this.id,
    this.title,
    this.body, {
    this.prints = false,
    this.disruptive = false,
    this.timeout = const Duration(seconds: 60),
  });

  final String group;
  final String id;
  final String title;
  final Body body;

  /// Mencetak ke kertas (butuh printer dan kertas).
  final bool prints;

  /// Mengubah keadaan Bluetooth perangkat (mati/nyala).
  final bool disruptive;
  final Duration timeout;
}

Future<Outcome> runCase(TestCase test, Ctx ctx) async {
  final Stopwatch watch = Stopwatch()..start();
  Verdict verdict;
  String note;
  try {
    note = await test.body(ctx).timeout(test.timeout) ?? '';
    verdict = Verdict.pass;
  } on Fail catch (e) {
    verdict = Verdict.fail;
    note = e.message;
  } on Skip catch (e) {
    verdict = Verdict.skip;
    note = e.message;
  } on Info catch (e) {
    verdict = Verdict.info;
    note = e.message;
  } on TimeoutException {
    verdict = Verdict.fail;
    note = 'Melewati batas waktu ${test.timeout.inSeconds} dtk.';
  } catch (e, st) {
    verdict = Verdict.fail;
    note = 'Exception tak terduga: $e\n${st.toString().split('\n').take(3).join('\n')}';
  }
  watch.stop();
  final Outcome outcome = Outcome(verdict, note, watch.elapsed);
  // ignore: avoid_print
  print('HARNESS|${test.group}|${test.id}|${verdict.name.toUpperCase()}|'
      '${watch.elapsedMilliseconds}ms|${note.replaceAll('\n', ' / ')}');
  return outcome;
}

void check(bool condition, String message) {
  if (!condition) throw Fail(message);
}

T unwrap<T>(PrinterResult<T> result, String what) => switch (result) {
      PrinterOk<T>(:final value) => value,
      PrinterErr<T>(:final failure) =>
        throw Fail('$what gagal: ${failure.message}'),
    };

PrinterFailure expectErr<T>(PrinterResult<T> result, String what) =>
    switch (result) {
      PrinterErr<T>(:final failure) => failure,
      PrinterOk<T>() => throw Fail('$what seharusnya gagal tetapi sukses'),
    };

String describe(PrinterStatus s) =>
    'hasPaper=${s.hasPaper}, coverClosed=${s.coverClosed}, hasError=${s.hasError}';

String describeCaps(PrinterCapabilities c) =>
    'paperWidthPx=${c.paperWidthPx}, autoCut=${c.autoCut}, '
    'reportsPaperOut=${c.reportsPaperOut}, confirmsPrint=${c.confirmsPrint}';

/// Struk yang memuat SEMUA jenis baris kontrak.
Receipt fullReceipt(String label, {ReceiptKind kind = ReceiptKind.customer}) =>
    Receipt(
      kind: kind,
      lines: <ReceiptLine>[
        ReceiptCenter('HARNESS TEST', emphasized: true),
        ReceiptCenter(label),
        const ReceiptDivider(),
        const ReceiptRow('Kode', 'TRX-0001'),
        const ReceiptRow('Total', 'Rp 5.000', emphasized: true),
        const ReceiptBlank(),
        const ReceiptQr('TRX-0001'),
        const ReceiptCenter('TRX-0001'),
        const ReceiptDivider(),
        const ReceiptCenter('Struk uji — abaikan'),
      ],
    );

Receipt longReceipt(int lines) => Receipt(
      lines: <ReceiptLine>[
        const ReceiptCenter('HARNESS STRUK PANJANG', emphasized: true),
        for (int i = 1; i <= lines; i++)
          ReceiptRow('Baris ${i.toString().padLeft(3, '0')}', 'Rp ${i * 100}'),
        const ReceiptDivider(),
        const ReceiptCenter('Akhir struk panjang'),
      ],
    );

/// Mengumpulkan event dari stream scan sampai selesai.
class ScanCapture {
  final List<ScanEvent> events = <ScanEvent>[];
  ScanFinished? finished;
  int get found => events.whereType<DeviceFound>().length;
}

Future<ScanCapture> collectScan(
  PrinterDeviceScanner scanner, {
  Duration timeout = const Duration(seconds: 25),
  Future<void> Function()? duringScan,
}) async {
  final ScanCapture capture = ScanCapture();
  final Completer<void> done = Completer<void>();
  final StreamSubscription<ScanEvent> sub = scanner.scan().listen(
    (ScanEvent e) {
      capture.events.add(e);
      if (e is ScanFinished) {
        capture.finished = e;
        if (!done.isCompleted) done.complete();
      }
    },
    onError: (Object e) {
      if (!done.isCompleted) done.completeError(e);
    },
  );
  try {
    if (duringScan != null) await duringScan();
    await done.future.timeout(timeout);
  } finally {
    await sub.cancel();
  }
  return capture;
}

Future<TransportPowerState> waitPower(
  TransportPowerControl power,
  TransportPowerState want, {
  Duration timeout = const Duration(seconds: 12),
}) async {
  final Stopwatch watch = Stopwatch()..start();
  while (watch.elapsed < timeout) {
    final TransportPowerState state = await power.powerState();
    if (state == want) return state;
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
  return power.powerState();
}

// ---------------------------------------------------------------------------
// Daftar kasus uji
// ---------------------------------------------------------------------------

final List<TestCase> allTests = <TestCase>[
  // ===== Dart murni (berjalan di perangkat) ================================
  TestCase('status', 'S1', 'PrinterStatus: parse byte DLE EOT', (c) async {
    final PrinterStatus ok = PrinterStatus.fromOfflineStatusByte(0x12);
    check(ok.hasPaper == true && ok.coverClosed == true && ok.hasError == false,
        '0x12 seharusnya normal: ${describe(ok)}');
    check(PrinterStatus.fromOfflineStatusByte(0x32).hasPaper == false,
        '0x32 seharusnya kertas habis');
    check(PrinterStatus.fromOfflineStatusByte(0x16).coverClosed == false,
        '0x16 seharusnya cover terbuka');
    check(PrinterStatus.fromOfflineStatusByte(0x52).hasError == true,
        '0x52 seharusnya galat');
    check(PrinterStatus.tryFromOfflineStatusByte(0x00) == PrinterStatus.unknown,
        'byte tidak valid seharusnya unknown');
    check(PrinterStatus(hasPaper: false).problemMessage == 'Kertas printer habis.',
        'problemMessage kertas habis');
    return null;
  }),
  TestCase('gate', 'G1', 'PrintJobGate: busy-lock dan timeout', (c) async {
    final PrintJobGate gate = PrintJobGate(
      timeout: const Duration(milliseconds: 300),
      stuckAfter: const Duration(milliseconds: 300),
    );
    final Completer<void> hold = Completer<void>();
    final Future<PrinterResult<int>> first = gate.run<int>(() async {
      await hold.future;
      return const PrinterOk<int>(1);
    });
    check(gate.isBusy, 'gate seharusnya sibuk');
    final PrinterFailure busy =
        expectErr(await gate.run<int>(() async => const PrinterOk<int>(2)), 'job kedua');
    check(busy.message == PrintJobGate.busyMessage, 'pesan busy salah: ${busy.message}');
    final PrinterFailure timeout = expectErr(await first, 'job pertama');
    check(timeout.message == PrintJobGate.timeoutMessage,
        'pesan timeout salah: ${timeout.message}');
    hold.complete();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    check(!gate.isBusy, 'gate seharusnya bebas setelah job selesai');
    return null;
  }),
  TestCase('receipt', 'R1', 'Receipt.toPlainText memuat semua jenis baris', (c) async {
    final String text = fullReceipt('x').toPlainText();
    for (final String part in <String>['HARNESS TEST', 'Kode', 'Rp 5.000', 'TRX-0001']) {
      check(text.contains(part), 'toPlainText tidak memuat "$part"');
    }
    return null;
  }),

  // ===== Vendor & deteksi ==================================================
  TestCase('vendor', 'V1', 'detectBuiltInPrinterVendor()', (c) async {
    final PrinterVendor? vendor = await detectBuiltInPrinterVendor();
    throw Info('terdeteksi: ${vendor?.name ?? 'tidak ada printer bawaan'}');
  }),
  TestCase('vendor', 'V2', 'createPrinterBackend untuk semua vendor', (c) async {
    final List<String> rows = <String>[];
    for (final PrinterVendor vendor in PrinterVendor.values) {
      final PrinterBackend b = createPrinterBackend(vendor);
      check(b.displayName.isNotEmpty, '${vendor.name}: displayName kosong');
      rows.add('${vendor.name}(requiresPairing=${b.requiresPairing}, '
          'paperWidth=${b.supportsPaperWidthSetting})');
    }
    return rows.join('; ');
  }),
  TestCase('vendor', 'V3', 'Backend bawaan: tidak melempar saat servis tak ada', (c) async {
    final List<String> rows = <String>[];
    for (final PrinterVendor vendor in <PrinterVendor>[
      PrinterVendor.innerImin,
      PrinterVendor.innerSunmi,
      PrinterVendor.innerXcheng,
    ]) {
      final PrinterBackend b = createPrinterBackend(vendor);
      final bool available = await b.isAvailable();
      final List<PrinterDevice> devices = await b.discoverDevices();
      String connect = 'tanpa perangkat';
      if (devices.isNotEmpty) {
        connect = (await b.connect(devices.first)).fold(
          onOk: (_) => 'connect OK',
          onErr: (f) => 'connect Err("${f.message}")',
        );
      }
      await b.disconnect();
      rows.add('${vendor.name}: available=$available, devices=${devices.length}, $connect');
    }
    return rows.join('; ');
  }),

  // ===== Kontrol Bluetooth (power / prasyarat / scan / pairing) ============
  TestCase('control', 'F1', 'printerFeature: kemampuan opsional tersedia', (c) async {
    check(printerFeature<TransportPowerControl>(c.bt) != null, 'TransportPowerControl null');
    check(printerFeature<PrinterDeviceScanner>(c.bt) != null, 'PrinterDeviceScanner null');
    check(printerFeature<TransportPrerequisites>(c.bt) != null, 'TransportPrerequisites null');
    check(printerFeature<TransportPowerControl>(c.backend(PrinterVendor.innerImin)) == null,
        'backend bawaan seharusnya tanpa TransportPowerControl');
    return null;
  }),
  TestCase('control', 'F2', 'checkPrerequisites: laporan prasyarat', (c) async {
    final TransportPrerequisites p = printerFeature<TransportPrerequisites>(c.bt)!;
    final PrerequisiteReport r = await p.checkPrerequisites();
    check(r.items.isNotEmpty, 'laporan kosong');
    final String items = r.items
        .map((i) => '${i.id}:${i.status.name}')
        .join(', ');
    final String next = r.nextStepFor(TransportOperation.scan)?.id ?? '-';
    throw Info('sdk=${r.sdkInt}; $items; langkah scan berikutnya=$next');
  }),
  TestCase('control', 'F3', 'powerState() menyala', (c) async {
    final TransportPowerControl p = printerFeature<TransportPowerControl>(c.bt)!;
    final TransportPowerState s = await p.powerState();
    check(s == TransportPowerState.on, 'state=$s (Bluetooth harus menyala)');
    return null;
  }),
  TestCase('control', 'F4', 'setEnabled(true) saat menyala → alreadyInState', (c) async {
    final TransportPowerControl p = printerFeature<TransportPowerControl>(c.bt)!;
    final PowerToggleOutcome o = unwrap(await p.setEnabled(true), 'setEnabled(true)');
    check(o == PowerToggleOutcome.alreadyInState, 'outcome=$o');
    return null;
  }),
  TestCase('control', 'F5', 'scan(): ScanStarted → ScanFinished', (c) async {
    final PrinterDeviceScanner s = printerFeature<PrinterDeviceScanner>(c.bt)!;
    final TransportPrerequisites p = printerFeature<TransportPrerequisites>(c.bt)!;
    final PrerequisiteReport r = await p.checkPrerequisites();
    final Prerequisite? missing = r.nextStepFor(TransportOperation.scan);
    if (missing != null) {
      throw Fail('prasyarat scan belum terpenuhi: ${missing.id} (${missing.status.name})');
    }
    final ScanCapture cap = await collectScan(s);
    check(cap.events.first is ScanStarted, 'event pertama bukan ScanStarted');
    final ScanFinished fin = cap.finished!;
    check(!s.isScanning, 'isScanning masih true setelah selesai');
    final String named = cap.events
        .whereType<DeviceFound>()
        .map((e) => e.printer.device.name.isEmpty ? '?' : e.printer.device.name)
        .take(8)
        .join(', ');
    return 'ditemukan ${cap.found} perangkat [$named]; selesai=${fin.reason.name}'
        '${fin.failure != null ? ' (${fin.failure!.message})' : ''}';
  }, timeout: const Duration(seconds: 40)),
  TestCase('control', 'F6', 'stopScan(): scan berhenti dengan reason stopped', (c) async {
    final PrinterDeviceScanner s = printerFeature<PrinterDeviceScanner>(c.bt)!;
    final ScanCapture cap = await collectScan(
      s,
      timeout: const Duration(seconds: 8),
      duringScan: () async {
        await Future<void>.delayed(const Duration(seconds: 1));
        check(s.isScanning, 'isScanning seharusnya true di tengah scan');
        await s.stopScan();
      },
    );
    final ScanEndReason reason = cap.finished!.reason;
    check(reason == ScanEndReason.stopped, 'reason=$reason');
    check(!s.isScanning, 'isScanning masih true setelah stopScan');
    return null;
  }, timeout: const Duration(seconds: 20)),
  TestCase('control', 'F7', 'pair() pada printer yang sudah ter-pairing', (c) async {
    final PrinterDevice target = await c.requireTarget();
    final PrinterDeviceScanner s = printerFeature<PrinterDeviceScanner>(c.bt)!;
    final PrinterDevice paired = unwrap(await s.pair(target), 'pair');
    check(paired.macAddress == target.macAddress, 'MAC hasil pair berbeda');
    return null;
  }, timeout: const Duration(seconds: 90)),
  TestCase('control', 'F8', 'Siklus nyala/mati Bluetooth + watchPowerState', (c) async {
    final TransportPowerControl p = printerFeature<TransportPowerControl>(c.bt)!;
    final List<TransportPowerState> seen = <TransportPowerState>[];
    final StreamSubscription<TransportPowerState> sub =
        p.watchPowerState().listen(seen.add);
    try {
      unwrap(await p.setEnabled(false), 'setEnabled(false)');
      final TransportPowerState off = await waitPower(p, TransportPowerState.off);
      check(off == TransportPowerState.off, 'setelah dimatikan state=$off');
      unwrap(await p.setEnabled(true), 'setEnabled(true)');
      final TransportPowerState on = await waitPower(p, TransportPowerState.on);
      check(on == TransportPowerState.on, 'setelah dinyalakan state=$on');
      await Future<void>.delayed(const Duration(seconds: 1));
    } finally {
      await sub.cancel();
    }
    check(seen.contains(TransportPowerState.off),
        'watchPowerState tidak pernah mengirim off (event: ${seen.map((e) => e.name).toList()})');
    check(seen.contains(TransportPowerState.on),
        'watchPowerState tidak pernah mengirim on (event: ${seen.map((e) => e.name).toList()})');
    return 'event: ${seen.map((e) => e.name).join(' → ')}';
  }, disruptive: true, timeout: const Duration(seconds: 60)),
  TestCase('control', 'F9', 'Bluetooth dimatikan di tengah scan → adapterOff', (c) async {
    final TransportPowerControl p = printerFeature<TransportPowerControl>(c.bt)!;
    final PrinterDeviceScanner s = printerFeature<PrinterDeviceScanner>(c.bt)!;
    ScanCapture? cap;
    try {
      cap = await collectScan(
        s,
        timeout: const Duration(seconds: 15),
        duringScan: () async {
          await Future<void>.delayed(const Duration(seconds: 1));
          unwrap(await p.setEnabled(false), 'setEnabled(false)');
        },
      );
    } finally {
      await p.setEnabled(true);
      await waitPower(p, TransportPowerState.on);
    }
    final ScanEndReason reason = cap.finished!.reason;
    check(reason == ScanEndReason.adapterOff || reason == ScanEndReason.stopped,
        'reason=$reason');
    return 'reason=${reason.name}';
  }, disruptive: true, timeout: const Duration(seconds: 60)),
  TestCase('control', 'F10', 'Tersambung → Bluetooth mati/nyala → ensureConnected pulih', (c) async {
    final PrinterDevice target = await c.requireTarget();
    final TransportPowerControl p = printerFeature<TransportPowerControl>(c.bt)!;
    unwrap(await c.bt.connect(target), 'connect awal');
    try {
      unwrap(await p.setEnabled(false), 'setEnabled(false)');
      await waitPower(p, TransportPowerState.off);
      final PrinterFailure offFail =
          expectErr(await c.bt.ensureConnected(lastDevice: target), 'ensureConnected saat mati');
      unwrap(await p.setEnabled(true), 'setEnabled(true)');
      await waitPower(p, TransportPowerState.on);
      await Future<void>.delayed(const Duration(seconds: 2));
      unwrap(await c.bt.ensureConnected(lastDevice: target), 'ensureConnected setelah nyala');
      return 'saat mati: "${offFail.message}"; setelah nyala tersambung kembali';
    } finally {
      await p.setEnabled(true);
    }
  }, disruptive: true, timeout: const Duration(seconds: 90)),

  // ===== Backend inti (Bluetooth ESC/POS) ==================================
  TestCase('core', 'C1', 'discoverDevices() memuat printer target', (c) async {
    final PrinterDevice t = await c.requireTarget();
    return 'target=${t.name}/${t.macAddress}';
  }),
  TestCase('core', 'C2', 'ensureConnected(null) → requiresDeviceSelection', (c) async {
    final PrinterFailure f = expectErr(await c.bt.ensureConnected(), 'ensureConnected(null)');
    check(f.requiresDeviceSelection, 'requiresDeviceSelection=false (${f.message})');
    return f.message;
  }),
  TestCase('core', 'C3', 'ensureConnected(perangkat tak dikenal) → requiresDeviceSelection', (c) async {
    final PrinterFailure f = expectErr(
      await c.bt.ensureConnected(
        lastDevice: const PrinterDevice(name: 'Hantu', macAddress: '11:11:11:11:11:11'),
      ),
      'ensureConnected(hantu)',
    );
    check(f.requiresDeviceSelection, 'requiresDeviceSelection=false (${f.message})');
    return f.message;
  }),
  TestCase('core', 'C4', 'connect() + isConnected()', (c) async {
    final PrinterDevice t = await c.requireTarget();
    unwrap(await c.bt.connect(t), 'connect');
    check(await c.bt.isConnected(), 'isConnected() false setelah connect');
    return null;
  }),
  TestCase('core', 'C5', 'connect() ulang ke alamat yang sama tetap sukses', (c) async {
    final PrinterDevice t = await c.requireTarget();
    unwrap(await c.bt.connect(t), 'connect pertama');
    final Stopwatch w = Stopwatch()..start();
    unwrap(await c.bt.connect(t), 'connect kedua');
    return 'connect kedua ${w.elapsedMilliseconds} ms';
  }),
  TestCase('core', 'C6', 'ensureConnected(lastDevice) → OK', (c) async {
    final PrinterDevice t = await c.requireTarget();
    final PrinterDevice d = unwrap(await c.bt.ensureConnected(lastDevice: t), 'ensureConnected');
    check(d.macAddress == t.macAddress, 'MAC berbeda');
    return null;
  }),
  TestCase('core', 'C7', 'checkStatus()', (c) async {
    final PrinterDevice t = await c.requireTarget();
    unwrap(await c.bt.ensureConnected(lastDevice: t), 'ensureConnected');
    final PrinterStatus s = unwrap(await c.bt.checkStatus(), 'checkStatus');
    throw Info(describe(s));
  }),
  TestCase('core', 'C8', 'capabilities()', (c) async {
    final PrinterCapabilities caps = await c.bt.capabilities();
    check(caps.paperWidthPx == paperWidth58Px || caps.paperWidthPx == paperWidth80Px,
        'paperWidthPx=${caps.paperWidthPx} bukan 384/576');
    throw Info(describeCaps(caps));
  }),
  TestCase('core', 'C9', 'setPaperWidth → lebar capabilities mengikuti', (c) async {
    check(c.bt.supportsPaperWidthSetting, 'supportsPaperWidthSetting=false');
    final List<String> rows = <String>[];
    c.bt.setPaperWidth(PaperWidthSetting.mm58);
    int px = (await c.bt.capabilities()).paperWidthPx;
    check(px == paperWidth58Px, 'mm58 → $px');
    rows.add('mm58=$px');
    c.bt.setPaperWidth(PaperWidthSetting.mm80);
    px = (await c.bt.capabilities()).paperWidthPx;
    check(px == paperWidth80Px, 'mm80 → $px');
    rows.add('mm80=$px');
    c.bt.setPaperWidth(PaperWidthSetting.auto);
    px = (await c.bt.capabilities()).paperWidthPx;
    rows.add('auto=$px');
    return rows.join(', ');
  }),
  TestCase('core', 'C10', 'preview(): PNG untuk semua jenis baris, kedua ReceiptKind', (c) async {
    final List<String> rows = <String>[];
    for (final ReceiptKind kind in ReceiptKind.values) {
      final List<int> png = await c.bt.preview(fullReceipt('preview ${kind.name}', kind: kind));
      check(png.length > 100 && png[0] == 0x89 && png[1] == 0x50 && png[2] == 0x4E && png[3] == 0x47,
          'bukan PNG valid untuk ${kind.name} (${png.length} byte)');
      rows.add('${kind.name}=${png.length}B');
    }
    final List<int> big = await c.bt.preview(longReceipt(120));
    check(big.length > 1000, 'preview struk panjang terlalu kecil');
    rows.add('panjang=${big.length}B');
    return rows.join(', ');
  }),
  TestCase('core', 'C11', 'disconnect() → isConnected false; printReceipt tanpa koneksi → Err', (c) async {
    await c.bt.disconnect();
    check(!await c.bt.isConnected(), 'isConnected() masih true setelah disconnect');
    final PrinterFailure f = expectErr(await c.bt.printReceipt(fullReceipt('tanpa koneksi')), 'printReceipt tanpa koneksi');
    return 'pesan: "${f.message}"';
  }),
  TestCase('core', 'C12', 'Sambung ulang setelah disconnect', (c) async {
    final PrinterDevice t = await c.requireTarget();
    await c.bt.disconnect();
    unwrap(await c.bt.ensureConnected(lastDevice: t), 'ensureConnected setelah disconnect');
    check(await c.bt.isConnected(), 'tidak tersambung kembali');
    return null;
  }),
  TestCase('core', 'C13', 'Fallback Xcheng→Sunmi: Err bersih, tanpa exception', (c) async {
    final PrinterBackend b = createPrinterBackend(PrinterVendor.innerXcheng);
    final List<PrinterDevice> devices = await b.discoverDevices();
    final String r = devices.isEmpty
        ? 'tanpa perangkat'
        : (await b.connect(devices.first)).fold(onOk: (_) => 'OK', onErr: (f) => 'Err(${f.message})');
    await b.disconnect();
    return 'devices=${devices.length}, connect=$r';
  }),

  // ===== Cetak fisik =======================================================
  TestCase('print', 'P1', 'printReceipt(): struk lengkap (semua jenis baris)', (c) async {
    final PrinterDevice t = await c.requireTarget();
    unwrap(await c.bt.ensureConnected(lastDevice: t), 'ensureConnected');
    final Stopwatch w = Stopwatch()..start();
    final PrintDelivery d = unwrap(await c.bt.printReceipt(fullReceipt('P1 lengkap')), 'printReceipt');
    return 'delivery=${d.name}, ${w.elapsedMilliseconds} ms — periksa kertas';
  }, prints: true),
  TestCase('print', 'P2', 'Cetak bersamaan: satu OK, satu ditolak busy', (c) async {
    final PrinterDevice t = await c.requireTarget();
    unwrap(await c.bt.ensureConnected(lastDevice: t), 'ensureConnected');
    final List<PrinterResult<PrintDelivery>> r = await Future.wait(<Future<PrinterResult<PrintDelivery>>>[
      c.bt.printReceipt(fullReceipt('P2 pertama')),
      c.bt.printReceipt(fullReceipt('P2 kedua')),
    ]);
    final int ok = r.where((e) => e.isOk).length;
    final List<PrinterFailure> errs = <PrinterFailure>[
      for (final PrinterResult<PrintDelivery> e in r)
        if (e.failureOrNull != null) e.failureOrNull!,
    ];
    check(ok == 1 && errs.length == 1, 'ok=$ok err=${errs.length}');
    check(errs.single.message == PrintJobGate.busyMessage, 'pesan: ${errs.single.message}');
    return 'satu struk tercetak, satu ditolak';
  }, prints: true),
  TestCase('print', 'P3', 'Struk panjang (120 baris, multi-pita raster)', (c) async {
    final PrinterDevice t = await c.requireTarget();
    unwrap(await c.bt.ensureConnected(lastDevice: t), 'ensureConnected');
    final Stopwatch w = Stopwatch()..start();
    final PrintDelivery d = unwrap(await c.bt.printReceipt(longReceipt(120)), 'printReceipt');
    return 'delivery=${d.name}, ${w.elapsedMilliseconds} ms — periksa 120 baris utuh';
  }, prints: true, timeout: const Duration(seconds: 90)),
  TestCase('print', 'P4', 'QR: data pendek, panjang (180 karakter), dan unicode', (c) async {
    final PrinterDevice t = await c.requireTarget();
    unwrap(await c.bt.ensureConnected(lastDevice: t), 'ensureConnected');
    final String long = List<String>.generate(180, (i) => String.fromCharCode(97 + i % 26)).join();
    final Receipt r = Receipt(lines: <ReceiptLine>[
      const ReceiptCenter('HARNESS QR', emphasized: true),
      const ReceiptQr('A'),
      ReceiptQr(long),
      const ReceiptQr('Parkir ÅÉ 駐車場 ✓'),
      const ReceiptCenter('3 QR: A / 180 huruf / unicode'),
    ]);
    unwrap(await c.bt.printReceipt(r), 'printReceipt');
    return 'periksa 3 QR bisa dipindai';
  }, prints: true),
  TestCase('print', 'P5', 'Lebar kertas 58 / 80 / otomatis', (c) async {
    final PrinterDevice t = await c.requireTarget();
    unwrap(await c.bt.ensureConnected(lastDevice: t), 'ensureConnected');
    final List<String> rows = <String>[];
    try {
      for (final PaperWidthSetting setting in PaperWidthSetting.values) {
        c.bt.setPaperWidth(setting);
        final int px = (await c.bt.capabilities()).paperWidthPx;
        unwrap(await c.bt.printReceipt(fullReceipt('P5 ${setting.name} ${px}px')), 'print ${setting.name}');
        rows.add('${setting.name}=${px}px');
      }
    } finally {
      c.bt.setPaperWidth(PaperWidthSetting.auto);
    }
    return '${rows.join(', ')} — periksa lebar tiap struk';
  }, prints: true, timeout: const Duration(seconds: 90)),
  TestCase('print', 'P6', 'Tiga cetakan beruntun stabil', (c) async {
    final PrinterDevice t = await c.requireTarget();
    unwrap(await c.bt.ensureConnected(lastDevice: t), 'ensureConnected');
    final List<int> ms = <int>[];
    for (int i = 1; i <= 3; i++) {
      final Stopwatch w = Stopwatch()..start();
      unwrap(await c.bt.printReceipt(fullReceipt('P6 #$i')), 'cetak #$i');
      ms.add(w.elapsedMilliseconds);
    }
    return 'waktu: ${ms.join(' / ')} ms';
  }, prints: true, timeout: const Duration(seconds: 120)),
  TestCase('print', 'P7', 'Cetak setelah disconnect: Err, lalu pulih setelah ensureConnected', (c) async {
    final PrinterDevice t = await c.requireTarget();
    await c.bt.disconnect();
    expectErr(await c.bt.printReceipt(fullReceipt('tidak boleh tercetak')), 'cetak tanpa koneksi');
    unwrap(await c.bt.ensureConnected(lastDevice: t), 'ensureConnected');
    unwrap(await c.bt.printReceipt(fullReceipt('P7 pulih')), 'cetak setelah pulih');
    return 'periksa hanya satu struk (P7 pulih)';
  }, prints: true),

  // ===== LAN (server TCP palsu di PC) ======================================
  TestCase('lan', 'L1', 'parseNetworkAddress', (c) async {
    check(parseNetworkAddress('192.168.1.5') == const NetworkAddress('192.168.1.5', 9100), 'ip tanpa port');
    check(parseNetworkAddress('192.168.1.5:9101') == const NetworkAddress('192.168.1.5', 9101), 'ip + port');
    check(parseNetworkAddress('printer.local:9100') != null, 'hostname');
    check(parseNetworkAddress('999.1.1.1') == null, 'ip > 255');
    check(parseNetworkAddress('1.2.3.4:0') == null, 'port 0');
    check(parseNetworkAddress('1.2.3.4:70000') == null, 'port > 65535');
    check(parseNetworkAddress('') == null, 'kosong');
    check(parseNetworkAddress('1.2.3') == null, 'ip tidak lengkap');
    return null;
  }),
  TestCase('lan', 'L2', 'Alamat tidak valid → requiresDeviceSelection', (c) async {
    final PrinterBackend b = c.backend(PrinterVendor.lan);
    final PrinterFailure f = expectErr(
      await b.connect(const PrinterDevice(name: 'x', macAddress: 'bukan alamat')),
      'connect alamat tidak valid',
    );
    check(f.requiresDeviceSelection, 'requiresDeviceSelection=false (${f.message})');
    return f.message;
  }),
  TestCase('lan', 'L3', 'Host tak terjangkau → Err dalam batas waktu', (c) async {
    final PrinterBackend b = createPrinterBackend(PrinterVendor.lan);
    final Stopwatch w = Stopwatch()..start();
    final PrinterFailure f = expectErr(
      await b.connect(const PrinterDevice(name: 'x', macAddress: '10.255.255.1:9100')),
      'connect host tak terjangkau',
    );
    check(w.elapsed < const Duration(seconds: 15), 'terlalu lama: ${w.elapsed}');
    return '${w.elapsedMilliseconds} ms: ${f.message}';
  }, timeout: const Duration(seconds: 30)),
  TestCase('lan', 'L4', 'Cetak ke server TCP palsu (status normal 0x12)', (c) async {
    return _lanPrint(c, 9100, expectOk: true, label: 'L4 normal');
  }),
  TestCase('lan', 'L5', 'Pre-check: kertas habis (0x32) → Err sebelum kirim', (c) async {
    return _lanPrint(c, 9101, expectOk: false, label: 'L5 kertas habis', expectMessage: 'Kertas printer habis.');
  }),
  TestCase('lan', 'L6', 'Pre-check: cover terbuka (0x16) → Err', (c) async {
    return _lanPrint(c, 9102, expectOk: false, label: 'L6 cover', expectMessage: 'Penutup printer terbuka.');
  }),
  TestCase('lan', 'L7', 'Pre-check: galat printer (0x52) → Err', (c) async {
    return _lanPrint(c, 9103, expectOk: false, label: 'L7 galat', expectMessage: 'Printer melaporkan galat.');
  }),
  TestCase('lan', 'L8', 'Printer bisu (tanpa jawaban status) tetap mencetak', (c) async {
    return _lanPrint(c, 9104, expectOk: true, label: 'L8 bisu');
  }, timeout: const Duration(seconds: 90)),

  // ===== Printer bawaan iMin D1 lewat USB internal =========================
  TestCase('builtin', 'IB1', 'detectBuiltInPrinterVendor → innerIminUsb (tanpa dialog izin)', (c) async {
    final Stopwatch w = Stopwatch()..start();
    final PrinterVendor? vendor = await detectBuiltInPrinterVendor();
    check(vendor == PrinterVendor.innerIminUsb, 'terdeteksi: ${vendor?.name}');
    return '${w.elapsedMilliseconds} ms';
  }),
  TestCase('builtin', 'IB2', 'innerIminUsb: ensureConnected() tanpa lastDevice', (c) async {
    final PrinterBackend b = c.backend(PrinterVendor.innerIminUsb);
    check(!b.requiresPairing, 'requiresPairing seharusnya false');
    final PrinterDevice d = unwrap(await b.ensureConnected(), 'ensureConnected');
    final PrinterStatus s = unwrap(await b.checkStatus(), 'checkStatus');
    return '${d.name}/${d.macAddress}; ${describe(s)}';
  }, timeout: const Duration(seconds: 90)),
  TestCase('builtin', 'IB3', 'innerIminUsb: printReceipt', (c) async {
    final PrinterBackend b = c.backend(PrinterVendor.innerIminUsb);
    unwrap(await b.ensureConnected(), 'ensureConnected');
    final PrintDelivery d = unwrap(await b.printReceipt(fullReceipt('IB3 innerIminUsb')), 'printReceipt');
    return 'delivery=${d.name} — periksa struk "IB3"';
  }, prints: true, timeout: const Duration(seconds: 90)),
  TestCase('builtin', 'IU1', 'USB: discoverDevices memuat printer internal', (c) async {
    final List<PrinterDevice> devices = await c.usb.discoverDevices();
    final String list = devices.map((d) => '${d.name}/${d.macAddress}').join(', ');
    check(devices.any((d) => d.macAddress == Ctx.internalUsb.macAddress),
        'printer internal tidak ada di daftar: $list');
    return list;
  }),
  TestCase('builtin', 'IU2', 'USB: connect (izin USB) + isConnected', (c) async {
    final Stopwatch w = Stopwatch()..start();
    unwrap(await c.usb.connect(Ctx.internalUsb), 'connect');
    check(await c.usb.isConnected(), 'isConnected() false setelah connect');
    return 'tersambung ${w.elapsedMilliseconds} ms';
  }, timeout: const Duration(seconds: 90)),
  TestCase('builtin', 'IU3', 'USB: checkStatus dari printer internal', (c) async {
    unwrap(await c.usb.ensureConnected(lastDevice: Ctx.internalUsb), 'ensureConnected');
    final Stopwatch w = Stopwatch()..start();
    final PrinterStatus s = unwrap(await c.usb.checkStatus(), 'checkStatus');
    throw Info('${describe(s)} (${w.elapsedMilliseconds} ms)');
  }),
  TestCase('builtin', 'IU4', 'USB: capabilities sebelum cetak', (c) async {
    unwrap(await c.usb.ensureConnected(lastDevice: Ctx.internalUsb), 'ensureConnected');
    throw Info(describeCaps(await c.usb.capabilities()));
  }),
  TestCase('builtin', 'IU5', 'USB: printReceipt struk lengkap', (c) async {
    unwrap(await c.usb.ensureConnected(lastDevice: Ctx.internalUsb), 'ensureConnected');
    final Stopwatch w = Stopwatch()..start();
    final PrintDelivery d = unwrap(await c.usb.printReceipt(fullReceipt('IU5 USB internal')), 'printReceipt');
    return 'delivery=${d.name}, ${w.elapsedMilliseconds} ms; sesudah: ${describeCaps(await c.usb.capabilities())}';
  }, prints: true, timeout: const Duration(seconds: 90)),
  TestCase('builtin', 'IU6', 'USB: struk panjang 120 baris (> 16 KB)', (c) async {
    unwrap(await c.usb.ensureConnected(lastDevice: Ctx.internalUsb), 'ensureConnected');
    final Stopwatch w = Stopwatch()..start();
    unwrap(await c.usb.printReceipt(longReceipt(120)), 'printReceipt');
    return '${w.elapsedMilliseconds} ms — periksa 120 baris utuh';
  }, prints: true, timeout: const Duration(seconds: 120)),
  TestCase('builtin', 'IU7', 'USB: 3 QR (pendek, panjang, unicode)', (c) async {
    unwrap(await c.usb.ensureConnected(lastDevice: Ctx.internalUsb), 'ensureConnected');
    final String long = List<String>.generate(180, (i) => String.fromCharCode(97 + i % 26)).join();
    unwrap(await c.usb.printReceipt(Receipt(lines: <ReceiptLine>[
      const ReceiptCenter('IU7 QR', emphasized: true),
      const ReceiptQr('A'),
      ReceiptQr(long),
      const ReceiptQr('Parkir ÅÉ 駐車場 ✓'),
      const ReceiptCenter('3 QR: A / 180 huruf / unicode'),
    ])), 'printReceipt');
    return 'periksa 3 QR bisa dipindai';
  }, prints: true, timeout: const Duration(seconds: 90)),
  TestCase('builtin', 'IU8', 'USB: lebar kertas 58 / 80 / otomatis', (c) async {
    unwrap(await c.usb.ensureConnected(lastDevice: Ctx.internalUsb), 'ensureConnected');
    final List<String> rows = <String>[];
    try {
      for (final PaperWidthSetting setting in PaperWidthSetting.values) {
        c.usb.setPaperWidth(setting);
        final int px = (await c.usb.capabilities()).paperWidthPx;
        unwrap(await c.usb.printReceipt(fullReceipt('IU8 ${setting.name} ${px}px')), 'print ${setting.name}');
        rows.add('${setting.name}=${px}px');
      }
    } finally {
      c.usb.setPaperWidth(PaperWidthSetting.auto);
    }
    return '${rows.join(', ')} — periksa lebar tiap struk';
  }, prints: true, timeout: const Duration(seconds: 120)),
  TestCase('builtin', 'IU9', 'USB: cetak bersamaan + disconnect lalu pulih', (c) async {
    unwrap(await c.usb.ensureConnected(lastDevice: Ctx.internalUsb), 'ensureConnected');
    final List<PrinterResult<PrintDelivery>> r = await Future.wait(<Future<PrinterResult<PrintDelivery>>>[
      c.usb.printReceipt(fullReceipt('IU9 bersamaan')),
      c.usb.printReceipt(fullReceipt('IU9 tidak boleh')),
    ]);
    final int ok = r.where((e) => e.isOk).length;
    check(ok == 1, 'cetak bersamaan ok=$ok (seharusnya 1)');
    await c.usb.disconnect();
    check(!await c.usb.isConnected(), 'isConnected() masih true setelah disconnect');
    final PrinterFailure f = expectErr(await c.usb.printReceipt(fullReceipt('tidak boleh')), 'cetak tanpa koneksi');
    unwrap(await c.usb.ensureConnected(lastDevice: Ctx.internalUsb), 'ensureConnected pulih');
    unwrap(await c.usb.printReceipt(fullReceipt('IU9 pulih')), 'cetak setelah pulih');
    return 'saat putus: "${f.message}"; periksa 2 struk: "IU9 bersamaan" dan "IU9 pulih"';
  }, prints: true, timeout: const Duration(seconds: 120)),
  TestCase('builtin', 'VB1', 'Bluetooth virtual: struk mini (< 4 KB)', (c) async {
    final PrinterDevice t = await c.requireTarget();
    unwrap(await c.bt.ensureConnected(lastDevice: t), 'ensureConnected');
    final Receipt mini = Receipt(lines: <ReceiptLine>[
      const ReceiptCenter('VB1 VIRTUAL MINI', emphasized: true),
    ]);
    final List<int> png = await c.bt.preview(mini);
    final PrintDelivery d = unwrap(await c.bt.printReceipt(mini), 'printReceipt');
    return 'delivery=${d.name}, preview ${png.length} B — periksa apakah "VB1" keluar';
  }, prints: true),

  // ===== Printer LAN sungguhan (butuh alamat di kolom LAN) ==================
  TestCase('reallan', 'RL1', 'connect() ke printer LAN + isConnected()', (c) async {
    final PrinterDevice d = c.realLanDevice;
    final Stopwatch w = Stopwatch()..start();
    unwrap(await c.realLan.connect(d), 'connect ${d.macAddress}');
    check(await c.realLan.isConnected(), 'isConnected() false setelah connect');
    return '${d.macAddress} tersambung ${w.elapsedMilliseconds} ms';
  }),
  TestCase('reallan', 'RL2', 'checkStatus() menjawab dari printer asli', (c) async {
    unwrap(await c.realLan.ensureConnected(lastDevice: c.realLanDevice), 'ensureConnected');
    final Stopwatch w = Stopwatch()..start();
    final PrinterStatus s = unwrap(await c.realLan.checkStatus(), 'checkStatus');
    throw Info('${describe(s)} (${w.elapsedMilliseconds} ms)');
  }),
  TestCase('reallan', 'RL3', 'capabilities() setelah koneksi', (c) async {
    unwrap(await c.realLan.ensureConnected(lastDevice: c.realLanDevice), 'ensureConnected');
    throw Info(describeCaps(await c.realLan.capabilities()));
  }),
  TestCase('reallan', 'RL4', 'preview(): PNG valid', (c) async {
    final List<int> png = await c.realLan.preview(fullReceipt('RL4'));
    check(png.length > 100 && png[0] == 0x89 && png[1] == 0x50, 'bukan PNG valid');
    return '${png.length} B';
  }),
  TestCase('reallan', 'RL5', 'printReceipt(): struk lengkap', (c) async {
    unwrap(await c.realLan.ensureConnected(lastDevice: c.realLanDevice), 'ensureConnected');
    final Stopwatch w = Stopwatch()..start();
    final PrintDelivery d = unwrap(await c.realLan.printReceipt(fullReceipt('RL5 LAN nyata')), 'printReceipt');
    final PrinterCapabilities caps = await c.realLan.capabilities();
    return 'delivery=${d.name}, ${w.elapsedMilliseconds} ms; ${describeCaps(caps)}';
  }, prints: true, timeout: const Duration(seconds: 90)),
  TestCase('reallan', 'RL6', 'QR: pendek, panjang, unicode', (c) async {
    unwrap(await c.realLan.ensureConnected(lastDevice: c.realLanDevice), 'ensureConnected');
    final String long = List<String>.generate(180, (i) => String.fromCharCode(97 + i % 26)).join();
    unwrap(await c.realLan.printReceipt(Receipt(lines: <ReceiptLine>[
      const ReceiptCenter('RL6 QR', emphasized: true),
      const ReceiptQr('A'),
      ReceiptQr(long),
      const ReceiptQr('Parkir ÅÉ 駐車場 ✓'),
      const ReceiptCenter('3 QR: A / 180 huruf / unicode'),
    ])), 'printReceipt');
    return 'periksa 3 QR bisa dipindai';
  }, prints: true, timeout: const Duration(seconds: 90)),
  TestCase('reallan', 'RL7', 'Struk panjang 120 baris', (c) async {
    unwrap(await c.realLan.ensureConnected(lastDevice: c.realLanDevice), 'ensureConnected');
    final Stopwatch w = Stopwatch()..start();
    unwrap(await c.realLan.printReceipt(longReceipt(120)), 'printReceipt');
    return '${w.elapsedMilliseconds} ms — periksa 120 baris utuh';
  }, prints: true, timeout: const Duration(seconds: 120)),
  TestCase('reallan', 'RL8', 'Lebar kertas 58 / 80 / otomatis', (c) async {
    unwrap(await c.realLan.ensureConnected(lastDevice: c.realLanDevice), 'ensureConnected');
    final List<String> rows = <String>[];
    try {
      for (final PaperWidthSetting setting in PaperWidthSetting.values) {
        c.realLan.setPaperWidth(setting);
        final int px = (await c.realLan.capabilities()).paperWidthPx;
        unwrap(await c.realLan.printReceipt(fullReceipt('RL8 ${setting.name} ${px}px')), 'print ${setting.name}');
        rows.add('${setting.name}=${px}px');
      }
    } finally {
      c.realLan.setPaperWidth(PaperWidthSetting.auto);
    }
    return '${rows.join(', ')} — periksa lebar tiap struk';
  }, prints: true, timeout: const Duration(seconds: 120)),
  TestCase('reallan', 'RL9', 'Cetak bersamaan: satu OK, satu ditolak busy', (c) async {
    unwrap(await c.realLan.ensureConnected(lastDevice: c.realLanDevice), 'ensureConnected');
    final List<PrinterResult<PrintDelivery>> r = await Future.wait(<Future<PrinterResult<PrintDelivery>>>[
      c.realLan.printReceipt(fullReceipt('RL9 pertama')),
      c.realLan.printReceipt(fullReceipt('RL9 kedua')),
    ]);
    final int ok = r.where((e) => e.isOk).length;
    check(ok == 1, 'ok=$ok (seharusnya 1)');
    return 'satu struk tercetak, satu ditolak';
  }, prints: true, timeout: const Duration(seconds: 90)),
  TestCase('reallan', 'RL10', 'Tiga cetakan beruntun', (c) async {
    unwrap(await c.realLan.ensureConnected(lastDevice: c.realLanDevice), 'ensureConnected');
    final List<int> ms = <int>[];
    for (int i = 1; i <= 3; i++) {
      final Stopwatch w = Stopwatch()..start();
      unwrap(await c.realLan.printReceipt(fullReceipt('RL10 #$i')), 'cetak #$i');
      ms.add(w.elapsedMilliseconds);
    }
    return 'waktu: ${ms.join(' / ')} ms';
  }, prints: true, timeout: const Duration(seconds: 120)),
  TestCase('reallan', 'RL11', 'disconnect → cetak Err → ensureConnected pulih → cetak OK', (c) async {
    await c.realLan.disconnect();
    check(!await c.realLan.isConnected(), 'isConnected() masih true');
    final PrinterFailure f = expectErr(await c.realLan.printReceipt(fullReceipt('tidak boleh')), 'cetak tanpa koneksi');
    unwrap(await c.realLan.ensureConnected(lastDevice: c.realLanDevice), 'ensureConnected');
    unwrap(await c.realLan.printReceipt(fullReceipt('RL11 pulih')), 'cetak setelah pulih');
    return 'saat putus: "${f.message}"; setelah pulih tercetak (periksa hanya satu struk RL11)';
  }, prints: true, timeout: const Duration(seconds: 90)),
  TestCase('reallan', 'RL12', 'Alamat printer salah (host sama, port tertutup) → Err cepat', (c) async {
    final PrinterBackend b = createPrinterBackend(PrinterVendor.lan);
    final String host = c.lanHostOnly.isEmpty ? c.lanHost : c.lanHostOnly;
    if (host.isEmpty) throw Skip('isi alamat printer LAN di kolom LAN');
    final Stopwatch w = Stopwatch()..start();
    final PrinterFailure f = expectErr(
      await b.connect(PrinterDevice(name: 'x', macAddress: '$host:9')),
      'connect port tertutup',
    );
    return '${w.elapsedMilliseconds} ms: ${f.message}';
  }, timeout: const Duration(seconds: 30)),

  // ===== USB (tanpa perangkat USB) =========================================
  TestCase('usb', 'U1', 'Backend USB: tanpa perangkat tidak melempar', (c) async {
    final PrinterBackend b = createPrinterBackend(PrinterVendor.usb);
    final bool available = await b.isAvailable();
    final List<PrinterDevice> devices = await b.discoverDevices();
    final String connect = (await b.connect(
      const PrinterDevice(name: 'USB palsu', macAddress: 'usb:1:2'),
    )).fold(onOk: (_) => 'OK', onErr: (f) => 'Err("${f.message}")');
    await b.disconnect();
    return 'available=$available, devices=${devices.length}, connect palsu=$connect';
  }),

  // ===== API lama (kompatibilitas mundur) ==================================
  TestCase('legacy', 'H1', 'BlueThermalPrinter.instance: isOn + getBondedDevices', (c) async {
    final legacy.BlueThermalPrinter p = legacy.BlueThermalPrinter.instance;
    check(await p.isOn == true, 'isOn bukan true');
    final List<legacy.BluetoothDevice> devices = await p.getBondedDevices();
    return 'ter-pairing: ${devices.map((d) => '${d.name}/${d.address}').join(', ')}';
  }),
];

Future<String?> _lanPrint(
  Ctx c,
  int port, {
  required bool expectOk,
  required String label,
  String? expectMessage,
}) async {
  if (c.lanHost.isEmpty) throw Skip('isi alamat PC (host) di kolom LAN');
  final PrinterBackend b = createPrinterBackend(PrinterVendor.lan);
  final int actualPort = c.lanBasePort + (port - 9100);
  final PrinterDevice device =
      PrinterDevice(name: 'PC-$actualPort', macAddress: '${c.lanHostOnly}:$actualPort');
  try {
    unwrap(await b.connect(device), 'connect ke ${device.macAddress}');
    final PrinterResult<PrintDelivery> r = await b.printReceipt(fullReceipt(label));
    if (expectOk) {
      final PrintDelivery d = unwrap(r, 'printReceipt');
      return 'delivery=${d.name} ke ${device.macAddress}';
    }
    final PrinterFailure f = expectErr(r, 'printReceipt');
    if (expectMessage != null) {
      check(f.message == expectMessage, 'pesan="${f.message}", seharusnya "$expectMessage"');
    }
    return 'ditolak: "${f.message}"';
  } finally {
    await b.disconnect();
  }
}

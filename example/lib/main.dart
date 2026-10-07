import 'package:flutter/material.dart';

import 'harness.dart';

void main() => runApp(const HarnessApp());

class HarnessApp extends StatelessWidget {
  const HarnessApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Uji Plugin Printer',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFF5A623),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const HarnessPage(),
    );
  }
}

class HarnessPage extends StatefulWidget {
  const HarnessPage({super.key});

  @override
  State<HarnessPage> createState() => _HarnessPageState();
}

class _HarnessPageState extends State<HarnessPage> {
  final Ctx _ctx = Ctx();
  final Map<String, Outcome> _results = <String, Outcome>{};
  final TextEditingController _btController = TextEditingController();
  final TextEditingController _lanController = TextEditingController();
  String? _running;
  bool _batchRunning = false;

  @override
  void dispose() {
    _btController.dispose();
    _lanController.dispose();
    super.dispose();
  }

  Future<void> _run(List<TestCase> tests, {required String label}) async {
    if (_batchRunning) return;
    _ctx
      ..btAddress = _btController.text.trim()
      ..lanHost = _lanController.text.trim()
      ..target = null;
    setState(() => _batchRunning = true);
    // ignore: avoid_print
    print('HARNESS|BATCH|$label|START|0ms|${tests.length} kasus');
    for (final TestCase test in tests) {
      if (!mounted) return;
      setState(() => _running = test.id);
      final Outcome outcome = await runCase(test, _ctx);
      if (!mounted) return;
      setState(() => _results[test.id] = outcome);
    }
    final Iterable<Outcome> done = tests
        .map((t) => _results[t.id])
        .whereType<Outcome>();
    int count(Verdict v) => done.where((o) => o.verdict == v).length;
    // ignore: avoid_print
    print('HARNESS|BATCH|$label|SUMMARY|0ms|pass=${count(Verdict.pass)} '
        'fail=${count(Verdict.fail)} skip=${count(Verdict.skip)} info=${count(Verdict.info)}');
    setState(() {
      _running = null;
      _batchRunning = false;
    });
  }

  List<TestCase> _where(bool Function(TestCase t) test) =>
      allTests.where(test).toList();

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Uji kontrak PrinterBackend')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _btController,
                    decoration: const InputDecoration(
                      labelText: 'MAC printer Bluetooth (kosong = otomatis)',
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _lanController,
                    decoration: const InputDecoration(
                      labelText: 'Host PC untuk uji LAN',
                      isDense: true,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(
                  key: const Key('run-safe'),
                  onPressed: _batchRunning
                      ? null
                      : () => _run(
                            _where((t) =>
                                !t.prints &&
                                !t.disruptive &&
                                t.group != 'lan' &&
                                t.group != 'reallan'),
                            label: 'aman',
                          ),
                  child: const Text('Aman'),
                ),
                FilledButton.tonal(
                  key: const Key('run-print'),
                  onPressed: _batchRunning
                      ? null
                      : () => _run(
                            _where((t) => t.prints && t.group != 'reallan'),
                            label: 'cetak',
                          ),
                  child: const Text('Cetak fisik'),
                ),
                FilledButton.tonal(
                  key: const Key('run-disruptive'),
                  onPressed: _batchRunning
                      ? null
                      : () => _run(_where((t) => t.disruptive),
                          label: 'disruptif'),
                  child: const Text('Disruptif'),
                ),
                FilledButton.tonal(
                  key: const Key('run-lan'),
                  onPressed: _batchRunning
                      ? null
                      : () => _run(_where((t) => t.group == 'lan'),
                          label: 'lan'),
                  child: const Text('LAN'),
                ),
                FilledButton.tonal(
                  key: const Key('run-reallan'),
                  onPressed: _batchRunning
                      ? null
                      : () => _run(_where((t) => t.group == 'reallan'),
                          label: 'reallan'),
                  child: const Text('LAN nyata'),
                ),
                OutlinedButton(
                  key: const Key('clear'),
                  onPressed: _batchRunning
                      ? null
                      : () => setState(_results.clear),
                  child: const Text('Bersihkan'),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.separated(
              itemCount: allTests.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (BuildContext context, int index) {
                final TestCase test = allTests[index];
                final Outcome? outcome = _results[test.id];
                final bool running = _running == test.id;
                final (IconData icon, Color color) = switch (outcome?.verdict) {
                  Verdict.pass => (Icons.check_circle, Colors.green),
                  Verdict.fail => (Icons.cancel, Colors.redAccent),
                  Verdict.skip => (Icons.remove_circle, Colors.grey),
                  Verdict.info => (Icons.info, Colors.lightBlueAccent),
                  null => (Icons.radio_button_unchecked, scheme.outline),
                };
                return ListTile(
                  dense: true,
                  leading: running
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(icon, color: color),
                  title: Text('${test.id} · ${test.title}'),
                  subtitle: Text(
                    [
                      '${test.group}${test.prints ? ' · cetak' : ''}'
                          '${test.disruptive ? ' · disruptif' : ''}',
                      if (outcome != null)
                        '${outcome.elapsed.inMilliseconds} ms — ${outcome.note}',
                    ].join('\n'),
                    maxLines: 6,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: _batchRunning
                      ? null
                      : () => _run(<TestCase>[test], label: test.id),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// `docs/design.md` D6 stage 3: the layer-3 golden routes on the phone. Copies the inputs
// out of the bundle, runs three rounds in a background isolate (as an app
// would route), shows the result and writes it to bench.txt in the app's
// documents for devicectl / adb to pull.
import 'dart:io';
import 'dart:isolate';

import 'package:brouter/bench.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

const _files = ['E120_N20.rd5', 'E120_N25.rd5', 'lookups.dat', 'hiking-mountain.brf', 'trekking.brf'];

void main() => runApp(const MaterialApp(home: BenchPage()));

class BenchPage extends StatefulWidget {
  const BenchPage({super.key});
  @override
  State<BenchPage> createState() => _BenchPageState();
}

class _BenchPageState extends State<BenchPage> {
  final _lines = <String>[];

  @override
  void initState() {
    super.initState();
    _run();
  }

  void _log(String s) {
    // ignore: avoid_print
    print('BENCH $s');
    setState(() => _lines.add(s));
  }

  Future<void> _run() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/brouter');
    await dir.create(recursive: true);
    for (final f in _files) {
      final data = await rootBundle.load('assets/$f');
      await File('${dir.path}/$f').writeAsBytes(data.buffer.asUint8List(), flush: true);
    }
    final routes = await rootBundle.load('assets/routes.tsv.gz');
    final text = String.fromCharCodes(gzip.decode(routes.buffer.asUint8List()));
    _log('device ${Platform.operatingSystem} ${Platform.operatingSystemVersion}');
    final out = await Isolate.run(() {
      final lines = <String>[];
      final all = runBench(parseRoutes(text), dir, 3, lines.add);
      final bad = all.expand((r) => r).where((x) => x.mismatch != null).length;
      lines.add(bad == 0 ? 'all routes identical to Java' : '$bad route runs differ from Java');
      return lines;
    });
    for (final l in out) {
      _log(l);
    }
    await File('${docs.path}/bench.txt').writeAsString('${_lines.join('\n')}\n');
    _log('DONE');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('brouter bench')),
        body: ListView(
          children: [
            for (final l in _lines)
              Text(l, style: TextStyle(fontSize: 11, color: l.contains('MISMATCH') ? Colors.red : null)),
          ],
        ),
      );
}

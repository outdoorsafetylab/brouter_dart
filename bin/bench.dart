// The route benchmark on the host (`docs/design.md` D6): dart compile exe bin/bench.dart
// and run it from the repository root, after golden/gen.sh or dart test has
// put the release inputs in golden/.build/input.
import 'dart:io';

import 'package:brouter/bench.dart';

void main(List<String> args) {
  final rounds = args.isEmpty ? 3 : int.parse(args.first);
  final release = File('golden/data/INPUT').readAsLinesSync().first.split(' ')[1];
  final dir = Directory('golden/.build/input/$release');
  final text = String.fromCharCodes(gzip.decode(File('golden/data/routes.tsv.gz').readAsBytesSync()));
  final all = runBench(parseRoutes(text), dir, rounds, print);
  final bad = all.expand((r) => r).where((x) => x.mismatch != null).length;
  print(bad == 0 ? 'all routes identical to Java' : '$bad route runs differ from Java');
  exit(bad == 0 ? 0 : 1);
}

// The comparator of lib/bench.dart (`docs/design.md`, Verification: a comparison tool must turn
// red on a mutation): a golden route passes, and each kind of tampering
// with its expected answer is reported.
import 'dart:io';

import 'package:brouter/bench.dart';
import 'package:test/test.dart';

import 'golden.dart';

RouteCase _copy(RouteCase c, {List<String>? result, List<String>? nodes}) {
  final n = RouteCase(c.name, c.profile, c.coords, result ?? c.result);
  n.nodes.addAll(nodes ?? c.nodes);
  return n;
}

void main() {
  final dir = goldenInput('E120_N20.rd5').parent;
  final text = String.fromCharCodes(gzip.decode(File('golden/data/routes.tsv.gz').readAsBytesSync()));
  final cases = parseRoutes(text);
  final ok = cases.firstWhere((c) => c.name == 'songxue-road' && c.profile == 'hiking-mountain');
  final err = cases.firstWhere((c) => c.result[0] == 'error');

  test('golden routes pass', () {
    expect(runCase(ok, dir).mismatch, isNull);
    expect(runCase(err, dir).mismatch, isNull);
  });

  test('a missing last point is reported', () {
    final c = _copy(ok, nodes: ok.nodes.sublist(0, ok.nodes.length - 1));
    expect(runCase(c, dir).mismatch, contains('points'));
  });

  test('an extra point is reported', () {
    final c = _copy(ok, nodes: [...ok.nodes, ok.nodes.last]);
    expect(runCase(c, dir).mismatch, contains('points'));
  });

  test('a changed point is reported', () {
    final f = ok.nodes[3].split('\t');
    f[3] = '${int.parse(f[3]) + 1}'; // cost
    final c = _copy(ok, nodes: [...ok.nodes.sublist(0, 3), f.join('\t'), ...ok.nodes.sublist(4)]);
    expect(runCase(c, dir).mismatch, startsWith('point 3'));
  });

  test('changed totals are reported', () {
    final r = [...ok.result];
    r[1] = '${int.parse(r[1]) + 1}'; // distance
    expect(runCase(_copy(ok, result: r), dir).mismatch, startsWith('totals'));
  });

  test('a different error is reported', () {
    final r = [err.result[0], '${err.result[1]}x'];
    expect(runCase(_copy(err, result: r), dir).mismatch, startsWith('error'));
  });
}

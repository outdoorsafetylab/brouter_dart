// The route benchmark of `docs/design.md` D6 stage 3: the layer-3 golden routes, run on
// whatever this runs on (a Mac, or a phone through bench_app), checked
// point by point against the Java answers and timed.
import 'dart:io';

import 'src/router/router.dart';
import 'src/util/float32.dart';

/// One golden route case (golden/FORMAT.md, "Route table").
class RouteCase {
  final String name;
  final String profile;
  final List<int> coords; // from ilon, ilat, to ilon, ilat
  final List<String> result; // the route line after the coordinates
  final List<String> nodes = []; // node lines, tab-joined, without "node"
  RouteCase(this.name, this.profile, this.coords, this.result);
}

/// Parses the uncompressed routes table.
List<RouteCase> parseRoutes(String text) {
  final out = <RouteCase>[];
  for (final line in text.split('\n')) {
    if (line.isEmpty) continue;
    final r = line.split('\t');
    if (r[0] == 'route') {
      out.add(RouteCase(r[1], r[2], [for (var i = 3; i < 7; i++) int.parse(r[i])], r.sublist(7)));
    } else {
      out.last.nodes.add(r.sublist(1).join('\t'));
    }
  }
  return out;
}

class RouteRun {
  final RouteCase c;
  final int micros;
  final String? mismatch; // null: identical to Java
  RouteRun(this.c, this.micros, this.mismatch);
}

String _hex8(double f) => floatToRawIntBits(f).toRadixString(16).padLeft(8, '0');

/// Runs [c] with the rd5 files and profiles in [dir]; compares with Java.
RouteRun runCase(RouteCase c, Directory dir) {
  final from = OsmNodeNamed()
    ..name = 'from'
    ..ilon = c.coords[0]
    ..ilat = c.coords[1];
  final to = OsmNodeNamed()
    ..name = 'to'
    ..ilon = c.coords[2]
    ..ilat = c.coords[3];
  final rc = RoutingContext()..localFunction = '${dir.path}${Platform.pathSeparator}${c.profile}.brf';
  final sw = Stopwatch()..start();
  final re = RoutingEngine(dir, [from, to], rc);
  re.doRun();
  sw.stop();
  String? mismatch;
  if (c.result[0] == 'error') {
    if (re.getErrorMessage() != c.result[1]) mismatch = 'error "${re.getErrorMessage()}"';
  } else if (re.getErrorMessage() != null) {
    mismatch = 'error "${re.getErrorMessage()}"';
  } else {
    final t = re.getFoundTrack()!;
    final got = ['ok', t.distance, t.ascend, t.plainAscend, t.cost, t.energy, t.getTotalSeconds(), t.nodes.length]
        .join('\t');
    for (var i = 0; i < t.nodes.length && i < c.nodes.length && mismatch == null; i++) {
      final e = t.nodes[i];
      final p = [e.getILon(), e.getILat(), e.getSElev(), e.cost, _hex8(e.getTime()), _hex8(e.getEnergy())].join('\t');
      if (p != c.nodes[i]) mismatch = 'point $i: $p, want ${c.nodes[i]}';
    }
    if (mismatch == null && t.nodes.length != c.nodes.length) {
      mismatch = '${t.nodes.length} points, the table has ${c.nodes.length}';
    }
    if (mismatch == null && got != c.result.join('\t')) mismatch = 'totals $got, want ${c.result.join('\t')}';
  }
  return RouteRun(c, sw.elapsedMicroseconds, mismatch);
}

/// [rounds] passes over every case; the first is cold, the rest warm.
/// Peak memory is the process's maximum resident set so far.
List<List<RouteRun>> runBench(List<RouteCase> cases, Directory dir, int rounds, [void Function(String)? log]) {
  final all = <List<RouteRun>>[];
  for (var r = 0; r < rounds; r++) {
    final runs = <RouteRun>[];
    for (final c in cases) {
      final run = runCase(c, dir);
      runs.add(run);
      log?.call('round $r ${c.name} ${c.profile} ${(run.micros / 1000).toStringAsFixed(1)} ms'
          '${run.mismatch == null ? '' : ' MISMATCH ${run.mismatch}'}');
    }
    all.add(runs);
    final total = runs.fold<int>(0, (s, x) => s + x.micros);
    log?.call('round $r total ${(total / 1000).toStringAsFixed(0)} ms,'
        ' peak rss ${(ProcessInfo.maxRss / 1048576).toStringAsFixed(0)} MiB');
  }
  return all;
}

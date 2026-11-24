// Layer 3 of the golden comparison (golden/FORMAT.md, "Route table"): the
// path search against Java v1.7.10, every point of every track.
import 'dart:io';

import 'package:brouter/src/router/router.dart';
import 'package:brouter/src/util/float32.dart';
import 'package:test/test.dart';

import 'golden.dart';

class _Case {
  final String name;
  final String profile;
  final List<int> coords; // from ilon, ilat, to ilon, ilat
  final List<String> result; // after the coordinates
  final List<List<String>> nodes = [];
  _Case(this.name, this.profile, this.coords, this.result);
}

List<_Case> _cases() {
  final out = <_Case>[];
  for (final r in goldenTable('routes.tsv.gz')) {
    if (r[0] == 'route') {
      out.add(_Case(r[1], r[2], [for (var i = 3; i < 7; i++) int.parse(r[i])], r.sublist(7)));
    } else {
      out.last.nodes.add(r.sublist(1));
    }
  }
  return out;
}

String _hex8(double f) => floatToRawIntBits(f).toRadixString(16).padLeft(8, '0');

void main() {
  final cases = _cases();
  final segments = goldenInput('E120_N20.rd5').parent;

  test('the table holds 24 routes', () => expect(cases, hasLength(24)));

  for (final c in cases) {
    test('${c.name} ${c.profile}', () {
      final from = OsmNodeNamed()
        ..name = 'from'
        ..ilon = c.coords[0]
        ..ilat = c.coords[1];
      final to = OsmNodeNamed()
        ..name = 'to'
        ..ilon = c.coords[2]
        ..ilat = c.coords[3];
      final rc = RoutingContext()..localFunction = '${segments.path}${Platform.pathSeparator}${c.profile}.brf';
      final re = RoutingEngine(segments, [from, to], rc);
      re.doRun();

      if (c.result[0] == 'error') {
        expect(re.getErrorMessage(), c.result[1]);
        return;
      }
      expect(re.getErrorMessage(), isNull);
      final t = re.getFoundTrack()!;
      final got = ['ok', t.distance, t.ascend, t.plainAscend, t.cost, t.energy, t.getTotalSeconds(), t.nodes.length]
          .map((e) => '$e')
          .toList();
      final pts = [
        for (final e in t.nodes)
          [
            '${e.getILon()}',
            '${e.getILat()}',
            '${e.getSElev()}',
            '${e.cost}',
            _hex8(e.getTime()),
            _hex8(e.getEnergy()),
          ]
      ];
      // the first point that differs says more than the totals
      for (var i = 0; i < pts.length && i < c.nodes.length; i++) {
        expect(pts[i], c.nodes[i], reason: 'point $i of ${c.nodes.length}');
      }
      expect(got, c.result);
    });
  }
}

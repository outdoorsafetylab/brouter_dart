// maxRunningTime, ported from Java v1.7.10 (RoutingEngine.doRun). The clock is
// a fake that moves a fixed step on every read, so each case is exact.
import 'dart:io';

import 'package:brouter/src/router/router.dart';
import 'package:test/test.dart';

import 'golden.dart';

void main() {
  final segments = goldenInput('E120_N20.rd5').parent;

  // The longest successful route in the table: its searches loop long enough
  // for every limit below.
  final route = goldenTable('routes.tsv.gz')
      .where((r) => r[0] == 'route' && r[7] == 'ok' && r[2] == 'hiking-mountain')
      .reduce((a, b) => int.parse(a[8]) >= int.parse(b[8]) ? a : b);

  RoutingEngine engine(int Function() clock) {
    final from = OsmNodeNamed()
      ..name = 'from'
      ..ilon = int.parse(route[3])
      ..ilat = int.parse(route[4]);
    final to = OsmNodeNamed()
      ..name = 'to'
      ..ilon = int.parse(route[5])
      ..ilat = int.parse(route[6]);
    final rc = RoutingContext()..localFunction = '${segments.path}${Platform.pathSeparator}${route[2]}.brf';
    return RoutingEngine(segments, [from, to], rc, clock: clock);
  }

  int Function() stepping(int step, [void Function()? onRead]) {
    var now = 0;
    return () {
      onRead?.call();
      return now += step;
    };
  }

  test('without a limit the clock is never compared', () {
    final re = engine(stepping(1 << 40));
    re.doRun();
    expect(re.getErrorMessage(), isNull);
    expect('${re.getFoundTrack()!.distance}', route[8]);
  });

  test('a limit stops the search with the Java message, in whole seconds', () {
    final re = engine(stepping(1000));
    re.doRun(15500);
    // every route starts with the target island check, as in Java
    expect(re.getErrorMessage(), 'target-island-check timeout after 15 seconds');
    expect(re.getFoundTrack()!.nodes, isEmpty);
  });

  test('re-tracking restarts the clock', () {
    var reads = 0;
    final unlimited = engine(stepping(1, () => reads++));
    unlimited.doRun(1 << 40);
    expect(unlimited.getErrorMessage(), isNull);

    // Without the restart the last check would see reads - 1 elapsed.
    final re = engine(stepping(1));
    re.doRun(reads - 2);
    expect(re.getErrorMessage(), isNull);
    expect('${re.getFoundTrack()!.distance}', route[8]);
  });
}

# brouter_dart

A Dart port of the routing engine of [BRouter](https://github.com/abrensch/brouter) v1.7.10 (MIT), for offline hiking routes in our Flutter apps. It reads BRouter's own `rd5` segment files and `.brf` profiles, and every layer is checked bit for bit against the Java engine of the same version.

- Design: `docs/design.md`
- Reference data and its format: `golden/` (`golden/FORMAT.md`)

```shell
dart pub get
dart analyze
dart test            # compares the port with golden/data
golden/gen.sh        # only to regenerate golden/data (needs Java and gh)
```

The tests also read the tiles and profiles of the release named in `golden/data/INPUT`; the first run downloads them with `gh` into `golden/.build/input`.

## Use

```dart
import 'dart:io';

import 'package:brouter/brouter.dart';

void main() {
  // The rd5 segments, lookups.dat and the .brf profiles, in one directory.
  final dir = Directory('segments');
  verifyLookups(dir); // throws if a segment does not match lookups.dat

  OsmNodeNamed point(String name, double lon, double lat) => OsmNodeNamed()
    ..name = name
    ..ilon = ((lon + 180) * 1e6 + 0.5).toInt()
    ..ilat = ((lat + 90) * 1e6 + 0.5).toInt();

  final rc = RoutingContext()..localFunction = '${dir.path}/hiking-mountain.brf';
  final engine = RoutingEngine(dir, [point('from', 121.5418, 25.1660), point('to', 121.5486, 25.1713)], rc)
    ..doRun(15000); // milliseconds; 0 or nothing for no limit
  final error = engine.getErrorMessage();
  if (error != null) {
    print(error); // for example "from-position not mapped in existing datafile"
    return;
  }
  final track = engine.getFoundTrack()!;
  print('${track.distance} m, ${track.ascend} m up, ${track.nodes.length} points');
}
```

The engine works synchronously; run it in an isolate of your own. `package:brouter/brouter.dart` is the public library; everything under `lib/src` may change.

Pure Dart, no Flutter dependency. Android, iOS and macOS; not the web (the decoder needs 64-bit integer bit operations). Each file under `lib/src` names the Java class it was ported from.

| Layer | Java modules | Dart | Status |
|---|---|---|---|
| 0 | util | `lib/src/util` | done |
| 1 | codec, mapaccess | `lib/src/codec`, `lib/src/mapaccess` | done |
| 2 | expressions | `lib/src/expressions` | done |
| 3 | core | `lib/src/router` | done (StdModel profiles) |

The route benchmark (`docs/design.md` D6): `dart compile exe bin/bench.dart` for the host, `bench_app/` for phones; `golden/src/Golden.java bench` times the Java engine on the same routes.

Not ported from util: `CompactLongMap` (mapaccess only puts and gets, so a `Map<int, V>` behaves the same), and the classes only the map creator, the server or core use (core brings its own when it is ported).

## Data attribution

The rd5 segments in `golden/data` and in the release assets are derived from OpenStreetMap: © OpenStreetMap contributors, under the [Open Database License 1.0](https://opendatacommons.org/licenses/odbl/1-0/). The rd5 files are produced by [brouter.de](https://brouter.de/). The code is MIT (`LICENSE`).

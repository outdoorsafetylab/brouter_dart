# golden

The reference side of the port (`docs/design.md`, D4 and D5): BRouter v1.7.10 built from source with its `Math.cos/sin/exp/atan2` calls switched to `StrictMath`, and a small Java program that writes what the Dart port must reproduce.

```shell
golden/gen.sh   # builds the engine, downloads the fixed inputs, rewrites golden/data
```

Needs Java 17 or later and an authenticated `gh`. The output is deterministic: running it twice gives the same bytes. `FORMAT.md` describes every file in `data/`.

Layers: 0 (util), 1 (decode), 2 (rules) and 3 (routes, cases in `routes.tsv`).

## Data attribution

The rd5 segments in `golden/data` and in the release assets are derived from OpenStreetMap: © OpenStreetMap contributors, under the [Open Database License 1.0](https://opendatacommons.org/licenses/odbl/1-0/). The rd5 files are produced by [brouter.de](https://brouter.de/). The code is MIT (`LICENSE`).
